# ExironClient

Elixir SDK for Exiron hooks over WebSocket or HTTP.

The client wraps Exiron's `/api` endpoints, handles bearer authentication, and
encodes or decodes payload data as base64 so callers can work with plain Elixir
binaries. Each client receives a generated instance ID used to renew its polling
lease. Only one client may be connected for a hook token at a time; another
instance ID using the same token is rejected until the active lease expires.

## Installation

Install the SDK from this Git repository. Add a Git dependency to your
application's `mix.exs`, replacing the ref with the full commit you have chosen:

```elixir
def deps do
  [
    {:exiron_client,
     git: "https://github.com/c2bw/exiron.git",
     subdir: "clients/elixir",
     ref: "<full-commit-sha>"}
  ]
end
```

Run `mix deps.get` and commit your application's `mix.lock`. To follow `main`
instead, replace `ref: ...` with `branch: "main"`; the lockfile still pins the
resolved commit until you explicitly run `mix deps.update exiron_client`.
Rebuild and restart your application after updating the dependency, including
rebuilding its image when deployed in Docker.

For local development, use `{:exiron_client, path: "/path/to/exiron/clients/elixir"}`.
See [compatibility](../../docs/compatibility.md) for SDK versions and server
capability negotiation.

## Complete worker example

The [client reference](../../docs/client-reference.md) compares SDK defaults,
capabilities, diagnostics, instrumentation and recovery in both languages.

Load [`examples/managed_worker.exs`](examples/managed_worker.exs) for an IEx worker
combining one-shot/streamed replies, bounded concurrency, deadlines, quarantine
recovery, runtime reporting and graceful shutdown. See the [run guide](../../docs/managed-worker-examples.md).

## Usage

```elixir
client =
  ExironClient.new(
    base_url: "http://localhost:4000",
    token: System.fetch_env!("EXIRON_HOOK_TOKEN"),
    client_id: "assistant-prod",
    listen: true
  )

{:ok, poller} =
  ExironClient.Poller.start_link(
    client: client,
    handler: fn request ->
      ExironClient.reply_text(client, request, "received: #{request.data}")
    end
  )

{:ok, _result} = ExironClient.push_text(client, "hello from an Elixir client")
{:ok, _result} = ExironClient.push_text(client, -1_001_234_567_890, "hello to one chat")
{:ok, _result} = ExironClient.push_text(client, "hello from a named bot", bot: "helper")
```

For non-text payloads, use `respond/4`, broadcast with `push/3`, or target a
specific Telegram chat with `push/4`. Supported datatypes are `"text"`,
`"audio"`, `"video"`, `"image"`, `"file"`, and `"sticker"`. Sticker payloads
should contain a Telegram sticker `file_id` or supported sticker URL. Use
`reply_sticker/4`, `push_sticker/3`, or `push_sticker/4` when you also want to
include the sticker emoji. Incoming messages expose `sticker_emoji` and a
derived `emoji_list` when the server knows similar emoji for that sticker emoji.
Pass `bot: "configured-bot-name"` to `push/4`, `push/5`, `push_text/3`,
`push_text/4`, `push_sticker/4`, or `push_sticker/5` to select a configured
Telegram bot for the target chat.

The SDK never automatically retries `reply_*`, `respond`, or `push` calls. A
transport error can mean the response was lost after Telegram accepted the
send. Likewise, an `%ExironClient.Error{reason: :telegram_delivery_timeout}`
means the server stopped waiting but the send may still complete. Treat either
result as unknown and avoid blind retries unless duplicate messages are
acceptable. Use `ExironClient.Error.telegram_delivery_timeout?/1` to identify
the explicit timeout case.

HTTP response bodies and WebSocket messages are limited to 128 MiB by default.
Set `max_response_bytes: byte_limit` in `ExironClient.new/1` when an
installation needs a different explicit limit. Oversized responses return or
stop polling with an `%ExironClient.Error{reason: :invalid_response}`.

## HTTP connection options

With Req 0.7 and later, use nested Finch options:

```elixir
req_options: [
  receive_timeout: 10_000,
  finch: [pool_timeout: 5000, conn_opts: [transport_opts: [timeout: 5000]]]
]
```

