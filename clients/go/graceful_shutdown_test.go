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

const drainCapabilities = `{"protocol_version":"1.16","capabilities":["client_retirement","http_lease_renewal"]}`
const drainBatch = `{"delivery_id":"batch-1","requests":[{"msgtype":"request","req_id":"req-1","service_id":222,"chat_id":123,"datatype":"text","data":"aGk="}]}`

func TestHTTPDrainFinishesStreamingBatchRenewsLeaseAndNeverFetchesAgain(t *testing.T) {
	var polls, retired, replies, leases atomic.Int32
	entered, release := make(chan struct{}), make(chan struct{})
	renewed := make(chan struct{}, 10)
	c, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", ClientID: "worker", Transport: TransportHTTP, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		switch req.URL.Path {
		case "/api/capabilities":
			return jsonResponse(200, drainCapabilities), nil
		case "/api/requests":
			polls.Add(1)
			return jsonResponse(200, drainBatch), nil
		case "/api/client-lease":
			leases.Add(1)
			renewed <- struct{}{}
			return jsonResponse(200, `{"ok":true,"lease_timeout_ms":300}`), nil
		case "/api/responses":
			replies.Add(1)
			return jsonResponse(200, `{"ok":true}`), nil
		case "/api/client-retire":
			retired.Add(1)
			var payload map[string]string
			_ = json.NewDecoder(req.Body).Decode(&payload)
			if payload["client_id"] != "worker" || payload["delivery_id"] != "batch-1" {
				t.Error(payload)
			}
			return jsonResponse(200, `{"ok":true}`), nil
		default:
			t.Error(req.URL.Path)
			return jsonResponse(500, `{}`), nil
		}
	})}})
	r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, GracefulShutdown: true, PollInterval: 10 * time.Millisecond, Handler: func(ctx context.Context, m Message) error {
		if _, err := c.UpdateText(ctx, m.ReqID, "partial"); err != nil {
			return err
		}
		close(entered)
		select {
		case <-release:
		case <-ctx.Done():
			return ctx.Err()
		}
		_, err := c.ReplyText(ctx, m.ReqID, "done")
		return err
	}})
	done := make(chan error, 1)
	go func() { done <- r.Run(context.Background()) }()
	awaitSignal(t, entered)
	awaitSignal(t, renewed)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	drained := make(chan error, 1)
	go func() { drained <- r.Drain(ctx) }()
	awaitSignal(t, r.lifetime().wake)
	awaitSignal(t, renewed)
	close(release)
	if err := awaitError(t, drained); err != nil {
		t.Fatal(err)
	}
	if err := awaitError(t, done); err != nil {
		t.Fatal(err)
	}
	if polls.Load() != 1 || retired.Load() != 1 || replies.Load() != 2 || leases.Load() < 2 {
		t.Fatal(polls.Load(), retired.Load(), replies.Load(), leases.Load())
	}
}

func TestHTTPDrainDeadlineReturnsWithoutAcknowledgingAnUncooperativeHandler(t *testing.T) {
	var retired atomic.Int32
	entered, release := make(chan struct{}), make(chan struct{})
	c, _ := NewClient(Config{BaseURL: "http://exiron.test", Transport: TransportHTTP, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		switch req.URL.Path {
		case "/api/capabilities":
			return jsonResponse(200, drainCapabilities), nil
		case "/api/requests":
			return jsonResponse(200, drainBatch), nil
		case "/api/client-lease":
			return jsonResponse(200, `{"ok":true,"lease_timeout_ms":3000}`), nil
		case "/api/client-retire":
			retired.Add(1)
			return jsonResponse(200, `{"ok":true}`), nil
		default:
			t.Error(req.URL.Path)
			return jsonResponse(500, `{}`), nil
		}
	})}})
	r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, GracefulShutdown: true, Handler: func(context.Context, Message) error { close(entered); <-release; return nil }})
	done := make(chan error, 1)
	go func() { done <- r.Run(context.Background()) }()
	awaitSignal(t, entered)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	if err := r.Drain(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal(err)
	}
	if retired.Load() != 0 {
		t.Fatal("acknowledged unfinished work")
	}
	close(release)
	_ = awaitError(t, done)
	if retired.Load() != 0 {
		t.Fatal("late acknowledgement after deadline")
	}
}

