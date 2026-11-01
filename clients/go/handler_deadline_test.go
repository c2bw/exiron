package exiron

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/gorilla/websocket"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestHandlerDeadlineKeepsUncooperativeSlotAndNeverQuarantinesLateSuccess(t *testing.T) {
	c, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	q, _ := NewQuarantine(QuarantineOptions{})
	expired, release := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerTimeout: 30 * time.Millisecond, Quarantine: q, HandlerFailurePolicy: HandlerFailureQuarantine, Handler: func(ctx context.Context, _ Message) error {
		calls.Add(1)
		if _, ok := ctx.Deadline(); !ok {
			t.Error("handler has no deadline")
		}
		<-ctx.Done()
		if !errors.Is(context.Cause(ctx), ErrHandlerDeadlineExceeded) {
			t.Error(context.Cause(ctx))
		}
		close(expired)
		<-release
		return nil
	}})
	done := make(chan error, 1)
	go func() { done <- r.handleBatch(context.Background(), []Message{{ReqID: "stuck"}, {ReqID: "queued"}}) }()
	awaitSignal(t, expired)
	if s := r.Status(); s.ActiveHandlers != 1 || s.OverdueHandlers != 1 || s.HandlerTimeout != 30*time.Millisecond || s.BatchCompleted != 0 {
		t.Fatal(s)
	}
	select {
	case err := <-done:
		t.Fatalf("returned before handler stopped: %v", err)
	default:
	}
	close(release)
	err := awaitError(t, done)
	if !errors.Is(err, ErrHandlerDeadlineExceeded) || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal(err)
	}
	if calls.Load() != 1 || q.Stats().Count != 0 {
		t.Fatal(calls.Load(), q.Stats())
	}
	if s := r.Status(); s.ActiveHandlers != 0 || s.OverdueHandlers != 0 || s.BatchTimedOut != 1 || s.LastError.Kind != "handler_deadline_exceeded" {
		t.Fatal(s)
	}
}

func TestHandlerDeadlineIncludesRetryWaitAndErrorCallbacks(t *testing.T) {
	c, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	q, _ := NewQuarantine(QuarantineOptions{})
	for _, callbackBlocks := range []bool{false, true} {
		t.Run(fmt.Sprint(callbackBlocks), func(t *testing.T) {
			var calls atomic.Int32
			opts := RunnerOptions{DisableRuntimeReporting: true, HandlerTimeout: 30 * time.Millisecond, HandlerMaxAttempts: 10, HandlerRetryDelay: time.Second, Quarantine: q, HandlerFailurePolicy: HandlerFailureQuarantine, Handler: func(context.Context, Message) error { calls.Add(1); return errors.New("application failure") }}
			if callbackBlocks {
				opts.HandlerMaxAttempts = 1
				opts.OnHandlerError = func(ctx context.Context, _ *HandlerFailure) { <-ctx.Done() }
			}
			r := c.NewRunner(opts)
			if err := r.handleBatch(context.Background(), []Message{{ReqID: "bad"}}); !errors.Is(err, ErrHandlerDeadlineExceeded) {
				t.Fatal(err)
			}
			if calls.Load() != 1 || q.Stats().Count != 0 || r.Status().BatchTimedOut != 1 {
				t.Fatal(calls.Load(), q.Stats(), r.Status())
			}
		})
	}
}

func TestHandlerDeadlineRetainsConcurrentAndOrderedSlots(t *testing.T) {
	for _, ordered := range []bool{false, true} {
		t.Run(fmt.Sprint(ordered), func(t *testing.T) {
			c, _ := NewClient(Config{BaseURL: "http://exiron.test"})
			expired := make(chan string, 2)
			releases := map[string]chan struct{}{"one": make(chan struct{}), "two": make(chan struct{})}
			var queued atomic.Int32
			r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerTimeout: 40 * time.Millisecond, HandlerConcurrency: 2, HandlerOrderByChat: ordered, Handler: func(ctx context.Context, m Message) error {
				release, ok := releases[m.ReqID]
				if !ok {
					queued.Add(1)
					return nil
				}
				<-ctx.Done()
				expired <- m.ReqID
				<-release
				return nil
			}})
			messages := []Message{{ReqID: "one", ServiceID: 1, ChatID: 1}, {ReqID: "two", ServiceID: 1, ChatID: 2}, {ReqID: "queued", ServiceID: 1, ChatID: 3}}
			done := make(chan error, 1)
			go func() { done <- r.handleBatch(context.Background(), messages) }()
			_ = awaitStarted(t, expired)
			_ = awaitStarted(t, expired)
			if s := r.Status(); s.ActiveHandlers != 2 || s.OverdueHandlers != 2 {
				t.Fatal(s)
			}
			close(releases["two"])
			select {
			case err := <-done:
				t.Fatalf("abandoned active sibling: %v", err)
			default:
			}
			if queued.Load() != 0 {
				t.Fatal("dispatched queued work after expiry")
			}
			close(releases["one"])
			if err := awaitError(t, done); !errors.Is(err, ErrHandlerDeadlineExceeded) {
				t.Fatal(err)
			}
			if queued.Load() != 0 || r.Status().BatchTimedOut != 2 {
				t.Fatal(queued.Load(), r.Status())
			}
		})
	}
}

