package exiron

import (
	"context"
	"errors"
	"net/http"
	"reflect"
	"testing"
	"time"
)

func TestRunnerPollsAndHandlesMessages(t *testing.T) {
	var attempts int
	var handled []string

	client, err := NewClient(Config{
		BaseURL:  "http://exiron.test",
		Token:    "ai-token",
		ClientID: "runner",
		HTTPClient: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			attempts++
			switch attempts {
			case 1:
				if r.URL.Query().Get("delivery_mode") != "explicit" || r.URL.Query().Get("delivery_ack") != "" {
					t.Fatalf("first poll query = %q, want unacknowledged explicit delivery", r.URL.RawQuery)
				}
				return jsonResponse(http.StatusOK, `{"delivery_id":"delivery-1","requests":[{"msgtype":"request","req_id":"req-1","datatype":"text","data":"aGVsbG8="}]}`), nil
			default:
				if r.URL.Query().Get("delivery_ack") != "delivery-1" {
					t.Fatalf("delivery_ack = %q, want delivery-1", r.URL.Query().Get("delivery_ack"))
				}
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
		Handler: func(_ context.Context, message Message) error {
			handled = append(handled, message.Text())
			return nil
		},
	})

	err = runner.Run(context.Background())
	apiErr := requireAPIError(t, err)
	if apiErr.Message != "stop" {
		t.Fatalf("Run error = %#v, want stop", apiErr)
	}
	if want := []string{"hello"}; !reflect.DeepEqual(handled, want) {
		t.Fatalf("handled = %v, want %v", handled, want)
	}
}

func TestRunnerDisconnectsAfterPollTimeout(t *testing.T) {
	attempts := 0
	var disconnected []error

	client, err := NewClient(Config{
		BaseURL:  "http://exiron.test",
		Token:    "ai-token",
		ClientID: "runner",
		HTTPClient: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			attempts++
			switch attempts {
			case 1:
				return jsonResponse(http.StatusOK, `{"requests":[]}`), nil
			default:
				<-r.Context().Done()
				return nil, r.Context().Err()
			}
		})},
		Transport: TransportHTTP,
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true,
		PollInterval:      time.Millisecond,
		DisconnectTimeout: 25 * time.Millisecond,
		Handler: func(context.Context, Message) error {
			return nil
		},
		OnDisconnect: func(_ context.Context, err error) {
			disconnected = append(disconnected, err)
			cancel()
		},
	})

	if err := runner.Run(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("Run error = %v, want context canceled", err)
	}
	if len(disconnected) != 1 {
		t.Fatalf("disconnected callbacks = %d, want 1", len(disconnected))
	}
	if disconnectErr := requireAPIError(t, disconnected[0]); disconnectErr.Reason != "transport_error" {
		t.Fatalf("disconnect error = %#v, want transport error", disconnectErr)
	}
	if attempts != 2 {
		t.Fatalf("attempts = %d, want 2", attempts)
	}
}

func TestRunnerStopsOnHandlerError(t *testing.T) {
	handlerErr := errors.New("handler failed")

	client, err := NewClient(Config{
		BaseURL: "http://exiron.test",
		HTTPClient: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			return jsonResponse(http.StatusOK, `{"requests":[{"msgtype":"request","req_id":"req-1","datatype":"text","data":"aGVsbG8="}]}`), nil
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
			return handlerErr
		},
	})

	if err := runner.Run(context.Background()); !errors.Is(err, handlerErr) {
		t.Fatalf("Run error = %v, want handler error", err)
	}
}
