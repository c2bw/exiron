package exiron

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/gorilla/websocket"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func awaitStarted(t *testing.T, ch <-chan string) string {
	t.Helper()
	select {
	case id := <-ch:
		return id
	case <-time.After(2 * time.Second):
		t.Fatal("handler did not start")
		return ""
	}
}

func TestHandlerConcurrencyBoundsActiveWorkAndRefillsSlots(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	started := make(chan string, 4)
	releases := map[string]chan struct{}{}
	messages := []Message{}
	for _, id := range []string{"one", "two", "three", "four"} {
		releases[id] = make(chan struct{})
		messages = append(messages, Message{ReqID: id})
	}
	var active, peak atomic.Int32
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerConcurrency: 2, Handler: func(_ context.Context, m Message) error {
		n := active.Add(1)
		for p := peak.Load(); n > p; p = peak.Load() {
			if peak.CompareAndSwap(p, n) {
				break
			}
		}
		defer active.Add(-1)
		started <- m.ReqID
		<-releases[m.ReqID]
		return nil
	}})
	result := make(chan error, 1)
	go func() { result <- runner.handleBatch(context.Background(), messages) }()
	first, second := awaitStarted(t, started), awaitStarted(t, started)
	if first == second || (first != "one" && first != "two") || (second != "one" && second != "two") {
		t.Fatalf("started %s %s", first, second)
	}
	close(releases["one"])
	if id := awaitStarted(t, started); id != "three" {
		t.Fatal(id)
	}
	close(releases["three"])
	if id := awaitStarted(t, started); id != "four" {
		t.Fatal(id)
	}
	close(releases["four"])
	select {
	case err := <-result:
		t.Fatalf("returned before active sibling: %v", err)
	default:
	}
	close(releases["two"])
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("batch did not finish")
	}
	if peak.Load() != 2 || active.Load() != 0 {
		t.Fatalf("peak=%d active=%d", peak.Load(), active.Load())
	}
}

func TestConcurrentExhaustionWaitsForActiveSiblings(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	siblingStarted := make(chan struct{})
	releaseSibling := make(chan struct{})
	failed := make(chan struct{})
	failure := errors.New("poison")
	var attempts, callbacks atomic.Int32
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerConcurrency: 2, HandlerOrderByChat: true, HandlerMaxAttempts: 2,
		Handler: func(_ context.Context, m Message) error {
			switch m.ReqID {
			case "poison":
				<-siblingStarted
				attempts.Add(1)
				return failure
			case "sibling":
				close(siblingStarted)
				<-releaseSibling
				return nil
			default:
				t.Error("queued handler started after failure")
				return nil
			}
		}, OnHandlerError: func(_ context.Context, f *HandlerFailure) {
			callbacks.Add(1)
			if !f.WillRetry {
				close(failed)
			}
		}})
	runner.handlerWait = func(context.Context, time.Duration) error { return nil }
	result := make(chan error, 1)
	go func() {
		result <- runner.handleBatch(context.Background(), []Message{{ReqID: "poison", ServiceID: 222, ChatID: 1}, {ReqID: "sibling", ServiceID: 222, ChatID: 2}})
	}()
	select {
	case <-failed:
	case <-time.After(2 * time.Second):
		t.Fatal("no exhausted failure")
	}
	select {
	case err := <-result:
		t.Fatalf("returned with sibling running: %v", err)
	default:
	}
	close(releaseSibling)
	select {
	case err := <-result:
		if !errors.Is(err, failure) {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("batch did not fail")
	}
	if attempts.Load() != 2 || callbacks.Load() != 2 {
		t.Fatal("retry policy changed")
	}
}

func TestConcurrentParentCancellationStopsDispatchAndJoinsHandlers(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	started := make(chan string, 3)
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerConcurrency: 2, Handler: func(ctx context.Context, m Message) error {
		started <- m.ReqID
		<-ctx.Done()
		return ctx.Err()
	}})
	result := make(chan error, 1)
	go func() {
		result <- runner.handleBatch(ctx, []Message{{ReqID: "one"}, {ReqID: "two"}, {ReqID: "queued"}})
	}()
	_ = awaitStarted(t, started)
	_ = awaitStarted(t, started)
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("handlers not joined")
	}
	select {
	case id := <-started:
		t.Fatal("started after cancellation: " + id)
	default:
	}
}

