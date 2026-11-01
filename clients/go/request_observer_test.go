package exiron

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestRequestObserverReportsOneLogicalCallAndIsolatesPanics(t *testing.T) {
	var events []RequestEvent
	calls := 0
	client, err := NewClient(Config{BaseURL: "http://example.test", Token: "private-token", OnRequest: func(event RequestEvent) { events = append(events, event); panic("observer failure") }, Retry: RetryPolicy{InitialDelay: time.Millisecond, MaxDelay: time.Millisecond, MaxElapsed: time.Second, DisableJitter: true}, HTTPClient: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		calls++
		if calls == 1 {
			return nil, errors.New("private error")
		}
		return jsonResponse(200, `{}`), nil
	})}})
	if err != nil {
		t.Fatal(err)
	}
	if err := client.request(context.Background(), "GET", "/api/request-state?req_id=private-id", "private-token", nil, nil); err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].Attempts != 2 || events[0].HTTPStatus != 200 || events[0].ErrorKind != "none" || events[0].Route != "/api/request-state" {
		t.Fatal(events)
	}
	encoded, _ := json.Marshal(events)
	if strings.Contains(string(encoded), "private") {
		t.Fatal(string(encoded))
	}
}
func TestRequestObserverDoesNotRetryMutationsAndSanitizesUnknownRoutes(t *testing.T) {
	if requestRoute("/api/deliveries/private-id?token=secret") != "/api/deliveries/:id" {
		t.Fatal("delivery diagnostic ID leaked")
	}
	var event RequestEvent
	calls := 0
	client, _ := NewClient(Config{BaseURL: "http://example.test", OnRequest: func(e RequestEvent) { event = e }, HTTPClient: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		calls++
		return jsonResponse(504, `{"error":"private body"}`), nil
	})}})
	if client.request(context.Background(), "POST", "/private-id?token=secret", "", nil, nil) == nil {
		t.Fatal("expected failure")
	}
	if calls != 1 || event.Attempts != 1 || event.Route != "other" || event.HTTPStatus != 504 {
		t.Fatal(event, calls)
	}
}
