package exiron

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

func TestReplyContextWireContract(t *testing.T) {
	assertKeyboardFixture(t, encodedResponseWithOptions("req-1", DatatypeText, []byte("ack"), ResponseOptions{ReplyToOriginal: true}), "response_reply_context_payload.json")
	final := false
	assertKeyboardFixture(t, encodedResponseWithOptions("req-1", DatatypeText, []byte("partial"), ResponseOptions{ReplyToOriginal: true, Final: &final, ParseMode: "plain"}), "response_reply_context_update_payload.json")
}

func TestReplyContextResponseAndStreamHelpers(t *testing.T) {
	var calls []map[string]any
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		var body map[string]any
		if err := json.NewDecoder(req.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		calls = append(calls, body)
		return jsonResponse(200, `{"ok":true}`), nil
	})}})
	ctx := context.Background()
	if _, err := client.RespondWithOptions(ctx, "req-1", DatatypeText, []byte("ack"), ResponseOptions{ReplyToOriginal: true}); err != nil {
		t.Fatal(err)
	}
	if calls[0]["reply_to_original"] != true {
		t.Fatal(calls)
	}
	chunks := make(chan string, 2)
	chunks <- "partial"
	chunks <- " result"
	close(chunks)
	if _, err := client.StreamText(ctx, "req-1", chunks, StreamOptions{Interval: time.Hour, ResponseOptions: ResponseOptions{ReplyToOriginal: true}}); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 3 || calls[1]["reply_to_original"] != true || calls[1]["final"] != false || calls[2]["reply_to_original"] != true || calls[2]["final"] != true || calls[2]["data"] != base64.StdEncoding.EncodeToString([]byte("partial result")) {
		t.Fatal(calls)
	}
	if _, err := client.ReplyText(ctx, "other", "default"); err != nil {
		t.Fatal(err)
	}
	if _, exists := calls[3]["reply_to_original"]; exists {
		t.Fatal("default behavior acquired reply context")
	}
}