func TestHandlerConcurrencyDefaultsAndValidation(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	if r := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true}); r.handlerConcurrency != 1 {
		t.Fatal("default must remain serial")
	}
	for _, limit := range []int{-1, 65} {
		r := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerConcurrency: limit, Handler: func(context.Context, Message) error { return nil }})
		if err := r.Run(context.Background()); err == nil {
			t.Fatalf("accepted limit %d", limit)
		}
	}
}

func TestConcurrentExhaustionStopsQueuedDispatch(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	var calls atomic.Int32
	failure := errors.New("failed")
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerConcurrency: 2, Handler: func(context.Context, Message) error { calls.Add(1); return failure }})
	messages := make([]Message, 20)
	if err := runner.handleBatch(context.Background(), messages); !errors.Is(err, failure) {
		t.Fatal(err)
	}
	if calls.Load() > 2 {
		t.Fatalf("started %d handlers after exhaustion", calls.Load())
	}
}

func TestConcurrentBatchesAcknowledgeOnlyAfterAllHandlersFinish(t *testing.T) {
	for _, transport := range []Transport{TransportHTTP, TransportWebSocket} {
		t.Run(map[Transport]string{TransportHTTP: "http", TransportWebSocket: "websocket"}[transport], func(t *testing.T) {
			ctx, stop := context.WithTimeout(context.Background(), 5*time.Second)
			defer stop()
			started := make(chan string, 3)
			acked := make(chan struct{}, 1)
			releases := map[string]chan struct{}{"one": make(chan struct{}), "two": make(chan struct{}), "three": make(chan struct{})}
			var upgrader websocket.Upgrader
			messages := []map[string]any{}
			for _, id := range []string{"one", "two", "three"} {
				chat := int64(2)
				if id == "one" {
					chat = 1
				}
				messages = append(messages, map[string]any{"service_id": int64(222), "chat_id": chat, "req_id": id, "msgtype": "request", "datatype": "text", "data": "eA=="})
			}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				switch req.URL.Path {
				case "/api/requests":
					w.Header().Set("Content-Type", "application/json")
					if req.URL.Query().Get("delivery_ack") == "batch" {
						acked <- struct{}{}
						stop()
						_ = json.NewEncoder(w).Encode(map[string]any{"requests": []any{}})
						return
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"delivery_id": "batch", "requests": messages})
				case "/api/socket":
					conn, err := upgrader.Upgrade(w, req, nil)
					if err != nil {
						t.Error(err)
						return
					}
					defer conn.Close()
					if err := conn.WriteMessage(websocket.TextMessage, contractFixture(t, "websocket_connected_frame.json")); err != nil {
						t.Error(err)
						return
					}
					if err := conn.WriteJSON(map[string]any{"type": "messages", "delivery_id": "batch", "messages": messages}); err != nil {
						t.Error(err)
						return
					}
					for {
						var frame map[string]any
						if err := conn.ReadJSON(&frame); err != nil {
							return
						}
						if frame["type"] == "ack" {
							acked <- struct{}{}
							stop()
							return
						}
						if frame["type"] == "ping" {
							_ = conn.WriteJSON(map[string]any{"type": "pong"})
						}
					}
				default:
					t.Errorf("unexpected path %s", req.URL.Path)
				}
			}))
			defer server.Close()
			client, err := NewClient(Config{BaseURL: server.URL, Token: "token", Transport: transport})
			if err != nil {
				t.Fatal(err)
			}
			runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerConcurrency: 2, HandlerOrderByChat: true, PollInterval: time.Millisecond, Handler: func(ctx context.Context, m Message) error {
				started <- m.ReqID
				select {
				case <-releases[m.ReqID]:
					return nil
				case <-ctx.Done():
					return ctx.Err()
				}
			}})
			result := make(chan error, 1)
			go func() { result <- runner.Run(ctx) }()
			first, second := awaitStarted(t, started), awaitStarted(t, started)
			if first == second {
				t.Fatal("message started twice")
			}
			close(releases["two"])
			if id := awaitStarted(t, started); id != "three" {
				t.Fatal(id)
			}
			close(releases["three"])
			select {
			case <-acked:
				t.Fatal("batch acknowledged with handler still running")
			default:
			}
			close(releases["one"])
			select {
			case <-acked:
			case <-time.After(2 * time.Second):
				t.Fatal("batch was not acknowledged")
			}
			select {
			case err := <-result:
				if !errors.Is(err, context.Canceled) {
					t.Fatal(err)
				}
			case <-time.After(time.Second):
				t.Fatal("runner did not stop")
			}
		})
	}
}

