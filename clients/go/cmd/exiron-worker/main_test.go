package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	exiron "github.com/c2bw/exiron/clients/go"
)

type gateway struct {
	bodies  chan map[string]any
	final   chan string
	partial atomic.Int32
	retired atomic.Int32
}

func fakeGateway(t *testing.T, text string) (*exiron.Client, *gateway) {
	t.Helper()
	g := &gateway{final: make(chan string, 4), bodies: make(chan map[string]any, 32)}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch req.URL.Path {
		case "/api/capabilities":
			_ = json.NewEncoder(w).Encode(map[string]any{"protocol_version": "1.17", "capabilities": []string{"client_retirement", "client_runtime_reporting", "http_lease_renewal", "cooperative_cancellation", "handler_failure_reporting", "inline_keyboards", "callback_queries"}})
		case "/api/requests":
			if req.URL.Query().Get("delivery_ack") != "" {
				_ = json.NewEncoder(w).Encode(map[string]any{"runtime_ref": "session", "requests": []any{}})
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"runtime_ref": "session", "delivery_id": "batch", "requests": []any{map[string]any{"req_id": "one", "msgtype": "request", "datatype": "text", "data": base64.StdEncoding.EncodeToString([]byte(text)), "service_id": 1, "chat_id": 1}}})
		case "/api/request-state":
			_ = json.NewEncoder(w).Encode(map[string]any{"req_id": "one", "state": "active"})
		case "/api/client-lease":
			_, _ = w.Write([]byte(`{"ok":true,"lease_timeout_ms":3000}`))
		case "/api/client-retire":
			g.retired.Add(1)
			_, _ = w.Write([]byte(`{"ok":true}`))
		case "/api/client-runtime", "/api/handler-reports":
			_, _ = w.Write([]byte(`{"ok":true}`))
		case "/api/responses":
			var body map[string]any
			if err := json.NewDecoder(req.Body).Decode(&body); err != nil {
				t.Error(err)
			}
			g.bodies <- body
			if body["parse_mode"] != "plain" {
				t.Error("example sent parsed markup")
			}
			if body["final"] == false {
				g.partial.Add(1)
			} else {
				data, _ := base64.StdEncoding.DecodeString(body["data"].(string))
				g.final <- string(data)
			}
			_, _ = w.Write([]byte(`{"ok":true}`))
		default:
			t.Errorf("unexpected path %s", req.URL.Path)
			w.WriteHeader(500)
		}
	}))
	t.Cleanup(server.Close)
	client, err := exiron.NewClient(exiron.Config{BaseURL: server.URL, Token: "token", ClientID: "example", Transport: exiron.TransportHTTP})
	if err != nil {
		t.Fatal(err)
	}
	return client, g
}
func receiveText(t *testing.T, ch <-chan string) string {
	t.Helper()
	select {
	case text := <-ch:
		return text
	case <-time.After(3 * time.Second):
		t.Fatal("no final response")
		return ""
	}
}
func TestReferenceWorkerReplyModesAndConfirmedDrain(t *testing.T) {
	for _, mode := range []string{"one-shot", "stream"} {
		t.Run(mode, func(t *testing.T) {
			client, g := fakeGateway(t, "hello")
			w := newWorker(client, mode)
			if err := w.start(); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = w.drain() })
			if text := receiveText(t, g.final); text != "Received: hello" {
				t.Fatal(text)
			}
			if err := w.drain(); err != nil {
				t.Fatal(err)
			}
			if w.running || g.retired.Load() != 1 || w.runner.Status().ActiveHandlers != 0 {
				t.Fatal(w.running, g.retired.Load(), w.runner.Status())
			}
			if mode == "one-shot" && g.partial.Load() != 0 {
				t.Fatal("one-shot produced streaming updates")
			}
			if mode == "stream" && g.partial.Load() == 0 {
				t.Fatal("stream produced no partial update")
			}
		})
	}
}
func TestReferenceWorkerRetainsQuarantineAfterDrainAndUsesExplicitReplacement(t *testing.T) {
	client, g := fakeGateway(t, "/ai /worker-fail")
	w := newWorker(client, "stream")
	if err := w.start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = w.drain() })
	var entry exiron.QuarantineEntry
	select {
	case entry = <-w.notices:
	case <-time.After(3 * time.Second):
		t.Fatal("no quarantine notification")
	}
	if err := w.drain(); err != nil {
		t.Fatal(err)
	}
	if len(w.quarantine.Entries()) != 1 {
		t.Fatal("drain discarded retained work")
	}
	select {
	case text := <-g.final:
		t.Fatalf("automatically replayed failed work: %s", text)
	default:
	}
	if err := w.recoverText(entry.ID, "Reviewed replacement"); err != nil {
		t.Fatal(err)
	}
	if text := receiveText(t, g.final); text != "Reviewed replacement" {
		t.Fatal(text)
	}
	if w.quarantine.Stats().Count != 0 || g.partial.Load() != 0 {
		t.Fatal(w.quarantine.Stats(), g.partial.Load())
	}
	if err := w.quarantine.Recover(context.Background(), entry.ID, func(context.Context, exiron.Message) error { t.Error("resolved entry replayed"); return nil }); err == nil {
		t.Fatal("resolved entry still present")
	}
}

