package exiron

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

type lifecycleCatalog struct {
	Version  string          `json:"scenario_version"`
	Message  map[string]any  `json:"message"`
	Partial  string          `json:"partial_text"`
	Reply    string          `json:"reply_text"`
	Recovery string          `json:"recovery_text"`
	Cases    []lifecycleCase `json:"cases"`
}
type lifecycleCase struct {
	ID                   string         `json:"id"`
	Transport            string         `json:"transport"`
	Operation            string         `json:"operation"`
	Timeout              int            `json:"handler_timeout_ms"`
	CancellationInterval int            `json:"cancellation_interval_ms"`
	Steps                []string       `json:"steps"`
	Expect               map[string]any `json:"expect"`
}

// Every case drives a real Runner and protocol transport. The gateway retains
// ownership until an ack/retirement is accepted; no outcome is inferred from a
// callback alone. Both SDKs consume this same input and expected observation.
func TestSharedManagedLifecycleScenarios(t *testing.T) {
	raw, err := os.ReadFile("../contract/lifecycle/managed.json")
	if err != nil {
		t.Fatal(err)
	}
	var catalog lifecycleCatalog
	if err = json.Unmarshal(raw, &catalog); err != nil {
		t.Fatal(err)
	}
	if catalog.Version != "1" || len(catalog.Cases) != 10 {
		t.Fatal("unsupported lifecycle catalog")
	}
	for _, scenario := range catalog.Cases {
		t.Run(scenario.ID, func(t *testing.T) { runLifecycleScenario(t, catalog, scenario) })
	}
}

type lifecycleGateway struct {
	t            *testing.T
	catalog      lifecycleCatalog
	scenario     lifecycleCase
	mu           sync.Mutex
	observed     map[string]any
	stage        int
	available    bool
	cancelled    bool
	entered      chan struct{}
	partial      chan struct{}
	acknowledged chan struct{}
	release      chan bool
}

func (g *lifecycleGateway) add(key string) int {
	g.mu.Lock()
	defer g.mu.Unlock()
	value := g.observed[key].(int) + 1
	g.observed[key] = value
	return value
}
func (g *lifecycleGateway) observe(key string, value any) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.observed[key] = value
}
func (g *lifecycleGateway) message() map[string]any {
	g.mu.Lock()
	defer g.mu.Unlock()
	message := map[string]any{}
	for k, v := range g.catalog.Message {
		message[k] = v
	}
	if g.stage > 0 {
		message["req_id"] = "req-2"
	}
	return message
}
func (g *lifecycleGateway) ack() bool {
	attempt := g.add("ack_attempts")
	if g.scenario.Operation == "connection_loss_before_ack" && attempt == 1 {
		return false
	}
	g.add("ack_commits")
	g.mu.Lock()
	g.available = false
	g.mu.Unlock()
	g.acknowledged <- struct{}{}
	return true
}
func (g *lifecycleGateway) serve(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	write := func(body any) {
		if err := json.NewEncoder(w).Encode(body); err != nil {
			g.t.Error(err)
		}
	}
	switch req.URL.Path {
	case "/api/capabilities":
		write(contractMap(g.t, "capabilities_response.json"))
	case "/api/requests":
		if req.URL.Query().Get("delivery_ack") != "" {
			if req.URL.Query().Get("delivery_ack") != "batch" {
				g.t.Error("acknowledged wrong HTTP delivery")
			}
			if !g.ack() {
				conn, _, err := w.(http.Hijacker).Hijack()
				if err != nil {
					g.t.Error(err)
					return
				}
				_ = conn.Close()
				return
			}
			write(map[string]any{"requests": []any{}})
		} else {
			g.mu.Lock()
			available := g.available
			g.mu.Unlock()
			if available {
				write(map[string]any{"delivery_id": "batch", "requests": []any{g.message()}})
			} else {
				write(map[string]any{"requests": []any{}})
			}
		}
	case "/api/client-lease":
		write(map[string]any{"ok": true, "lease_timeout_ms": 10000})
	case "/api/request-state":
		g.mu.Lock()
		cancelled := g.cancelled
		g.mu.Unlock()
		state := "active"
		if cancelled {
			state = "cancelled"
		}
		write(map[string]any{"req_id": req.URL.Query().Get("req_id"), "state": state})
	case "/api/responses":
		var payload struct {
			Final *bool  `json:"final"`
			Data  string `json:"data"`
			ReqID string `json:"req_id"`
		}
		if err := json.NewDecoder(req.Body).Decode(&payload); err != nil {
			g.t.Error(err)
		}
		if payload.Final != nil && !*payload.Final {
			// Count partials separately from final mutations, including after stop.
			g.add("partial_replies")
			g.partial <- struct{}{}
		} else {
			g.add("final_replies")
		}
		data, err := base64.StdEncoding.DecodeString(payload.Data)
		if err != nil {
			g.t.Error(err)
		}
		final := payload.Final == nil || *payload.Final
		g.mu.Lock()
		g.observed["replies"] = append(g.observed["replies"].([]any), map[string]any{"request_id": payload.ReqID, "text": string(data), "final": final})
		g.mu.Unlock()
		write(map[string]bool{"ok": true})
	case "/api/client-retire":
		var payload map[string]string
		if err := json.NewDecoder(req.Body).Decode(&payload); err != nil {
			g.t.Error(err)
		}
		if payload["delivery_id"] != "batch" || payload["client_id"] != "lifecycle" {
			g.t.Errorf("retired wrong delivery: %v", payload)
		}
		g.add("retirements")
		g.mu.Lock()
		g.stage++
		g.available = g.scenario.Operation == "quarantine_recovery_restart" && g.stage == 1
		g.mu.Unlock()
		write(map[string]bool{"ok": true})
	case "/api/socket":
		conn, err := (&websocket.Upgrader{}).Upgrade(w, req, nil)
		if err != nil {
			g.t.Error(err)
			return
		}
		defer conn.Close()
		if conn.WriteJSON(contractMap(g.t, "websocket_connected_frame.json")) != nil {
			return
		}
		if conn.WriteJSON(map[string]any{"type": "messages", "delivery_id": "batch", "messages": []any{g.message()}}) != nil {
			return
		}
		for {
			var frame map[string]any
			if conn.ReadJSON(&frame) != nil {
				return
			}
			switch frame["type"] {
			case "ping":
				if conn.WriteJSON(map[string]string{"type": "pong"}) != nil {
					return
				}
			case "ack":
				if frame["delivery_id"] != "batch" {
					g.t.Error("acknowledged wrong delivery")
				}
				if !g.ack() {
					return
				}
			default:
				g.t.Errorf("unexpected client frame: %v", frame)
				return
			}
		}
	default:
		g.t.Errorf("unexpected endpoint: %s", req.URL.Path)
		http.Error(w, "unexpected", 500)
	}
}

