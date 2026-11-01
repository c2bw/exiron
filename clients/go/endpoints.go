package exiron

import (
	"context"
	"net/http"
	"net/url"
)

// Auth authenticates a hook token and returns the authenticated hook.
//
// If hookToken is omitted or empty, the client's configured token is used.
func (c *Client) Auth(ctx context.Context, hookToken ...string) (*AuthResponse, error) {
	token := c.token
	if len(hookToken) > 0 && hookToken[0] != "" {
		token = hookToken[0]
	}

	var response wireAuthResponse
	if err := c.request(ctx, http.MethodPost, "/api/auth", token, wireAuthRequest{HookToken: token}, &response); err != nil {
		return nil, err
	}
	converted := response.toAuthResponse()
	return &converted, nil
}

// Requests fetches queued routed requests for the authenticated hook.
//
// This one-shot operation is not retried after transport errors because
// the server may already have drained the queue. Use Runner for explicit
// delivery acknowledgement and recoverable polling.
func (c *Client) Requests(ctx context.Context) ([]Message, error) {
	query := url.Values{
		"client_id": {c.clientID},
		"listen":    {c.listen},
	}
	messages, _, err := c.requestMessages(ctx, query)
	return messages, err
}

func (c *Client) requestsDelivery(ctx context.Context, deliveryAck string) ([]Message, string, error) {
	query := url.Values{
		"client_id":     {c.clientID},
		"listen":        {c.listen},
		"delivery_mode": {"explicit"},
	}
	if deliveryAck != "" {
		query.Set("delivery_ack", deliveryAck)
	}
	return c.requestMessages(ctx, query)
}

func (c *Client) requestMessages(ctx context.Context, query url.Values) ([]Message, string, error) {
	messages, batch, _, err := c.requestMessagesRuntime(ctx, query)
	return messages, batch, err
}
func (c *Client) requestsDeliveryRuntime(ctx context.Context, ack string) ([]Message, string, string, error) {
	query := url.Values{"client_id": {c.clientID}, "listen": {c.listen}, "delivery_mode": {"explicit"}}
	if ack != "" {
		query.Set("delivery_ack", ack)
	}
	return c.requestMessagesRuntime(ctx, query)
}

func (c *Client) requestMessagesRuntime(ctx context.Context, query url.Values) ([]Message, string, string, error) {
	var response wireRequestsResponse
	path := "/api/requests?" + query.Encode()
	if err := c.request(ctx, http.MethodGet, path, c.token, nil, &response); err != nil {
		return nil, "", "", err
	}
	if response.Requests == nil {
		return nil, "", "", invalidResponse("expected requests to be a list", nil)
	}

	messages, err := decodeMessages(response.Requests)
	if err != nil {
		return nil, "", "", err
	}
	return messages, response.DeliveryID, response.RuntimeRef, nil
}

// Respond sends a response for a pending Telegram request.
func (c *Client) Respond(ctx context.Context, reqID string, datatype Datatype, data []byte) (*OkResponse, error) {
	return c.respond(ctx, reqID, datatype, data, nil)
}

func (c *Client) respond(ctx context.Context, reqID string, datatype Datatype, data []byte, stickerEmoji *string) (*OkResponse, error) {
	var response wireOKResponse
	if err := c.request(ctx, http.MethodPost, "/api/responses", c.token, sizedPayload{data: data, build: func(bytes []byte) any { return encodedResponse(reqID, datatype, bytes, stickerEmoji) }}, &response); err != nil {
		return nil, err
	}
	converted := response.toOKResponse()
	return &converted, nil
}

// RespondMessage sends a response for message.
func (c *Client) RespondMessage(ctx context.Context, message Message, datatype Datatype, data []byte) (*OkResponse, error) {
	return c.Respond(ctx, message.ReqID, datatype, data)
}

// ReplyText sends a text response for a pending Telegram request.
func (c *Client) ReplyText(ctx context.Context, reqID string, text string) (*OkResponse, error) {
	return c.Respond(ctx, reqID, DatatypeText, []byte(text))
}

// ReplyTextMessage sends a text response for message.
func (c *Client) ReplyTextMessage(ctx context.Context, message Message, text string) (*OkResponse, error) {
	return c.RespondMessage(ctx, message, DatatypeText, []byte(text))
}

// ReplySticker sends a sticker response for a pending Telegram request.
func (c *Client) ReplySticker(ctx context.Context, reqID string, stickerFileID string, emoji string) (*OkResponse, error) {
	return c.respond(ctx, reqID, DatatypeSticker, []byte(stickerFileID), optionalString(emoji))
}

// ReplyStickerMessage sends a sticker response for message.
func (c *Client) ReplyStickerMessage(ctx context.Context, message Message, stickerFileID string, emoji string) (*OkResponse, error) {
	return c.ReplySticker(ctx, message.ReqID, stickerFileID, emoji)
}

