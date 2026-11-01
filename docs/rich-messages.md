# Text updates, actions, topics, albums and metadata

These are additive protocol 1.1 capabilities. Existing one-shot responses, pushes,
HTTP polling, WebSocket delivery, explicit acknowledgements and sticker helpers
remain available. One-shot completion remains the default. Both included clients
now support the additional operations and incoming metadata.

## Choose one-shot or streamed text

A normal `POST /api/responses` still completes the pending request:

```json
{"req_id":"request-id","datatype":"text","data":"SGVsbG8="}
```

Opt in to progressive updates by adding `"final": false`. Each update contains
the **complete replacement text**, rather than a token delta. The first update
creates a Telegram reply; subsequent updates edit the same reply. Protocol 1.3
automatically splits long text into ordered parts and retains their message IDs.
Successful updates return `{"ok":true,"final":false,"message_id":123}`.

Finish by sending another response with `"final": true` (or omitting `final`).
A final response retains the existing `{"ok":true}` success shape and completes
the request once. Concurrent responses remain rejected as in-flight.

Only text can be progressive, and a progressive reply cannot switch to media.
A logical text reply can contain up to 131072 UTF-16 units and 512 KiB of UTF-8
source, split into at most 32 parts. The original pending-request
deadline still applies; updates do not extend it. If a send times out, its result
is unknown and the request is closed rather than blindly starting another
message. Restart loses unfinished requests, as before.

The high-level client stream helpers accept UTF-8 **chunks**, append them, and
coalesce intermediate edits to a default 500 ms interval. Closing the input
stream finalizes the reply. They stop on errors; they do not automatically retry
an ambiguous delivery or finalize a failed stream. A producer can also call the
lower-level update method with full replacement text when it needs precise
control. See [long-text delivery](long-text.md) for formatting, editing, keyboard
placement and partial-delivery behavior.

### Elixir

```elixir
# Existing one-shot API, unchanged:
ExironClient.reply_text(client, request, "Hello")

# Opt-in chunks:
ExironClient.stream_text(client, request, ["Hel", "lo"], interval_ms: 500)

# Or explicitly control each full-text update:
ExironClient.update_text(client, request, "Working…")
ExironClient.update_text(client, request, "Almost finished…")
ExironClient.respond(client, request, "text", "Finished", parse_mode: "plain")
```

### Go

```go
// Existing one-shot API, unchanged:
_, err := client.ReplyText(ctx, request.ReqID, "Hello")

// Opt-in chunks; the producer should also observe ctx cancellation.
chunks := make(chan string, 2)
chunks <- "Hel"
chunks <- "lo"
close(chunks)
_, err = client.StreamText(ctx, request.ReqID, chunks)

// Or explicit replacement-text updates:
_, err = client.UpdateText(ctx, request.ReqID, "Working…")
_, err = client.RespondWithOptions(ctx, request.ReqID, exiron.DatatypeText,
    []byte("Finished"), exiron.ResponseOptions{ParseMode: "plain"})
```

Streaming and edit helpers default to plain text. Existing one-shot text retains
its Markdown behavior, including the existing fallback after a Markdown parse
error. Explicit `parse_mode` may be `plain`, `Markdown`, `MarkdownV2`, or `HTML`.
Explicit entities take precedence over parse mode. Incomplete HTML/Markdown
during streaming can be invalid; plain text is the default for that reason.

## Edit a completed reply

`POST /api/edits` takes `req_id`, `datatype: "text"`, base64 `data`, and optional
formatting fields. It edits a retained text reply identified by the **original
request ID**. It cannot edit arbitrary Telegram message IDs or another hook's
replies. Editing an unfinished reply through this endpoint is rejected; use
response updates until it completes.

Exiron retains minimal receipts for the latest **500 replies** with usable
Telegram IDs. Receipts contain addressing/ownership, not message bodies. Evicted
receipts and restarts remove this editing capability. Edits stay bound to the
bot that actually sent the reply; alternate-bot fallback is disabled for edits.
Removing that bot makes its old replies uneditable through Exiron.

```elixir
ExironClient.edit_text(client, request, "Corrected text")
```

```go
_, err := client.EditText(ctx, request.ReqID, "Corrected text")
```

Edits do not increase completed-response counts. Telegram's “message is not
modified” response is treated as a successful idempotent edit, which also lets
a final stream update repeat the last partial text.

## Typing and upload indicators

`POST /api/actions` takes `req_id` and `action`. It requires a pending request
owned by the authenticated hook, inherits that request's chat/topic, and does
not complete or extend it. Supported actions include `typing`, `upload_photo`,
`record_video`, `upload_video`, `record_voice`, `upload_voice`,
`upload_document`, `choose_sticker`, `find_location`, `record_video_note`, and
`upload_video_note`.

```elixir
ExironClient.typing(client, request)
ExironClient.chat_action(client, request, "upload_photo")
```

```go
_, err := client.Typing(ctx, request.ReqID)
_, err = client.ChatAction(ctx, request.ReqID, "upload_photo")
```

