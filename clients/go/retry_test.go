package exiron

import (
	"context"
	"errors"
	"net/http"
	"reflect"
	"sync/atomic"
	"testing"
	"time"
)

func TestRetriesTransportErrorsWithExponentialBackoff(t *testing.T) {
	var attempts atomic.Int32
	var sleeps []time.Duration

	client, err := NewClient(Config{
		BaseURL: "http://exiron.test",
		Token:   "ai-token",
		HTTPClient: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			if attempts.Add(1) < 3 {
				return nil, errors.New("connection refused")
			}
			return jsonResponse(http.StatusOK, `{"enabled":true,"version":"0.1.0"}`), nil
		})},
		Retry: RetryPolicy{
			DisableJitter: true,
			InitialDelay:  10 * time.Millisecond,
			MaxDelay:      30 * time.Second,
			MaxElapsed:    30 * time.Second,
			Sleep: func(_ context.Context, delay time.Duration) error {
				sleeps = append(sleeps, delay)
				return nil
			},
		},
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	status, err := client.Status(context.Background())
	if err != nil {
		t.Fatalf("Status returned error: %v", err)
	}
	if !status.Enabled {
		t.Fatalf("status.Enabled = false, want true")
	}
	if attempts.Load() != 3 {
		t.Fatalf("attempts = %d, want 3", attempts.Load())
	}
	if want := []time.Duration{10 * time.Millisecond, 20 * time.Millisecond}; !reflect.DeepEqual(sleeps, want) {
		t.Fatalf("sleeps = %v, want %v", sleeps, want)
	}
}

func TestDoesNotRetryPushAfterAmbiguousTransportError(t *testing.T) {
	var attempts atomic.Int32
	var sleeps []time.Duration

	client, err := NewClient(Config{
		BaseURL: "http://exiron.test",
		Token:   "ai-token",
		HTTPClient: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			attempts.Add(1)
			return nil, errors.New("response connection closed")
		})},
		Retry: RetryPolicy{
			DisableJitter: true,
			InitialDelay:  10 * time.Millisecond,
			MaxDelay:      30 * time.Second,
			MaxElapsed:    30 * time.Second,
			Sleep: func(_ context.Context, delay time.Duration) error {
				sleeps = append(sleeps, delay)
				return nil
			},
		},
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	_, err = client.PushText(context.Background(), "hello")
	apiErr := requireAPIError(t, err)
	if apiErr.Reason != "transport_error" {
		t.Fatalf("Reason = %q, want transport_error", apiErr.Reason)
	}
	if attempts.Load() != 1 {
		t.Fatalf("attempts = %d, want 1", attempts.Load())
	}
	if len(sleeps) != 0 {
		t.Fatalf("sleeps = %v, want none", sleeps)
	}
}

func TestDoesNotRetryOneShotRequestsAfterAmbiguousTransportError(t *testing.T) {
	var attempts atomic.Int32
	var sleeps []time.Duration

	client, err := NewClient(Config{
		BaseURL: "http://exiron.test",
		Token:   "ai-token",
		HTTPClient: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			attempts.Add(1)
			return nil, errors.New("response connection closed")
		})},
		Retry: RetryPolicy{
			DisableJitter: true,
			InitialDelay:  10 * time.Millisecond,
			MaxDelay:      30 * time.Second,
			MaxElapsed:    30 * time.Second,
			Sleep: func(_ context.Context, delay time.Duration) error {
				sleeps = append(sleeps, delay)
				return nil
			},
		},
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	_, err = client.Requests(context.Background())
	apiErr := requireAPIError(t, err)
	if apiErr.Reason != "transport_error" {
		t.Fatalf("Reason = %q, want transport_error", apiErr.Reason)
	}
	if attempts.Load() != 1 {
		t.Fatalf("attempts = %d, want 1", attempts.Load())
	}
	if len(sleeps) != 0 {
		t.Fatalf("sleeps = %v, want none", sleeps)
	}
}

func TestStopsRetryingAfterConfiguredRetryTime(t *testing.T) {
	var attempts atomic.Int32
	var sleeps []time.Duration

	client, err := NewClient(Config{
		BaseURL: "http://exiron.test",
		HTTPClient: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			attempts.Add(1)
			return nil, errors.New("connection refused")
		})},
		Retry: RetryPolicy{
			DisableJitter: true,
			InitialDelay:  20 * time.Millisecond,
			MaxDelay:      30 * time.Second,
			MaxElapsed:    30 * time.Millisecond,
			Sleep: func(_ context.Context, delay time.Duration) error {
				sleeps = append(sleeps, delay)
				return nil
			},
		},
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	_, err = client.Status(context.Background())
	apiErr := requireAPIError(t, err)
	if apiErr.Reason != "transport_error" {
		t.Fatalf("Reason = %q, want transport_error", apiErr.Reason)
	}
	if attempts.Load() != 2 {
		t.Fatalf("attempts = %d, want 2", attempts.Load())
	}
	if want := []time.Duration{20 * time.Millisecond}; !reflect.DeepEqual(sleeps, want) {
		t.Fatalf("sleeps = %v, want %v", sleeps, want)
	}
}

func TestRetriesHookAlreadyConnectedWithServerDelay(t *testing.T) {
	var attempts atomic.Int32
	var sleeps []time.Duration

	client, err := NewClient(Config{
		BaseURL:  "http://exiron.test",
		Token:    "ai-token",
		ClientID: "worker",
		HTTPClient: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			if attempts.Add(1) == 1 {
				return jsonResponse(http.StatusConflict, `{"error":"hook already connected","retry_after_ms":12}`), nil
			}
			return jsonResponse(http.StatusOK, `{"requests":[]}`), nil
		})},
		Retry: RetryPolicy{
			DisableJitter: true,
			InitialDelay:  250 * time.Millisecond,
			MaxDelay:      30 * time.Second,
			MaxElapsed:    30 * time.Second,
			Sleep: func(_ context.Context, delay time.Duration) error {
				sleeps = append(sleeps, delay)
				return nil
			},
		},
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	requests, _, err := client.requestsDelivery(context.Background(), "")
	if err != nil {
		t.Fatalf("Requests returned error: %v", err)
	}
	if len(requests) != 0 {
		t.Fatalf("len(requests) = %d, want 0", len(requests))
	}
	if attempts.Load() != 2 {
		t.Fatalf("attempts = %d, want 2", attempts.Load())
	}
	if want := []time.Duration{12 * time.Millisecond}; !reflect.DeepEqual(sleeps, want) {
		t.Fatalf("sleeps = %v, want %v", sleeps, want)
	}
}
