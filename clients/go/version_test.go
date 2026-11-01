package exiron

import (
	"os"
	"strings"
	"testing"
)

func TestSDKVersionMatchesPackagedSource(t *testing.T) {
	data, err := os.ReadFile("VERSION")
	if err != nil {
		t.Fatal(err)
	}
	if Version() != strings.TrimSpace(string(data)) || Version() == "" {
		t.Fatal("SDK version mismatch")
	}
	if ProtocolVersion == Version() {
		t.Fatal("SDK and protocol versions conflated")
	}
}
