package exiron

import (
	"context"
	"net/http"
	"testing"
)

func TestPollReportsSDKPackageVersion(t *testing.T) {
	client, err := NewClient(Config{BaseURL: "http://example.test", Token: "token", ClientID: "worker", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if req.Header.Get("x-exiron-sdk") != "go" || req.Header.Get("x-exiron-sdk-version") != Version() {
			t.Fatal("missing SDK package identity")
		}
		return jsonResponse(200, `{"requests":[]}`), nil
	})}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Requests(context.Background()); err != nil {
		t.Fatal(err)
	}
}
