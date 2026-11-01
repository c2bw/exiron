package exiron

import (
	"context"
	"net/http"
	"testing"
)

func TestClientPresenceStatusFixture(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		return jsonResponse(200, string(contractFixture(t, "status_client_presence_response.json"))), nil
	})}})
	status, err := client.Status(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	presence := status.Hooks[0].Client
	if presence == nil || presence.ClientID == nil || *presence.ClientID != "worker" || presence.State != "http_lease_expired" || presence.AwaitingResponse != 1 || presence.SendingRequests != 0 || presence.LastContactAt == nil || presence.Transport == nil || *presence.Transport != "http" {
		t.Fatalf("presence=%#v", presence)
	}
	if presence.Runtime == nil || presence.Runtime.Status != "session_inactive" || !presence.Runtime.Stale || presence.Runtime.OverdueHandlers != 1 {
		t.Fatal(presence.Runtime)
	}
	if presence.CurrentClientID != nil {
		t.Fatal("expired lease has a current client")
	}
	legacy, _ := NewClient(Config{BaseURL: "http://exiron.test", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		return jsonResponse(200, string(contractFixture(t, "status_response.json"))), nil
	})}})
	old, err := legacy.Status(context.Background())
	if err != nil || old.Hooks[0].Client != nil {
		t.Fatalf("legacy presence changed: %#v err=%v", old, err)
	}
}
