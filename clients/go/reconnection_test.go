package exiron

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestRetryJitterBoundsAndHints(t *testing.T) {
	p := normalizeRetry(RetryPolicy{InitialDelay: time.Second, MaxDelay: 2 * time.Second})
	for _, base := range []time.Duration{time.Nanosecond, time.Second, 4 * time.Second} {
		capped := min(base, p.MaxDelay)
		for i := 0; i < 100; i++ {
			got := retryDelay(p, base, transportError(errors.New("offline")))
			if got < capped/2 || got > capped {
				t.Fatalf("jitter %v outside [%v,%v]", got, capped/2, capped)
			}
		}
	}
	p.DisableJitter = true
	if got := retryDelay(p, time.Second, nil); got != time.Second {
		t.Fatal(got)
	}
	for _, status := range []int{409, 429} {
		e := &Error{StatusCode: status, RetryAfterMS: 5000, Reason: "hook_already_connected"}
		if got := retryDelay(p, time.Second, e); got != 5*time.Second {
			t.Fatal(got)
		}
	}
	if canRetry(p, time.Now(), time.Duration(math.MaxInt64)) {
		t.Fatal("overflow bypassed retry budget")
	}
	if got := nextRetryDelay(time.Duration(math.MaxInt64-1), time.Duration(math.MaxInt64)); got != time.Duration(math.MaxInt64) {
		t.Fatal(got)
	}
}

func TestRetryAfterParsing(t *testing.T) {
	now := time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		header string
		want   int
	}{
		{" 2 ", 2000}, {now.Add(3 * time.Second).Format(http.TimeFormat), 3000},
		{"-1", 0}, {"1.5", 0}, {"nonsense", 0}, {"", 0}, {"0", 0},
		{now.Add(-time.Second).Format(http.TimeFormat), 0},
	} {
		e := responseError(429, []byte(`{"error":"limited"}`), http.Header{"Retry-After": {tc.header}}, now)
		if e.RetryAfterMS != tc.want {
			t.Fatalf("%q => %d want %d", tc.header, e.RetryAfterMS, tc.want)
		}
	}
	e := responseError(429, []byte(`{"error":"limited","retry_after_ms":3000}`), http.Header{"Retry-After": {"1"}}, now)
	if e.RetryAfterMS != 3000 {
		t.Fatal(e)
	}
	e = responseError(429, nil, http.Header{"Retry-After": {"99999999999999999999999999999999"}}, now)
	if canRetry(normalizeRetry(RetryPolicy{}), time.Now(), retryDelay(normalizeRetry(RetryPolicy{}), time.Second, e)) {
		t.Fatal("huge hint bypassed budget")
	}
	e = responseError(503, nil, http.Header{"Retry-After": {"2"}}, now)
	if e.RetryAfterMS != 0 {
		t.Fatal("changed server error retry policy")
	}
}

func TestRateLimitRetriesOnlySafeOperations(t *testing.T) {
	for _, tc := range []struct {
		method, path string
		safe         bool
	}{
		{"GET", "/api/status", true}, {"GET", "/api/capabilities", true},
		{"GET", "/api/requests?delivery_mode=explicit", true}, {"GET", "/api/requests", false},
		{"POST", "/api/auth", true}, {"POST", "/api/responses", false}, {"POST", "/api/push", false},
		{"POST", "/api/idempotent/responses", false}, {"POST", "/api/client-lease", false},
	} {
		t.Run(tc.method+tc.path, func(t *testing.T) {
			attempts := 0
			var waits []time.Duration
			c, err := NewClient(Config{BaseURL: "http://exiron.test", Retry: RetryPolicy{MaxElapsed: 5 * time.Second, Sleep: func(_ context.Context, d time.Duration) error { waits = append(waits, d); return nil }}, HTTPClient: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
				attempts++
				if attempts == 1 {
					r := jsonResponse(429, `{"error":"limited"}`)
					r.Header.Set("Retry-After", "2")
					return r, nil
				}
				return jsonResponse(200, `{}`), nil
			})}})
			if err != nil {
				t.Fatal(err)
			}
			err = c.request(context.Background(), tc.method, tc.path, "", nil, nil)
			if tc.safe {
				if err != nil || attempts != 2 || len(waits) != 1 || waits[0] != 2*time.Second {
					t.Fatalf("%v attempts=%d waits=%v", err, attempts, waits)
				}
			} else if err == nil || attempts != 1 || len(waits) != 0 {
				t.Fatalf("unsafe replay: %v attempts=%d waits=%v", err, attempts, waits)
			}
		})
	}
}

