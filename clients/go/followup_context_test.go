package exiron

import (
	"encoding/json"
	"testing"
)

func TestFollowupContextDecodeAndOlderRequests(t *testing.T) {
	for _, name := range []string{"requests_followup_response.json", "requests_response.json"} {
		var payload wireRequestsResponse
		if err := json.Unmarshal(contractFixture(t, name), &payload); err != nil {
			t.Fatal(err)
		}
		messages, err := decodeMessages(payload.Requests)
		if err != nil || len(messages) != 1 {
			t.Fatal(messages, err)
		}
		message := messages[0]
		if name == "requests_followup_response.json" {
			if message.FollowupReqID == nil || *message.FollowupReqID != "req-parent" || message.ReqID != "req-followup" || message.Text() != "more" {
				t.Fatal(message)
			}
		} else if message.FollowupReqID != nil {
			t.Fatal("older request gained follow-up context")
		}
	}
}
