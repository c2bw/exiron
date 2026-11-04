# Exiron Go SDK

Go SDK for Exiron hooks over WebSocket or HTTP.

The client wraps Exiron's `/api` endpoints, handles bearer authentication, and
encodes or decodes payload data as base64 so callers can work with plain Go
strings or byte slices. Each client receives a generated instance ID used to
renew its polling lease. Only one client may be connected for a hook token
at a time; another instance ID using the same token is rejected until the active
lease expires.

## Installation

Use the SDK directly from the repository's nested Go module. From your own Go
project, replace the placeholder with the full Git commit you want to use:

```sh
go get 'github.com/c2bw/exiron/clients/go@<full-commit-sha>'
go list -m -json github.com/c2bw/exiron/clients/go
```

Commit your application's `go.mod` and `go.sum`. Go records the selected commit
as a module version (typically a pseudo-version). To select the current branch
tip explicitly, use
`go get github.com/c2bw/exiron/clients/go@main`, then review and commit the
resulting dependency changes. Rebuild and restart your worker after updating,
including rebuilding its image when deployed in Docker.

See [compatibility](../../docs/compatibility.md) for SDK versions and server
capability negotiation.

## Complete worker example

The [client reference](../../docs/client-reference.md) compares SDK defaults,
capabilities, diagnostics, instrumentation and recovery in both languages.

Run [`cmd/exiron-worker`](cmd/exiron-worker/main.go) for a console worker combining
one-shot/streamed replies, bounded concurrency, deadlines, quarantine recovery,
runtime reporting and graceful shutdown. See the [run guide](../../docs/managed-worker-examples.md).

## Usage

```go
package main

import (
	"context"
	"log"
	"os"

	exiron "github.com/c2bw/exiron/clients/go"
)

func main() {
	ctx := context.Background()

	client, err := exiron.New(
		"http://localhost:4000",
		exiron.WithToken(os.Getenv("EXIRON_HOOK_TOKEN")),
		exiron.WithClientID("assistant-prod"),
		exiron.WithListen(),
	)
	if err != nil {
		log.Fatal(exiron.SummarizeError(err))
	}


	_, err = client.PushTextWithOptions(ctx, "hello from a named bot", exiron.PushOptions{
		Bot: "helper",
	})
	if err != nil {
		log.Fatal(exiron.SummarizeError(err))
	}

	runner := client.NewRunner(exiron.RunnerOptions{
		Handler: func(ctx context.Context, request exiron.Message) error {
			if request.Datatype == exiron.DatatypeText {
				_, err := client.ReplyTextMessage(ctx, request, "received: "+request.Text())
				return err
			}
			return nil
		},
	})

	if err := runner.Run(ctx); err != nil {
		if exiron.IsHookAlreadyConnected(err) {
			log.Fatal("another client is already polling with this hook token")
		}
		log.Fatal(exiron.SummarizeError(err))
	}
}
```

HTTP response bodies and WebSocket frames are limited to 128 MiB by default.
Use `WithMaxResponseBytes` when an installation needs a different explicit
limit.

For non-text payloads, use `Respond` and `Push` with one of Exiron's supported
datatypes: `DatatypeText`, `DatatypeAudio`, `DatatypeVideo`, `DatatypeImage`,
`DatatypeFile`, or `DatatypeSticker`. Sticker payloads should contain a
Telegram sticker `file_id` or supported sticker URL. Use `ReplySticker`,
`PushSticker`, or `PushStickerWithChatID` when you also want to include the
sticker emoji. Incoming messages expose `StickerEmoji` and a derived
`EmojiList` when the server knows similar emoji for that sticker emoji.
Use `PushOptions{Bot: "configured-bot-name"}` with `PushWithOptions`,
`PushWithChatIDOptions`, `PushTextWithOptions`, `PushTextWithChatIDOptions`,
`PushStickerWithOptions`, or `PushStickerWithChatIDOptions` to select a
configured Telegram bot for the target chat.

The SDK never automatically retries reply or push calls. A transport error can
mean the response was lost after Telegram accepted the send. Likewise, when
`IsTelegramDeliveryTimeout(err)` is true, the server stopped waiting but the
send may still complete. Treat either result as unknown and avoid blind retries
unless duplicate Telegram messages are acceptable.

## Managed polling

