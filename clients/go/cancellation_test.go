package exiron

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"reflect"
	"testing"
)

func TestCancelRequestContractAndTypedResult(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if req.URL.Path != "/api/cancellations" || req.Header.Get("Authorization") != "Bearer token" {
			t.Fatal(req)
		}
		var actual, expected any
		if err := json.NewDecoder(req.Body).Decode(&actual); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(contractFixture(t, "cancel_payload.json"), &expected); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(actual, expected) {
			t.Fatalf("payload=%v", actual)
		}
		return jsonResponse(200, string(contractFixture(t, "cancel_response.json"))), nil
	})}})
	result, err := client.CancelRequest(context.Background(), "request-1")
	if err != nil {
		t.Fatal(err)
	}
	if !result.OK || !result.Cancelled || result.DeliveryStatus != "partial" || !reflect.DeepEqual(result.MessageIDs, []int64{901, 902}) {
		t.Fatalf("result=%#v", result)
	}
}

func TestCancelledStreamStopsWithoutFurtherUpdates(t *testing.T) {
	calls := 0
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		calls++
		return jsonResponse(409, string(contractFixture(t, "cancelled_error.json"))), nil
	})}})
	chunks := make(chan string, 2)
	chunks <- "first"
	chunks <- "later"
	close(chunks)
	_, err := client.StreamText(context.Background(), "request", chunks)
	if !IsRequestCancelled(fmt.Errorf("wrapped: %w", err)) || calls != 1 {
		t.Fatalf("error=%v calls=%d", err, calls)
	}
}

func TestCancelledHandlerDoesNotRetryOrBlockOtherMessages(t *testing.T) {
	calls := 0
	runner := &Runner{handlerMaxAttempts: 10, handler: func(_ context.Context, m Message) error {
		calls++
		if m.ReqID == "cancelled" {
			return apiError(409, contractFixture(t, "cancelled_error.json"))
		}
		return nil
	}}
	if err := runner.handleMessage(context.Background(), Message{ReqID: "cancelled"}); err != nil {
		t.Fatal(err)
	}
	if err := runner.handleMessage(context.Background(), Message{ReqID: "next"}); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("calls=%d", calls)
	}
}
