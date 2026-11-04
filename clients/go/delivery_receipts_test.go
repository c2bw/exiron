package exiron

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
)

func TestDeliveryReceiptsRoundTrip(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		var body map[string]any
		if err := json.NewDecoder(req.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if body["delivery_receipts"] != true {
			t.Fatal(body)
		}
		return jsonResponse(200, `{"ok":true,"sent":1,"receipts":[{"service_id":222,"chat_id":123,"message_thread_id":7,"message_ids":[901,902]}]}`), nil
	})}})
	response, err := client.RespondWithOptions(context.Background(), "request", DatatypeText, []byte("hello"), ResponseOptions{DeliveryReceipts: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(response.Receipts) != 1 || len(response.Receipts[0].MessageIDs) != 2 || response.Receipts[0].ServiceID != 222 {
		t.Fatal(response)
	}
	push, err := client.PushWithChatIDOptions(context.Background(), 123, DatatypeText, []byte("hello"), PushOptions{DeliveryReceipts: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(push.Receipts) != 1 || push.Receipts[0].ChatID != 123 || *push.Receipts[0].MessageThreadID != 7 {
		t.Fatal(push)
	}
}