`Client.NewRunner` is the recommended way to receive work. The runner uses a
raw JSON websocket by default, reconnects after transport failures, and keeps
the server-side managed client connection authoritative. Set
`exiron.WithTransport(exiron.TransportHTTP)` to use the polling fallback. HTTP
fallback polls every second by default, which keeps the server's three-second
client lease alive. Managed clients target a local disconnect within two
seconds of the previous healthy connection; override this with
`DisconnectTimeout`.

The caller still owns the message handler. The handler should inspect each
message, perform application work, and call `ReplyTextMessage`, `Respond`,
`Push`, or another application API when needed. Handler calls are serial by default, so a
slow handler delays the next poll and can make the server mark the client
disconnected. For long-running HTTP work, enable lease renewal and keep owned work inside
the managed handler. Return only after completing it or explicitly transferring
responsibility. Detached goroutines are not covered by handler drain/deadlines.

The runner acknowledges a delivery only after every handler in its batch
succeeds. Unacknowledged routed requests are delivered again after reconnect,
including with the HTTP fallback. Delivery is therefore at least once; make
handlers idempotent because a lost acknowledgement can repeat completed work.

```go
runner := client.NewRunner(exiron.RunnerOptions{
	PollInterval:      time.Second,
	DisconnectTimeout: 2 * time.Second,
	OnConnect: func(ctx context.Context) {
		log.Print("exiron client connected")
	},
	OnDisconnect: func(ctx context.Context, err error) {
		log.Printf("exiron client disconnected: %v", exiron.SummarizeError(err))
	},
	Handler: func(ctx context.Context, request exiron.Message) error {
		if request.Datatype != exiron.DatatypeText {
			return nil
		}

		_, err := client.ReplyTextMessage(ctx, request, "ack")
		return err
	},
})

if err := runner.Run(ctx); err != nil {
	log.Fatal(exiron.SummarizeError(err))
}
```

Returning an error from the handler stops `Run`. Use that for fatal conditions.
For recoverable per-message failures, log them and return `nil` so the poller
continues:

```go
runner := client.NewRunner(exiron.RunnerOptions{
	Handler: func(ctx context.Context, request exiron.Message) error {
		if err := process(request); err != nil {
			log.Printf("request %s failed: %v", request.ReqID, exiron.SummarizeError(err))
			return nil
		}
		return nil
	},
})
```

`OnConnect` is called after the first successful poll in a connected stretch.
`OnDisconnect` is called when a previously connected runner stops maintaining
the polling lease, with the stop reason. Repeated successful polls do not fire
additional connect callbacks.

`Run` blocks until the context is canceled or an error occurs. Call it directly
from your service's main goroutine, or run it in a goroutine when your program
has other work to do:

```go
go func() {
	if err := runner.Run(ctx); err != nil {
		log.Printf("exiron runner stopped: %v", exiron.SummarizeError(err))
	}
}()
```

The lower-level `Requests` method is still available when you need a custom
polling loop.

`exiron.WithListen()` asks for ambient listen messages without duplicating a
routed command for the same hook. Use `exiron.WithListenAll()` when an audit
style client intentionally wants both the `listen` copy and the routed
`request` for matching messages.

When constructing `exiron.Config` directly, set `ListenMode` to `ListenOff`,
`ListenOn`, or `ListenAll`. Empty or unknown values are treated as `ListenOff`.

Use a stable client ID for long-running hook clients that should reclaim their own
lease after a restart. If another client ID is already polling with the same
hook token, the client follows the server's `retry_after_ms` hint within the
configured retry budget. If the active lease still cannot be reclaimed, polling
returns a 409 error and `IsHookAlreadyConnected` returns true.

## Bounded handler retries

Managed runners default to one handler attempt. To opt in:

```go
runner := client.NewRunner(exiron.RunnerOptions{
    Handler: handleMessage,
    HandlerMaxAttempts: 3,
    HandlerRetryDelay: 250 * time.Millisecond,
    OnHandlerError: func(ctx context.Context, failure *exiron.HandlerFailure) {
        log.Printf("request=%s attempt=%d retry=%t",
            failure.RequestID, failure.Attempt, failure.WillRetry)
    },
})
```

