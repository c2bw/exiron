package exiron

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestReplyTextBase64EncodesData(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertRequest(t, r, http.MethodPost, "/api/responses")

		assertJSONBodyMatchesFixture(t, r, "response_payload.json")

		_, _ = w.Write(contractFixture(t, "ok_response.json"))
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	response, err := client.ReplyTextMessage(context.Background(), Message{ReqID: "req-1"}, "ack")
	if err != nil {
		t.Fatalf("ReplyTextMessage returned error: %v", err)
	}
	if !response.OK {
		t.Fatalf("OK = false, want true")
	}
}

func TestPushTextBase64EncodesData(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertRequest(t, r, http.MethodPost, "/api/push")

		assertJSONBodyMatchesFixture(t, r, "push_payload.json")

		_, _ = w.Write(contractFixture(t, "push_response.json"))
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	response, err := client.PushText(context.Background(), "hello")
	if err != nil {
		t.Fatalf("PushText returned error: %v", err)
	}
	if !response.OK || response.Sent != 2 {
		t.Fatalf("response = %#v, want ok with sent=2", response)
	}
}

func TestPushTextWithOptionsSelectsBot(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertRequest(t, r, http.MethodPost, "/api/push")

		assertJSONBodyMatchesFixture(t, r, "push_bot_payload.json")

		_, _ = w.Write(contractFixture(t, "push_response.json"))
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	response, err := client.PushTextWithOptions(context.Background(), "hello", PushOptions{Bot: "second-bot"})
	if err != nil {
		t.Fatalf("PushTextWithOptions returned error: %v", err)
	}
	if !response.OK || response.Sent != 2 {
		t.Fatalf("response = %#v, want ok with sent=2", response)
	}
}

func TestPushTextWithChatIDUsesSharedContractPayload(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertRequest(t, r, http.MethodPost, "/api/push")

		assertJSONBodyMatchesFixture(t, r, "push_chat_payload.json")

		_, _ = w.Write(contractFixture(t, "push_response.json"))
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	response, err := client.PushTextWithChatID(context.Background(), -1_001_234_567_890, "hello")
	if err != nil {
		t.Fatalf("PushTextWithChatID returned error: %v", err)
	}
	if !response.OK || response.Sent != 2 {
		t.Fatalf("response = %#v, want ok with sent=2", response)
	}
}

func TestPushStickerBase64EncodesFileID(t *testing.T) {
	stickerEmoji := "🔥"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertRequest(t, r, http.MethodPost, "/api/push")

		assertJSONBodyMatchesFixture(t, r, "push_sticker_payload.json")

		_, _ = w.Write(contractFixture(t, "push_response.json"))
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	response, err := client.PushSticker(context.Background(), "sticker-file-id", stickerEmoji)
	if err != nil {
		t.Fatalf("PushSticker returned error: %v", err)
	}
	if !response.OK || response.Sent != 2 {
		t.Fatalf("response = %#v, want ok with sent=2", response)
	}
}

func TestReplyStickerBase64EncodesFileIDAndEmoji(t *testing.T) {
	stickerEmoji := "🔥"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertRequest(t, r, http.MethodPost, "/api/responses")

		assertJSONBodyMatchesFixture(t, r, "response_sticker_payload.json")

		_, _ = w.Write(contractFixture(t, "ok_response.json"))
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	response, err := client.ReplySticker(context.Background(), "req-1", "sticker-file-id", stickerEmoji)
	if err != nil {
		t.Fatalf("ReplySticker returned error: %v", err)
	}
	if !response.OK {
		t.Fatalf("OK = false, want true")
	}
}
