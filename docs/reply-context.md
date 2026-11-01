# Telegram reply context

Protocol 1.6 advertises `reply_context`. Set `reply_to_original: true` when starting
a response to make its first message a Telegram reply to the incoming message.
The default stays unchanged: omitting the flag sends an ordinary message in the
request's chat and forum topic. One-shot and optional streaming APIs keep their
existing behavior and success response shapes.

```json
{
  "req_id": "request-id",
  "datatype": "text",
  "data": "YWNr",
  "reply_to_original": true
}
```

The server derives the destination from the authenticated request. It uses that
incoming message's own `message_id`, rather than the message it was replying to.
Clients cannot supply another message/chat ID through this option. Chat and forum
topic remain fixed to the request. A request without a positive source message ID
returns `invalid_payload` (400) when reply context is requested; it remains
available for an ordinary response.

## Streams and multipart text

Choose reply context on the **first** response or partial update. A stream retains
that choice on subsequent updates, including when the flag is omitted. Repeating
the same flag is valid; attempting to add or remove context after the first
successful update returns `invalid_payload`. Telegram edits cannot change an
existing message's reply relationship.

For long text, **only the first part replies to the original**. Continuation
messages stay in the same chat/topic without repeating the reference. Growing,
finalizing or shortening a stream reuses the existing message IDs. Edits and
surplus-message deletions do not send reply parameters. Completed-reply edits
preserve the original relationship, and newly appended parts remain ordinary
continuations. Existing formatting, inline keyboards and cancellation behavior
continue to apply.

The option also works with media, stickers and album responses. An album receives
one reply reference on the Telegram media-group request; Telegram controls how the
group is displayed. A callback's new response can reply to the clicked bot message.
`edit_origin: true` edits that existing message, so it cannot be combined with the
reply-context option. Completed edits and independent pushes also reject this
option: they do not create a response to a pending source request.

## Unavailable originals

Exiron sends typed Telegram `ReplyParameters` with
`allow_sending_without_reply: false`. It does not silently remove the reference or
retry as an unrelated message when Telegram rejects a missing/deleted original.
The existing delivery error and diagnostics report that failure. If the first
send was explicitly rejected and the request remains open, the caller may choose
to retry with `reply_to_original: false`. Do not replay a partial or uncertain send
blindly; follow [delivery diagnostics](delivery-diagnostics.md).

Telegram documents these parameters in the
[Bot API](https://core.telegram.org/bots/api#replyparameters).

## Elixir client

```elixir
ExironClient.respond(client, request, "text", "Acknowledged", reply_to_original: true)

# Opt-in streamed reply:
ExironClient.stream_text(client, request, chunks, reply_to_original: true)

# Or send full replacement updates yourself:
ExironClient.update_text(client, request, "Working…", reply_to_original: true)
ExironClient.reply_text(client, request, "Finished") # Retains the initial context.
```

Media uses the same response option, for example:

```elixir
ExironClient.respond(client, request, "file", bytes,
  file_name: "report.pdf", reply_to_original: true)
```

## Go client

```go
_, err := client.RespondWithOptions(ctx, request.ReqID, exiron.DatatypeText,
    []byte("Acknowledged"), exiron.ResponseOptions{ReplyToOriginal: true})

_, err = client.StreamText(ctx, request.ReqID, chunks, exiron.StreamOptions{
    ResponseOptions: exiron.ResponseOptions{ReplyToOriginal: true},
})
```

For manual streaming, start with `RespondWithOptions` and `Final: &partial`, where
`partial := false`. Existing `UpdateText` and `ReplyText` calls can then continue
or finalize the response without resending the flag. A false Go option is omitted
from JSON; omission on an ongoing stream retains the initial choice.

When connecting to a different server version, check that authentication
advertises the `reply_context` capability before relying on it. Older servers may
ignore an unknown optional field. The included clients and server share the
protocol 1.6 contract fixtures.
