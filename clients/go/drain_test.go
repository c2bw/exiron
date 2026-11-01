package exiron

import (
	"context"
	"net/http"
	"sync/atomic"
	"testing"
)

func TestDrainRejectionIsClassifiedWithoutRetryingMutation(t *testing.T) {
	var calls atomic.Int32
	client, err := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		calls.Add(1)
		return jsonResponse(503, string(contractFixture(t, "error_draining.json"))), nil
	})}})
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.Push(context.Background(), DatatypeText, []byte("new"))
	if !IsDraining(err) || IsDraining(nil) || IsSendCapacityExceeded(err) {
		t.Fatalf("unexpected classification: %v", err)
	}
	if calls.Load() != 1 {
		t.Fatalf("mutation retried %d times", calls.Load())
	}
}