For an existing named pool, use `finch: [name: MyFinch, pool_timeout: 5000]`.
The SDK also accepts existing top-level `pool_timeout`, named `finch`, and
`connect_options` settings and converts them for Req 0.7. Applications using
Req 0.5 or 0.6 can keep their existing options. Handler deadlines continue to
cap pool and receive timeouts without changing connection pool settings.

## Managed polling

The managed `ExironClient.Poller` uses a raw JSON websocket by default,
reconnects after transport failures, and keeps the server-side managed client
connection authoritative. Set `transport: :http` to use the polling fallback.
For `wss://` connections, certificate-chain and hostname verification are
enabled by default using the Erlang/OTP trusted CA store. This is a behavior
change for clients that previously relied on the old insecure default: an
untrusted or hostname-mismatched certificate now causes the connection to
fail. Use `websocket_tls_options: [cacerts: ...]` or another supported `:ssl`
option when connecting to a private CA or when custom TLS configuration is
required.

For local development or tests only, an explicit opt-out is available:

```elixir
client =
  ExironClient.new(
    base_url: "https://localhost:4000",
    allow_insecure_websocket_tls: true
  )
```

Do not enable `allow_insecure_websocket_tls` in production: it disables
certificate and hostname verification and can expose hook tokens and messages
to an active network attacker. The option has no effect on plain `ws://`
connections, which retain their existing behavior.
HTTP fallback polls every second by default, which keeps the server's
three-second client lease alive. Managed clients target a local disconnect
within two seconds of the previous healthy connection; override this with
`:disconnect_timeout_ms`.

The caller still owns the message handler. The handler should inspect each
message, perform application work, and call `reply_text/3`, `respond/4`,
`push/3`, or another application API when needed. Handler calls are serial by default. The
websocket transport pauses inbound reads while a batch is being handled so work
cannot accumulate in an unbounded client mailbox; with the HTTP fallback, a
slow handler delays the next poll and can make the server mark the client
disconnected. For long-running HTTP work, enable lease renewal and keep owned work inside
the managed handler. Return only after completing it or explicitly transferring
responsibility. Application-owned detached processes are not covered by managed
drain/deadlines.

The WebSocket client models transport progress explicitly as `:disconnected`,
`:connecting`, `:connected`, `:paused`, or `:closing`. Frame buffering and
fragment reassembly are isolated from transport I/O, and a single delivery
worker provides backpressure while a batch is handled. The transport is kept
behind a small `ExironClient.SocketTransportBehaviour`, so a different socket
implementation can be introduced without changing the poller API.

The poller acknowledges a delivery only after every handler in its batch
succeeds. Unacknowledged routed requests are delivered again after reconnect,
including with the HTTP fallback. Delivery is therefore at least once; make
handlers idempotent because a lost acknowledgement can repeat completed work.

```elixir
{:ok, poller} =
  ExironClient.Poller.start_link(
    client: client,
    interval_ms: 1_000,
    disconnect_timeout_ms: 2_000,
    on_connect: fn ->
      Logger.info("exiron client connected")
    end,
    on_disconnect: fn reason ->
      Logger.warning("exiron client disconnected: #{inspect(reason)}")
    end,
    handler: fn request ->
      ExironClient.reply_text(client, request, "ack")
    end
  )
```

Returning `{:error, reason}` from the handler stops the poller. Use that for
fatal conditions. For recoverable per-message failures, log them and return
`:ok` so polling continues:

```elixir
handler = fn request ->
  case process(request) do
    :ok ->
      :ok

    {:error, reason} ->
      Logger.warning("request #{request.req_id} failed: #{inspect(reason)}")
      :ok
  end
end
```

`:on_connect` is called after the server confirms a WebSocket connection, or
after the first successful HTTP poll in a connected stretch. A successful
WebSocket upgrade alone does not trigger it. `:on_disconnect` is called when a
previously connected poller stops maintaining the polling lease, with the stop
reason. Repeated confirmations or successful polls do not fire additional
connect callbacks.

In an OTP application, run the poller under a supervisor so normal process
restarts are handled by OTP:

