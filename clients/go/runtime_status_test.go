package exiron

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestRunnerStatusDuringBlockedHTTPWorkAndDrain(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	c, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "private-token", Transport: TransportHTTP,
		HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			switch req.URL.Path {
			case "/api/capabilities":
				return jsonResponse(200, drainCapabilities), nil
			case "/api/requests":
				return jsonResponse(200, drainBatch), nil
			case "/api/client-lease":
				return jsonResponse(200, `{"ok":true,"lease_timeout_ms":3000}`), nil
			case "/api/client-retire":
				return jsonResponse(200, `{"ok":true}`), nil
			}
			return nil, errors.New("private-token")
		})}})
	var r *Runner
	r = c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, GracefulShutdown: true, Handler: func(context.Context, Message) error {
		s := r.Status() // Safe even from the handler.
		if s.Phase != "handling" || s.ActiveHandlers != 1 || !s.Connected || s.LastConnectedAt.IsZero() {
			t.Errorf("handler status: %+v", s)
		}
		close(entered)
		<-release
		return nil
	}})
	if s := r.Status(); s.Phase != "idle" {
		t.Fatal(s)
	}
	done := make(chan error, 1)
	go func() { done <- r.Run(context.Background()) }()
	awaitSignal(t, entered)
	before := r.Status()
	if before.BatchSize != 1 || before.BatchCompleted != 0 || before.BatchAge <= 0 {
		t.Fatal(before)
	}
	deadline, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	drained := make(chan error, 1)
	go func() { drained <- r.Drain(deadline) }()
	awaitSignal(t, r.lifetime().wake)
	s := r.Status()
	if s.Phase != "draining" || s.ActiveHandlers != 1 || s.DrainStartedAt.IsZero() || s.DrainRemaining <= 0 {
		t.Fatal(s)
	}
	encoded, _ := json.Marshal(s)
	if strings.Contains(string(encoded), "private-token") || strings.Contains(string(encoded), "req-1") {
		t.Fatal(string(encoded))
	}
	close(release)
	if err := awaitError(t, drained); err != nil {
		t.Fatal(err)
	}
	if err := awaitError(t, done); err != nil {
		t.Fatal(err)
	}
	s = r.Status()
	if s.Phase != "stopped" || s.Connected || s.ActiveHandlers != 0 || s.BatchCompleted != 1 || s.BatchAge != 0 || s.DrainRemaining != 0 {
		t.Fatal(s)
	}
}

func TestRunnerStatusReportsBackoffAndRedactsErrors(t *testing.T) {
	waiting, release := make(chan struct{}), make(chan struct{})
	c, _ := NewClient(Config{BaseURL: "http://exiron.test", Transport: TransportHTTP, Retry: RetryPolicy{MaxElapsed: time.Nanosecond}, HTTPClient: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) { return nil, errors.New("private-url-and-token") })}})
	r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, Handler: func(context.Context, Message) error { return nil }})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	r.wait = func(context.Context, time.Duration) error { close(waiting); <-release; return context.Canceled }
	done := make(chan error, 1)
	go func() { done <- r.Run(ctx) }()
	awaitSignal(t, waiting)
	s := r.Status()
	if s.Phase != "backing_off" || s.Connected || s.RetryAt.IsZero() || s.RetryIn <= 0 || s.LastError.Kind != "transport_error" {
		t.Fatal(s)
	}
	bytes, _ := json.Marshal(s)
	if strings.Contains(string(bytes), "private-") {
		t.Fatal(string(bytes))
	}
	cancel()
	close(release)
	_ = awaitError(t, done)
	if r.Status().Phase != "stopped" || !r.Status().RetryAt.IsZero() {
		t.Fatal(r.Status())
	}
}

func TestRunnerStatusConcurrentReadsAndHandlerProgress(t *testing.T) {
	c, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	entered := make(chan struct{}, 2)
	release := make(chan struct{})
	r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerConcurrency: 2, Handler: func(context.Context, Message) error { entered <- struct{}{}; <-release; return nil }})
	done := make(chan error, 1)
	go func() { done <- r.handleBatch(context.Background(), []Message{{ReqID: "one"}, {ReqID: "two"}}) }()
	awaitSignal(t, entered)
	awaitSignal(t, entered)
	if s := r.Status(); s.ActiveHandlers != 2 || s.BatchSize != 2 || s.BatchCompleted != 0 {
		t.Fatal(s)
	}
	var readers sync.WaitGroup
	for i := 0; i < 8; i++ {
		readers.Add(1)
		go func() {
			defer readers.Done()
			for j := 0; j < 1000; j++ {
				_ = r.Status()
			}
		}()
	}
	close(release)
	if err := awaitError(t, done); err != nil {
		t.Fatal(err)
	}
	readers.Wait()
	if s := r.Status(); s.ActiveHandlers != 0 || s.BatchCompleted != 2 {
		t.Fatal(s)
	}
	// Caller mutation cannot change the retained status.
	s := r.Status()
	s.LastError.Kind = "secret"
	if r.Status().LastError.Kind != "" {
		t.Fatal(r.Status())
	}
}

func TestRunnerStatusHandlerErrorsAreBoundedAndRunResets(t *testing.T) {
	c, _ := NewClient(Config{BaseURL: "http://exiron.test", Transport: TransportHTTP, HTTPClient: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) { return jsonResponse(200, drainBatch), nil })}})
	var r *Runner
	r = c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, Handler: func(context.Context, Message) error {
		if r.Status().LastError.Kind != "" {
			t.Error("previous run's error was retained")
		}
		return errors.New("private-message-content")
	}})
	for i := 0; i < 2; i++ {
		if err := r.Run(context.Background()); err == nil {
			t.Fatal("expected failure")
		}
		s := r.Status()
		if s.Phase != "stopped" || s.LastError.Kind != "handler_error" || s.BatchCompleted != 0 || s.ActiveHandlers != 0 {
			t.Fatal(s)
		}
		b, _ := json.Marshal(s)
		if strings.Contains(string(b), "private-message") {
			t.Fatal(string(b))
		}
	}
}