func TestConcurrentCancellationDoesNotCancelActiveSibling(t *testing.T) {
	var cancelNow atomic.Bool
	cancelled := make(chan struct{}, 1)
	siblingStarted := make(chan struct{})
	releaseSibling := make(chan struct{})
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		state := "active"
		if req.URL.Query().Get("req_id") == "cancel" && cancelNow.Load() {
			state = "cancelled"
		}
		return jsonResponse(200, `{"req_id":"`+req.URL.Query().Get("req_id")+`","state":"`+state+`","expires_in_ms":null}`), nil
	})}})
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerConcurrency: 2, CooperativeCancellation: true, CancellationInterval: 100 * time.Millisecond,
		Handler: func(ctx context.Context, m Message) error {
			if m.ReqID == "cancel" {
				<-siblingStarted
				cancelNow.Store(true)
				<-ctx.Done()
				if !errors.Is(context.Cause(ctx), ErrRequestCancelled) {
					t.Error(context.Cause(ctx))
				}
				cancelled <- struct{}{}
				return ctx.Err()
			}
			close(siblingStarted)
			<-releaseSibling
			if ctx.Err() != nil {
				t.Error("sibling context was cancelled")
			}
			return nil
		}})
	result := make(chan error, 1)
	go func() {
		result <- runner.handleBatch(context.Background(), []Message{{ReqID: "cancel", Msgtype: "request"}, {ReqID: "sibling", Msgtype: "request"}})
	}()
	select {
	case <-cancelled:
	case <-time.After(2 * time.Second):
		t.Fatal("request did not cancel")
	}
	select {
	case err := <-result:
		t.Fatalf("batch returned with sibling running: %v", err)
	default:
	}
	close(releaseSibling)
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("batch did not finish")
	}
}

func TestConcurrentHandlerReportsRemainScopedToEachMessage(t *testing.T) {
	reports := make(chan HandlerReport, 4)
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", ClientID: "worker", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		var report HandlerReport
		if err := json.NewDecoder(req.Body).Decode(&report); err != nil {
			t.Error(err)
		}
		reports <- report
		return jsonResponse(200, `{"ok":true}`), nil
	})}})
	var one, two atomic.Int32
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerConcurrency: 2, HandlerOrderByChat: true, ReportHandlerFailures: true, HandlerMaxAttempts: 2,
		Handler: func(_ context.Context, m Message) error {
			counter := &one
			if m.ReqID == "two" {
				counter = &two
			}
			if counter.Add(1) == 1 {
				return errors.New("private failure")
			}
			return nil
		}})
	runner.handlerWait = func(context.Context, time.Duration) error { return nil }
	ctx := context.WithValue(context.Background(), handlerDeliveryKey{}, "batch")
	if err := runner.handleBatch(ctx, []Message{{ReqID: "one", Msgtype: "request", ServiceID: 222, ChatID: 1}, {ReqID: "two", Msgtype: "request", ServiceID: 222, ChatID: 2}}); err != nil {
		t.Fatal(err)
	}
	grouped := map[string][]string{}
	for i := 0; i < 4; i++ {
		select {
		case r := <-reports:
			if r.DeliveryID != "batch" || r.ClientID != "worker" {
				t.Fatal(r)
			}
			grouped[r.RequestID] = append(grouped[r.RequestID], r.State)
		default:
			t.Fatal("missing report")
		}
	}
	for _, id := range []string{"one", "two"} {
		if len(grouped[id]) != 2 || grouped[id][0] != "retrying" || grouped[id][1] != "recovered" {
			t.Fatal(grouped)
		}
	}
}
