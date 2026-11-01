package exiron

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"testing"
	"time"
)

func TestRichMessageHelpersKeepOneShotAndStreamingSeparate(t *testing.T) {
	var calls []map[string]any
	var paths []string
	client, err := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", HTTPClient: &http.Client{
		Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			var body map[string]any
			data, _ := io.ReadAll(req.Body)
			if err := json.Unmarshal(data, &body); err != nil {
				t.Fatal(err)
			}
			calls = append(calls, body)
			paths = append(paths, req.URL.Path)
			return jsonResponse(200, `{"ok":true}`), nil
		})}})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if _, err := client.ReplyText(ctx, "request", "one shot"); err != nil {
		t.Fatal(err)
	}
	if _, present := calls[0]["final"]; present {
		t.Fatal("one-shot acquired streaming semantics")
	}
	chunks := make(chan string, 2)
	chunks <- "Hel"
	chunks <- "lo"
	close(chunks)
	if _, err := client.StreamText(ctx, "request", chunks, StreamOptions{Interval: time.Hour}); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 3 || calls[1]["final"] != false || calls[2]["final"] != true {
		t.Fatalf("calls=%v", calls)
	}
	if calls[1]["data"] != base64.StdEncoding.EncodeToString([]byte("Hel")) || calls[2]["data"] != base64.StdEncoding.EncodeToString([]byte("Hello")) {
		t.Fatalf("calls=%v", calls)
	}
	if _, err := client.Typing(ctx, "request"); err != nil {
		t.Fatal(err)
	}
	if paths[3] != "/api/actions" || calls[3]["action"] != "typing" {
		t.Fatalf("calls=%v", calls)
	}
	if _, err := client.EditText(ctx, "request", "fixed"); err != nil {
		t.Fatal(err)
	}
	if paths[4] != "/api/edits" {
		t.Fatalf("paths=%v", paths)
	}
	topic := int64(7)
	if _, err := client.PushWithChatIDOptions(ctx, 123, DatatypeFile, []byte("bytes"),
		PushOptions{MessageThreadID: &topic, Caption: "report", FileName: "report.pdf", MIMEType: "application/pdf"}); err != nil {
		t.Fatal(err)
	}
	if calls[5]["message_thread_id"] != float64(7) || calls[5]["file_name"] != "report.pdf" {
		t.Fatalf("calls=%v", calls)
	}
}

func TestAlbumHelpersAndDecodingRetainMetadata(t *testing.T) {
	caption := "Photos"
	filename := "one.jpg"
	topic := int64(7)
	items := []MediaItem{{Datatype: DatatypeImage, Data: []byte("one"), Caption: &caption, FileName: &filename},
		{Datatype: DatatypeVideo, Data: []byte("two")}}
	encoded, err := encodeAlbum(items)
	if err != nil {
		t.Fatal(err)
	}
	body := base64.StdEncoding.EncodeToString(encoded)
	message, err := decodeMessage(wireMessage{Datatype: "album", Data: &body, MessageThreadID: &topic})
	if err != nil {
		t.Fatal(err)
	}
	if len(message.MediaItems) != 2 || string(message.MediaItems[0].Data) != "one" || *message.MediaItems[0].FileName != "one.jpg" || *message.MessageThreadID != 7 {
		t.Fatalf("message=%#v", message)
	}
	calls := 0
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		calls++
		var payload wireResponsePayload
		if err := json.NewDecoder(req.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if payload.Datatype != "album" || payload.Data != body {
			t.Fatalf("payload=%#v", payload)
		}
		return jsonResponse(200, `{"ok":true}`), nil
	})}})
	if _, err := client.ReplyAlbum(context.Background(), "request", items); err != nil {
		t.Fatal(err)
	}
	if _, err := encodeAlbum(items[:1]); err == nil {
		t.Fatal("one-member outbound album accepted")
	}
	if calls != 1 {
		t.Fatalf("calls=%d", calls)
	}
}

func TestStreamUnknownDeliveryAndCancellationDoNotRetry(t *testing.T) {
	calls := 0
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		calls++
		return jsonResponse(504, `{"code":"telegram_delivery_timeout","error":"telegram delivery result timed out"}`), nil
	})}})
	chunks := make(chan string, 2)
	chunks <- "one"
	chunks <- "two"
	close(chunks)
	if _, err := client.StreamText(context.Background(), "request", chunks); err == nil {
		t.Fatal("expected unknown delivery error")
	}
	if calls != 1 {
		t.Fatalf("calls=%d", calls)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	blocked := make(chan string)
	if _, err := client.StreamText(ctx, "request", blocked); !errors.Is(err, context.Canceled) {
		t.Fatalf("error=%v", err)
	}
	if calls != 1 {
		t.Fatalf("calls=%d", calls)
	}
}

func TestSharedRichMessageContractFixture(t *testing.T) {
	var response wireRequestsResponse
	if err := json.Unmarshal(contractFixture(t, "requests_rich_response.json"), &response); err != nil {
		t.Fatal(err)
	}
	messages, err := decodeMessages(response.Requests)
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 2 || len(messages[0].MediaItems) != 2 || string(messages[0].MediaItems[0].Data) != "photo-one" || *messages[0].MessageThreadID != 7 {
		t.Fatalf("messages=%#v", messages)
	}
	if len(messages[1].Entities) != 1 || messages[1].Entities[0].Type != "bot_command" {
		t.Fatalf("entities=%#v", messages[1].Entities)
	}
}