func TestHandlerDeadlineSharesBudgetAcrossSuccessfulRetriesAndCleansContext(t *testing.T) {
	c, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	var first time.Time
	var saved context.Context
	calls := 0
	r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerTimeout: time.Second, HandlerMaxAttempts: 2, Handler: func(ctx context.Context, _ Message) error {
		calls++
		deadline, _ := ctx.Deadline()
		saved = ctx
		if calls == 1 {
			first = deadline
			return errors.New("retry")
		}
		if !deadline.Equal(first) {
			t.Error("budget reset on retry")
		}
		return nil
	}})
	r.handlerWait = func(context.Context, time.Duration) error { return nil }
	if err := r.handleBatch(context.Background(), []Message{{ReqID: "ok"}}); err != nil {
		t.Fatal(err)
	}
	if calls != 2 || r.Status().BatchTimedOut != 0 || r.Status().OverdueHandlers != 0 {
		t.Fatal(calls, r.Status())
	}
	awaitSignal(t, saved.Done())
	if !errors.Is(context.Cause(saved), context.Canceled) {
		t.Fatal(context.Cause(saved))
	}
}

func TestHandlerDeadlineDisabledValidationAndParentCancellation(t *testing.T) {
	c, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, Handler: func(ctx context.Context, _ Message) error {
		if _, ok := ctx.Deadline(); ok {
			t.Error("default added a deadline")
		}
		return nil
	}})
	if err := r.handleBatch(context.Background(), []Message{{}}); err != nil {
		t.Fatal(err)
	}
	bad := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerTimeout: -time.Second, Handler: func(context.Context, Message) error { return nil }})
	if err := bad.Run(context.Background()); err == nil {
		t.Fatal("accepted negative timeout")
	}
	ctx, cancel := context.WithCancel(context.Background())
	entered := make(chan struct{})
	r = c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerTimeout: time.Second, Handler: func(ctx context.Context, _ Message) error { close(entered); <-ctx.Done(); return nil }})
	done := make(chan error, 1)
	go func() { done <- r.handleBatch(ctx, []Message{{}}) }()
	awaitSignal(t, entered)
	cancel()
	if err := awaitError(t, done); !errors.Is(err, context.Canceled) || errors.Is(err, ErrHandlerDeadlineExceeded) {
		t.Fatal(err)
	}
	if r.Status().BatchTimedOut != 0 {
		t.Fatal(r.Status())
	}
}

