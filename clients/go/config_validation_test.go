package exiron

import (
	"strings"
	"testing"
	"time"
)

func TestNewClientValidatesBaseURL(t *testing.T) {
	t.Parallel()

	valid := []string{
		"http://example.test",
		"https://example.test/exiron/",
	}
	for _, baseURL := range valid {
		baseURL := baseURL
		t.Run("valid_"+baseURL, func(t *testing.T) {
			t.Parallel()
			if _, err := New(baseURL); err != nil {
				t.Fatalf("New(%q) returned error: %v", baseURL, err)
			}
		})
	}

	invalid := []string{
		"",
		"example.test",
		"ftp://example.test",
		"http:///missing-host",
		"http://example.test?token=secret",
		"http://example.test#fragment",
	}
	for _, baseURL := range invalid {
		baseURL := baseURL
		t.Run("invalid_"+baseURL, func(t *testing.T) {
			t.Parallel()
			if _, err := New(baseURL); err == nil {
				t.Fatalf("New(%q) returned nil error", baseURL)
			}
		})
	}
}

func TestNewClientRejectsInvalidTransport(t *testing.T) {
	t.Parallel()

	_, err := New("http://example.test", WithTransport(Transport(99)))
	if err == nil || !strings.Contains(err.Error(), "invalid transport 99") {
		t.Fatalf("New returned error %v, want invalid transport", err)
	}
}

func TestNewClientRejectsNegativeRetryMaxDelay(t *testing.T) {
	t.Parallel()

	_, err := New(
		"http://example.test",
		WithRetryPolicy(RetryPolicy{MaxDelay: -time.Nanosecond}),
	)
	if err == nil || !strings.Contains(err.Error(), "retry max delay must not be negative") {
		t.Fatalf("New returned error %v, want negative retry max delay error", err)
	}
}
