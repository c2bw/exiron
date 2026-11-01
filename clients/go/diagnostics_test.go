package exiron

import (
	"errors"
	"fmt"
	"strings"
	"testing"
)

func TestDiagnosticsDoNotExposeCredentialsOrBodies(t *testing.T) {
	cfg := Config{BaseURL: "http://user:password@example.test/private?key=secret", Token: "bearer-secret", ClientID: "private-id"}
	client, err := NewClient(Config{BaseURL: "http://example.test"})
	if err != nil {
		t.Fatal(err)
	}
	client.baseURL, client.token, client.clientID = cfg.BaseURL, cfg.Token, cfg.ClientID
	for _, value := range []any{cfg, &cfg, client, *client} {
		for _, format := range []string{"%v", "%+v", "%#v"} {
			output := fmt.Sprintf(format, value)
			for _, secret := range []string{"password", "private", "secret", "example.test"} {
				if strings.Contains(output, secret) {
					t.Fatalf("unsafe formatting: %s", output)
				}
			}
		}
	}
	raw := &Error{Reason: "transport_error", Message: "bearer-secret", Body: []byte("private body"), Err: errors.New("private cause")}
	wrapped := fmt.Errorf("private outer: %w", raw)
	summary := SummarizeError(wrapped)
	if summary.Kind != "transport_error" || strings.Contains(fmt.Sprint(summary), "private") {
		t.Fatal(summary)
	}
	if raw.Message != "bearer-secret" || !errors.Is(wrapped, raw.Err) {
		t.Fatal("raw diagnostic access changed")
	}
	if SummarizeError(nil).Kind != "none" {
		t.Fatal("nil error summary")
	}
}
