package exiron

import (
	"context"
	"errors"
	"net/http"
	"reflect"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestRunnerUsesRetryAfterForWebSocketConflict(t *testing.T) {
	var upgrader websocket.Upgrader
	var attempts atomic.Int32

	server := newWebSocketTestServer(t, func(conn *websocket.Conn, attempt int32) {
		frame := map[string]any{"type": "error", "error": "stop"}
		if attempt == 1 {
			frame = map[string]any{
				"type":           "error",
				"error":          "hook already connected",
				"retry_after_ms": 12,
			}
		}
		if err := conn.WriteJSON(frame); err != nil {
			t.Fatalf("write error frame: %v", err)
		}
	}, &upgrader, &attempts)
	defer server.Close()

	client, err := New(server.URL, WithToken("ai-token"), WithClientID("runner"))
	if err != nil {
		t.Fatalf("New returned error: %v", err)
	}

	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true,
		PollInterval: 250 * time.Millisecond,
		Handler: func(context.Context, Message) error {
			return nil
		},
	})
	var waits []time.Duration
	runner.wait = func(_ context.Context, delay time.Duration) error {
		waits = append(waits, delay)
		return nil
	}

	apiErr := requireAPIError(t, runner.Run(context.Background()))
	if apiErr.Message != "stop" {
		t.Fatalf("Run error = %#v, want stop", apiErr)
	}
	if attempts.Load() != 2 {
		t.Fatalf("attempts = %d, want 2", attempts.Load())
	}
	if want := []time.Duration{12 * time.Millisecond}; !reflect.DeepEqual(waits, want) {
		t.Fatalf("waits = %v, want %v", waits, want)
	}
}

func TestRunnerLifecycleCallbacks(t *testing.T) {
	var attempts atomic.Int32
	var connected int
	var disconnected []error

	client, err := NewClient(Config{
		BaseURL:  "http://exiron.test",
		Token:    "ai-token",
		ClientID: "runner",
		HTTPClient: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			switch attempts.Add(1) {
			case 1, 2:
				return jsonResponse(http.StatusOK, `{"requests":[]}`), nil
			default:
				return jsonResponse(http.StatusConflict, `{"error":"stop"}`), nil
			}
		})},
		Retry:     RetryPolicy{MaxElapsed: -1},
		Transport: TransportHTTP,
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true,
		PollInterval: time.Millisecond,
		Handler: func(context.Context, Message) error {
			return nil
		},
		OnConnect: func(context.Context) {
			connected++
		},
		OnDisconnect: func(_ context.Context, err error) {
			disconnected = append(disconnected, err)
		},
	})

	err = runner.Run(context.Background())
	apiErr := requireAPIError(t, err)
	if apiErr.Message != "stop" {
		t.Fatalf("Run error = %#v, want stop", apiErr)
	}
	if connected != 1 {
		t.Fatalf("connected callbacks = %d, want 1", connected)
	}
	if len(disconnected) != 1 {
		t.Fatalf("disconnected callbacks = %d, want 1", len(disconnected))
	}
	if disconnectErr := requireAPIError(t, disconnected[0]); disconnectErr.Message != "stop" {
		t.Fatalf("disconnect error = %#v, want stop", disconnectErr)
	}
}

func TestRunnerReconnectsAfterTransportError(t *testing.T) {
	var attempts atomic.Int32
	var connected atomic.Int32
	var disconnected []error

	client, err := NewClient(Config{
		BaseURL:  "http://exiron.test",
		Token:    "ai-token",
		ClientID: "runner",
		HTTPClient: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			switch attempts.Add(1) {
			case 1:
				return jsonResponse(http.StatusOK, `{"requests":[]}`), nil
			case 2:
				return nil, errors.New("connection refused")
			default:
				return jsonResponse(http.StatusOK, `{"requests":[]}`), nil
			}
		})},
		Retry:     RetryPolicy{MaxElapsed: -1},
		Transport: TransportHTTP,
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true,
		PollInterval: time.Millisecond,
		Handler: func(context.Context, Message) error {
			return nil
		},
		OnConnect: func(context.Context) {
			if connected.Add(1) == 2 {
				cancel()
			}
		},
		OnDisconnect: func(_ context.Context, err error) {
			disconnected = append(disconnected, err)
		},
	})

	if err := runner.Run(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("Run error = %v, want context canceled", err)
	}
	if connected.Load() != 2 {
		t.Fatalf("connected callbacks = %d, want 2", connected.Load())
	}
	if len(disconnected) == 0 {
		t.Fatalf("disconnected callbacks = 0, want at least transport disconnect")
	}
	if disconnectErr := requireAPIError(t, disconnected[0]); disconnectErr.Reason != "transport_error" {
		t.Fatalf("disconnect error = %#v, want transport error", disconnectErr)
	}
	if attempts.Load() < 3 {
		t.Fatalf("attempts = %d, want at least 3", attempts.Load())
	}
}
