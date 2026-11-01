package exiron

import (
	"context"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestRequestLimitConfigurationAndSizing(t *testing.T) {
	c, err := New("http://exiron.test")
	if err != nil || c.maxRequestBytes != 51*1024*1024 {
		t.Fatal(c, err)
	}
	if _, err = New("http://exiron.test", WithMaxRequestBytes(-1)); err == nil {
		t.Fatal("accepted negative limit")
	}
	for n := 0; n < 20; n++ {
		if got := base64Size(int64(n)); got != int64(len(encodedPayload(DatatypeFile, make([]byte, n), PushOptions{}).Data)) {
			t.Fatal(n, got)
		}
	}
	if base64Size(math.MaxInt64) != math.MaxInt64 {
		t.Fatal("size overflow")
	}
}

func TestOutgoingPayloadExactBoundaries(t *testing.T) {
	ctx := context.Background()
	raw := []byte{0, 255, 1, 2, 3, 4, 5}
	caption := "é<quoted>\n\""
	items := []MediaItem{{Datatype: DatatypeFile, Data: raw, Caption: &caption}, {Datatype: DatatypeImage, Data: []byte{}}}
	album, _ := encodeAlbum(items)
	final := false
	ro := ResponseOptions{Caption: caption, IdempotencyKey: "reply-1", Final: &final}
	po := PushOptions{Caption: caption, IdempotencyKey: "push-1"}
	cases := []struct {
		name    string
		payload any
		send    func(*Client) error
	}{
		{"respond", encodedResponse("req", DatatypeFile, raw, nil), func(c *Client) error { _, e := c.Respond(ctx, "req", DatatypeFile, raw); return e }},
		{"options", encodedResponseWithOptions("req", DatatypeFile, raw, ro), func(c *Client) error { _, e := c.RespondWithOptions(ctx, "req", DatatypeFile, raw, ro); return e }},
		{"push", encodedPayload(DatatypeFile, raw, po), func(c *Client) error { _, e := c.PushWithOptions(ctx, DatatypeFile, raw, po); return e }},
		{"chat", encodedPayloadWithChatID(123, DatatypeFile, raw, po), func(c *Client) error { _, e := c.PushWithChatIDOptions(ctx, 123, DatatypeFile, raw, po); return e }},
		{"edit", encodedResponseWithOptions("req", DatatypeText, []byte("hello"), ResponseOptions{ParseMode: "plain"}), func(c *Client) error { _, e := c.EditText(ctx, "req", "hello"); return e }},
		{"album-reply", encodedResponseWithOptions("req", DatatypeAlbum, album, ro), func(c *Client) error { _, e := c.ReplyAlbumWithOptions(ctx, "req", items, ro); return e }},
		{"album-push", encodedPayload(DatatypeAlbum, album, po), func(c *Client) error { _, e := c.PushAlbum(ctx, items, po); return e }},
		{"album-chat", encodedPayloadWithChatID(123, DatatypeAlbum, album, po), func(c *Client) error { _, e := c.PushAlbumWithChatID(ctx, 123, items, po); return e }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			expected, _ := json.Marshal(tc.payload)
			for _, delta := range []int64{-1, 0, 1} {
				calls := 0
				limit := int64(len(expected)) + delta
				c, err := NewClient(Config{BaseURL: "http://exiron.test", MaxRequestBytes: limit, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
					calls++
					body, _ := io.ReadAll(req.Body)
					if string(body) != string(expected) {
						t.Errorf("wire payload changed: %s want %s", body, expected)
					}
					return jsonResponse(200, `{"ok":true,"sent":1}`), nil
				})}})
				if err != nil {
					t.Fatal(err)
				}
				err = tc.send(c)
				if delta < 0 {
					if err == nil || requireAPIError(t, err).Reason != "payload_too_large" || calls != 0 {
						t.Fatal(err, calls)
					}
				} else if err != nil || calls != 1 {
					t.Fatal(err, calls)
				}
			}
		})
	}
}

func TestOversizedDataRejectedBeforeBase64AndNetwork(t *testing.T) {
	c, _ := New("http://exiron.test", WithMaxRequestBytes(32))
	builds := 0
	payload := sizedPayload{data: make([]byte, 30), build: func(data []byte) any {
		builds++
		if data != nil {
			t.Fatal("encoded oversized data")
		}
		return encodedPayload(DatatypeFile, nil, PushOptions{})
	}}
	err := c.request(context.Background(), "POST", "/api/push", "", payload, nil)
	if err == nil || requireAPIError(t, err).Reason != "payload_too_large" || builds != 1 {
		t.Fatal(err, builds)
	}
}

func TestRequestEnvelopeAndControlBodiesAreLimited(t *testing.T) {
	c, _ := New("http://exiron.test", WithMaxRequestBytes(24), WithToken(strings.Repeat("t", 25)))
	if _, err := c.Auth(context.Background()); err == nil || requireAPIError(t, err).Reason != "payload_too_large" {
		t.Fatal(err)
	}
	if _, err := c.EditKeyboard(context.Background(), "req", InlineKeyboard{{{Text: strings.Repeat("x", 40), CallbackData: "ok"}}}); err == nil || requireAPIError(t, err).Reason != "payload_too_large" {
		t.Fatal(err)
	}
}

func TestAlbumSizeIncludesOuterEncodingAndNilMembers(t *testing.T) {
	items := []MediaItem{{Datatype: DatatypeFile, Data: nil}, {Datatype: DatatypeImage, Data: []byte{}}}
	encoded, _ := encodeAlbum(items)
	wire, _ := json.Marshal(encodedPayload(DatatypeAlbum, encoded, PushOptions{}))
	c, _ := New("http://exiron.test", WithMaxRequestBytes(int64(len(wire))))
	got, err := c.albumData(items, encodedPayload(DatatypeAlbum, nil, PushOptions{}))
	if err != nil || string(got) != string(encoded) {
		t.Fatal(string(got), err)
	}
	c.maxRequestBytes--
	if _, err = c.albumData(items, encodedPayload(DatatypeAlbum, nil, PushOptions{})); err == nil {
		t.Fatal("ignored album envelope")
	}
	c.maxRequestBytes = 16
	if _, err = c.albumData([]MediaItem{{Datatype: DatatypeFile, Data: make([]byte, 20)}, {Datatype: DatatypeImage}}, encodedPayload(DatatypeAlbum, nil, PushOptions{})); err == nil {
		t.Fatal("ignored member limit")
	}
}

func TestStreamStopsLocallyWhenAccumulatedPayloadExceedsLimit(t *testing.T) {
	calls := 0
	c, _ := NewClient(Config{BaseURL: "http://exiron.test", MaxRequestBytes: 110, HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		calls++
		return jsonResponse(200, `{"ok":true,"final":false,"message_id":1}`), nil
	})}})
	chunks := make(chan string, 2)
	chunks <- "p"
	chunks <- strings.Repeat("x", 100)
	close(chunks)
	_, err := c.StreamText(context.Background(), "req", chunks, StreamOptions{Interval: time.Hour})
	if err == nil || requireAPIError(t, err).Reason != "payload_too_large" || calls != 1 {
		t.Fatal(err, calls)
	}
}
