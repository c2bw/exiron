package exiron

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"testing"
)

func TestKeyedMutationsUseDedicatedRoutesAndDoNotAutomaticallyRetry(t *testing.T) {
	var paths []string
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		paths = append(paths, req.URL.Path)
		var body map[string]any
		if err := json.NewDecoder(req.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if body["idempotency_key"] != "key-1" {
			t.Fatal(body)
		}
		return jsonResponse(409, string(contractFixture(t, "error_idempotency_in_progress.json"))), nil
	})}})
	_, err := client.RespondWithOptions(context.Background(), "req-1", DatatypeText, []byte("hello"), ResponseOptions{IdempotencyKey: "key-1"})
	if !IsIdempotencyInProgress(err) {
		t.Fatal(err)
	}
	_, err = client.PushWithOptions(context.Background(), DatatypeText, []byte("hello"), PushOptions{IdempotencyKey: "key-1"})
	if !IsIdempotencyInProgress(err) {
		t.Fatal(err)
	}
	_, err = client.PushWithChatIDOptions(context.Background(), 123, DatatypeText, []byte("hello"), PushOptions{IdempotencyKey: "key-1"})
	if !IsIdempotencyInProgress(err) {
		t.Fatal(err)
	}
	if len(paths) != 3 || paths[0] != "/api/idempotent/responses" || paths[1] != "/api/idempotent/push" || paths[2] != "/api/idempotent/push" {
		t.Fatal(paths)
	}
	assertKeyboardFixture(t, encodedResponseWithOptions("req-1", DatatypeText, []byte("hello"), ResponseOptions{IdempotencyKey: "reply-1"}), "idempotent_response_payload.json")
	assertKeyboardFixture(t, encodedPayload(DatatypeText, []byte("hello"), PushOptions{IdempotencyKey: "push-1"}), "idempotent_push_payload.json")
}

func TestKeyedOldServerNeverFallsBackToUnkeyedMutation(t *testing.T) {
	calls := 0
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		calls++
		if req.URL.Path != "/api/idempotent/responses" {
			t.Fatal("unsafe fallback: " + req.URL.Path)
		}
		return jsonResponse(404, `{"error":"not found"}`), nil
	})}})
	_, err := client.RespondWithOptions(context.Background(), "req-1", DatatypeText, []byte("hello"), ResponseOptions{IdempotencyKey: "key"})
	if err == nil || calls != 1 {
		t.Fatalf("err=%v calls=%d", err, calls)
	}
}

func TestStreamDerivesDistinctStableOperationKeys(t *testing.T) {
	var current []string
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if req.URL.Path != "/api/idempotent/responses" {
			t.Fatal(req.URL.Path)
		}
		var body struct {
			Key   string `json:"idempotency_key"`
			Final bool   `json:"final"`
		}
		if err := json.NewDecoder(req.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		current = append(current, body.Key)
		return jsonResponse(200, `{"ok":true,"message_id":901}`), nil
	})}})
	run := func() []string {
		current = nil
		chunks := make(chan string, 1)
		chunks <- "hello"
		close(chunks)
		_, err := client.StreamText(context.Background(), "req-1", chunks, StreamOptions{ResponseOptions: ResponseOptions{IdempotencyKey: "stream-base"}})
		if err != nil {
			t.Fatal(err)
		}
		return append([]string(nil), current...)
	}
	first, second := run(), run()
	if len(first) != 2 || first[0] == first[1] || first[0] == "stream-base" {
		t.Fatal(first)
	}
	if len(second) != 2 || first[0] != second[0] || first[1] != second[1] {
		t.Fatalf("unstable keys %v %v", first, second)
	}
}

func TestIdempotencyValidationAndErrorClassifiers(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", HTTPClient: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		t.Error("invalid key must not send")
		return nil, errors.New("unexpected")
	})}})
	_, err := client.RespondWithOptions(context.Background(), "req-1", DatatypeText, nil, ResponseOptions{IdempotencyKey: "not valid"})
	if err == nil {
		t.Fatal("invalid key accepted")
	}
	_, err = client.EditText(context.Background(), "req-1", "edit", ResponseOptions{IdempotencyKey: "valid"})
	if err == nil {
		t.Fatal("completed edit accepted a key")
	}
	if !IsIdempotencyConflict(apiError(409, contractFixture(t, "error_idempotency_conflict.json"))) {
		t.Fatal("conflict not classified")
	}
	for _, file := range []string{"error_idempotency_capacity_exceeded.json", "error_idempotency_result_unavailable.json"} {
		if !IsIdempotencyUnavailable(apiError(503, contractFixture(t, file))) {
			t.Fatal(file)
		}
	}
	if IsIdempotencyConflict(nil) || IsIdempotencyInProgress(nil) || IsIdempotencyUnavailable(nil) {
		t.Fatal("nil classified as an error")
	}
}