func TestHandlerDeadlineStopsStreamsWithoutFinalizationOrAcknowledgement(t *testing.T) {
	for _, transport := range []Transport{TransportHTTP, TransportWebSocket} {
		t.Run(fmt.Sprint(transport), func(t *testing.T) {
			var updates, finals, acks atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				switch req.URL.Path {
				case "/api/requests":
					if req.URL.Query().Get("delivery_ack") != "" {
						acks.Add(1)
					}
					_, _ = w.Write([]byte(drainBatch))
				case "/api/responses":
					var body map[string]any
					_ = json.NewDecoder(req.Body).Decode(&body)
					if body["final"] == true {
						finals.Add(1)
					} else {
						updates.Add(1)
					}
					_, _ = w.Write([]byte(`{"ok":true}`))
				case "/api/socket":
					conn, err := (&websocket.Upgrader{}).Upgrade(w, req, nil)
					if err != nil {
						return
					}
					defer conn.Close()
					_ = conn.WriteMessage(websocket.TextMessage, contractFixture(t, "websocket_connected_frame.json"))
					var batch struct {
						DeliveryID string            `json:"delivery_id"`
						Requests   []json.RawMessage `json:"requests"`
					}
					_ = json.Unmarshal([]byte(drainBatch), &batch)
					_ = conn.WriteJSON(map[string]any{"type": "messages", "delivery_id": batch.DeliveryID, "messages": batch.Requests})
					for {
						var frame map[string]any
						if conn.ReadJSON(&frame) != nil {
							return
						}
						if frame["type"] == "ack" {
							acks.Add(1)
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
			chunks := make(chan string, 1)
			chunks <- "partial"
			r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerTimeout: 500 * time.Millisecond, Handler: func(ctx context.Context, m Message) error { _, err := c.StreamText(ctx, m.ReqID, chunks); return err }})
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			if err := r.Run(ctx); !errors.Is(err, ErrHandlerDeadlineExceeded) {
				t.Fatal(err)
			}
			if updates.Load() != 1 || finals.Load() != 0 || acks.Load() != 0 {
				t.Fatal(updates.Load(), finals.Load(), acks.Load())
			}
			if r.Status().LastError.Kind != "handler_deadline_exceeded" {
				t.Fatal(r.Status())
			}
		})
	}
}

func TestHandlerDeadlineDuringDrainNeverRetiresTheBatch(t *testing.T) {
	var polls, retired atomic.Int32
	expired, release := make(chan struct{}), make(chan struct{})
	c, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", Transport: TransportHTTP, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		switch req.URL.Path {
		case "/api/capabilities":
			return jsonResponse(200, drainCapabilities), nil
		case "/api/client-lease":
			return jsonResponse(200, `{"ok":true,"lease_timeout_ms":3000}`), nil
		case "/api/client-retire":
			retired.Add(1)
			return jsonResponse(200, `{"ok":true}`), nil
		case "/api/requests":
			polls.Add(1)
			return jsonResponse(200, drainBatch), nil
		}
		return nil, errors.New("unexpected request")
	})}})
	r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, GracefulShutdown: true, PollInterval: 10 * time.Millisecond, HandlerTimeout: 40 * time.Millisecond, Handler: func(ctx context.Context, _ Message) error { <-ctx.Done(); close(expired); <-release; return nil }})
	done := make(chan error, 1)
	go func() { done <- r.Run(context.Background()) }()
	awaitSignal(t, expired)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	drained := make(chan error, 1)
	go func() { drained <- r.Drain(ctx) }()
	awaitSignal(t, r.lifetime().wake)
	if s := r.Status(); s.Phase != "draining" || s.ActiveHandlers != 1 || s.OverdueHandlers != 1 {
		t.Fatal(s)
	}
	if retired.Load() != 0 {
		t.Fatal("retired overdue active work")
	}
	close(release)
	if err := awaitError(t, drained); !errors.Is(err, ErrHandlerDeadlineExceeded) {
		t.Fatal(err)
	}
	if err := awaitError(t, done); !errors.Is(err, ErrHandlerDeadlineExceeded) {
		t.Fatal(err)
	}
	if retired.Load() != 0 || polls.Load() != 1 {
		t.Fatal(retired.Load(), polls.Load())
	}
}

func TestHandlerDeadlinePreservesEarlierParentDeadlineAndConfirmedServerCancellation(t *testing.T) {
	c, _ := NewClient(Config{BaseURL: "http://exiron.test", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if req.URL.Path != "/api/request-state" {
			t.Error(req.URL.Path)
		}
		return jsonResponse(200, `{"req_id":"one","state":"cancelled"}`), nil
	})}})
	r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerTimeout: time.Second, CooperativeCancellation: true, Handler: func(context.Context, Message) error { t.Error("cancelled handler ran"); return nil }})
	if err := r.handleBatch(context.Background(), []Message{{ReqID: "one"}}); err != nil {
		t.Fatal(err)
	}
	if s := r.Status(); s.BatchCompleted != 1 || s.BatchTimedOut != 0 || s.ActiveHandlers != 0 {
		t.Fatal(s)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	r = c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerTimeout: time.Second, Handler: func(ctx context.Context, _ Message) error { <-ctx.Done(); return nil }})
	if err := r.handleBatch(ctx, []Message{{}}); !errors.Is(err, context.DeadlineExceeded) || errors.Is(err, ErrHandlerDeadlineExceeded) {
		t.Fatal(err)
	}
	if r.Status().BatchTimedOut != 0 {
		t.Fatal(r.Status())
	}
}
