package exiron

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestQuarantineRetainsOriginalMessageAndExplicitRecovery(t *testing.T) {
	q, _ := NewQuarantine(QuarantineOptions{MaxMessages: 2})
	c, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	caption := "original caption"
	message := Message{ReqID: "failed", Datatype: DatatypeText, Data: []byte("original"), Caption: &caption,
		MediaItems: []MediaItem{{Data: []byte("media")}}}
	r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerFailurePolicy: HandlerFailureQuarantine, Quarantine: q,
		Handler: func(_ context.Context, m Message) error {
			m.Data[0] = 'X'
			*m.Caption = "changed"
			m.MediaItems[0].Data[0] = 'X'
			return errors.New("private-error")
		}})
	if err := r.handleBatch(context.Background(), []Message{message}); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(fmt.Sprintf("%+v/%#v", q, q), "original") {
		t.Fatal("store formatting exposed payload")
	}
	entries := q.Entries()
	if len(entries) != 1 || entries[0].Attempts != 1 || q.Stats().Bytes <= 0 {
		t.Fatal(entries, q.Stats())
	}
	id := entries[0].ID
	check := func(_ context.Context, m Message) error {
		if string(m.Data) != "original" || *m.Caption != "original caption" || string(m.MediaItems[0].Data) != "media" {
			t.Errorf("mutated recovery payload: %+v", m)
		}
		m.Data[0] = 'Y'
		return errors.New("retry later")
	}
	if err := q.Recover(context.Background(), id, check); err == nil {
		t.Fatal("recovery must retain failure")
	}
	if q.Stats().Count != 1 || q.Stats().Recovering != 0 {
		t.Fatal(q.Stats())
	}
	if err := q.Recover(context.Background(), id, func(ctx context.Context, m Message) error { _ = check(ctx, m); return nil }); err != nil {
		t.Fatal(err)
	}
	if q.Stats().Count != 0 || q.Stats().Bytes != 0 {
		t.Fatal(q.Stats())
	}
	if err := q.Recover(context.Background(), id, check); !errors.Is(err, ErrQuarantineNotFound) {
		t.Fatal(err)
	}
}

func TestQuarantineContinuesSerialConcurrentAndOrderedBatches(t *testing.T) {
	for _, concurrency := range []int{1, 3} {
		for _, ordered := range []bool{false, true} {
			t.Run(fmt.Sprintf("%d/%t", concurrency, ordered), func(t *testing.T) {
				q, _ := NewQuarantine(QuarantineOptions{})
				c, _ := NewClient(Config{BaseURL: "http://exiron.test"})
				var failures, healthy, notified atomic.Int32
				r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerFailurePolicy: HandlerFailureQuarantine, Quarantine: q,
					HandlerConcurrency: concurrency, HandlerOrderByChat: ordered, HandlerMaxAttempts: 2,
					Handler: func(_ context.Context, m Message) error {
						if m.ReqID == "bad" {
							failures.Add(1)
							return errors.New("private-error")
						}
						healthy.Add(1)
						return nil
					},
					OnQuarantined: func(_ context.Context, entry QuarantineEntry) {
						notified.Add(1)
						if q.Stats().Count != 1 || entry.RequestID != "bad" {
							t.Error(entry)
						}
					}})
				r.handlerWait = func(context.Context, time.Duration) error { return nil }
				messages := []Message{{ReqID: "bad", ServiceID: 1, ChatID: 1}, {ReqID: "good-1", ServiceID: 1, ChatID: 1}, {ReqID: "good-2", ServiceID: 1, ChatID: 2}}
				if err := r.handleBatch(context.Background(), messages); err != nil {
					t.Fatal(err)
				}
				s := r.Status()
				if failures.Load() != 2 || healthy.Load() != 2 || notified.Load() != 1 || s.BatchQuarantined != 1 || s.BatchCompleted != 3 || s.Quarantine.Count != 1 {
					t.Fatal(failures.Load(), healthy.Load(), notified.Load(), s)
				}
				encoded, _ := json.Marshal(s)
				if strings.Contains(string(encoded), "private-error") || strings.Contains(string(encoded), "bad") {
					t.Fatal(string(encoded))
				}
			})
		}
	}
}