func TestRateLimitBudgetAndCancellation(t *testing.T) {
	for _, cancelWait := range []bool{false, true} {
		ctx, cancel := context.WithCancel(context.Background())
		attempts, waits := 0, 0
		budget := time.Millisecond
		if cancelWait {
			budget = 5 * time.Second
		}
		c, _ := NewClient(Config{BaseURL: "http://exiron.test", Retry: RetryPolicy{MaxElapsed: budget, Sleep: func(ctx context.Context, _ time.Duration) error { waits++; cancel(); return ctx.Err() }}, HTTPClient: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
			attempts++
			r := jsonResponse(429, `{"error":"limited"}`)
			r.Header.Set("Retry-After", "2")
			return r, nil
		})}})
		err := c.request(ctx, "GET", "/api/status", "", nil, nil)
		cancel()
		if err == nil || attempts != 1 {
			t.Fatalf("attempts=%d err=%v", attempts, err)
		}
		if cancelWait && (!errors.Is(err, context.Canceled) || waits != 1) {
			t.Fatal(err, waits)
		}
		if !cancelWait && waits != 0 {
			t.Fatal("slept past budget")
		}
	}
}

func TestWebSocketHandshakeRateLimitHint(t *testing.T) {
	attempts := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts++
		if attempts == 1 {
			w.Header().Set("Retry-After", "2")
			w.WriteHeader(429)
			return
		}
		conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.Close()
		_ = conn.WriteJSON(map[string]any{"type": "error", "error": "stop"})
	}))
	defer server.Close()
	c, _ := New(server.URL, WithToken("token"))
	r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, Handler: func(context.Context, Message) error { return nil }})
	var waits []time.Duration
	r.wait = func(_ context.Context, d time.Duration) error { waits = append(waits, d); return nil }
	err := r.Run(context.Background())
	if err == nil || attempts != 2 || len(waits) != 1 || waits[0] != 2*time.Second {
		t.Fatal(err, attempts, waits)
	}
}

func TestRunnerBackoffResetsAfterConnection(t *testing.T) {
	c, _ := New("http://exiron.test", WithRetryPolicy(RetryPolicy{DisableJitter: true, MaxDelay: 4 * time.Second}))
	r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true, PollInterval: time.Second})
	coordinator := newRunnerCoordinator(r)
	calls := 0
	var waits []time.Duration
	r.wait = func(_ context.Context, d time.Duration) error { waits = append(waits, d); return nil }
	stop := errors.New("stop")
	err := coordinator.run(context.Background(), func(ctx context.Context) error {
		calls++
		if calls == 4 {
			coordinator.connect(ctx)
		}
		if calls == 5 {
			return stop
		}
		return transportError(errors.New("offline"))
	})
	if !errors.Is(err, stop) || len(waits) != 4 {
		t.Fatal(err, waits)
	}
	for i, want := range []time.Duration{time.Second, 2 * time.Second, 4 * time.Second, time.Second} {
		if waits[i] != want {
			t.Fatal(waits)
		}
	}
}

func TestWebSocketRetryBudgetRejectsLongHint(t *testing.T) {
	c, _ := New("http://exiron.test", WithRetryPolicy(RetryPolicy{MaxElapsed: time.Millisecond}))
	r := c.NewRunner(RunnerOptions{DisableRuntimeReporting: true})
	coordinator := newRunnerCoordinator(r)
	waits := 0
	r.wait = func(context.Context, time.Duration) error { waits++; return nil }
	failure := &Error{StatusCode: 429, RetryAfterMS: 2000, retryableConnection: true}
	err := coordinator.run(context.Background(), func(context.Context) error { return failure })
	if err != failure || waits != 0 {
		t.Fatal(err, waits)
	}
}

func TestRateLimitWithoutHintUsesJitterAndServerErrorsRemainFatal(t *testing.T) {
	for _, status := range []int{429, 401, 403, 500, 503} {
		attempts, waits := 0, 0
		c, _ := NewClient(Config{BaseURL: "http://exiron.test", Retry: RetryPolicy{InitialDelay: 10 * time.Millisecond, Sleep: func(_ context.Context, delay time.Duration) error {
			waits++
			if delay < 5*time.Millisecond || delay > 10*time.Millisecond {
				t.Error(delay)
			}
			return nil
		}}, HTTPClient: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
			attempts++
			if attempts == 1 {
				return jsonResponse(status, `{"error":"rejected"}`), nil
			}
			return jsonResponse(200, `{}`), nil
		})}})
		err := c.request(context.Background(), "GET", "/api/status", "", nil, nil)
		if status == 429 {
			if err != nil || attempts != 2 || waits != 1 {
				t.Fatal(err, attempts, waits)
			}
		} else if err == nil || attempts != 1 || waits != 0 {
			t.Fatal(err, attempts, waits)
		}
	}
}

func TestRateLimitedStreamDoesNotReplay(t *testing.T) {
	calls := 0
	c, _ := NewClient(Config{BaseURL: "http://exiron.test", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		calls++
		var payload wireResponsePayload
		if err := json.NewDecoder(req.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if payload.Final != nil && !*payload.Final {
			return jsonResponse(200, `{"ok":true,"final":false,"message_id":901}`), nil
		}
		response := jsonResponse(429, `{"error":"limited"}`)
		response.Header.Set("Retry-After", "1")
		return response, nil
	})}})
	chunks := make(chan string, 2)
	chunks <- "partial"
	chunks <- " done"
	close(chunks)
	_, err := c.StreamText(context.Background(), "req-1", chunks, StreamOptions{Interval: time.Hour})
	if !isRateLimited(err) || calls != 2 {
		t.Fatal(err, calls)
	}
}
