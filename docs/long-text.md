# Long-text delivery

Protocol 1.3 advertises `long_text`. Existing one-shot responses, pushes, text
updates, stream helpers and edit helpers automatically support long text. No
client-side splitting or new request option is needed. The included Go and
Elixir clients accept streams beyond the former single-message limit.

Exiron bounds a logical text payload to 131072 UTF-16 units and 524288 UTF-8
source bytes (512 KiB), producing at most 32 Telegram messages. Each part fits
4096 rendered UTF-16 units, and literal grapheme clusters and escape sequences
stay intact. A grapheme that cannot fit a Telegram message is rejected. Source
markup counts toward the logical payload bound, even though Telegram's part
limit applies after parsing. Telegram documents the part limit in
[sendMessage](https://core.telegram.org/bots/api#sendmessage).

## Existing APIs

Elixir:

```elixir
ExironClient.reply_text(client, request, long_text)
ExironClient.stream_text(client, request, chunks)
ExironClient.edit_text(client, request, replacement_text)
```

Go:

```go
_, err := client.ReplyText(ctx, request.ReqID, longText)
_, err = client.StreamText(ctx, request.ReqID, chunks)
_, err = client.EditText(ctx, request.ReqID, replacementText)
```

Send a full logical replacement on every low-level update. Exiron reuses known
Telegram IDs by part position, creates additional parts when text grows, and
deletes surplus parts when it shrinks. Deletions depend on Telegram allowing
those messages to be deleted. One-shot and final responses retain the exact
`{"ok":true}` shape. Partial updates preserve `message_id` as the first part's ID
and add `message_ids` when there are multiple parts:

```json
{"ok":true,"final":false,"message_id":901,"message_ids":[901,902]}
```

The Go `OkResponse.MessageIDs` field retains this optional list; the Elixir client
returns it in the response map. A push's `sent` count remains the number of chats,
regardless of the number of text parts. Reply receipts retain IDs, ownership and
keyboard context; they do not retain the full text.

## Formatting and buttons

Plain text is split without changing its content. Explicit `entities` are clipped
to each part and their UTF-16 offsets adjusted, preserving attributes such as link
URLs. HTML tags are closed and reopened at boundaries, and HTML escapes stay
intact. Markdown and MarkdownV2 emphasis, links, inline code and fenced code blocks
are balanced independently in each part. MarkdownV2 ordinary quote lines retain
their quote prefix. Legacy Markdown retains its plain-text fallback for malformed
markup; malformed explicit HTML/MarkdownV2 nesting is rejected before sending.
Telegram still validates supported tags, entity types, escaping and attributes.

All parts inherit the original chat and forum topic. Inline buttons stay on the
**first part**, keeping their source message stable as a stream grows. Omitted
keyboards preserve existing buttons; `[]` removes them. Button callbacks can edit
the full logical reply with `edit_callback_text` / `EditCallbackText`, including
shrinking it. Keyboard-only edits target the first part without changing text.

## Failures and deadlines

Parts are delivered sequentially through the existing per-bot send coordinator.
An explicit 429 retry affects only the rejected part. Fallback to another bot is
allowed before the first successful part; subsequent parts stay on the actual
sending bot. An ordinary send from another request may run between parts, but
this reply's parts retain their relative order.

Delivery is not atomic. If a later part fails, an earlier part may already be
visible. Exiron returns `telegram_delivery_timeout` (HTTP 504) for partial or
uncertain delivery and closes a pending response to prevent whole-reply retries
from duplicating text. An uncertain multipart edit also invalidates its retained
receipt. Inspect the chat before choosing to send a new reply; do not blindly
retry a 504. Failed or incomplete sends may leave visible text or inactive buttons.

Existing request deadlines and the overall send timeout still apply; they are
not extended per part. Large replies under Telegram rate limits may need a larger
`EXIRON_SEND_TIMEOUT_MS` and compatible client HTTP timeouts. Restart loss and the
bounded receipt/callback retention rules remain unchanged. For caption validation and opt-in overflow, see
[media captions](media-captions.md).
