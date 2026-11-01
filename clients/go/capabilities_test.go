package exiron

import (
	"context"
	"errors"
	"net/http"
	"testing"
)

func TestFeatureNegotiationUsesOneDiscoveryForAllEnabledFeatures(t *testing.T) {
	discovery, auth, polls := 0, 0, 0
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", Transport: TransportHTTP, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		switch req.URL.Path {
		case "/api/capabilities":
			discovery++
			return jsonResponse(200, string(contractFixture(t, "capabilities_response.json"))), nil
		case "/api/auth":
			auth++
			t.Error("new server must not use legacy auth")
			return jsonResponse(500, `{}`), nil
		case "/api/requests":
			polls++
			return jsonResponse(409, `{"error":"stop"}`), nil
		default:
			t.Errorf("unexpected path %s", req.URL.Path)
			return jsonResponse(500, `{}`), nil
		}
	})}})
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, CooperativeCancellation: true, ReportHandlerFailures: true, HTTPLeaseRenewal: true, Handler: func(context.Context, Message) error { return nil }})
	if err := runner.Run(context.Background()); err == nil {
		t.Fatal("expected poll stop")
	}
	if discovery != 1 || auth != 0 || polls != 1 {
		t.Fatalf("discovery=%d auth=%d polls=%d", discovery, auth, polls)
	}
}

func TestDiscoveryFallbackOnlyForMissingOrUnsupportedRoute(t *testing.T) {
	for _, status := range []int{404, 405, 401, 403, 429, 500, 503} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			discovery, auth := 0, 0
			client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", Retry: RetryPolicy{MaxElapsed: -1}, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
				if req.URL.Path == "/api/capabilities" {
					discovery++
					return jsonResponse(status, `{"error":"not available"}`), nil
				}
				if req.URL.Path != "/api/auth" {
					t.Error(req.URL.Path)
				}
				auth++
				return jsonResponse(200, string(contractFixture(t, "auth_response.json"))), nil
			})}})
			protocol, err := client.Capabilities(context.Background())
			legacy := status == 404 || status == 405
			if legacy && (err != nil || !protocol.Supports("cooperative_cancellation")) {
				t.Fatalf("protocol=%v err=%v", protocol, err)
			}
			if !legacy && err == nil {
				t.Fatal("failed discovery was accepted")
			}
			expected := 0
			if legacy {
				expected = 1
			}
			if discovery != 1 || auth != expected {
				t.Fatalf("discovery=%d auth=%d", discovery, auth)
			}
		})
	}
}

func TestMalformedDiscoveryAndTransportErrorsNeverFallBack(t *testing.T) {
	bodies := []string{`{}`, `{"protocol_version":"1.15","capabilities":null}`, `{"protocol_version":"1.15","capabilities":[null]}`, `{"protocol_version":"1.15","capabilities":[1]}`, `not-json`}
	for _, body := range bodies {
		calls := 0
		client, _ := NewClient(Config{BaseURL: "http://exiron.test", Retry: RetryPolicy{MaxElapsed: -1}, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			calls++
			if req.URL.Path != "/api/capabilities" {
				t.Error("unsafe fallback")
			}
			return jsonResponse(200, body), nil
		})}})
		if _, err := client.Capabilities(context.Background()); err == nil {
			t.Fatal("accepted malformed discovery: " + body)
		}
		if calls != 1 {
			t.Fatal(calls)
		}
	}
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Retry: RetryPolicy{MaxElapsed: -1}, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if req.URL.Path != "/api/capabilities" {
			t.Error("unsafe fallback")
		}
		return nil, errors.New("offline")
	})}})
	if _, err := client.Capabilities(context.Background()); err == nil {
		t.Fatal("transport failure accepted")
	}
}

func TestDisabledFeaturesDoNotDiscoverAndMissingSupportNeverPolls(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		discovery, polls := 0, 0
		client, _ := NewClient(Config{BaseURL: "http://exiron.test", Transport: TransportHTTP, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			switch req.URL.Path {
			case "/api/capabilities":
				discovery++
				return jsonResponse(200, `{"protocol_version":"1.15","capabilities":[]}`), nil
			case "/api/requests":
				polls++
				return jsonResponse(409, `{"error":"stop"}`), nil
			default:
				t.Error(req.URL.Path)
				return jsonResponse(500, `{}`), nil
			}
		})}})
		runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, ReportHandlerFailures: enabled, Handler: func(context.Context, Message) error { return nil }})
		if err := runner.Run(context.Background()); err == nil {
			t.Fatal("expected failure")
		}
		if enabled && (discovery != 1 || polls != 0) {
			t.Fatalf("unsupported feature consumed work: %d %d", discovery, polls)
		}
		if !enabled && (discovery != 0 || polls != 1) {
			t.Fatalf("default changed: %d %d", discovery, polls)
		}
	}
}
