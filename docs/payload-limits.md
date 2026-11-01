# Outgoing payload limits

Both SDKs limit complete outgoing JSON bodies to **51 MiB (53,477,376 bytes)** by
default. This matches the server's default `EXIRON_API_BODY_LENGTH`.

Before encoding a response, push or edit's data, the SDK counts its base64 size
and JSON envelope, including optional metadata. Album helpers first count every
member's base64 size and JSON metadata, array delimiters and commas, then account
for the outer base64 encoding of that album JSON and its request envelope. File
bytes are not base64 encoded until this check passes.

An exact-limit payload is allowed; a payload one byte larger is rejected locally
with `payload_too_large`. The local error has no HTTP status because no request was
sent. Metadata must still be examined/serialized to count JSON escaping; these
checks avoid allocating oversized media encodings, rather than making all request
construction allocation-free. A final body check also covers control requests and
metadata-only operations such as keyboard edits.

## Configure matching limits

Server:

```sh
EXIRON_API_BODY_LENGTH=53477376
```

This existing setting controls the authenticated API parser's maximum JSON body
size. Its default is now a fixed 51 MiB, independent of
`EXIRON_MAX_QUEUE_BYTES_PER_HOOK`. Queue capacity governs queued incoming work;
upload capacity governs HTTP request bodies. Increasing either no longer
implicitly increases the other. Explicit existing body-limit settings retain
their values. The unauthenticated `/api/auth` endpoint retains its smaller
16 KiB parser limit.

Go:

```go
client, err := exiron.New(url,
    exiron.WithToken(token),
    exiron.WithMaxRequestBytes(51 * 1024 * 1024),
)
```

`Config.MaxRequestBytes` is also available. Zero selects the default; negative
values are rejected. Local failures are `*exiron.Error` with
`Reason == "payload_too_large"` and `StatusCode == 0`.

Elixir:

```elixir
client = ExironClient.new(
  base_url: url,
  token: token,
  max_request_bytes: 51 * 1024 * 1024
)
```

The setting must be a positive integer. Local failures return
`{:error, %ExironClient.Error{reason: :payload_too_large, status: nil}}`.

The setting is local to each client, not negotiated from the server. Deployments
with a larger explicit server limit should raise the SDK limit too. Deployments
that previously increased queue capacity to obtain a larger implicit upload limit
must now explicitly configure `EXIRON_API_BODY_LENGTH` as well.

## What the limit means

The limit covers encoded JSON bytes, not raw file bytes. Base64 uses
`4 * ceil(raw_bytes / 3)` bytes; metadata further reduces available space. Albums
have two encoding layers, so the raw sum of members is not a valid estimate of
request size. Each SDK counts its own JSON encoding, including UTF-8 and escaped
metadata.

`MaxResponseBytes` / `:max_response_bytes` remain separate incoming-body and
WebSocket-frame limits. These upload checks do not change server queue budgets,
Telegram file limits or existing logical text/caption limits. Raw bytes already
allocated by callers remain their responsibility. Custom Elixir Req adapters or
streaming body providers that transform/generate bytes after validation are
outside the structured SDK payload check; binary/iodata body overrides are checked.

One-shot responses, files, albums, callbacks, idempotency keys and text streaming
keep their existing APIs. Every stream update is checked independently using its
accumulated text. If an update exceeds the limit, the stream stops with the local
error: it does not resend previous updates or send a finalization request. An
already-accepted partial reply may remain visible until its existing lifecycle
ends; callers can use existing cancellation controls if needed.

The server remains authoritative and rejects oversized HTTP bodies with 413
before passing the parsed request to the Hub. A smaller reverse-proxy or
endpoint-specific limit can still reject a payload accepted by the SDK.
