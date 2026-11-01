package exiron

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
	"time"
)

func TestAuthUsesConfiguredToken(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertRequest(t, r, http.MethodPost, "/api/auth")
		assertAuthorization(t, r, "Bearer ai-token")

		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode body: %v", err)
		}
		if body["hook_token"] != "ai-token" {
			t.Fatalf("hook_token = %q, want ai-token", body["hook_token"])
		}
		_, _ = w.Write(contractFixture(t, "auth_response.json"))
	}))
	defer server.Close()

	client := newTestClient(t, server.URL+"/")
	auth, err := client.Auth(context.Background())
	if err != nil {
		t.Fatalf("Auth returned error: %v", err)
	}
	if auth.Hook != "assistant" || auth.AuthResponse != "OK" || auth.ServerVersion != "0.1.0" {
		t.Fatalf("unexpected auth response: %#v", auth)
	}
}

func TestAuthDecodesSharedContractFixture(t *testing.T) {
	fixture := contractFixture(t, "auth_response.json")

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertRequest(t, r, http.MethodPost, "/api/auth")
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write(fixture)
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	auth, err := client.Auth(context.Background())
	if err != nil {
		t.Fatalf("Auth returned error: %v", err)
	}
	if auth.Hook != "assistant" || auth.AuthResponse != "OK" || auth.ServerVersion != "0.1.0" {
		t.Fatalf("unexpected auth response: %#v", auth)
	}
}

func TestRequestsDeclareConfiguredListenMode(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertRequest(t, r, http.MethodGet, "/api/requests")
		if r.URL.Query().Get("client_id") != "listener" {
			t.Fatalf("client_id query = %q, want listener", r.URL.Query().Get("client_id"))
		}
		if r.URL.Query().Get("listen") != "true" {
			t.Fatalf("listen query = %q, want true", r.URL.Query().Get("listen"))
		}
		writeJSON(t, w, map[string]any{"requests": []any{}})
	}))
	defer server.Close()

	client, err := New(
		server.URL,
		WithToken("ai-token"),
		WithClientID("listener"),
		WithListen(),
	)
	if err != nil {
		t.Fatalf("New returned error: %v", err)
	}
	if _, err := client.Requests(context.Background()); err != nil {
		t.Fatalf("Requests returned error: %v", err)
	}
}

func TestRequestsDeclareListenAllMode(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertRequest(t, r, http.MethodGet, "/api/requests")
		if r.URL.Query().Get("listen") != "all" {
			t.Fatalf("listen query = %q, want all", r.URL.Query().Get("listen"))
		}
		writeJSON(t, w, map[string]any{"requests": []any{}})
	}))
	defer server.Close()

	client, err := New(
		server.URL,
		WithToken("ai-token"),
		WithClientID("listener"),
		WithListenAll(),
	)
	if err != nil {
		t.Fatalf("New returned error: %v", err)
	}
	if _, err := client.Requests(context.Background()); err != nil {
		t.Fatalf("Requests returned error: %v", err)
	}
}

func TestRequestsFetchesAndDecodesQueuedMessages(t *testing.T) {
	messageID := int64(789)
	replyToMessageID := int64(456)
	lastName := "Lovelace"
	username := "ada"
	languageCode := "en"
	instance := "assistant-bot"
	stickerID := "sticker-id"
	stickerEmoji := "🤣"
	emojiList := []string{"😆", "🤣", "😀", "😂", "😄", "😃", "😁"}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertRequest(t, r, http.MethodGet, "/api/requests")
		assertAuthorization(t, r, "Bearer ai-token")

		writeJSON(t, w, map[string]any{
			"requests": []map[string]any{
				{
					"msgtype":             "request",
					"req_id":              "req-1",
					"message_id":          messageID,
					"reply_to_message_id": replyToMessageID,
					"from": map[string]any{
						"id":            42,
						"is_bot":        false,
						"first_name":    "Ada",
						"last_name":     lastName,
						"username":      username,
						"language_code": languageCode,
					},
					"service_id":    222,
					"chat_id":       123,
					"instance":      instance,
					"datatype":      "text",
					"data":          base64.StdEncoding.EncodeToString([]byte("/ai hello")),
					"sticker_id":    stickerID,
					"sticker_emoji": stickerEmoji,
					"emoji_list":    emojiList,
				},
			},
		})
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	messages, err := client.Requests(context.Background())
	if err != nil {
		t.Fatalf("Requests returned error: %v", err)
	}
	if len(messages) != 1 {
		t.Fatalf("got %d messages, want 1", len(messages))
	}

	message := messages[0]
	if message.Msgtype != "request" || message.ReqID != "req-1" ||
		message.ServiceID != 222 || message.ChatID != 123 ||
		message.Datatype != DatatypeText || string(message.Data) != "/ai hello" ||
		message.Text() != "/ai hello" {
		t.Fatalf("unexpected message: %#v", message)
	}
	if message.Instance == nil || *message.Instance != instance {
		t.Fatalf("Instance = %v, want %q", message.Instance, instance)
	}
	if message.MessageID == nil || *message.MessageID != messageID {
		t.Fatalf("MessageID = %v, want %d", message.MessageID, messageID)
	}
	if message.ReplyToMessageID == nil || *message.ReplyToMessageID != replyToMessageID {
		t.Fatalf("ReplyToMessageID = %v, want %d", message.ReplyToMessageID, replyToMessageID)
	}
	if message.From == nil || message.From.ID != 42 || message.From.FirstName != "Ada" ||
		message.From.LastName == nil || *message.From.LastName != lastName ||
		message.From.Username == nil || *message.From.Username != username ||
		message.From.LanguageCode == nil || *message.From.LanguageCode != languageCode {
		t.Fatalf("From = %#v, want Ada sender", message.From)
	}
	if message.StickerEmoji == nil || *message.StickerEmoji != stickerEmoji {
		t.Fatalf("StickerEmoji = %v, want %q", message.StickerEmoji, stickerEmoji)
	}
	if message.StickerID == nil || *message.StickerID != stickerID {
		t.Fatalf("StickerID = %v, want %q", message.StickerID, stickerID)
	}
	if !reflect.DeepEqual(message.EmojiList, emojiList) {
		t.Fatalf("EmojiList = %#v, want %#v", message.EmojiList, emojiList)
	}
}