func TestWebSocketDrainMaintainsHeartbeatAndUsesConfirmedRetirementInsteadOfAck(t *testing.T) {
	entered, release, ping := make(chan struct{}), make(chan struct{}), make(chan struct{}, 20)
	var retired, acks atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		switch req.URL.Path {
		case "/api/capabilities":
			_, _ = w.Write([]byte(drainCapabilities))
		case "/api/client-retire":
			retired.Add(1)
			_, _ = w.Write([]byte(`{"ok":true}`))
		case "/api/socket":
			conn, err := (&websocket.Upgrader{}).Upgrade(w, req, nil)
			if err != nil {
				t.Error(err)
				return
			}
			defer conn.Close()
			_ = conn.WriteMessage(websocket.TextMessage, contractFixture(t, "websocket_connected_frame.json"))
			var batch map[string]any
			_ = json.Unmarshal([]byte(drainBatch), &batch)
			_ = conn.WriteJSON(map[string]any{"type": "messages", "delivery_id": "batch-1", "messages": batch["requests"]})
			for {
				var frame map[string]any
				if conn.ReadJSON(&frame) != nil {
					return
				}
				if frame["type"] == "ping" {
					ping <- struct{}{}
					_ = conn.WriteJSON(map[string]string{"type": "pong"})
				}
				if frame["type"] == "ack" {
					acks.Add(1)
				}
			}
		default:
			t.Error(req.URL.Path)
		}
	}))
	defer server.Close()
	c, _ := New(server.URL, WithToken("token"))
	r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, GracefulShutdown: true, DisconnectTimeout: 300 * time.Millisecond, Handler: func(ctx context.Context, _ Message) error {
		close(entered)
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}})
	done := make(chan error, 1)
	go func() { done <- r.Run(context.Background()) }()
	awaitSignal(t, entered)
	if status := r.Status(); status.Phase != "handling" || status.ActiveHandlers != 1 || !status.Connected {
		t.Fatal(status)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	drained := make(chan error, 1)
	go func() { drained <- r.Drain(ctx) }()
	awaitSignal(t, r.lifetime().wake)
	awaitSignal(t, ping)
	close(release)
	if err := awaitError(t, drained); err != nil {
		t.Fatal(err)
	}
	if err := awaitError(t, done); err != nil {
		t.Fatal(err)
	}
	if retired.Load() != 1 || acks.Load() != 0 {
		t.Fatal(retired.Load(), acks.Load())
	}
}

func TestGracefulShutdownRequiresCapabilityAndRetirementErrorsAreNotRetried(t *testing.T) {
	for _, support := range []bool{false, true} {
		var polls, retired atomic.Int32
		entered, release := make(chan struct{}), make(chan struct{})
		c, _ := NewClient(Config{BaseURL: "http://exiron.test", Transport: TransportHTTP, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			switch req.URL.Path {
			case "/api/capabilities":
				if support {
					return jsonResponse(200, drainCapabilities), nil
				}
				return jsonResponse(200, `{"protocol_version":"1.15","capabilities":["http_lease_renewal"]}`), nil
			case "/api/requests":
				polls.Add(1)
				return jsonResponse(200, drainBatch), nil
			case "/api/client-lease":
				return jsonResponse(200, `{"ok":true,"lease_timeout_ms":3000}`), nil
			case "/api/client-retire":
				retired.Add(1)
				return jsonResponse(409, `{"code":"client_lease_lost","error":"lost"}`), nil
			default:
				t.Error(req.URL.Path)
				return jsonResponse(500, `{}`), nil
			}
		})}})
		r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, GracefulShutdown: true, Handler: func(context.Context, Message) error { close(entered); <-release; return nil }})
		done := make(chan error, 1)
		go func() { done <- r.Run(context.Background()) }()
		if !support {
			if err := awaitError(t, done); err == nil || polls.Load() != 0 {
				t.Fatal(err, polls.Load())
			}
			continue
		}
		awaitSignal(t, entered)
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		drained := make(chan error, 1)
		go func() { drained <- r.Drain(ctx) }()
		awaitSignal(t, r.lifetime().wake)
		close(release)
		if err := awaitError(t, drained); !IsClientLeaseLost(err) {
			t.Fatal(err)
		}
		if err := awaitError(t, done); !IsClientLeaseLost(err) {
			t.Fatal(err)
		}
		cancel()
		if retired.Load() != 1 || polls.Load() != 1 {
			t.Fatal(retired.Load(), polls.Load())
		}
	}
}

func awaitSignal(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(3 * time.Second):
		t.Fatal("event timed out")
	}
}
func awaitError(t *testing.T, ch <-chan error) error {
	t.Helper()
	select {
	case err := <-ch:
		return err
	case <-time.After(3 * time.Second):
		t.Fatal("runner did not stop")
		return nil
	}
}

func TestDrainDoesNotReconnectAfterAnUncertainRetirement(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	var polls, retired atomic.Int32
	c, _ := NewClient(Config{BaseURL: "http://exiron.test", Transport: TransportHTTP, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		switch req.URL.Path {
		case "/api/capabilities":
			return jsonResponse(200, drainCapabilities), nil
		case "/api/requests":
			polls.Add(1)
			return jsonResponse(200, drainBatch), nil
		case "/api/client-lease":
			return jsonResponse(200, `{"ok":true,"lease_timeout_ms":3000}`), nil
		case "/api/client-retire":
			retired.Add(1)
			return nil, errors.New("retirement response lost")
		default:
			t.Error(req.URL.Path)
			return jsonResponse(500, `{}`), nil
		}
	})}})
	r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, GracefulShutdown: true, Handler: func(context.Context, Message) error { close(entered); <-release; return nil }})
	done := make(chan error, 1)
	go func() { done <- r.Run(context.Background()) }()
	awaitSignal(t, entered)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	drained := make(chan error, 1)
	go func() { drained <- r.Drain(ctx) }()
	awaitSignal(t, r.lifetime().wake)
	close(release)
	if err := awaitError(t, drained); !isTransportError(err) {
		t.Fatal(err)
	}
	if err := awaitError(t, done); !isTransportError(err) {
		t.Fatal(err)
	}
	if retired.Load() != 1 || polls.Load() != 1 {
		t.Fatal(retired.Load(), polls.Load())
	}
}