func runLifecycleScenario(t *testing.T, catalog lifecycleCatalog, scenario lifecycleCase) {
	g := &lifecycleGateway{t: t, catalog: catalog, scenario: scenario, available: true, observed: map[string]any{}, entered: make(chan struct{}, 8), partial: make(chan struct{}, 8), acknowledged: make(chan struct{}, 8), release: make(chan bool, 8)}
	for key := range scenario.Expect {
		if key == "replies" {
			g.observed[key] = []any{}
		} else if key != "outcome" {
			g.observed[key] = 0
		}
	}
	server := httptest.NewServer(http.HandlerFunc(g.serve))
	defer server.Close()
	transport := TransportHTTP
	if scenario.Transport == "websocket" {
		transport = TransportWebSocket
	} else if scenario.Transport != "http" {
		t.Fatal("unknown transport")
	}
	client, err := NewClient(Config{BaseURL: server.URL, Token: "synthetic", ClientID: "lifecycle", Transport: transport, HTTPClient: &http.Client{Timeout: time.Second}, Retry: RetryPolicy{InitialDelay: time.Millisecond, MaxDelay: 5 * time.Millisecond, MaxElapsed: time.Second, DisableJitter: true}})
	if err != nil {
		t.Fatal(err)
	}
	store, err := NewQuarantine(QuarantineOptions{MaxMessages: 10, MaxBytes: 65536})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	handler := func(ctx context.Context, message Message) error {
		g.add("handler_calls")
		g.entered <- struct{}{}
		switch scenario.Operation {
		case "failure_during_drain", "quarantine_recovery_restart":
			select {
			case success := <-g.release:
				if !success {
					return errors.New("synthetic handler failure")
				}
			case <-ctx.Done():
				return ctx.Err()
			}
		case "deadline_during_stream", "cancellation_during_stream":
			chunks := make(chan string, 1)
			chunks <- catalog.Partial
			defer close(chunks)
			_, err := client.StreamText(ctx, message.ReqID, chunks, StreamOptions{Interval: time.Millisecond})
			return err
		case "connection_loss_before_ack":
		default:
			return errors.New("unknown lifecycle operation")
		}
		_, err := client.ReplyText(ctx, message.ReqID, catalog.Reply)
		return err
	}
	opts := RunnerOptions{DisableRuntimeReporting: true, GracefulShutdown: true, PollInterval: 10 * time.Millisecond, DisconnectTimeout: time.Second, Handler: handler, HandlerTimeout: time.Duration(scenario.Timeout) * time.Millisecond, Quarantine: store}
	if scenario.Operation == "quarantine_recovery_restart" || scenario.Operation == "deadline_during_stream" {
		opts.HandlerFailurePolicy = HandlerFailureQuarantine
	}
	if scenario.Operation == "cancellation_during_stream" {
		opts.CooperativeCancellation = true
		opts.CancellationInterval = time.Duration(scenario.CancellationInterval) * time.Millisecond
	}
	var runner *Runner
	var done chan error
	var drained chan error
	start := func() {
		runner = client.NewRunner(opts)
		done = make(chan error, 1)
		current, result := runner, done
		go func() { result <- current.Run(ctx) }()
	}
	start()
	defer func() {
		cancel()
		if done != nil {
			_ = awaitError(t, done)
		}
	}()
	startDrain := func() {
		drained = make(chan error, 1)
		current, result := runner, drained
		go func() { result <- current.Drain(ctx) }()
		awaitSignal(t, runner.lifetime().wake)
	}
	outcome := ""
	for _, step := range scenario.Steps {
		switch step {
		case "await_handler":
			awaitSignal(t, g.entered)
		case "await_partial":
			awaitSignal(t, g.partial)
		case "start_drain":
			startDrain()
		case "fail_handler":
			g.release <- false
		case "complete_handler":
			g.release <- true
		case "cancel_request":
			g.mu.Lock()
			g.cancelled = true
			g.mu.Unlock()
		case "await_failed_stop":
			if awaitError(t, drained) == nil {
				t.Fatal("failed handler drained successfully")
			}
			err := awaitError(t, done)
			done = nil
			var failure *HandlerFailure
			if !errors.As(err, &failure) {
				t.Fatalf("want handler failure, got %v", err)
			}
			outcome = "handler_failed"
		case "await_deadline_stop":
			err := awaitError(t, done)
			done = nil
			if !errors.Is(err, ErrHandlerDeadlineExceeded) {
				t.Fatalf("want deadline failure, got %v", err)
			}
			if store.Stats().Count != 0 {
				t.Fatal("deadline failure was quarantined")
			}
			outcome = "deadline_exceeded"
		case "await_drained_stop":
			if err := awaitError(t, drained); err != nil {
				t.Fatal(err)
			}
			if err := awaitError(t, done); err != nil {
				t.Fatal(err)
			}
			done = nil
			outcome = "drained"
		case "await_acknowledgement":
			awaitSignal(t, g.acknowledged)
		case "drain":
			if err := runner.Drain(ctx); err != nil {
				t.Fatal(err)
			}
			if err := awaitError(t, done); err != nil {
				t.Fatal(err)
			}
			done = nil
			outcome = "drained"
		case "check_quarantine":
			g.observe("quarantined_before_recovery", store.Stats().Count)
		case "recover":
			entries := store.Entries()
			if len(entries) != 1 {
				t.Fatal(entries)
			}
			if err := store.Recover(ctx, entries[0].ID, func(ctx context.Context, m Message) error {
				_, err := client.ReplyText(ctx, m.ReqID, catalog.Recovery)
				return err
			}); err != nil {
				t.Fatal(err)
			}
			g.observe("quarantined_after_recovery", store.Stats().Count)
		case "restart":
			start()
		default:
			t.Fatalf("unknown lifecycle step %q", step)
		}
	}
	if runner.Status().ActiveHandlers != 0 {
		t.Fatal("managed run left active work")
	}
	if scenario.Operation == "quarantine_recovery_restart" {
		g.observe("quarantined_after_restart", store.Stats().Count)
		outcome = "recovered_and_restarted"
	}
	g.observe("quarantined_final", store.Stats().Count)
	g.mu.Lock()
	g.observed["outcome"] = outcome
	encoded, _ := json.Marshal(g.observed)
	g.mu.Unlock()
	// JSON normalization keeps integer representation identical to the catalog.
	var observed map[string]any
	_ = json.Unmarshal(encoded, &observed)
	if !reflect.DeepEqual(observed, scenario.Expect) {
		t.Fatalf("observed %s; expected %v", encoded, scenario.Expect)
	}
}