Telegram indicators last up to roughly five seconds and can clear sooner when
a message arrives. Applications may refresh them during long jobs. Actions are
not automatically started or repeatedly refreshed by existing reply methods.
They use the same bounded send capacity and rate-limit coordination as messages.

## Forum topics

Incoming messages expose `message_thread_id`. Responses, streamed updates,
actions and album replies inherit the original request's topic automatically.
Callers cannot redirect a response into another topic.

Pushes can set `message_thread_id`, using a positive Telegram topic ID and an
explicit `chat_id`. Route authorization for that chat remains enforced.

```elixir
ExironClient.push(client, chat_id, "text", "Hello topic", message_thread_id: topic_id)
```

```go
_, err := client.PushWithChatIDOptions(ctx, chatID, exiron.DatatypeText,
    []byte("Hello topic"), exiron.PushOptions{MessageThreadID: &topicID})
```

## Albums

Sending albums is explicit through the new client album helpers or the
`album` datatype. The base64 `data` decodes to a JSON array of 2..10 members.
Each member has `datatype` and base64 `data`, with optional caption, caption
entities, filename and MIME type. Image/video members may be mixed; audio and
document albums must each contain only their respective type. Exiron sends
them as a Telegram media group with multipart attachments.

```elixir
items = [
  %ExironClient.MediaItem{datatype: "image", data: photo_bytes, file_name: "photo.jpg", caption: "Photos"},
  %ExironClient.MediaItem{datatype: "video", data: video_bytes, file_name: "clip.mp4"}
]
ExironClient.reply_album(client, request, items)
ExironClient.push_album_to_chat(client, chat_id, items, message_thread_id: topic_id)
```

```go
name, caption := "photo.jpg", "Photos"
items := []exiron.MediaItem{
    {Datatype: exiron.DatatypeImage, Data: photoBytes, FileName: &name, Caption: &caption},
    {Datatype: exiron.DatatypeVideo, Data: videoBytes},
}
_, err := client.ReplyAlbum(ctx, request.ReqID, items)
_, err = client.PushAlbumWithChatID(ctx, chatID, items,
    exiron.PushOptions{MessageThreadID: &topicID})
```

Album pushes retain the existing meaning of `sent`: successful target chats,
not the number of album members. Existing media download, request-body, pending
and queue-byte limits still apply; large albums can be rejected by those limits.

### Optional grouped intake

**Individual media delivery remains the default** to preserve existing handlers.
Incoming individual members now include `media_group_id`, captions and metadata.

Set `EXIRON_GROUP_ALBUMS=true` and restart Exiron to collect incoming members into
one `album` request/listen message. Enable this only after handlers are ready for
the new datatype. The included clients decode its members to
`message.media_items` (Elixir) or `message.MediaItems` (Go), with decoded bytes.

Collection waits for a 350 ms quiet period, bounded by a 1500 ms window and
100 retained Telegram updates. Members are grouped by chat, topic and group ID;
up to 10 members and the existing total download limit are accepted. Topic and
member message IDs, captions, entities and filenames remain available. A caption
containing a route command can route the album as one request.

Telegram has no explicit album-complete update. Late members or a Telegram batch
boundary can split an album into separate deliveries sharing `media_group_id`;
a fragment may contain one member. Clients can inspect those IDs if they need
additional application-level reconciliation. Do not blindly feed a one-member
fragment into an outbound album helper, since Telegram requires at least two
members; send that member as ordinary media instead.

Failed album downloads are retried without acknowledging the buffered batch.
Already processed messages can replay, with existing incoming deduplication.
Collection is in memory and follows the existing restart-loss contract.

## Rich metadata and compatibility

Both HTTP and WebSocket clients expose optional `caption`, `entities`,
`caption_entities`, `file_name`, `mime_type`, `media_group_id`, and
`message_thread_id`, in addition to existing sender/message/reply metadata.

Entity offsets and lengths use **UTF-16 code units**, not UTF-8 byte offsets.
Server validation rejects out-of-range spans and partial surrogate boundaries.
Outgoing entity objects preserve common formatting, mentions, links, custom emoji
and date-time metadata. Filenames are used for multipart uploads; MIME metadata
is retained, while Telegram determines the uploaded media's content type.

Caption commands now participate in normal routing. Passthrough rewriting clears
entities on the rewritten text or parent caption so stale offsets are not
misrepresented; original album-member captions remain attached to their members.

Protocol 1.1 advertises `text_updates`, `message_edits`, `chat_actions`,
`forum_topics`, `media_albums`, and `message_metadata`. Clients can check the
advertised capabilities before invoking a new operation. The existing one-shot
APIs do not require opting into any of them.

Telegram method details:
[editMessageText](https://core.telegram.org/bots/api#editmessagetext),
[sendChatAction](https://core.telegram.org/bots/api#sendchataction),
[sendMediaGroup](https://core.telegram.org/bots/api#sendmediagroup).

Protocol 1.2 also adds [inline buttons and callback handling](inline-buttons.md), including keyboard-only edits for media replies.