func TestRequestObservationIsExplicit(t *testing.T) {
	for _, flag := range []string{"", "false", "true", "invalid"} {
		cfg, mode, err := configuration(func(key string) string {
			switch key {
			case "EXIRON_HOOK_TOKEN":
				return "synthetic"
			case "EXIRON_OBSERVE_REQUESTS":
				return flag
			default:
				return ""
			}
		})
		if flag == "invalid" {
			if err == nil {
				t.Fatal("invalid observation flag accepted")
			}
			continue
		}
		if err != nil || mode != "one-shot" || (cfg.OnRequest != nil) != (flag == "true") {
			t.Fatalf("unexpected settings for %q", flag)
		}
	}
}

func TestReferenceWorkerFeedbackAndFollowups(t *testing.T) {
	for _, mode := range []string{"one-shot", "stream"} {
		t.Run(mode, func(t *testing.T) {
			client, g := fakeGateway(t, "unused")
			w := newWorker(client, mode)
			w.feedback = true
			parent := "parent"
			message := exiron.Message{Msgtype: "request", Datatype: exiron.DatatypeText, ReqID: "one", FollowupReqID: &parent, Data: []byte("more")}
			if err := w.handle(context.Background(), message); err != nil {
				t.Fatal(err)
			}
			if text := receiveText(t, g.final); text != "Follow-up received: more" {
				t.Fatal(text)
			}
			for {
				body := <-g.bodies
				if body["final"] != false {
					if _, ok := body["inline_keyboard"]; !ok {
						t.Fatal("feedback missing")
					}
					break
				}
			}
			keyboard, _ := exiron.WithFeedback(nil)
			origin := "one"
			rating := exiron.Message{Msgtype: "request", Datatype: exiron.DatatypeCallback, ReqID: "vote", Data: []byte(keyboard[0][0].CallbackData), From: &exiron.TelegramUser{ID: 42}, CallbackQuery: &exiron.CallbackQuery{ID: "click", OriginReqID: &origin}}
			if err := w.handle(context.Background(), rating); err != nil {
				t.Fatal(err)
			}
			if text := receiveText(t, g.final); text != "Thanks for the feedback." {
				t.Fatal(text)
			}
			body := <-g.bodies
			if _, ok := body["inline_keyboard"]; ok {
				t.Fatal("rating acknowledgement offers recursive feedback")
			}
		})
	}
}
func TestFeedbackFlagValidation(t *testing.T) {
	for _, value := range []string{"", "true", "false", "bad"} {
		enabled, err := feedbackEnabled(func(string) string { return value })
		if (err != nil) != (value == "bad") || enabled != (value == "true") {
			t.Fatal(value, enabled, err)
		}
	}
}
func TestFeedbackChecksCapabilitiesBeforePolling(t *testing.T) {
	var polls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/capabilities" {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"protocol_version":"1.18","capabilities":[]}`))
			return
		}
		polls.Add(1)
		w.WriteHeader(500)
	}))
	defer server.Close()
	client, _ := exiron.NewClient(exiron.Config{BaseURL: server.URL, Token: "token"})
	w := newWorker(client, "one-shot")
	w.feedback = true
	if err := w.start(); err == nil {
		t.Fatal("unsupported feedback started")
	}
	if polls.Load() != 0 || w.running {
		t.Fatal("work consumed before negotiation")
	}
}
