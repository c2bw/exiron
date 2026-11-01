package exiron

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"testing"
	"time"
)

func TestSendCapacityErrorContract(t *testing.T) {
	calls := 0
	body := contractFixture(t, "error_hook_send_queue_full.json")
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		calls++
		return jsonResponse(503, string(body)), nil
	})}})
	_, err := client.ReplyText(context.Background(), "req-1", "reply")
	var apiErr *Error
	if !IsSendCapacityExceeded(err) || !errors.As(err, &apiErr) || apiErr.RetryAfterMS != 1000 || apiErr.Reason != "hook_send_queue_full" || calls != 1 {
		t.Fatalf("calls=%d err=%#v", calls, err)
	}
	if !IsSendCapacityExceeded(fmt.Errorf("wrapped: %w", err)) {
		t.Fatal("wrapped error not recognized")
	}
	if !IsSendCapacityExceeded(apiError(503, []byte(`{"code":"send_queue_full","error":"send queue full"}`))) {
		t.Fatal("global capacity not recognized")
	}
	if IsSendCapacityExceeded(nil) || IsSendCapacityExceeded(&Error{Reason: "telegram_delivery_timeout"}) {
		t.Fatal("uncertain delivery classified as capacity rejection")
	}
	_, err = client.PushWithChatID(context.Background(), 123, DatatypeText, []byte("push"))
	if !IsSendCapacityExceeded(err) || calls != 2 {
		t.Fatalf("calls=%d err=%v", calls, err)
	}
}

func TestStreamCapacityRejectionDoesNotReplay(t *testing.T) {
	calls := 0
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		calls++
		var payload wireResponsePayload
		if err := json.NewDecoder(req.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if payload.Final != nil && !*payload.Final {
			return jsonResponse(200, `{"ok":true,"final":false,"message_id":901}`), nil
		}
		return jsonResponse(503, `{"code":"hook_send_queue_full","error":"hook send queue full","retry_after_ms":1000}`), nil
	})}})
	chunks := make(chan string, 2)
	chunks <- "partial"
	chunks <- " done"
	close(chunks)
	_, err := client.StreamText(context.Background(), "req-1", chunks, StreamOptions{Interval: time.Hour})
	if !IsSendCapacityExceeded(err) || calls != 2 {
		t.Fatalf("calls=%d err=%v", calls, err)
	}
}

func TestHookCapacityStatusConversion(t *testing.T) {
	var wire wireStatus
	if err := json.Unmarshal([]byte(`{"hooks":[{"name":"assistant","health":{"in_flight_sends":2,"in_flight_send_limit":10,"send_capacity_rejections":3,"in_flight_send_bytes":12,"in_flight_send_bytes_limit":100,"send_byte_capacity_rejections":2}}]}`), &wire); err != nil {
		t.Fatal(err)
	}
	status := wire.toStatus()
	health := status.Hooks[0].Health
	if health == nil || health.InFlightSends != 2 || health.InFlightSendLimit != 10 || health.SendCapacityRejections != 3 || health.InFlightSendBytes != 12 || health.InFlightSendBytesLimit != 100 || health.SendByteCapacityRejections != 2 {
		t.Fatalf("health=%#v", health)
	}
}
