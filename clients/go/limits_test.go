package exiron

import (
	"context"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
)

func TestReadResponseBodyHandlesMaxInt64Limit(t *testing.T) {
	body, err := readResponseBody(strings.NewReader("ok"), math.MaxInt64)
	if err != nil {
		t.Fatalf("readResponseBody returned error: %v", err)
	}
	if string(body) != "ok" {
		t.Fatalf("readResponseBody body = %q, want ok", body)
	}
}

func TestHTTPResponseBodyLimit(t *testing.T) {
	client, err := NewClient(Config{
		BaseURL:          "http://exiron.test",
		ClientID:         "limited-client",
		MaxResponseBytes: 16,
		HTTPClient: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
			return jsonResponse(http.StatusOK, strings.Repeat("x", 17)), nil
		})},
		Retry: RetryPolicy{MaxElapsed: -1},
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	_, err = client.Status(context.Background())
	apiErr := requireAPIError(t, err)
	if apiErr.Reason != "invalid_response" || !strings.Contains(apiErr.Message, "size limit") {
		t.Fatalf("Status error = %#v, want response size limit", apiErr)
	}
}

func TestWebSocketHandshakeResponseBodyLimit(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(strings.Repeat("x", 17)))
	}))
	defer server.Close()

	client, err := NewClient(Config{
		BaseURL:          server.URL,
		ClientID:         "limited-client",
		MaxResponseBytes: 16,
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, Handler: func(context.Context, Message) error {
		return nil
	}})
	_, err = newWebSocketSession(runner, nil).dialWebSocket(context.Background())
	apiErr := requireAPIError(t, err)
	if apiErr.Reason != "invalid_response" || !strings.Contains(apiErr.Message, "size limit") {
		t.Fatalf("dialWebSocket error = %#v, want response size limit", apiErr)
	}
}

func TestWebSocketFrameLimit(t *testing.T) {
	var upgrader websocket.Upgrader
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Fatalf("upgrade: %v", err)
		}
		defer conn.Close()

		if err := conn.WriteMessage(websocket.TextMessage, []byte(strings.Repeat("x", 65))); err != nil {
			t.Fatalf("write oversized frame: %v", err)
		}
	}))
	defer server.Close()

	client, err := NewClient(Config{
		BaseURL:          server.URL,
		ClientID:         "limited-client",
		MaxResponseBytes: 64,
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, Handler: func(context.Context, Message) error {
		return nil
	}})
	apiErr := requireAPIError(t, runner.Run(context.Background()))
	if apiErr.Reason != "invalid_response" || !strings.Contains(apiErr.Message, "frame") {
		t.Fatalf("Run error = %#v, want frame size limit", apiErr)
	}
}
