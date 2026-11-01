package exiron

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/gorilla/websocket"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestHandlerReportsPreserveRetriesAndOnlySendBoundedMetadata(t *testing.T) {
	for _, recover := range []bool{false, true} {
		t.Run(map[bool]string{false: "exhausted", true: "recovered"}[recover], func(t *testing.T) {
			var reports []HandlerReport
			client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", ClientID: "worker", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
				var report HandlerReport
				if err := json.NewDecoder(req.Body).Decode(&report); err != nil {
					t.Fatal(err)
				}
				reports = append(reports, report)
				return jsonResponse(503, `{"error":"unavailable"}`), nil
			})}})
			calls, callbacks := 0, 0
			original := errors.New("PRIVATE application body and credentials")
			runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, ReportHandlerFailures: true, HandlerMaxAttempts: 3,
				OnHandlerError: func(context.Context, *HandlerFailure) { callbacks++ },
				Handler: func(context.Context, Message) error {
					calls++
					if recover && calls == 3 {
						return nil
					}
					return original
				}})
			runner.handlerWait = func(context.Context, time.Duration) error { return nil }
			ctx := context.WithValue(context.Background(), handlerDeliveryKey{}, "batch")
			err := runner.handleMessage(ctx, Message{ReqID: "req-1", Msgtype: "request"})
			if recover && err != nil || !recover && !errors.Is(err, original) {
				t.Fatal(err)
			}
			if calls != 3 || callbacks != map[bool]int{true: 2, false: 3}[recover] || len(reports) != 3 {
				t.Fatalf("calls=%d callbacks=%d reports=%d", calls, callbacks, len(reports))
			}
			for i, r := range reports {
				if r.Attempt != i+1 || r.MaxAttempts != 3 || r.RequestID != "req-1" || r.ClientID != "worker" || r.DeliveryID != "batch" {
					t.Fatal(r)
				}
				data, _ := json.Marshal(r)
				if strings.Contains(string(data), "PRIVATE") {
					t.Fatal("private error sent")
				}
			}
			if reports[0].State != "retrying" || reports[2].State != map[bool]string{true: "recovered", false: "exhausted"}[recover] {
				t.Fatal(reports)
			}
		})
	}
}

func TestHandlerReportingOptInRequiresCapability(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if req.URL.Path != "/api/capabilities" {
			t.Errorf("consumed work before capability check: %s", req.URL.Path)
		}
		return jsonResponse(200, `{"protocol_version":"1.15","capabilities":[]}`), nil
	})}})
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, ReportHandlerFailures: true, Handler: func(context.Context, Message) error { return nil }})
	if err := runner.Run(context.Background()); err == nil || !strings.Contains(err.Error(), "handler_failure_reporting") {
		t.Fatal(err)
	}
}

func TestHandlerReportsSkipListenersAndDefaultAddsNoTraffic(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", HTTPClient: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		t.Error("unexpected diagnostic request")
		return jsonResponse(500, `{}`), nil
	})}})
	for _, enabled := range []bool{false, true} {
		runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, ReportHandlerFailures: enabled, Handler: func(context.Context, Message) error { return errors.New("failed") }})
		ctx := context.WithValue(context.Background(), handlerDeliveryKey{}, "batch")
		_ = runner.handleMessage(ctx, Message{ReqID: "listen-1", Msgtype: "listen"})
		if !enabled {
			_ = runner.handleMessage(ctx, Message{ReqID: "req-1", Msgtype: "request"})
		}
	}
}

func TestManagedHandlerReportsIncludeHTTPAndWebSocketBatch(t *testing.T) {
	for _, transport := range []Transport{TransportHTTP, TransportWebSocket} {
		t.Run(map[Transport]string{TransportHTTP: "http", TransportWebSocket: "websocket"}[transport], func(t *testing.T) {
			ctx, stop := context.WithTimeout(context.Background(), 5*time.Second)
			defer stop()
			reports := make(chan HandlerReport, 4)
			acked := make(chan struct{}, 1)
			var upgrader websocket.Upgrader
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				switch req.URL.Path {
				case "/api/capabilities":
					_, _ = w.Write(contractFixture(t, "auth_response.json"))
				case "/api/handler-reports":
					var r HandlerReport
					if err := json.NewDecoder(req.Body).Decode(&r); err != nil {
						t.Error(err)
						return
					}
					reports <- r
					w.WriteHeader(503)
					_, _ = w.Write([]byte(`{"error":"unavailable"}`))
				case "/api/requests":
					if req.URL.Query().Get("delivery_ack") != "" {
						acked <- struct{}{}
						stop()
						_, _ = w.Write([]byte(`{"requests":[]}`))
						return
					}
					_, _ = w.Write([]byte(`{"delivery_id":"delivery-example","requests":[{"req_id":"req-1","msgtype":"request","datatype":"text","data":"eA=="}]}`))
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
						var f map[string]any
						if err := conn.ReadJSON(&f); err != nil {
							return
						}
						if f["type"] == "ack" {
							acked <- struct{}{}
							stop()
							return
						}
						if f["type"] == "ping" {
							_ = conn.WriteJSON(map[string]any{"type": "pong"})
						}
					}
				default:
					t.Errorf("unexpected path %s", req.URL.Path)
				}
			}))
			defer server.Close()
			client, err := NewClient(Config{BaseURL: server.URL, Token: "token", ClientID: "worker", Transport: transport})
			if err != nil {
				t.Fatal(err)
			}
			calls := 0
			runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, ReportHandlerFailures: true, HandlerMaxAttempts: 2, HandlerRetryDelay: time.Millisecond,
				Handler: func(context.Context, Message) error {
					calls++
					if calls == 1 {
						return errors.New("PRIVATE")
					}
					return nil
				}})
			runner.wait = func(ctx context.Context, _ time.Duration) error { return ctx.Err() }
			if err := runner.Run(ctx); !errors.Is(err, context.Canceled) {
				t.Fatal(err)
			}
			select {
			case <-acked:
			default:
				t.Fatal("batch not acknowledged")
			}
			for _, state := range []string{"retrying", "recovered"} {
				select {
				case r := <-reports:
					if r.State != state || r.DeliveryID != "delivery-example" {
						t.Fatal(r)
					}
				default:
					t.Fatal("missing " + state + " report")
				}
			}
		})
	}
}