// Push pushes a payload to all push-enabled targets for the authenticated hook.
func (c *Client) Push(ctx context.Context, datatype Datatype, data []byte) (*PushResponse, error) {
	return c.PushWithOptions(ctx, datatype, data, PushOptions{})
}

// PushWithOptions pushes a payload with optional delivery controls.
func (c *Client) PushWithOptions(ctx context.Context, datatype Datatype, data []byte, opts PushOptions) (*PushResponse, error) {
	path, err := keyedMutationPath("push", opts.IdempotencyKey)
	if err != nil {
		return nil, err
	}
	var response wirePushResponse
	if err := c.request(ctx, http.MethodPost, path, c.token, sizedPayload{data: data, build: func(bytes []byte) any { return encodedPayload(datatype, bytes, opts) }}, &response); err != nil {
		return nil, err
	}
	converted := response.toPushResponse()
	return &converted, nil
}

// PushWithChatID pushes a payload to a specific push-enabled chat for the authenticated hook.
func (c *Client) PushWithChatID(ctx context.Context, chatID int64, datatype Datatype, data []byte) (*PushResponse, error) {
	return c.PushWithChatIDOptions(ctx, chatID, datatype, data, PushOptions{})
}

// PushWithChatIDOptions pushes a payload to a specific chat with optional delivery controls.
func (c *Client) PushWithChatIDOptions(ctx context.Context, chatID int64, datatype Datatype, data []byte, opts PushOptions) (*PushResponse, error) {
	path, err := keyedMutationPath("push", opts.IdempotencyKey)
	if err != nil {
		return nil, err
	}
	var response wirePushResponse
	if err := c.request(ctx, http.MethodPost, path, c.token, sizedPayload{data: data, build: func(bytes []byte) any { return encodedPayloadWithChatID(chatID, datatype, bytes, opts) }}, &response); err != nil {
		return nil, err
	}
	converted := response.toPushResponse()
	return &converted, nil
}

// PushText pushes a text payload.
func (c *Client) PushText(ctx context.Context, text string) (*PushResponse, error) {
	return c.Push(ctx, DatatypeText, []byte(text))
}

// PushTextWithOptions pushes a text payload with optional delivery controls.
func (c *Client) PushTextWithOptions(ctx context.Context, text string, opts PushOptions) (*PushResponse, error) {
	return c.PushWithOptions(ctx, DatatypeText, []byte(text), opts)
}

// PushTextWithChatID pushes a text payload to a specific chat.
func (c *Client) PushTextWithChatID(ctx context.Context, chatID int64, text string) (*PushResponse, error) {
	return c.PushWithChatID(ctx, chatID, DatatypeText, []byte(text))
}

// PushTextWithChatIDOptions pushes a text payload to a specific chat with optional delivery controls.
func (c *Client) PushTextWithChatIDOptions(ctx context.Context, chatID int64, text string, opts PushOptions) (*PushResponse, error) {
	return c.PushWithChatIDOptions(ctx, chatID, DatatypeText, []byte(text), opts)
}

// PushSticker pushes a sticker payload.
func (c *Client) PushSticker(ctx context.Context, stickerFileID string, emoji string) (*PushResponse, error) {
	return c.PushStickerWithOptions(ctx, stickerFileID, emoji, PushOptions{})
}

// PushStickerWithOptions pushes a sticker payload with optional delivery controls.
func (c *Client) PushStickerWithOptions(ctx context.Context, stickerFileID string, emoji string, opts PushOptions) (*PushResponse, error) {
	opts.StickerEmoji = emoji
	return c.PushWithOptions(ctx, DatatypeSticker, []byte(stickerFileID), opts)
}

// PushStickerWithChatID pushes a sticker payload to a specific chat.
func (c *Client) PushStickerWithChatID(ctx context.Context, chatID int64, stickerFileID string, emoji string) (*PushResponse, error) {
	return c.PushStickerWithChatIDOptions(ctx, chatID, stickerFileID, emoji, PushOptions{})
}

// PushStickerWithChatIDOptions pushes a sticker payload to a specific chat with optional delivery controls.
func (c *Client) PushStickerWithChatIDOptions(ctx context.Context, chatID int64, stickerFileID string, emoji string, opts PushOptions) (*PushResponse, error) {
	opts.StickerEmoji = emoji
	return c.PushWithChatIDOptions(ctx, chatID, DatatypeSticker, []byte(stickerFileID), opts)
}

// Status fetches Exiron status scoped to the client's authenticated hook.
func (c *Client) Status(ctx context.Context) (*Status, error) {
	var response wireStatus
	if err := c.request(ctx, http.MethodGet, "/api/status", c.token, nil, &response); err != nil {
		return nil, err
	}
	converted := response.toStatus()
	return &converted, nil
}

func optionalString(value string) *string {
	if value == "" {
		return nil
	}
	return &value
}