```elixir
children = [
  {ExironClient.Poller,
   client: client,
   interval_ms: 1_000,
   handler: handler}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

The lower-level `requests/1` function is still available when you need a custom
polling loop.

`listen: true` asks for ambient listen messages without duplicating a routed
command for the same hook. Use `listen: :all` when an audit style client
intentionally wants both the `listen` copy and the routed `request` for
matching messages.

Use a stable `:client_id` for long-running hook clients that should reclaim their
own lease after a restart. If another client ID is already polling with the same
hook token, the client follows the server's `retry_after_ms` hint within the
configured retry budget. If the active lease still cannot be reclaimed, polling
returns `{:error, %ExironClient.Error{status: 409}}` and
`ExironClient.Error.hook_already_connected?/1` returns true.

## Bounded handler retries

Managed pollers default to one handler attempt. To opt in:

```elixir
{ExironClient.Poller,
 client: client,
 handler: &MyHandler.handle/1,
 handler_max_attempts: 3,
 handler_retry_delay_ms: 250,
 on_handler_error: fn failure ->
   IO.inspect(Map.take(failure, [:request_id, :attempt, :max_attempts, :will_retry?]))
 end}
```

Both transports accept 1..10 attempts and a positive retry delay. Only the failing
message is retried locally. Exhaustion stops the poller without acknowledging its
batch. The failure callback also receives `reason`, which may contain application
data; avoid logging it without redaction. Handler exceptions follow this same
bounded policy. Handlers must tolerate repeated side effects and replay after
connection loss or restart. See [failure semantics](../../docs/request-tracing.md#client-handler-failure-policy).

## Rich messages and opt-in streaming

Existing one-shot reply, push and transport APIs remain available. New helpers add
progressive text updates, edits, typing actions, topic-aware pushes and albums.
See the [server and client guide](../../docs/rich-messages.md) for examples in both
languages, incoming metadata, capability checks and bounded-lifetime behavior.

Use `reply_text/3` for a one-shot response, `stream_text/4` for UTF-8 chunks,
or `update_text/4` for explicit replacement text. `edit_text/4` edits retained
completed replies. `typing/2` and `chat_action/3` leave the request pending.
Album helpers accept `ExironClient.MediaItem` values with decoded `data`; incoming
albums expose `Message.media_items`. Generic `respond/5` and push options now accept
caption, entity, filename, MIME, topic and parse-mode metadata.

[Inline buttons and callbacks](../../docs/inline-buttons.md) adds reply/push keyboards, direct callback routing, and helpers for editing clicked messages and their buttons. Existing one-shot and optional streaming APIs remain available.

[Long-text delivery](../../docs/long-text.md) automatically splits one-shot replies, pushes and streamed text while preserving topic placement and later editing. Requires protocol 1.3.

[Request cancellation](../../docs/request-cancellation.md) stops queued work and remaining sends, reports delivery certainty, and rejects further updates. Both clients provide an explicit cancellation helper (protocol 1.4).

[Delivery diagnostics](../../docs/delivery-diagnostics.md) adds per-part outcomes, safe Telegram errors and explicit retry guidance to HTTP errors, the monitor and both clients (protocol 1.5).

[Telegram reply context](../../docs/reply-context.md) optionally attaches the first response message to its original Telegram message while preserving forum topics and stream behavior (protocol 1.6).

[Media captions](../../docs/media-captions.md) validates captions before uploading and offers opt-in overflow into following text messages, including albums (protocol 1.7).

[Send fairness](../../docs/send-fairness.md) limits active deliveries per hook, exposes capacity and rejections, and adds explicit overload retry hints and SDK classifiers (protocol 1.8).

[Client visibility](../../docs/client-visibility.md) shows observed contact, session state and assigned work without treating an expired HTTP polling lease as proof of a disconnect (protocol 1.9). Both SDKs also automatically report their package version for display beside each hook (protocol 1.19), independently of runtime reporting.

[Cooperative handler cancellation](../../docs/cooperative-cancellation.md) lets managed clients opt in to server cancellation and expiry signals while keeping existing handler and reply APIs (protocol 1.10).

[Graceful drain](../../docs/graceful-drain.md) pauses new intake for planned restarts while pending replies and streaming continue. New pushes and completed-reply edits receive a distinct `draining` rejection (protocol 1.11).

[Handler failure reporting](../../docs/handler-reporting.md) optionally shows client retry attempts, exhaustion and recovery in request activity using bounded metadata (protocol 1.12). Application errors remain local.

[Bounded handler concurrency](../../docs/client-concurrency.md) optionally runs up to `:handler_concurrency` messages within a batch in parallel (1–64; default 1). Batches remain acknowledged only after successful handling.

Enable `handler_order_by_chat: true` with concurrency to preserve handler order within each service/chat/topic while unrelated conversations run in parallel. See [conversation ordering](../../docs/client-concurrency.md#conversation-ordering).

[HTTP lease renewal](../../docs/http-lease-renewal.md) optionally keeps an owned batch alive during long handlers and streams without fetching or acknowledging work (protocol 1.13).

[Optional idempotency keys](../../docs/idempotency.md) replay bounded response/push results without resending Telegram operations; both SDKs use dedicated keyed routes and preserve existing unkeyed and streaming APIs (protocol 1.14).

[Capability discovery](../../docs/capability-discovery.md) negotiates all enabled features once at managed startup using normal bearer API limits, with a single legacy-auth fallback only for a missing/unsupported endpoint. Manual inspection is available through `ExironClient.capabilities(client)`.

[Client reconnection](../../docs/client-reconnection.md) covers default retry jitter, safe HTTP 429 retries, server retry hints, and reconnect budgets in both SDKs.

[Outgoing payload limits](../../docs/payload-limits.md) reject oversized uploads before encoding media. Configure `:max_request_bytes` to match the server upload limit (51 MiB by default).

[Outgoing send byte budgets](../../docs/send-byte-budget.md) share the existing capacity error handling and add per-hook byte usage, limit and rejection counts to status. One-shot and streamed sends remain available.

[Graceful client shutdown](../../docs/client-shutdown.md) optionally finishes the current batch and retires its session without another poll. Enable `:graceful_shutdown` before starting; existing cancellation and reply APIs remain available.

[Managed client runtime status](../../docs/client-runtime-status.md) exposes local connection phases, handler counts, batch age, reconnect timing and drain progress without consuming work or exposing message content.

[Opt-in handler quarantine](../../docs/handler-quarantine.md) isolates exhausted handler failures in an application-supplied bounded store, with explicit recovery callbacks and unchanged default stop-on-failure behavior.

[Optional handler deadlines](../../docs/handler-deadlines.md) bound managed processing and retries cooperatively, expose overdue slots, and leave unfinished batches unacknowledged. Disabled by default.

[Optional runtime reporting](../../docs/client-runtime-reporting.md) sends bounded client observations to the monitor, with session fencing and explicit freshness. Reporting is enabled automatically when capability discovery advertises support and does not renew leases or acknowledge work. Opt out with `runtime_reporting: false`.

## Internal lifecycle responsibilities

`DeliveryWorker` shares batch-worker startup, job references, completion and
cleanup between graceful HTTP and WebSocket polling. `SocketDelivery` adds the
socket heartbeat timestamp. `ClientDrain` owns drain admission, the original
deadline and a single completion reply. These modules share the existing batch
worker; they have no process of their own.

Transport adapters retain acknowledgement timing, retirement requests and
connection behavior: HTTP keeps lease renewal and polling; WebSocket keeps
read pausing, pings and asynchronous retirement. The ordinary HTTP poller still
executes handlers synchronously when graceful shutdown is disabled. Public
options, callbacks, one-shot replies and streaming APIs are unchanged.

For routine logs, use `ExironClient.Error.summary(error)` rather than inspecting
raw errors. See [safe diagnostics](../../docs/client-diagnostics.md); original
message/body fields remain available for explicit inspection.

[Optional response feedback](../../docs/response-feedback.md):
`ExironClient.Feedback.keyboard/1` appends a rating row without removing existing
buttons; `from_message/1` identifies the rated request and clicker. Reply modes and
transports remain explicit choices.

### WebSocket lifecycle callbacks

The managed poller resets reconnect backoff only when Exiron confirms the session
with its `connected` frame. Opening a socket alone does not reset the retry budget.
A connected session invokes `on_disconnect` once when it disconnects or terminates,
including supervisor shutdown. A server-accepted reconnect starts a new callback
cycle; failed handshakes do not produce disconnect callbacks for unaccepted sessions.
Untrappable process kills cannot run termination callbacks.

## Sticker identity

Protocol 1.20 advertises `sticker_file_unique_id`. Incoming sticker messages
carry optional `file_unique_id` (Go: `FileUniqueID`) in both request and listen
deliveries over HTTP and WebSocket. Use it to identify and deduplicate the same
file across deliveries. `sticker_id` (Go: `StickerID`) remains Telegram's
sendable `file_id`; a `file_unique_id` cannot be used to download or send a file.
Older servers and payloads without this field decode with a nil value.