func TestQuarantineCapacityNeverEvictsAndStopsDispatch(t *testing.T) {
	c, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	q, _ := NewQuarantine(QuarantineOptions{MaxMessages: 1})
	r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerFailurePolicy: HandlerFailureQuarantine, Quarantine: q, Handler: func(context.Context, Message) error { return errors.New("failed") }})
	if err := r.handleBatch(context.Background(), []Message{{ReqID: "first"}, {ReqID: "second"}, {ReqID: "third"}}); !errors.Is(err, ErrQuarantineFull) {
		t.Fatal(err)
	}
	if entries := q.Entries(); len(entries) != 1 || entries[0].RequestID != "first" {
		t.Fatal(entries)
	}
	// A new runner shares the retained store; successful work can still proceed.
	healthy := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerFailurePolicy: HandlerFailureQuarantine, Quarantine: q, Handler: func(context.Context, Message) error { return nil }})
	if err := healthy.handleBatch(context.Background(), []Message{{ReqID: "healthy"}}); err != nil {
		t.Fatal(err)
	}
	size := q.Stats().Bytes
	small, _ := NewQuarantine(QuarantineOptions{MaxBytes: size - 1})
	r.quarantine = small
	if err := r.handleBatch(context.Background(), []Message{{ReqID: "first"}}); !errors.Is(err, ErrQuarantineFull) {
		t.Fatal(err)
	}
	if small.Stats().Count != 0 || small.Stats().Bytes != 0 {
		t.Fatal(small.Stats())
	}
}

func TestQuarantineRecoveryClaimsRetainCapacityAndReleaseOnPanicOrCancellation(t *testing.T) {
	c, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	q, _ := NewQuarantine(QuarantineOptions{MaxMessages: 1})
	r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerFailurePolicy: HandlerFailureQuarantine, Quarantine: q, Handler: func(context.Context, Message) error { return errors.New("failed") }})
	_ = r.handleBatch(context.Background(), []Message{{ReqID: "bad"}})
	id := q.Entries()[0].ID
	entered, release := make(chan struct{}), make(chan struct{})
	done := make(chan error, 1)
	go func() {
		done <- q.Recover(context.Background(), id, func(context.Context, Message) error { close(entered); <-release; return errors.New("keep") })
	}()
	awaitSignal(t, entered)
	if q.Stats().Recovering != 1 || q.Stats().Count != 1 {
		t.Fatal(q.Stats())
	}
	if err := q.Recover(context.Background(), id, func(context.Context, Message) error { return nil }); !errors.Is(err, ErrQuarantineBusy) {
		t.Fatal(err)
	}
	if err := r.handleBatch(context.Background(), []Message{{ReqID: "another"}}); !errors.Is(err, ErrQuarantineFull) {
		t.Fatal(err)
	}
	close(release)
	_ = awaitError(t, done)
	func() {
		defer func() {
			if recover() == nil {
				t.Error("panic was swallowed")
			}
		}()
		_ = q.Recover(context.Background(), id, func(context.Context, Message) error { panic("recovery panic") })
	}()
	if q.Stats().Recovering != 0 || q.Stats().Count != 1 {
		t.Fatal(q.Stats())
	}
	ctx, cancel := context.WithCancel(context.Background())
	if err := q.Recover(ctx, id, func(context.Context, Message) error { cancel(); return nil }); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if q.Stats().Count != 1 {
		t.Fatal(q.Stats())
	}
}

func TestQuarantineIsOptInAndNeverConvertsLeaseLossOrCancellation(t *testing.T) {
	c, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	q, _ := NewQuarantine(QuarantineOptions{})
	failure := errors.New("handler failure")
	stopped := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, Quarantine: q, Handler: func(context.Context, Message) error { return failure }})
	if err := stopped.handleBatch(context.Background(), []Message{{ReqID: "bad"}}); !errors.Is(err, failure) {
		t.Fatal(err)
	}
	for _, err := range []error{ErrClientLeaseLost, context.Canceled} {
		ctx, cancel := context.WithCancel(context.Background())
		r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerFailurePolicy: HandlerFailureQuarantine, Quarantine: q, Handler: func(context.Context, Message) error {
			if errors.Is(err, context.Canceled) {
				cancel()
			}
			return err
		}})
		if result := r.handleBatch(ctx, []Message{{ReqID: "bad"}}); result == nil {
			t.Fatal("converted control failure to success")
		}
		cancel()
	}
	if q.Stats().Count != 0 {
		t.Fatal(q.Stats())
	}
	for _, opts := range []RunnerOptions{{HandlerFailurePolicy: "unknown"}, {HandlerFailurePolicy: HandlerFailureQuarantine}, {HandlerFailurePolicy: HandlerFailureQuarantine, Quarantine: &Quarantine{}}} {
		opts.Handler = func(context.Context, Message) error { return nil }
		if err := c.NewRunner(opts).Run(context.Background()); err == nil {
			t.Fatal("accepted invalid policy/store")
		}
	}
	if _, err := NewQuarantine(QuarantineOptions{MaxBytes: -1}); err == nil {
		t.Fatal("accepted invalid limits")
	}
}

