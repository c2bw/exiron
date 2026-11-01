package exiron

import (
	"context"
	"encoding/json"
	"net/http"
	"reflect"
	"testing"
)

func TestInlineButtonContractAndCallbackDecoding(t *testing.T) {
	var response wireRequestsResponse
	if err := json.Unmarshal(contractFixture(t, "requests_callback_response.json"), &response); err != nil {
		t.Fatal(err)
	}
	messages, err := decodeMessages(response.Requests)
	if err != nil {
		t.Fatal(err)
	}
	m := messages[0]
	if m.CallbackData() != "next:2" || m.CallbackQuery.ID != "query-1" || *m.CallbackQuery.OriginReqID != "req-1" || *m.MessageID != 901 || *m.MessageThreadID != 7 || m.From.ID != 42 || m.Text() != "" {
		t.Fatalf("message=%#v", m)
	}
	keyboard := InlineKeyboard{{{Text: "Next", CallbackData: "next:2"}, {Text: "Help", URL: "https://example.com/help"}}}
	payload := encodedResponseWithOptions("req-1", DatatypeText, []byte("Choose"), ResponseOptions{InlineKeyboard: &keyboard})
	assertKeyboardFixture(t, payload, "response_keyboard_payload.json")
	empty := InlineKeyboard{}
	payload = encodedResponseWithOptions("callback-request", DatatypeKeyboard, nil, ResponseOptions{InlineKeyboard: &empty, EditOrigin: true})
	assertKeyboardFixture(t, payload, "callback_keyboard_payload.json")
}

func TestInlineButtonHelpersChooseOperationsAndPreserveDefaults(t *testing.T) {
	var calls []map[string]any
	var paths []string
	client, err := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		var body map[string]any
		if err := json.NewDecoder(req.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		calls = append(calls, body)
		paths = append(paths, req.URL.Path)
		return jsonResponse(200, `{"ok":true}`), nil
	})}})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	empty := InlineKeyboard{}
	if _, err := client.EditCallbackText(ctx, "click", "Updated", ResponseOptions{InlineKeyboard: &empty}); err != nil {
		t.Fatal(err)
	}
	if calls[0]["edit_origin"] != true || paths[0] != "/api/responses" {
		t.Fatal(calls)
	}
	if _, ok := calls[0]["final"]; ok {
		t.Fatal("one-shot default changed")
	}
	if _, err := client.EditCallbackKeyboard(ctx, "click", nil); err != nil {
		t.Fatal(err)
	}
	if calls[1]["datatype"] != "keyboard" || calls[1]["edit_origin"] != true || !reflect.DeepEqual(calls[1]["inline_keyboard"], []any{}) {
		t.Fatal(calls)
	}
	if _, err := client.EditKeyboard(ctx, "original", empty); err != nil {
		t.Fatal(err)
	}
	if paths[2] != "/api/edits" {
		t.Fatal(paths)
	}
	if _, err := client.ReplyText(ctx, "click", "New reply"); err != nil {
		t.Fatal(err)
	}
	if _, ok := calls[3]["edit_origin"]; ok {
		t.Fatal("normal reply edits its source")
	}
	if _, err := client.PushWithChatIDOptions(ctx, 123, DatatypeText, []byte("Menu"), PushOptions{InlineKeyboard: &empty}); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(calls[4]["inline_keyboard"], []any{}) {
		t.Fatal(calls)
	}
}

func assertKeyboardFixture(t *testing.T, payload any, fixture string) {
	t.Helper()
	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	var actual, expected any
	if err := json.Unmarshal(encoded, &actual); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(contractFixture(t, fixture), &expected); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(actual, expected) {
		t.Fatalf("actual=%v expected=%v", actual, expected)
	}
}