Both transports accept 1..10 attempts; zero selects the default of one.
A zero delay selects 250 ms; negative delays are rejected by `Run`.
Only the failing message is retried locally, and waits observe context cancellation.
Exhaustion stops the runner without acknowledging its batch.
Handler errors are returned as `*HandlerFailure`, which identifies the request and
attempt count and unwraps the cause for `errors.Is`/`errors.As`.
A handler's own transport error is fatal to this runner, rather than triggering a
reconnection. The callback's `Err` may contain application data; log it with care.
Handlers remain responsible for idempotency across retries and reconnects.
See [failure semantics](../../docs/request-tracing.md#client-handler-failure-policy).

## Rich messages and opt-in streaming

Existing one-shot reply, push and transport APIs remain available. New helpers add
progressive text updates, edits, typing actions, topic-aware pushes and albums.
See the [server and client guide](../../docs/rich-messages.md) for examples in both
languages, incoming metadata, capability checks and bounded-lifetime behavior.

Use `ReplyText` for one-shot text, `StreamText` for chunks, or `UpdateText` for
explicit replacement text. `RespondWithOptions` accepts optional `ResponseOptions`
without changing `Respond`. `EditText`, `Typing`, `ChatAction`, `ReplyAlbum`,
`PushAlbum` and `PushAlbumWithChatID` are additive helpers. Incoming albums expose
`Message.MediaItems` with decoded bytes. `PushOptions` adds topic and metadata
fields; existing fields and methods are unchanged.

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

[Bounded handler concurrency](../../docs/client-concurrency.md) optionally runs up to `HandlerConcurrency` messages within a batch in parallel (1–64; default 1). Batches remain acknowledged only after successful handling.

Enable `HandlerOrderByChat: true` with concurrency to preserve handler order within each service/chat/topic while unrelated conversations run in parallel. See [conversation ordering](../../docs/client-concurrency.md#conversation-ordering).

[HTTP lease renewal](../../docs/http-lease-renewal.md) optionally keeps an owned batch alive during long handlers and streams without fetching or acknowledging work (protocol 1.13).

[Optional idempotency keys](../../docs/idempotency.md) replay bounded response/push results without resending Telegram operations; both SDKs use dedicated keyed routes and preserve existing unkeyed and streaming APIs (protocol 1.14).

[Capability discovery](../../docs/capability-discovery.md) negotiates all enabled features once at managed startup using normal bearer API limits, with a single legacy-auth fallback only for a missing/unsupported endpoint. Manual inspection is available through `client.Capabilities(ctx)`.

[Client reconnection](../../docs/client-reconnection.md) covers default retry jitter, safe HTTP 429 retries, server retry hints, and reconnect budgets in both SDKs.

[Outgoing payload limits](../../docs/payload-limits.md) reject oversized uploads before encoding media. Configure `MaxRequestBytes` to match the server upload limit (51 MiB by default).

[Outgoing send byte budgets](../../docs/send-byte-budget.md) share the existing capacity error handling and add per-hook byte usage, limit and rejection counts to status. One-shot and streamed sends remain available.

[Graceful client shutdown](../../docs/client-shutdown.md) optionally finishes the current batch and retires its session without another poll. Enable `RunnerOptions.GracefulShutdown` before starting; existing cancellation and reply APIs remain available.

[Managed client runtime status](../../docs/client-runtime-status.md) exposes local connection phases, handler counts, batch age, reconnect timing and drain progress without consuming work or exposing message content.

[Opt-in handler quarantine](../../docs/handler-quarantine.md) isolates exhausted handler failures in an application-supplied bounded store, with explicit recovery callbacks and unchanged default stop-on-failure behavior.

[Optional handler deadlines](../../docs/handler-deadlines.md) bound managed processing and retries cooperatively, expose overdue slots, and leave unfinished batches unacknowledged. Disabled by default.

[Optional runtime reporting](../../docs/client-runtime-reporting.md) sends bounded client observations to the monitor, with session fencing and explicit freshness. Reporting is enabled automatically when capability discovery advertises support and does not renew leases or acknowledge work. Opt out with `DisableRuntimeReporting: true`; `RuntimeReporting: false` uses automatic negotiation.

[Safe diagnostics](../../docs/client-diagnostics.md) covers redacted configuration formatting and safe error summaries.

[Optional response feedback](../../docs/response-feedback.md): `WithFeedback`
appends a rating row without removing existing buttons; `ParseFeedback` identifies
the rated request and clicker. Reply modes and transports remain explicit choices.

## Sticker identity

Protocol 1.20 advertises `sticker_file_unique_id`. Incoming sticker messages
carry optional `file_unique_id` (Go: `FileUniqueID`) in both request and listen
deliveries over HTTP and WebSocket. Use it to identify and deduplicate the same
file across deliveries. `sticker_id` (Go: `StickerID`) remains Telegram's
sendable `file_id`; a `file_unique_id` cannot be used to download or send a file.
Older servers and payloads without this field decode with a nil value.
