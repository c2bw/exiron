# Media captions and overflow

Protocol 1.7 advertises `caption_overflow`. Captions on images, videos, audio and
files are checked before uploading. Albums are checked in full before sending
any member. Oversized or malformed captions return `invalid_payload` (HTTP 400);
a pending request remains available for a corrected response.

Telegram allows 1024 characters after entity parsing for media captions; see
[sendDocument](https://core.telegram.org/bots/api#senddocument) and
[sendMediaGroup](https://core.telegram.org/bots/api#sendmediagroup). Exiron applies
a conservative limit of **1024 rendered UTF-16 units** (an emoji outside the BMP
uses two units). Captions default to plain text. `parse_mode` supports `plain`,
`HTML`, `Markdown` and `MarkdownV2`; explicit `caption_entities`, including `[]`,
take precedence over parse mode. Offsets and lengths use UTF-16 units.

## Dashboard captions

The Overview traffic log displays captions beneath media previews for incoming
and outgoing messages, including photos and files. Captions retain line breaks
and wrap long text; markup is displayed as text. Activity events expose an
optional `caption` field alongside the payload summary. Older events without
captions keep their existing display.

## Opt-in overflow

Set `caption_overflow: true` to keep the first caption part on the media and send
the remainder as text messages of at most 4096 rendered UTF-16 units each. Without
this flag, a caption that exceeds the limit is rejected. Nothing is silently
truncated. Graphemes and escapes stay intact; markup is balanced per part and
explicit entity offsets are clipped and adjusted. A grapheme larger than 1024
units can move entirely into the first following text message, leaving an empty
media caption; one larger than 4096 units is rejected.

```json
{
  "req_id": "request-id",
  "datatype": "file",
  "data": "Ynl0ZXM=",
  "caption": "Your report, which can exceed the caption limit…",
  "caption_overflow": true
}
```

The same flag works on `/api/push`. It is a boolean and is only enabled for
caption-capable media or albums, not text or stickers. Streaming text remains a
separate option; one-shot responses keep their existing success shape.

All parts stay in the same chat and forum topic. `reply_to_original: true`
continues to apply to the media upload. The first overflow text message replies
to the newly sent media; further text parts do not repeat that reference. Inline
buttons remain attached to the media. Existing keyboard edits and callbacks keep
that media message as their target; overflow is not a retained editable text
response. A push's `sent` count remains the number of chats.

## Albums

Put each caption, its `caption_entities` or its `parse_mode` on the relevant
member. The top-level album `caption` is not applied to members. The top-level
`caption_overflow` flag applies to every member. Exiron uploads the album once,
then sends member overflow in album order, linking the first continuation for
each member to that member's Telegram message ID.

The total caption source, across all members, is bounded to 131072 UTF-16 units
and 524288 UTF-8 bytes. A response can produce at most 32 overflow text messages
in addition to the media upload. Markup counts toward these source bounds.

## SDK examples

Elixir:

```elixir
ExironClient.respond(client, request, "file", bytes,
  caption: report, caption_overflow: true)

items = [
  %ExironClient.MediaItem{datatype: "image", data: photo,
    caption: description, parse_mode: "HTML"},
  %ExironClient.MediaItem{datatype: "video", data: video}
]
ExironClient.reply_album(client, request, items, caption_overflow: true)
ExironClient.push_album_to_chat(client, chat_id, items, caption_overflow: true)
```

Go:

```go
_, err := client.RespondWithOptions(ctx, request.ReqID, exiron.DatatypeFile, data,
    exiron.ResponseOptions{Caption: report, CaptionOverflow: true})

_, err = client.ReplyAlbumWithOptions(ctx, request.ReqID, items,
    exiron.ResponseOptions{CaptionOverflow: true})
_, err = client.PushAlbumWithChatID(ctx, chatID, items,
    exiron.PushOptions{CaptionOverflow: true})
```

Use `MediaItem.ParseMode` for formatted Go album members. The existing
`ReplyAlbum` signature and all response, push and streaming defaults remain
available. Check the negotiated capability before using overflow with older
servers.

## Delivery failures

Parts share the existing send deadline and per-bot coordinator. After a media
upload succeeds, overflow stays on that bot. A 429 retry applies only to the
rejected part. There is no whole-response retry or bot fallback after a partial
success. Cancellation and expiry stop remaining parts and preserve known IDs.

Delivery is not atomic: media may be visible even when following text fails.
Exiron returns `telegram_delivery_timeout` (HTTP 504) after a partial failure and
closes the pending request to prevent re-uploading media on retry. Inspect
[delivery diagnostics](delivery-diagnostics.md) and the chat before sending
anything again. Telegram still validates URLs, permissions, supported entities
and other API restrictions; local preflight does not guarantee Telegram acceptance.
