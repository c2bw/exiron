# Inline buttons and callbacks

Protocol 1.2 adds `inline_keyboards` and `callback_queries`. Existing one-shot
responses remain the default; text streaming is still optional. Both included
clients support these features over HTTP polling and WebSockets.

Attach `inline_keyboard` to a response, push, or text edit. It is an array of
rows, each containing buttons with `text` and exactly one of `callback_data` or
`url`. Callback data is application text, 1–64 UTF-8 bytes. URLs support HTTP,
HTTPS and `tg://`. Exiron accepts at most 20 rows, 8 buttons per row and 100
buttons total; labels are limited to 256 UTF-8 bytes and URLs to 2048 bytes.
Albums do not support inline keyboards.

```json
{
  "req_id": "request-id",
  "datatype": "text",
  "data": "Q2hvb3Nl",
  "inline_keyboard": [[
    {"text": "Next", "callback_data": "next:2"},
    {"text": "Help", "url": "https://example.com/help"}
  ]]
}
```

The same optional keyboard field works on `/api/push`, including media pushes.
For edits and ongoing text streams, omit the keyboard to preserve existing
buttons; send `[]` to remove them. Explicitly supplying a new keyboard replaces
its callback references. To change only buttons on a retained reply, post to
`/api/edits` with `datatype: "keyboard"`, `data: ""`, `req_id` and
`inline_keyboard`. Retained reply receipts are bounded to the latest 500 replies.
Pushes have no reply request ID, but their buttons can be edited from a callback.

## Receiving clicks

A click arrives as an ordinary request with `datatype: "callback"`. Its `data`
is the base64-encoded application callback data, decoded by both clients. The
`from` field identifies the person who clicked; `chat_id`, `message_id` and
`message_thread_id` identify the source message. `callback_query` contains `id`
and `origin_req_id` (null for push buttons). Use the click's new `req_id` to
respond. Ordinary reply helpers send a new message. Set `edit_origin: true` on
a text response to replace the clicked message instead, or use
`datatype: "keyboard"`, empty data and a keyboard to change only its buttons.
Text replacement applies to text messages; use keyboard-only edits for media.

Exiron schedules Telegram's callback acknowledgement as soon as it processes the
click, independently of handler replies and the normal outbound send queue. It
prioritizes callbacks in a fetched update batch before buffering albums or
downloading media. The acknowledgement clears Telegram's waiting indicator; it
does not mean the client has completed the request. The acknowledgement pool is
bounded to 64 concurrent calls with one-second connection, pool and receive
timeouts. Failures do not replay accepted client work. Telegram acknowledgement
behavior is described in the [Bot API](https://core.telegram.org/bots/api#answercallbackquery).

## Elixir client

```elixir
keyboard = [[%{text: "Next", callback_data: "next:2"}]]
ExironClient.respond(client, request, "text", "Choose", inline_keyboard: keyboard)

# In your request handler:
case message.datatype do
  "callback" ->
    case ExironClient.Message.callback_data(message) do
      "next:2" ->
        ExironClient.edit_callback_text(client, message, "Page 2", inline_keyboard: [])
      _ ->
        ExironClient.reply_text(client, message, "Unknown action")
    end
  _ ->
    # Existing text/media handling continues here.
    :ok
end

# Change only buttons, completing the callback request:
ExironClient.edit_callback_keyboard(client, message, keyboard)
# Or edit a completed reply using its original request ID:
ExironClient.edit_keyboard(client, original_request_id, [])
```

`update_text/4` and `stream_text/4` also accept `inline_keyboard` and
`edit_origin: true`. Their existing deadline and explicit finalization rules
still apply.

## Go client

```go
keyboard := exiron.InlineKeyboard{{{Text: "Next", CallbackData: "next:2"}}}
_, err := client.RespondWithOptions(ctx, request.ReqID, exiron.DatatypeText,
    []byte("Choose"), exiron.ResponseOptions{InlineKeyboard: &keyboard})

// In your request handler:
if message.Datatype == exiron.DatatypeCallback && message.CallbackData() == "next:2" {
    empty := exiron.InlineKeyboard{}
    _, err = client.EditCallbackText(ctx, message.ReqID, "Page 2",
        exiron.ResponseOptions{InlineKeyboard: &empty})
}

// Change only buttons, completing the callback request:
_, err = client.EditCallbackKeyboard(ctx, message.ReqID, keyboard)
// Or edit a completed reply using its original request ID:
_, err = client.EditKeyboard(ctx, originalRequestID, exiron.InlineKeyboard{})
```

A nil `ResponseOptions.InlineKeyboard` preserves buttons. A pointer to an empty
keyboard removes them. `EditKeyboard` and `EditCallbackKeyboard` also accept a
nil keyboard as an explicit removal. `PushOptions` supports the same optional
keyboard pointer. Streaming can use `StreamOptions.ResponseOptions` with
`InlineKeyboard` and `EditOrigin`.

## Ownership and lifetime

Exiron replaces outgoing callback data with opaque references and binds them to
the creating hook, actual sending bot, chat, message and topic. Clicks go directly
to that hook, independent of text routes, and are not broadcast to listener
hooks. Forged, expired, replaced or removed references receive an unavailable
acknowledgement. Offline or overloaded hooks reject clicks without posting chat
messages. Redelivered callback IDs are deduplicated within the existing bounded
500-message deduplication window; repeated clicks with different IDs remain
separate requests.

Bindings live in memory, retain at most 5000 callback references, and expire
24 hours after the latest successful keyboard send/edit. Older bindings may be
evicted at capacity. Restart loss is intentional: old callback buttons become
unavailable after restart; URL buttons continue to work. Re-send the menu to
create fresh buttons. This supports bot messages in chats; inline-mode messages
and callback game buttons are not supported. Any user who can click a button in
the chat can invoke it. Sensitive actions should authorize the clicking user in
the handler.
