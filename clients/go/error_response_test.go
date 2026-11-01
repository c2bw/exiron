package exiron

import (
	"context"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestNormalizesServerErrors(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"error":"invalid token"}`, http.StatusUnauthorized)
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	_, err := client.Requests(context.Background())

	apiErr := requireAPIError(t, err)
	if apiErr.StatusCode != http.StatusUnauthorized || apiErr.Reason != "invalid_token" || apiErr.Message != "invalid token" {
		t.Fatalf("error = %#v, want invalid token 401", apiErr)
	}
}

func TestPrefersStableServerErrorCode(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"code":"request_in_flight","error":"localized or changed message"}`, http.StatusConflict)
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	_, err := client.Requests(context.Background())
	apiErr := requireAPIError(t, err)
	if apiErr.Code != "request_in_flight" || apiErr.Reason != "request_in_flight" || apiErr.Message != "localized or changed message" {
		t.Fatalf("error = %#v, want stable request_in_flight code", apiErr)
	}
}

func TestDetectsHookAlreadyConnectedErrors(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"error":"hook already connected"}`, http.StatusConflict)
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	_, err := client.Requests(context.Background())

	if !IsHookAlreadyConnected(err) {
		t.Fatalf("IsHookAlreadyConnected(%#v) = false, want true", err)
	}

	apiErr := requireAPIError(t, err)
	if apiErr.StatusCode != http.StatusConflict || apiErr.Reason != "hook_already_connected" {
		t.Fatalf("error = %#v, want hook already connected 409", apiErr)
	}
}

func TestParsesHookAlreadyConnectedRetryAfter(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
		_, _ = w.Write(contractFixture(t, "error_response.json"))
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	_, err := client.Requests(context.Background())

	apiErr := requireAPIError(t, err)
	if apiErr.RetryAfterMS != 3000 {
		t.Fatalf("RetryAfterMS = %d, want 3000", apiErr.RetryAfterMS)
	}
}

func TestDetectsTelegramDeliveryTimeoutErrors(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"error":"telegram delivery result timed out"}`, http.StatusGatewayTimeout)
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	_, err := client.PushText(context.Background(), "hello")

	if !IsTelegramDeliveryTimeout(err) {
		t.Fatalf("IsTelegramDeliveryTimeout(%#v) = false, want true", err)
	}
	if IsHookAlreadyConnected(err) {
		t.Fatalf("IsHookAlreadyConnected(%#v) = true, want false", err)
	}

	apiErr := requireAPIError(t, err)
	if apiErr.StatusCode != http.StatusGatewayTimeout ||
		apiErr.Reason != "telegram_delivery_result_timed_out" {
		t.Fatalf("error = %#v, want telegram delivery timeout 504", apiErr)
	}
}

func TestRejectsMalformedMessagePayloads(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(t, w, map[string]any{
			"requests": []map[string]any{
				{
					"msgtype":  "request",
					"req_id":   "req-1",
					"datatype": "text",
					"data":     "not base64",
				},
			},
		})
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	_, err := client.Requests(context.Background())

	apiErr := requireAPIError(t, err)
	if apiErr.Reason != "invalid_response" || apiErr.Message != "message data is not valid base64" {
		t.Fatalf("error = %#v, want invalid base64 response", apiErr)
	}
}

func TestRejectsMissingRequestsList(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(t, w, map[string]any{"ok": true})
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	_, err := client.Requests(context.Background())

	apiErr := requireAPIError(t, err)
	if apiErr.Reason != "invalid_response" || apiErr.Message != "expected requests to be a list" {
		t.Fatalf("error = %#v, want missing requests list response", apiErr)
	}
}

func TestRejectsMissingMessageData(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(t, w, map[string]any{
			"requests": []map[string]any{
				{
					"msgtype":  "request",
					"req_id":   "req-1",
					"datatype": "text",
				},
			},
		})
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	_, err := client.Requests(context.Background())

	apiErr := requireAPIError(t, err)
	if apiErr.Reason != "invalid_response" || apiErr.Message != "message data is missing" {
		t.Fatalf("error = %#v, want missing data response", apiErr)
	}
}

func TestDefaultsMissingMessageTypeToRequest(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(t, w, map[string]any{
			"requests": []map[string]any{
				{
					"req_id":   "req-1",
					"datatype": "text",
					"data":     base64.StdEncoding.EncodeToString([]byte("hello")),
				},
			},
		})
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	messages, err := client.Requests(context.Background())
	if err != nil {
		t.Fatalf("Requests returned error: %v", err)
	}
	if messages[0].Msgtype != "request" {
		t.Fatalf("Msgtype = %q, want request", messages[0].Msgtype)
	}
}