func TestQuarantineAcknowledgesHTTPAndWebSocketOnlyAfterHealthyHandlersFinish(t *testing.T) {
	for _, transport := range []Transport{TransportHTTP, TransportWebSocket} {
		t.Run(fmt.Sprint(transport), func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			entered, release, retained := make(chan struct{}), make(chan struct{}), make(chan struct{})
			acked := make(chan struct{}, 1)
			var replies atomic.Int32
			batch := `{"delivery_id":"batch","requests":[{"req_id":"bad","msgtype":"request","datatype":"text","data":"eA=="},{"req_id":"good","msgtype":"request","datatype":"text","data":"eA=="}]}`
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				switch req.URL.Path {
				case "/api/requests":
					if req.URL.Query().Get("delivery_ack") == "batch" {
						acked <- struct{}{}
						cancel()
						_, _ = w.Write([]byte(`{"requests":[]}`))
						return
					}
					_, _ = w.Write([]byte(batch))
				case "/api/responses":
					replies.Add(1)
					_, _ = w.Write([]byte(`{"ok":true}`))
				case "/api/socket":
					conn, err := (&websocket.Upgrader{}).Upgrade(w, req, nil)
					if err != nil {
						return
					}
					defer conn.Close()
					_ = conn.WriteMessage(websocket.TextMessage, contractFixture(t, "websocket_connected_frame.json"))
					var wire struct {
						DeliveryID string            `json:"delivery_id"`
						Requests   []json.RawMessage `json:"requests"`
					}
					_ = json.Unmarshal([]byte(batch), &wire)
					_ = conn.WriteJSON(map[string]any{"type": "messages", "delivery_id": wire.DeliveryID, "messages": wire.Requests})
					for {
						var frame map[string]any
						if conn.ReadJSON(&frame) != nil {
							return
						}
						if frame["type"] == "ack" {
							acked <- struct{}{}
							cancel()
							return
						}
						if frame["type"] == "ping" {
							_ = conn.WriteJSON(map[string]string{"type": "pong"})
						}
					}
				default:
					t.Error(req.URL.Path)
				}
			}))
			defer server.Close()
			c, _ := NewClient(Config{BaseURL: server.URL, Token: "token", Transport: transport})
			q, _ := NewQuarantine(QuarantineOptions{})
			r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, PollInterval: time.Millisecond, HandlerFailurePolicy: HandlerFailureQuarantine, Quarantine: q, OnQuarantined: func(context.Context, QuarantineEntry) { close(retained) }, Handler: func(handlerCtx context.Context, m Message) error {
				if m.ReqID == "bad" {
					return errors.New("poison")
				}
				close(entered)
				select {
				case <-release:
				case <-handlerCtx.Done():
					return handlerCtx.Err()
				}
				if _, err := c.UpdateText(handlerCtx, m.ReqID, "partial"); err != nil {
					return err
				}
				_, err := c.ReplyText(handlerCtx, m.ReqID, "done")
				return err
			}})
			done := make(chan error, 1)
			go func() { done <- r.Run(ctx) }()
			awaitSignal(t, entered)
			awaitSignal(t, retained)
			select {
			case <-acked:
				t.Fatal("acknowledged unfinished sibling")
			default:
			}
			close(release)
			awaitSignal(t, acked)
			_ = awaitError(t, done)
			if q.Stats().Count != 1 || replies.Load() != 2 {
				t.Fatal(q.Stats(), replies.Load())
			}
		})
	}
}

func TestConcurrentQuarantineProducersRespectCountAndByteLimits(t *testing.T) {
	c, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	q, _ := NewQuarantine(QuarantineOptions{MaxMessages: 3})
	messages := make([]Message, 30)
	for i := range messages {
		messages[i] = Message{ReqID: "bad", Data: []byte("payload")}
	}
	opts := RunnerOptions{DisableRuntimeReporting: true, HandlerFailurePolicy: HandlerFailureQuarantine, Quarantine: q, HandlerConcurrency: 8, Handler: func(context.Context, Message) error { return errors.New("failed") }}
	if err := c.NewRunner(opts).handleBatch(context.Background(), messages); !errors.Is(err, ErrQuarantineFull) {
		t.Fatal(err)
	}
	if q.Stats().Count != 3 {
		t.Fatal(q.Stats())
	}
	small, _ := NewQuarantine(QuarantineOptions{MaxBytes: q.Stats().Bytes / 3 * 2})
	opts.Quarantine = small
	if err := c.NewRunner(opts).handleBatch(context.Background(), messages); !errors.Is(err, ErrQuarantineFull) {
		t.Fatal(err)
	}
	if stats := small.Stats(); stats.Count != 2 || stats.Bytes > stats.MaxBytes {
		t.Fatal(stats)
	}
}
