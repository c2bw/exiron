package exiron

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/gorilla/websocket"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestRuntimeReportingContinuesWhileHTTPAndWebSocketHandlersAreOverdue(t *testing.T) {
	for _, transport := range []Transport{TransportHTTP, TransportWebSocket} {
		t.Run(fmt.Sprint(transport), func(t *testing.T) {
			reports := make(chan ClientRuntimeReport, 10)
			var discovery, acks atomic.Int32
			const caps = `{"protocol_version":"1.17","capabilities":["client_runtime_reporting","http_lease_renewal"]}`
			batch := strings.Replace(drainBatch, `"delivery_id":"batch-1"`, `"runtime_ref":"session-1","delivery_id":"batch-1"`, 1)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				switch req.URL.Path {
				case "/api/capabilities":
					discovery.Add(1)
					_, _ = w.Write([]byte(caps))
				case "/api/requests":
					if req.URL.Query().Get("delivery_ack") != "" {
						acks.Add(1)
					}
					_, _ = w.Write([]byte(batch))
				case "/api/client-lease":
					_, _ = w.Write([]byte(`{"ok":true,"lease_timeout_ms":3000}`))
				case "/api/client-runtime":
					var report ClientRuntimeReport
					_ = json.NewDecoder(req.Body).Decode(&report)
					reports <- report
					// A diagnostic failure must not stop the runner or retry the same payload.
					w.WriteHeader(503)
					_, _ = w.Write([]byte(`{"error":"unavailable"}`))
				case "/api/socket":
					conn, err := (&websocket.Upgrader{}).Upgrade(w, req, nil)
					if err != nil {
						return
					}
					defer conn.Close()
					var connected map[string]any
					_ = json.Unmarshal(contractFixture(t, "websocket_connected_frame.json"), &connected)
					connected["runtime_ref"] = "session-1"
					_ = conn.WriteJSON(connected)
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
			c, _ := NewClient(Config{BaseURL: server.URL, Token: "private-token", ClientID: "worker", Transport: transport})
			entered, expired, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
			r := c.NewRunner(RunnerOptions{HTTPLeaseRenewal: transport == TransportHTTP, HandlerTimeout: 100 * time.Millisecond, PollInterval: 10 * time.Millisecond,
				Handler: func(ctx context.Context, _ Message) error {
					close(entered)
					<-ctx.Done()
					close(expired)
					<-release
					return nil
				}})
			ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
			defer cancel()
			done := make(chan error, 1)
			go func() { done <- r.Run(ctx) }()
			awaitSignal(t, entered)
			awaitSignal(t, expired)
			var previous int64
			var report ClientRuntimeReport
			deadline := time.NewTimer(7 * time.Second)
			defer deadline.Stop()
			for report.OverdueHandlers == 0 {
				select {
				case report = <-reports:
					if report.Sequence <= previous {
						t.Fatal("repeated report sequence")
					}
					previous = report.Sequence
				case <-deadline.C:
					t.Fatal("no overdue report while handler blocked")
				}
			}
			if report.ActiveHandlers != 1 || report.RuntimeRef != "session-1" || report.ClientID != "worker" || report.Phase != "handling" {
				t.Fatal(report)
			}
			bytes, _ := json.Marshal(report)
			if strings.Contains(string(bytes), "private-token") || strings.Contains(string(bytes), "req-1") {
				t.Fatal(string(bytes))
			}
			select {
			case err := <-done:
				t.Fatalf("reporting error stopped active handler: %v", err)
			default:
			}
			if discovery.Load() != 1 || acks.Load() != 0 {
				t.Fatal(discovery.Load(), acks.Load())
			}
			close(release)
			if err := awaitError(t, done); !errors.Is(err, ErrHandlerDeadlineExceeded) {
				t.Fatal(err)
			}
			if acks.Load() != 0 {
				t.Fatal("acknowledged overdue work")
			}
		})
	}
}

