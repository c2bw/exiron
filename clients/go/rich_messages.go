package exiron

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"unicode/utf8"
)

// RespondWithOptions preserves Respond's one-shot default and adds optional metadata.
func (c *Client) RespondWithOptions(ctx context.Context, reqID string, datatype Datatype, data []byte, opts ResponseOptions) (*OkResponse, error) {
	path, err := keyedMutationPath("responses", opts.IdempotencyKey)
	if err != nil {
		return nil, err
	}
	var response wireOKResponse
	if err := c.request(ctx, http.MethodPost, path, c.token, sizedPayload{data: data, build: func(bytes []byte) any { return encodedResponseWithOptions(reqID, datatype, bytes, opts) }}, &response); err != nil {
		return nil, err
	}
	converted := response.toOKResponse()
	return &converted, nil
}

// UpdateText creates or replaces a partial reply without completing its request.
func (c *Client) UpdateText(ctx context.Context, reqID, text string) (*OkResponse, error) {
	final := false
	return c.RespondWithOptions(ctx, reqID, DatatypeText, []byte(text), ResponseOptions{Final: &final, ParseMode: "plain"})
}

// EditText edits a retained completed text reply by its original request ID.
func (c *Client) EditText(ctx context.Context, reqID, text string, opts ...ResponseOptions) (*OkResponse, error) {
	options := ResponseOptions{ParseMode: "plain"}
	if len(opts) > 0 {
		options = opts[0]
		if options.ParseMode == "" {
			options.ParseMode = "plain"
		}
	}
	if options.IdempotencyKey != "" {
		return nil, invalidResponse("idempotency keys are supported only for responses and pushes", nil)
	}
	var response wireOKResponse
	if err := c.request(ctx, http.MethodPost, "/api/edits", c.token, sizedPayload{data: []byte(text), build: func(bytes []byte) any { return encodedResponseWithOptions(reqID, DatatypeText, bytes, options) }}, &response); err != nil {
		return nil, err
	}
	result := response.toOKResponse()
	return &result, nil
}

// ChatAction sends a short-lived action to a pending request's chat and topic.
func (c *Client) ChatAction(ctx context.Context, reqID, action string) (*OkResponse, error) {
	var response wireOKResponse
	payload := struct {
		ReqID  string `json:"req_id"`
		Action string `json:"action"`
	}{reqID, action}
	if err := c.request(ctx, http.MethodPost, "/api/actions", c.token, payload, &response); err != nil {
		return nil, err
	}
	result := response.toOKResponse()
	return &result, nil
}
func (c *Client) Typing(ctx context.Context, reqID string) (*OkResponse, error) {
	return c.ChatAction(ctx, reqID, "typing")
}

func albumDatatype(t Datatype) bool {
	return t == DatatypeImage || t == DatatypeVideo || t == DatatypeAudio || t == DatatypeFile
}
func encodeAlbum(items []MediaItem) ([]byte, error) {
	if len(items) < 2 || len(items) > 10 {
		return nil, invalidResponse("albums require 2..10 items", nil)
	}
	for _, item := range items {
		if !albumDatatype(item.Datatype) {
			return nil, invalidResponse("invalid album member datatype", nil)
		}
	}
	data, err := json.Marshal(items)
	if err != nil {
		return nil, invalidResponse("invalid media album", err)
	}
	return data, nil
}
func (c *Client) ReplyAlbum(ctx context.Context, reqID string, items []MediaItem) (*OkResponse, error) {
	return c.ReplyAlbumWithOptions(ctx, reqID, items, ResponseOptions{})
}

// ReplyAlbumWithOptions adds caption overflow and reply context to album replies.
func (c *Client) ReplyAlbumWithOptions(ctx context.Context, reqID string, items []MediaItem, opts ResponseOptions) (*OkResponse, error) {
	data, err := c.albumData(items, encodedResponseWithOptions(reqID, DatatypeAlbum, nil, opts))
	if err != nil {
		return nil, err
	}
	return c.RespondWithOptions(ctx, reqID, DatatypeAlbum, data, opts)
}
func (c *Client) PushAlbum(ctx context.Context, items []MediaItem, opts ...PushOptions) (*PushResponse, error) {
	options := PushOptions{}
	if len(opts) > 0 {
		options = opts[0]
	}
	data, err := c.albumData(items, encodedPayload(DatatypeAlbum, nil, options))
	if err != nil {
		return nil, err
	}

	return c.PushWithOptions(ctx, DatatypeAlbum, data, options)
}
func (c *Client) PushAlbumWithChatID(ctx context.Context, chatID int64, items []MediaItem, opts ...PushOptions) (*PushResponse, error) {
	options := PushOptions{}
	if len(opts) > 0 {
		options = opts[0]
	}
	data, err := c.albumData(items, encodedPayloadWithChatID(chatID, DatatypeAlbum, nil, options))
	if err != nil {
		return nil, err
	}

	return c.PushWithChatIDOptions(ctx, chatID, DatatypeAlbum, data, options)
}

