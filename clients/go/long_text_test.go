package exiron

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestLongTextStreamAndMultipartReceipts(t *testing.T) {
	var calls []map[string]any
	client, err := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		var body map[string]any
		if err := json.NewDecoder(req.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		calls = append(calls, body)
		if body["final"] == false {
			return jsonResponse(200, string(contractFixture(t, "long_response_update.json"))), nil
		}
		return jsonResponse(200, `{"ok":true}`), nil
	})}})
	if err != nil {
		t.Fatal(err)
	}
	var fixture wireResponsePayload
	if err := json.Unmarshal(contractFixture(t, "long_response_payload.json"), &fixture); err != nil {
		t.Fatal(err)
	}
	text, err := base64.StdEncoding.DecodeString(fixture.Data)
	if err != nil {
		t.Fatal(err)
	}
	result, err := client.UpdateText(context.Background(), "long-request", string(text))
	if err != nil {
		t.Fatal(err)
	}
	if len(result.MessageIDs) != 2 || result.MessageIDs[0] != 901 || result.MessageIDs[1] != 902 || *result.MessageID != 901 {
		t.Fatalf("result=%#v", result)
	}
	assertKeyboardFixture(t, encodedResponseWithOptions("long-request", DatatypeText, text, ResponseOptions{Final: fixture.Final, ParseMode: "plain"}), "long_response_payload.json")
	chunks := make(chan string, 2)
	chunks <- strings.Repeat("x", 4096)
	chunks <- "😀tail"
	close(chunks)
	if _, err := client.StreamText(context.Background(), "stream", chunks, StreamOptions{Interval: time.Hour}); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 3 || calls[1]["final"] != false || calls[2]["final"] != true || calls[2]["data"] != fixture.Data {
		t.Fatal(calls)
	}
}

func TestLongTextLogicalLimitRemainsBounded(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) { t.Fatal("oversized stream was sent"); return nil, nil })}})
	chunks := make(chan string, 1)
	chunks <- strings.Repeat("x", MaxTextUnits+1)
	close(chunks)
	if _, err := client.StreamText(context.Background(), "request", chunks); err == nil {
		t.Fatal("oversized stream accepted")
	}
}