func TestRuntimeReportingRequiresCapabilityAndReferenceAndHonorsOptOut(t *testing.T) {
	var polls, reports, discovery atomic.Int32
	c, _ := NewClient(Config{BaseURL: "http://exiron.test", Transport: TransportHTTP, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		switch req.URL.Path {
		case "/api/capabilities":
			discovery.Add(1)
			return jsonResponse(200, `{"protocol_version":"1.17","capabilities":[]}`), nil
		case "/api/requests":
			polls.Add(1)
			return jsonResponse(200, drainBatch), nil
		default:
			reports.Add(1)
			return jsonResponse(200, `{"ok":true}`), nil
		}
	})}})
	r := c.NewRunner(RunnerOptions{RuntimeReporting: true, Handler: func(context.Context, Message) error { t.Error("unsupported reporter consumed work"); return nil }})
	if err := r.Run(context.Background()); err == nil {
		t.Fatal("accepted unsupported server")
	}
	if polls.Load() != 0 || reports.Load() != 0 || discovery.Load() != 1 {
		t.Fatal(polls.Load(), reports.Load(), discovery.Load())
	}
	r = c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, Handler: func(context.Context, Message) error { return errors.New("stop") }})
	_ = r.Run(context.Background())
	if polls.Load() != 1 || reports.Load() != 0 || discovery.Load() != 1 {
		t.Fatal("disabled mode added reporting traffic")
	}
	c.httpClient.Transport = roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if req.URL.Path == "/api/capabilities" {
			return jsonResponse(200, `{"protocol_version":"1.17","capabilities":["client_runtime_reporting"]}`), nil
		}
		return jsonResponse(200, drainBatch), nil
	})
	r = c.NewRunner(RunnerOptions{RuntimeReporting: true, Handler: func(context.Context, Message) error { t.Error("missing session fence allowed handler"); return nil }})
	if err := r.Run(context.Background()); err == nil {
		t.Fatal("accepted missing runtime reference")
	}
}

func TestRuntimeReportingCancelsItsInFlightRequestWhenRunStops(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	cancelled := make(chan error, 1)
	c, _ := NewClient(Config{BaseURL: "http://exiron.test", Transport: TransportHTTP, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		switch req.URL.Path {
		case "/api/capabilities":
			return jsonResponse(200, `{"protocol_version":"1.17","capabilities":["client_runtime_reporting"]}`), nil
		case "/api/requests":
			return jsonResponse(200, strings.Replace(drainBatch, `"delivery_id":"batch-1"`, `"runtime_ref":"session","delivery_id":"batch-1"`, 1)), nil
		case "/api/client-runtime":
			close(started)
			<-req.Context().Done()
			cancelled <- req.Context().Err()
			return nil, req.Context().Err()
		}
		return nil, errors.New("unexpected request")
	})}})
	r := c.NewRunner(RunnerOptions{RuntimeReporting: true, Handler: func(context.Context, Message) error { <-release; return errors.New("stop") }})
	done := make(chan error, 1)
	go func() { done <- r.Run(context.Background()) }()
	awaitSignal(t, started)
	close(release)
	if err := awaitError(t, cancelled); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if err := awaitError(t, done); err == nil {
		t.Fatal("lost handler failure")
	}
}

func TestAutomaticRuntimeReportingNegotiation(t *testing.T) {
	for _, tc := range []struct {
		name      string
		caps      string
		status    int
		disable   bool
		invalidID bool
		enabled   bool
		discovery int32
	}{
		{name: "supported", caps: `{"protocol_version":"1.19","capabilities":["client_runtime_reporting"]}`, enabled: true, discovery: 1},
		{name: "unsupported", caps: `{"protocol_version":"1.16","capabilities":[]}`, discovery: 1},
		{name: "unavailable", status: 503, caps: `{"error":"unavailable"}`, discovery: 1},
		{name: "disabled", disable: true},
		{name: "invalid ID", invalidID: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var discovery atomic.Int32
			id := "worker"
			if tc.invalidID {
				id = strings.Repeat("x", 129)
			}
			c, _ := NewClient(Config{BaseURL: "http://exiron.test", ClientID: id, Transport: TransportHTTP, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
				switch req.URL.Path {
				case "/api/capabilities":
					discovery.Add(1)
					status := tc.status
					if status == 0 {
						status = 200
					}
					return jsonResponse(status, tc.caps), nil
				case "/api/requests":
					return jsonResponse(200, strings.Replace(drainBatch, `"delivery_id":`, `"runtime_ref":"session","delivery_id":`, 1)), nil
				case "/api/client-runtime":
					return jsonResponse(200, `{"ok":true}`), nil
				default:
					t.Errorf("unexpected path %s", req.URL.Path)
					return nil, errors.New("unexpected request")
				}
			})}})
			stop := errors.New("handler completed")
			r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: tc.disable, Handler: func(context.Context, Message) error { return stop }})
			if err := r.Run(context.Background()); !errors.Is(err, stop) {
				t.Fatalf("handler did not run: %v", err)
			}
			if r.runtimeReporting != tc.enabled || discovery.Load() != tc.discovery {
				t.Fatalf("enabled=%v discoveries=%d", r.runtimeReporting, discovery.Load())
			}
		})
	}
}

func TestRuntimeReportingRejectsContradictoryOptions(t *testing.T) {
	c, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	r := c.NewRunner(RunnerOptions{RuntimeReporting: true, DisableRuntimeReporting: true, Handler: func(context.Context, Message) error { return nil }})
	if err := r.Run(context.Background()); err == nil {
		t.Fatal("accepted contradictory reporting options")
	}
}
