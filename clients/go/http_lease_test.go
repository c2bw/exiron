package exiron

import (
	"context"
	"errors"
	"net/http"
	"sync/atomic"
	"testing"
	"time"
)

func TestHTTPLeaseRenewalKeepsLongOrderedBatchAndAcknowledgesAfterCleanup(t *testing.T) {
	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	var renewals, polls, reports, firstAttempts atomic.Int32
	var expires atomic.Int64
	ready := make(chan struct{})
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", ClientID: "worker", Transport: TransportHTTP, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		switch req.URL.Path {
		case "/api/capabilities":
			return jsonResponse(200, string(contractFixture(t, "auth_response.json"))), nil
		case "/api/client-lease":
			if time.Now().UnixNano() >= expires.Load() {
				return jsonResponse(409, string(contractFixture(t, "error_client_lease_lost.json"))), nil
			}
			expires.Store(time.Now().Add(1200 * time.Millisecond).UnixNano())
			if n := renewals.Add(1); n == 4 {
				close(ready)
			}
			return jsonResponse(200, `{"ok":true,"lease_timeout_ms":1200}`), nil
		case "/api/handler-reports":
			reports.Add(1)
			return jsonResponse(200, `{"ok":true}`), nil
		case "/api/requests":
			if polls.Add(1) == 1 {
				expires.Store(time.Now().Add(1200 * time.Millisecond).UnixNano())
				return jsonResponse(200, `{"delivery_id":"batch","requests":[{"req_id":"first","msgtype":"request","service_id":222,"chat_id":1,"datatype":"text","data":"eA=="},{"req_id":"next","msgtype":"request","service_id":222,"chat_id":1,"datatype":"text","data":"eA=="},{"req_id":"other","msgtype":"request","service_id":222,"chat_id":2,"datatype":"text","data":"eA=="}]}`), nil
			}
			if time.Now().UnixNano() >= expires.Load() {
				t.Error("lease expired before acknowledgement")
			}
			if req.URL.Query().Get("delivery_ack") != "batch" {
				t.Error("batch not acknowledged")
			}
			if renewals.Load() < 5 {
				t.Error("missing periodic/final renewal")
			}
			stop()
			return jsonResponse(200, `{"requests":[]}`), nil
		default:
			t.Errorf("unexpected request %s", req.URL.Path)
			return jsonResponse(500, `{}`), nil
		}
	})}})
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HTTPLeaseRenewal: true, HandlerConcurrency: 2, HandlerOrderByChat: true, ReportHandlerFailures: true, HandlerMaxAttempts: 2, HandlerRetryDelay: time.Millisecond, PollInterval: time.Millisecond,
		Handler: func(ctx context.Context, m Message) error {
			if m.ReqID == "first" && firstAttempts.Add(1) == 1 {
				select {
				case <-ready:
					return errors.New("retry locally")
				case <-time.After(3 * time.Second):
					t.Error("lease stopped renewing")
					return errors.New("timeout")
				}
			}
			if ctx.Err() != nil {
				t.Error("healthy lease cancelled handler")
			}
			return nil
		}})
	if err := runner.Run(ctx); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if polls.Load() != 2 || reports.Load() != 2 {
		t.Fatalf("polls=%d reports=%d", polls.Load(), reports.Load())
	}
}