// StreamOptions controls opt-in chunk streaming. Zero Interval selects 500ms.
type StreamOptions struct {
	Interval        time.Duration
	ResponseOptions ResponseOptions
}

// StreamText appends UTF-8 chunks, coalesces edits, and completes on channel close.
// Cancellation or an uncertain delivery stops immediately without blind retries.
func (c *Client) StreamText(ctx context.Context, reqID string, chunks <-chan string, opts ...StreamOptions) (*OkResponse, error) {
	options := StreamOptions{}
	if len(opts) > 0 {
		options = opts[0]
	}
	interval := options.Interval
	if interval == 0 {
		interval = 500 * time.Millisecond
	}
	if interval < 0 {
		return nil, invalidResponse("stream interval must be positive", nil)
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	text := ""
	sent := ""
	partial := false
	sendUpdate := func(final bool) (*OkResponse, error) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		payloadOpts := options.ResponseOptions
		if payloadOpts.IdempotencyKey != "" {
			if !validIdempotencyKey(payloadOpts.IdempotencyKey) {
				return nil, invalidResponse("invalid idempotency key", nil)
			}
			payloadOpts.IdempotencyKey = streamIdempotencyKey(payloadOpts.IdempotencyKey, reqID, text, final)
		}
		payloadOpts.Final = &final
		if payloadOpts.ParseMode == "" {
			payloadOpts.ParseMode = "plain"
		}
		return c.RespondWithOptions(ctx, reqID, DatatypeText, []byte(text), payloadOpts)
	}
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case chunk, ok := <-chunks:
			if !ok {
				if text == "" {
					return nil, invalidResponse("empty text stream", nil)
				}
				return sendUpdate(true)
			}
			if !utf8.ValidString(chunk) || len(text)+len(chunk) > MaxTextBytes {
				return nil, invalidResponse("text stream exceeds the logical text byte limit", nil)
			}
			text += chunk
			if textUnits(text) > MaxTextUnits {
				return nil, invalidResponse("text stream exceeds the logical text UTF-16 limit", nil)
			}
			if !partial && text != "" {
				if _, err := sendUpdate(false); err != nil {
					return nil, err
				}
				sent = text
				partial = true
			}
		case <-ticker.C:
			if text != "" && text != sent {
				if _, err := sendUpdate(false); err != nil {
					return nil, err
				}
				sent = text
			}
		}
	}
}

// EditCallbackText edits the clicked button's message, completing the callback.
// ReplyText continues to send a new message for callbacks.
func (c *Client) EditCallbackText(ctx context.Context, reqID, text string, opts ...ResponseOptions) (*OkResponse, error) {
	options := ResponseOptions{}
	if len(opts) > 0 {
		options = opts[0]
	}
	options.EditOrigin = true
	if options.ParseMode == "" {
		options.ParseMode = "plain"
	}
	return c.RespondWithOptions(ctx, reqID, DatatypeText, []byte(text), options)
}

// CallbackData returns the application's button data, or an empty string.
func (m Message) CallbackData() string {
	if m.Datatype == DatatypeCallback {
		return string(m.Data)
	}
	return ""
}

// EditKeyboard replaces buttons on a retained reply without changing its content.
// Pass an empty keyboard to remove all buttons.
func (c *Client) EditKeyboard(ctx context.Context, reqID string, keyboard InlineKeyboard) (*OkResponse, error) {
	if keyboard == nil {
		keyboard = InlineKeyboard{}
	}
	var response wireOKResponse
	payload := encodedResponseWithOptions(reqID, DatatypeKeyboard, nil, ResponseOptions{InlineKeyboard: &keyboard})
	if err := c.request(ctx, http.MethodPost, "/api/edits", c.token, payload, &response); err != nil {
		return nil, err
	}
	converted := response.toOKResponse()
	return &converted, nil
}

// EditCallbackKeyboard replaces buttons on the clicked message, completing the callback.
func (c *Client) EditCallbackKeyboard(ctx context.Context, reqID string, keyboard InlineKeyboard) (*OkResponse, error) {
	if keyboard == nil {
		keyboard = InlineKeyboard{}
	}
	return c.RespondWithOptions(ctx, reqID, DatatypeKeyboard, nil, ResponseOptions{InlineKeyboard: &keyboard, EditOrigin: true})
}

// MaxTextUnits bounds one logical reply, automatically split by the server.
const MaxTextUnits = 131072

// MaxTextBytes bounds UTF-8 source bytes for one logical reply.
const MaxTextBytes = 524288

func textUnits(text string) int {
	units := 0
	for _, r := range text {
		if r > 0xffff {
			units += 2
		} else {
			units++
		}
	}
	return units
}
