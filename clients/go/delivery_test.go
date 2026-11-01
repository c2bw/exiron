package exiron

import (
	"context"
	"net/http"
	"testing"
)

func TestDeliveryErrorRetainsStructuredDiagnostics(t *testing.T) {
	err := apiError(504, contractFixture(t, "delivery_error.json"))
	if err.Reason != "telegram_delivery_timeout" || err.Delivery == nil {
		t.Fatalf("error=%#v", err)
	}
	d := err.Delivery
	if d.ConfirmedParts != 1 || len(d.Parts) != 3 || d.Parts[0].MessageIDs[0] != 901 || *d.LastError.Code != 429 || *d.LastError.RetryAfterMS != 2000 || d.RetrySafe || d.RetryAction != "inspect_chat" {
		t.Fatalf("diagnostics=%#v", d)
	}
	if apiError(400, []byte(`{"error":"invalid payload","code":"invalid_payload"}`)).Delivery != nil {
		t.Fatal("legacy error acquired diagnostics")
	}
}

func TestDeliveryStatusFetchesSharedSnapshot(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if req.Method != "GET" || req.URL.Path != "/api/deliveries/request-1" || req.Header.Get("Authorization") != "Bearer token" {
			t.Fatal(req)
		}
		return jsonResponse(200, string(contractFixture(t, "delivery_diagnostics.json"))), nil
	})}})
	d, err := client.DeliveryStatus(context.Background(), "request-1")
	if err != nil {
		t.Fatal(err)
	}
	if d.ID != "delivery-1" || d.Parts[1].Status != "rejected" || d.UnattemptedParts != 1 {
		t.Fatalf("diagnostics=%#v", d)
	}
}
