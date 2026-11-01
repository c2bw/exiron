package exiron

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/gorilla/websocket"
)

func newTestClient(t *testing.T, baseURL string) *Client {
	t.Helper()

	client, err := New(
		baseURL,
		WithToken("ai-token"),
		WithClientID("test-client"),
		WithRetryPolicy(RetryPolicy{MaxElapsed: -1}),
	)
	if err != nil {
		t.Fatalf("New returned error: %v", err)
	}
	return client
}

func assertRequest(t *testing.T, r *http.Request, method, path string) {
	t.Helper()

	if r.Method != method {
		t.Fatalf("method = %s, want %s", r.Method, method)
	}
	if r.URL.Path != path {
		t.Fatalf("path = %s, want %s", r.URL.Path, path)
	}
	if accept := r.Header.Get("accept"); accept != "application/json" {
		t.Fatalf("accept = %q, want application/json", accept)
	}
}

func assertAuthorization(t *testing.T, r *http.Request, expected string) {
	t.Helper()

	if got := r.Header.Get("authorization"); got != expected {
		t.Fatalf("authorization = %q, want %q", got, expected)
	}
}

func writeJSON(t *testing.T, w http.ResponseWriter, value any) {
	t.Helper()

	w.Header().Set("content-type", "application/json")
	if err := json.NewEncoder(w).Encode(value); err != nil {
		t.Fatalf("encode response: %v", err)
	}
}

func requireAPIError(t *testing.T, err error) *Error {
	t.Helper()

	var apiErr *Error
	if !errors.As(err, &apiErr) {
		t.Fatalf("error = %v, want *Error", err)
	}
	return apiErr
}

func jsonResponse(status int, body string) *http.Response {
	return &http.Response{
		StatusCode: status,
		Header:     http.Header{"content-type": []string{"application/json"}},
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) {
	return fn(r)
}

func contractFixture(t *testing.T, name string) []byte {
	t.Helper()

	fixture, err := os.ReadFile(filepath.Join("..", "contract", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}

	return fixture
}

func contractMap(t *testing.T, name string) map[string]any {
	t.Helper()

	var value map[string]any
	if err := json.Unmarshal(contractFixture(t, name), &value); err != nil {
		t.Fatalf("decode fixture %s: %v", name, err)
	}

	return value
}

func assertJSONBodyMatchesFixture(t *testing.T, r *http.Request, name string) {
	t.Helper()

	var body map[string]any
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if want := contractMap(t, name); !reflect.DeepEqual(body, want) {
		t.Fatalf("body = %#v, want %#v", body, want)
	}
}

func newWebSocketTestServer(t *testing.T, handler func(*websocket.Conn, int32), upgrader *websocket.Upgrader, attempts *atomic.Int32) *httptest.Server {
	t.Helper()

	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempt := attempts.Add(1)
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Fatalf("upgrade: %v", err)
		}
		defer conn.Close()
		handler(conn, attempt)
	}))
}
