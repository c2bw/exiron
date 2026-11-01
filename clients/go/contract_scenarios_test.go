package exiron

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSharedScenariosExecuteAgainstClientProtocolAdapters(t *testing.T) {
	manifest := contractMap(t, "manifest.json")
	paths, err := filepath.Glob(filepath.Join("..", "contract", "scenarios", "*.json"))
	if err != nil {
		t.Fatalf("glob scenarios: %v", err)
	}
	if len(paths) != 8 {
		t.Fatalf("scenario count = %d, want 8", len(paths))
	}

	for _, path := range paths {
		var scenario map[string]any
		contents, readErr := os.ReadFile(path)
		if readErr != nil {
			t.Fatalf("read scenario %s: %v", path, readErr)
		}
		if err := json.Unmarshal(contents, &scenario); err != nil {
			t.Fatalf("decode scenario %s: %v", path, err)
		}
		if scenario["scenario_version"] != "1" {
			t.Fatalf("scenario %s has unsupported version %#v", path, scenario["scenario_version"])
		}

		for _, rawCase := range scenario["cases"].([]any) {
			scenarioCase := rawCase.(map[string]any)
			t.Run(fmt.Sprintf("%s/%s", scenario["id"], scenarioCase["id"]), func(t *testing.T) {
				executeSharedScenarioCase(t, scenarioCase, manifest)
			})
		}
	}
}

func executeSharedScenarioCase(t *testing.T, scenarioCase, manifest map[string]any) {
	t.Helper()
	request, _ := scenarioCase["request"].(map[string]any)
	response, _ := scenarioCase["response"].(map[string]any)

	for _, values := range []map[string]any{request, response} {
		for key, rawFixture := range values {
			fixture, ok := rawFixture.(string)
			if ok && strings.HasSuffix(key, "_fixture") {
				_ = contractMap(t, fixture)
			}
		}
	}

	if code, ok := response["error_code"].(string); ok {
		body, _ := json.Marshal(map[string]any{"code": code, "error": "changed message"})
		err := apiError(intValue(response["status"], 409), body)
		if err.Code != code || err.Reason != code {
			t.Fatalf("error = %#v, want stable code %q", err, code)
		}
	}

	if response["protocol_version"] == "manifest" {
		fixtureName, _ := response["response_fixture"].(string)
		if fixtureName == "" {
			fixtureName, _ = response["frame_fixture"].(string)
		}
		fixture := contractMap(t, fixtureName)
		if fixture["protocol_version"] != manifest["protocol_version"] {
			t.Fatalf("protocol version = %#v, want %#v", fixture["protocol_version"], manifest["protocol_version"])
		}
		if !sameStrings(fixture["capabilities"], manifest["capabilities"]) {
			t.Fatalf("capabilities differ from manifest")
		}
	}
}

func intValue(value any, fallback int) int {
	if number, ok := value.(float64); ok {
		return int(number)
	}
	return fallback
}

func sameStrings(left, right any) bool {
	leftJSON, _ := json.Marshal(left)
	rightJSON, _ := json.Marshal(right)
	return string(leftJSON) == string(rightJSON)
}