func TestRequestsDecodesSharedContractFixture(t *testing.T) {
	fixture := contractFixture(t, "requests_response.json")

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertRequest(t, r, http.MethodGet, "/api/requests")
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write(fixture)
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	messages, err := client.Requests(context.Background())
	if err != nil {
		t.Fatalf("Requests returned error: %v", err)
	}
	if len(messages) != 1 {
		t.Fatalf("got %d messages, want 1", len(messages))
	}
	message := messages[0]
	if message.Msgtype != "request" || message.ReqID != "req-1" || string(message.Data) != "/ai hello" {
		t.Fatalf("unexpected message: %#v", message)
	}
	if message.StickerEmoji == nil || *message.StickerEmoji != "🤣" {
		t.Fatalf("sticker emoji = %#v, want rolling-on-floor-laughing", message.StickerEmoji)
	}
	if len(message.EmojiList) != 7 {
		t.Fatalf("emoji list len = %d, want 7", len(message.EmojiList))
	}
}

func TestRequestsAcceptsNullableTelegramMessageIDs(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(t, w, map[string]any{
			"requests": []map[string]any{
				{
					"msgtype":             "listen",
					"req_id":              "req-2",
					"message_id":          nil,
					"reply_to_message_id": nil,
					"from":                nil,
					"service_id":          222,
					"chat_id":             123,
					"instance":            nil,
					"datatype":            "text",
					"data":                base64.StdEncoding.EncodeToString([]byte("hello")),
				},
			},
		})
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	messages, err := client.Requests(context.Background())
	if err != nil {
		t.Fatalf("Requests returned error: %v", err)
	}
	if messages[0].Msgtype != "listen" {
		t.Fatalf("Msgtype = %q, want listen", messages[0].Msgtype)
	}
	if messages[0].MessageID != nil || messages[0].ReplyToMessageID != nil {
		t.Fatalf("message IDs = %v/%v, want nil/nil", messages[0].MessageID, messages[0].ReplyToMessageID)
	}
}

func TestStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertRequest(t, r, http.MethodGet, "/api/status")
		_, _ = w.Write(contractFixture(t, "status_response.json"))
	}))
	defer server.Close()

	client := newTestClient(t, server.URL)
	status, err := client.Status(context.Background())
	if err != nil {
		t.Fatalf("Status returned error: %v", err)
	}
	if !status.Enabled || !status.TelegramPolling || status.Version != "0.1.0" || status.Requested != 1 {
		t.Fatalf("status = %#v, want enabled polling status", status)
	}
	lastPolledAt := time.Date(2026, 7, 6, 18, 0, 0, 0, time.UTC)
	if status.TelegramLastPolledAt == nil || !status.TelegramLastPolledAt.Equal(lastPolledAt) {
		t.Fatalf("TelegramLastPolledAt = %v, want %v", status.TelegramLastPolledAt, lastPolledAt)
	}
	if len(status.Chats) != 1 || status.Chats[0].ID != 123 || !status.Chats[0].Polling || len(status.Chats[0].BotMemberships) != 1 {
		t.Fatalf("Chats = %#v, want polling chat with bot membership", status.Chats)
	}
	if len(status.Routes) != 1 || status.Routes[0].ID != 7 || status.Routes[0].ChatAlias != "home" {
		t.Fatalf("Routes = %#v, want route with id and chat alias", status.Routes)
	}
	if status.Routes[0].DefaultBot == nil || *status.Routes[0].DefaultBot != "assistant-bot" {
		t.Fatalf("Routes = %#v, want route with default bot", status.Routes)
	}
	if len(status.Events) != 1 || status.Events[0].BotName == nil || *status.Events[0].BotName != "assistant-bot" {
		t.Fatalf("Events = %#v, want event with bot name", status.Events)
	}
	if len(status.OverloadEvents) != 1 || status.OverloadEvents[0].Reason != "max_queue_per_hook" {
		t.Fatalf("OverloadEvents = %#v, want queue cap event", status.OverloadEvents)
	}
	if len(status.SendFailures) != 1 || status.SendFailures[0].Operation != "reply" {
		t.Fatalf("SendFailures = %#v, want reply failure", status.SendFailures)
	}
	if len(status.MembershipEvents) != 1 || status.MembershipEvents[0].Action != "added" {
		t.Fatalf("MembershipEvents = %#v, want added event", status.MembershipEvents)
	}
	if len(status.BotMemberships) != 1 || !status.BotMemberships[0].Present {
		t.Fatalf("BotMemberships = %#v, want present membership", status.BotMemberships)
	}
	if len(status.ClientEvents) != 1 || status.ClientEvents[0].ClientID != "runner" || !status.ClientEvents[0].Listening {
		t.Fatalf("ClientEvents = %#v, want connected runner event", status.ClientEvents)
	}
}
