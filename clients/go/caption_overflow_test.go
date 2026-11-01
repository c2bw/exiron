package exiron

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"testing"
)

func TestCaptionOverflowWireContract(t *testing.T) {
	assertKeyboardFixture(t, encodedResponseWithOptions("req-1", DatatypeFile, []byte("bytes"), ResponseOptions{Caption: "report", CaptionOverflow: true}), "response_caption_overflow_payload.json")
	assertKeyboardFixture(t, encodedPayloadWithChatID(123, DatatypeFile, []byte("bytes"), PushOptions{Caption: "report", CaptionOverflow: true}), "push_caption_overflow_payload.json")
	body, _ := json.Marshal(encodedResponseWithOptions("req-1", DatatypeFile, []byte("bytes"), ResponseOptions{}))
	var defaults map[string]any
	_ = json.Unmarshal(body, &defaults)
	if _, exists := defaults["caption_overflow"]; exists {
		t.Fatal("default acquired overflow")
	}
}

func TestAlbumCaptionOverflowOptions(t *testing.T) {
	caption := "<b>Photos</b>"
	items := []MediaItem{{Datatype: DatatypeImage, Data: []byte("one"), Caption: &caption, ParseMode: "HTML"}, {Datatype: DatatypeVideo, Data: []byte("two")}}
	calls := 0
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		calls++
		var payload map[string]any
		if err := json.NewDecoder(req.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if payload["caption_overflow"] != true {
			t.Fatal(payload)
		}
		data, err := base64.StdEncoding.DecodeString(payload["data"].(string))
		if err != nil {
			t.Fatal(err)
		}
		var members []MediaItem
		if err := json.Unmarshal(data, &members); err != nil {
			t.Fatal(err)
		}
		if members[0].ParseMode != "HTML" || *members[0].Caption != caption {
			t.Fatal(members)
		}
		return jsonResponse(200, `{"ok":true,"sent":1}`), nil
	})}})
	ctx := context.Background()
	if _, err := client.ReplyAlbumWithOptions(ctx, "req-1", items, ResponseOptions{CaptionOverflow: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.PushAlbumWithChatID(ctx, 123, items, PushOptions{CaptionOverflow: true}); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatal(calls)
	}
}
