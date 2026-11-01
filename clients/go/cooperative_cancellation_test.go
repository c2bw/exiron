package exiron

import (
	"context"
	"errors"
	"github.com/gorilla/websocket"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestCooperativeHTTPCancellationHandlesSiblingAndAcknowledgesBatch(t *testing.T) {
	for _, reason := range []string{"cancelled", "expired"} {
		t.Run(reason, func(t *testing.T) {
			ctx, stop := context.WithCancel(context.Background())
			defer stop()
			var cancelNow atomic.Bool
			var polls atomic.Int32
			var calls atomic.Int32
			var failures atomic.Int32
			acked := make(chan struct{}, 1)
			notices := make(chan RequestCancellation, 1)
			client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", Transport: TransportHTTP, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
				switch req.URL.Path {
				case "/api/capabilities":
					return jsonResponse(200, `{"protocol_version":"1.15","capabilities":["cooperative_cancellation"]}`), nil
				case "/api/request-state":
					state := "active"
					if req.URL.Query().Get("req_id") == "req-1" && cancelNow.Load() {
						state = reason
					}
					return jsonResponse(200, `{"req_id":"`+req.URL.Query().Get("req_id")+`","state":"`+state+`","expires_in_ms":60000}`), nil
				case "/api/requests":
					if polls.Add(1) == 1 {
						return jsonResponse(200, `{"delivery_id":"delivery-1","requests":[{"msgtype":"request","req_id":"req-1","datatype":"text","data":"eA=="},{"msgtype":"request","req_id":"req-2","datatype":"text","data":"eQ=="}]}`), nil
					}
					if req.URL.Query().Get("delivery_ack") == "delivery-1" {
						acked <- struct{}{}
					}
					stop()
					return jsonResponse(200, `{"requests":[]}`), nil
				default:
					t.Errorf("unexpected path %s", req.URL.Path)
					return jsonResponse(500, `{}`), nil
				}
			})}})
			runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, CooperativeCancellation: true, CancellationInterval: 100 * time.Millisecond, HandlerMaxAttempts: 3,
				OnHandlerError: func(context.Context, *HandlerFailure) { failures.Add(1) }, OnRequestCancelled: func(_ context.Context, e RequestCancellation) { notices <- e },
				Handler: func(ctx context.Context, m Message) error {
					calls.Add(1)
					if m.ReqID == "req-1" {
						cancelNow.Store(true)
						<-ctx.Done()
						expected := ErrRequestCancelled
						if reason == "expired" {
							expected = ErrRequestExpired
						}
						if !errors.Is(context.Cause(ctx), expected) {
							t.Errorf("cause=%v", context.Cause(ctx))
						}
						return ctx.Err()
					}
					return nil
				}})
			runner.wait = func(ctx context.Context, _ time.Duration) error { return ctx.Err() }
			if err := runner.Run(ctx); !errors.Is(err, context.Canceled) {
				t.Fatal(err)
			}
			if calls.Load() != 2 || failures.Load() != 0 {
				t.Fatalf("calls=%d failures=%d", calls.Load(), failures.Load())
			}
			select {
			case <-acked:
			default:
				t.Fatal("batch not acknowledged")
			}
			select {
			case event := <-notices:
				if event.Reason != reason || event.RequestID != "req-1" {
					t.Fatal(event)
				}
			default:
				t.Fatal("missing notification")
			}
		})
	}
}

func TestCooperativeControlErrorsDoNotCancelAndWatcherStops(t *testing.T) {
	var queries atomic.Int32
	entered := make(chan struct{})
	released := make(chan struct{})
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if queries.Add(1) == 1 {
			return jsonResponse(503, `{"error":"unavailable"}`), nil
		}
		close(entered)
		<-req.Context().Done()
		close(released)
		return nil, req.Context().Err()
	})}})
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, CooperativeCancellation: true, CancellationInterval: 100 * time.Millisecond, Handler: func(ctx context.Context, _ Message) error {
		select {
		case <-entered:
		case <-time.After(2 * time.Second):
			t.Error("watcher did not run")
		}
		if ctx.Err() != nil {
			t.Error("control failure cancelled handler")
		}
		return nil
	}})
	if err := runner.handleMessage(context.Background(), Message{ReqID: "req-1", Msgtype: "request"}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-released:
	default:
		t.Fatal("in-flight control request leaked")
	}
}

func TestCooperativePreCancelledWorkIsSkippedAndListenIsUnaffected(t *testing.T) {
	var calls atomic.Int32
	var queries atomic.Int32
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		queries.Add(1)
		return jsonResponse(200, `{"req_id":"req-1","state":"cancelled","expires_in_ms":null}`), nil
	})}})
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, CooperativeCancellation: true, CancellationInterval: 100 * time.Millisecond, Handler: func(context.Context, Message) error { calls.Add(1); return nil }})
	if err := runner.handleMessage(context.Background(), Message{ReqID: "req-1", Msgtype: "request"}); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 0 {
		t.Fatal("cancelled work invoked handler")
	}
	if err := runner.handleMessage(context.Background(), Message{ReqID: "req-1", Msgtype: "listen"}); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 || queries.Load() != 1 {
		t.Fatalf("calls=%d queries=%d", calls.Load(), queries.Load())
	}
}

func TestCooperativeCancellationRequiresCapabilityBeforePolling(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if req.URL.Path != "/api/capabilities" {
			t.Error("consumed work before capability check")
		}
		return jsonResponse(200, `{"capabilities":[]}`), nil
	})}})
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, CooperativeCancellation: true, Handler: func(context.Context, Message) error { return nil }})
	if err := runner.Run(context.Background()); err == nil {
		t.Fatal("unsupported cancellation silently enabled")
	}
}

func TestCooperativeWebSocketCancellationAcknowledgesDelivery(t *testing.T) {
	ctx, stop := context.WithTimeout(context.Background(), 5*time.Second)
	defer stop()
	var running atomic.Bool
	acked := make(chan struct{}, 1)
	var upgrader websocket.Upgrader
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		switch req.URL.Path {
		case "/api/capabilities":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"protocol_version":"1.15","capabilities":["cooperative_cancellation"]}`))
		case "/api/request-state":
			state := "active"
			if running.Load() {
				state = "cancelled"
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"req_id":"req-1","state":"` + state + `","expires_in_ms":null}`))
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
			if err := conn.WriteMessage(websocket.TextMessage, contractFixture(t, "websocket_messages_frame.json")); err != nil {
				t.Error(err)
				return
			}
			for {
				var frame map[string]any
				if err := conn.ReadJSON(&frame); err != nil {
					return
				}
				if frame["type"] == "ack" && frame["delivery_id"] == "delivery-example" {
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
	client, err := NewClient(Config{BaseURL: server.URL, Token: "token"})
	if err != nil {
		t.Fatal(err)
	}
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, CooperativeCancellation: true, CancellationInterval: 100 * time.Millisecond,
		Handler: func(ctx context.Context, _ Message) error {
			running.Store(true)
			<-ctx.Done()
			if !errors.Is(context.Cause(ctx), ErrRequestCancelled) {
				t.Errorf("cause=%v", context.Cause(ctx))
			}
			return ctx.Err()
		}})
	if err := runner.Run(ctx); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	select {
	case <-acked:
	default:
		t.Fatal("cancelled delivery was not acknowledged")
	}
}