func TestHTTPLeaseFailureSignalsActiveHandlersAndNeverAcknowledgesOrReclaims(t *testing.T) {
	for _, failure := range []string{"lost", "unavailable", "timeout"} {
		t.Run(failure, func(t *testing.T) {
			var renewals, polls, callbacks atomic.Int32
			cancelled := make(chan struct{}, 1)
			sibling := make(chan struct{})
			release := make(chan struct{})
			client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", Transport: TransportHTTP, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
				switch req.URL.Path {
				case "/api/capabilities":
					return jsonResponse(200, string(contractFixture(t, "auth_response.json"))), nil
				case "/api/client-lease":
					if renewals.Add(1) == 1 {
						return jsonResponse(200, `{"ok":true,"lease_timeout_ms":600}`), nil
					}
					switch failure {
					case "timeout":
						<-req.Context().Done()
						return nil, req.Context().Err()
					case "unavailable":
						return jsonResponse(503, `{"error":"unavailable"}`), nil
					default:
						return jsonResponse(409, string(contractFixture(t, "error_client_lease_lost.json"))), nil
					}
				case "/api/requests":
					polls.Add(1)
					if req.URL.Query().Get("delivery_ack") != "" {
						t.Error("lost batch acknowledged")
					}
					return jsonResponse(200, `{"delivery_id":"batch","requests":[{"req_id":"first","service_id":222,"chat_id":1,"datatype":"text","data":"eA=="},{"req_id":"queued","service_id":222,"chat_id":1,"datatype":"text","data":"eA=="},{"req_id":"other","service_id":222,"chat_id":2,"datatype":"text","data":"eA=="}]}`), nil
				default:
					t.Error(req.URL.Path)
					return jsonResponse(500, `{}`), nil
				}
			})}})
			runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HTTPLeaseRenewal: true, HandlerConcurrency: 2, HandlerOrderByChat: true, PollInterval: time.Millisecond,
				OnHandlerError: func(context.Context, *HandlerFailure) { callbacks.Add(1) },
				Handler: func(ctx context.Context, m Message) error {
					switch m.ReqID {
					case "first":
						<-sibling
						<-ctx.Done()
						if !errors.Is(context.Cause(ctx), ErrClientLeaseLost) {
							t.Error(context.Cause(ctx))
						}
						cancelled <- struct{}{}
						return ctx.Err()
					case "other":
						close(sibling)
						<-release
						return nil
					default:
						t.Error("queued handler started after lease loss")
						return nil
					}
				}})
			result := make(chan error, 1)
			go func() { result <- runner.Run(context.Background()) }()
			select {
			case <-cancelled:
			case <-time.After(2 * time.Second):
				t.Fatal("handler was not cancelled")
			}
			select {
			case err := <-result:
				t.Fatalf("returned with sibling running: %v", err)
			default:
			}
			close(release)
			select {
			case err := <-result:
				if !IsClientLeaseLost(err) {
					t.Fatal(err)
				}
			case <-time.After(time.Second):
				t.Fatal("runner did not stop")
			}
			if polls.Load() != 1 || callbacks.Load() != 0 {
				t.Fatalf("polls=%d callbacks=%d", polls.Load(), callbacks.Load())
			}
		})
	}
}

func TestHTTPLeaseDefaultsAndCapabilityValidation(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Transport: TransportHTTP, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if req.URL.Path != "/api/capabilities" {
			t.Error("work consumed without support")
		}
		return jsonResponse(200, `{"protocol_version":"1.15","capabilities":[]}`), nil
	})}})
	if client.NewRunner(RunnerOptions{DisableRuntimeReporting: true}).httpLeaseRenewal {
		t.Fatal("must default off")
	}
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HTTPLeaseRenewal: true, Handler: func(context.Context, Message) error { return nil }})
	if err := runner.Run(context.Background()); err == nil {
		t.Fatal("unsupported server accepted")
	}
	ws, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	if err := ws.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HTTPLeaseRenewal: true, Handler: func(context.Context, Message) error { return nil }}).Run(context.Background()); err == nil {
		t.Fatal("websocket option accepted")
	}
}

func TestHTTPLeaseFinalFailurePreventsAcknowledgement(t *testing.T) {
	var calls atomic.Int32
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Transport: TransportHTTP, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if calls.Add(1) == 1 {
			return jsonResponse(200, `{"ok":true,"lease_timeout_ms":3000}`), nil
		}
		return jsonResponse(409, string(contractFixture(t, "error_client_lease_lost.json"))), nil
	})}})
	handled := 0
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HTTPLeaseRenewal: true, Handler: func(context.Context, Message) error { handled++; return nil }})
	if err := runner.handleHTTPBatch(context.Background(), "batch", []Message{{ReqID: "one"}}); !IsClientLeaseLost(err) {
		t.Fatal(err)
	}
	if handled != 1 || calls.Load() != 2 {
		t.Fatalf("handled=%d renewals=%d", handled, calls.Load())
	}
}

func TestHTTPLeaseParentCancellationCleansUpInFlightControlCall(t *testing.T) {
	var calls atomic.Int32
	blocked := make(chan struct{})
	released := make(chan struct{})
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Transport: TransportHTTP, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if calls.Add(1) == 1 {
			return jsonResponse(200, `{"ok":true,"lease_timeout_ms":600}`), nil
		}
		close(blocked)
		<-req.Context().Done()
		close(released)
		return nil, req.Context().Err()
	})}})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HTTPLeaseRenewal: true, PollInterval: time.Millisecond, Handler: func(ctx context.Context, _ Message) error { <-ctx.Done(); return ctx.Err() }})
	result := make(chan error, 1)
	go func() { result <- runner.handleHTTPBatch(ctx, "batch", []Message{{ReqID: "one"}}) }()
	select {
	case <-blocked:
	case <-time.After(time.Second):
		t.Fatal("control call did not start")
	}
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("shutdown blocked")
	}
	select {
	case <-released:
	default:
		t.Fatal("control call leaked after shutdown")
	}
}
