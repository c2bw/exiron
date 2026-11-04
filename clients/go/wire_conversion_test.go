package exiron

import (
	"encoding/base64"
	"encoding/json"
	"reflect"
	"testing"
)

func TestWireAuthResponseMatchesPublicJSONDecoding(t *testing.T) {
	fixture := contractFixture(t, "auth_response.json")

	var wire wireAuthResponse
	if err := json.Unmarshal(fixture, &wire); err != nil {
		t.Fatalf("decode wire auth response: %v", err)
	}
	var public AuthResponse
	if err := json.Unmarshal(fixture, &public); err != nil {
		t.Fatalf("decode public auth response: %v", err)
	}

	if got := wire.toAuthResponse(); !reflect.DeepEqual(got, public) {
		t.Fatalf("converted auth response = %#v, direct public response = %#v", got, public)
	}
	protocol := ProtocolInfo{Version: public.ProtocolVersion, Capabilities: public.Capabilities}
	if public.ProtocolVersion != ProtocolVersion || !protocol.Supports("websocket") {
		t.Fatalf("auth protocol metadata = %#v", public)
	}
}

func TestWireStatusMatchesPublicJSONDecoding(t *testing.T) {
	fixture := contractFixture(t, "status_response.json")

	var wire wireStatus
	if err := json.Unmarshal(fixture, &wire); err != nil {
		t.Fatalf("decode wire status: %v", err)
	}
	var public Status
	if err := json.Unmarshal(fixture, &public); err != nil {
		t.Fatalf("decode public status: %v", err)
	}

	if got := wire.toStatus(); !reflect.DeepEqual(got, public) {
		t.Fatalf("converted status = %#v, direct public status = %#v", got, public)
	}
}

func TestWireMessageConversionPreservesPublicFieldsAndDecodesData(t *testing.T) {
	lastName := "Lovelace"
	username := "ada"
	languageCode := "en"
	instance := "assistant-bot"
	stickerID := "sticker-id"
	fileUniqueID := "unique-sticker"
	stickerEmoji := "🤣"
	messageID := int64(789)
	replyToMessageID := int64(456)

	wire := wireMessage{
		Msgtype:          "request",
		ReqID:            "req-1",
		From:             &wireTelegramUser{ID: 42, FirstName: "Ada", LastName: &lastName, Username: &username, LanguageCode: &languageCode},
		ServiceID:        222,
		ChatID:           123,
		Instance:         &instance,
		Datatype:         string(DatatypeText),
		Data:             pointer(base64.StdEncoding.EncodeToString([]byte("hello"))),
		StickerID:        &stickerID,
		FileUniqueID:     &fileUniqueID,
		StickerEmoji:     &stickerEmoji,
		EmojiList:        []string{"🤣"},
		MessageID:        &messageID,
		ReplyToMessageID: &replyToMessageID,
	}

	got, err := decodeMessage(wire)
	if err != nil {
		t.Fatalf("decodeMessage returned error: %v", err)
	}
	want := Message{
		Msgtype:          "request",
		ReqID:            "req-1",
		From:             &TelegramUser{ID: 42, FirstName: "Ada", LastName: &lastName, Username: &username, LanguageCode: &languageCode},
		ServiceID:        222,
		ChatID:           123,
		Instance:         &instance,
		Datatype:         DatatypeText,
		Data:             []byte("hello"),
		StickerID:        &stickerID,
		FileUniqueID:     &fileUniqueID,
		StickerEmoji:     &stickerEmoji,
		EmojiList:        []string{"🤣"},
		MessageID:        &messageID,
		ReplyToMessageID: &replyToMessageID,
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("decoded message = %#v, want %#v", got, want)
	}
}

func TestWireAcknowledgementResponsesConvertToPublicModels(t *testing.T) {
	if got, want := (wireOKResponse{OK: true}).toOKResponse(), (OkResponse{OK: true}); !reflect.DeepEqual(got, want) {
		t.Fatalf("OK response = %#v, want %#v", got, want)
	}
	if got, want := (wirePushResponse{OK: true, Sent: 2}).toPushResponse(), (PushResponse{OK: true, Sent: 2}); !reflect.DeepEqual(got, want) {
		t.Fatalf("push response = %#v, want %#v", got, want)
	}
}

func TestPublicModelsKeepJSONBehavior(t *testing.T) {
	message, err := json.Marshal(Message{Msgtype: "request", ReqID: "req-1", Data: []byte("hidden")})
	if err != nil {
		t.Fatalf("marshal message: %v", err)
	}
	var messageJSON map[string]any
	if err := json.Unmarshal(message, &messageJSON); err != nil {
		t.Fatalf("decode message JSON: %v", err)
	}
	if _, ok := messageJSON["data"]; ok {
		t.Fatalf("message JSON unexpectedly included decoded data: %s", message)
	}
	if messageJSON["req_id"] != "req-1" {
		t.Fatalf("message JSON req_id = %v, want req-1", messageJSON["req_id"])
	}

	auth, err := json.Marshal(AuthResponse{AuthResponse: "OK", Hook: "assistant", ServerVersion: "0.1.0"})
	if err != nil {
		t.Fatalf("marshal auth response: %v", err)
	}
	var authJSON map[string]any
	if err := json.Unmarshal(auth, &authJSON); err != nil {
		t.Fatalf("decode auth JSON: %v", err)
	}
	if authJSON["auth_response"] != "OK" || authJSON["hook"] != "assistant" || authJSON["server_version"] != "0.1.0" {
		t.Fatalf("auth JSON = %s, want stable public fields", auth)
	}
}

func pointer(value string) *string {
	return &value
}

func TestStickerFileUniqueIDDecoding(t *testing.T) {
	for _, msgtype := range []string{"request", "listen"} {
		for _, field := range []string{`,"file_unique_id":"unique-sticker"`, `,"file_unique_id":null`, ``} {
			payload := `{"msgtype":"` + msgtype + `","datatype":"file","data":"c3RpY2tlciBieXRlcw==","sticker_id":"sendable-id"` + field + `}`
			var wire wireMessage
			if err := json.Unmarshal([]byte(payload), &wire); err != nil {
				t.Fatal(err)
			}
			message, err := decodeMessage(wire)
			if err != nil {
				t.Fatal(err)
			}
			if message.Msgtype != msgtype || message.StickerID == nil || *message.StickerID != "sendable-id" || string(message.Data) != "sticker bytes" {
				t.Fatalf("sticker metadata lost: %#v", message)
			}
			if field == `,"file_unique_id":"unique-sticker"` {
				if message.FileUniqueID == nil || *message.FileUniqueID != "unique-sticker" {
					t.Fatalf("file identity lost: %#v", message)
				}
			} else if message.FileUniqueID != nil {
				t.Fatalf("missing/null file identity = %v", message.FileUniqueID)
			}
		}
	}
}

func TestEventConversionPreservesStickerFileIdentity(t *testing.T) {
	uniqueID := "unique-sticker"
	stickerID := "sendable-id"
	event := (wireEvent{FileUniqueID: &uniqueID, StickerID: &stickerID}).toEvent()
	if event.FileUniqueID == nil || *event.FileUniqueID != uniqueID || event.StickerID == nil || *event.StickerID != stickerID {
		t.Fatalf("sticker identity lost: %#v", event)
	}
}
