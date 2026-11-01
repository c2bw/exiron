# Managed worker reference examples

Two runnable examples combine the SDK's existing lifecycle controls:

- [Go command](../clients/go/cmd/exiron-worker/main.go), run from `clients/go`.
- [Elixir module](../clients/elixir/examples/managed_worker.exs), loaded from `clients/elixir`.

Both support **one-shot or streamed text** and HTTP or WebSocket transport. They
are reference workers for adaptation, not deployment managers. They add no SDK
runtime behavior and send nothing merely by building/loading the example.
Use a dedicated test hook when learning the recovery commands. Only one consumer
can own a hook at a time; run these examples sequentially for the same token.

## Prerequisites and settings

Use the current server with protocol 1.17 capabilities. These examples explicitly
enable graceful retirement, runtime reporting, cooperative cancellation and handler
failure reporting. HTTP graceful mode also enables lease renewal. Startup checks
support before consuming work. SDK defaults elsewhere remain unchanged.

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `EXIRON_HOOK_TOKEN` | Required | Hook bearer token. It is never a command-line argument or printed by the example. |
| `EXIRON_BASE_URL` | `http://localhost:4000` | Server URL. |
| `EXIRON_TRANSPORT` | `websocket` | `websocket` or `http`. |
| `EXIRON_REPLY_MODE` | `one-shot` | `one-shot` or `stream`. |
| `EXIRON_OBSERVE_REQUESTS` | `false` | `true` enables sanitized API completion logs; unset or `false` disables them. |
| `EXIRON_CLIENT_ID` | SDK-generated | Optional instance ID; never run two instances sharing an ID. |

Settings are read at example startup. Restarting the managed poller reuses the
same client, reply mode and quarantine; it does not reload environment variables.
Restart the whole example to change these settings, after resolving retained work.

The sample handles routed **text requests** and echoes at most 1,024 input
codepoints in plain text. Other datatypes are quarantined by this sample handler;
the SDK's rich message, media, callback and push APIs remain available. Streaming
uses a bounded inline/joined producer and the same final answer as one-shot mode.
There is no detached application job acknowledged before its work finishes.

## Go: run and control

From the repository root:

```sh
cd clients/go
export EXIRON_HOOK_TOKEN='your-test-hook-token'
EXIRON_TRANSPORT=http EXIRON_REPLY_MODE=stream go run ./cmd/exiron-worker
```

Use `go run ./cmd/exiron-worker -h` to view setup without connecting or supplying
a token. Leave transport/reply variables unset for WebSocket and one-shot replies.

The stdin console supports:

| Command | Behavior |
| --- | --- |
| `status` | Local runtime snapshot, including handler/deadline/quarantine gauges. |
| `quarantine` | Retained metadata and entry IDs; no message contents or raw errors. |
| `drain` | Finish the current batch and retire, then keep the console/store alive. |
| `restart` | Start a new managed run only after the old run actually ends, reusing the store. |
| `recover ID REPLACEMENT_TEXT` | Invoke an explicit callback sending the chosen final plain-text reply. Never replay the original handler. |
| `resolve ID` | Explicitly remove an entry already handled externally; sends nothing. |
| `quit` | Drain and exit. Remaining in-memory entries are lost. |

Ctrl+C and SIGTERM attempt graceful drain before exit. The run context is not
cancelled before that drain attempt. The example joins its managed run before
restarting or exiting, and its stream producer observes cancellation and is joined
when the handler ends. General Go handlers/transports that ignore cancellation can
still delay shutdown; see [client shutdown](client-shutdown.md).

EOF disables the console while a healthy worker continues running, so the command
can also run with closed stdin. If the managed loop fails with no console, it exits
with an error. With the console open, it leaves status/quarantine available for an
operator decision. It never automatically restarts a failed run or recovers entries.
Metadata notifications are best effort; `quarantine` lists all retained entries.
A recovery request uses its own ten-second context, so it still works after drain
has cancelled the managed run's context. A signal arriving during such a console
request is handled when that request returns.

## Elixir: load and control

From the repository root:

```sh
cd clients/elixir
export EXIRON_HOOK_TOKEN='your-test-hook-token'
EXIRON_TRANSPORT=http EXIRON_REPLY_MODE=stream iex -S mix run examples/managed_worker.exs
```

Loading the file defines `ExironExampleWorker` without starting a client. In IEx:

```elixir
alias ExironExampleWorker, as: Worker
{:ok, _supervisor} = Worker.start()

Worker.status()
Worker.quarantine()

:ok = Worker.drain() # Keep the store and example supervisor alive.
Worker.status()     # Worker stopped; quarantine still available.

# Supply an application-specific callback. Return :ok only when resolved.
Worker.recover(entry_id, fn original ->
  MyRecovery.handle(original)
end)

# Or deliberately choose a new final reply after reviewing the earlier outcome.
Worker.recover_text(entry_id, "Operator-reviewed replacement reply")
# Explicitly acknowledge resolution performed elsewhere; no send:
Worker.resolve(entry_id)

{:ok, _poller} = Worker.restart()
:ok = Worker.shutdown() # Drain, then stop the entire example/store.
```

Replace `entry_id` with an ID returned by `Worker.quarantine()`; do not invoke
all three recovery alternatives for the same entry. The module also accepts
`start(client: existing_client, transport: :http, reply_mode: :stream,
on_quarantined: callback)` for integration with application-owned configuration.

A `:one_for_one` supervisor owns the quarantine, state agent and temporary poller.
Fatal poller failures leave the store alive for recovery. `restart/0` checks the
old process's local status and never intentionally overlaps a running poller.
If supervision is still completing a stop, retry the restart after it settles.
The inline stream producer uses `HandlerDeadline.wait/1`; no extra application
producer process survives a cancelled stream.

`recover/2` runs the supplied callback in its caller, outside managed handler
concurrency and budgets. Coordinate deadlines for custom recovery work yourself.
`recover_text/2` uses the client's ten-second receive timeout and independent
request context; it does not inherit a dead poller token. Errors retain entries.

**Call `drain/0` or `shutdown/0` before leaving IEx.** This interactive module does
not install OS signal handlers or application shutdown callbacks. For a production
OTP application, move the children into your application's supervision tree and
call `ExironClient.Poller.drain/2` from a shutdown coordinator, such as
`Application.prep_stop/1`, before the supervisor terminates its children. An
external VM kill is not a graceful drain.

## Safe failure/recovery walkthrough

With a dedicated hook configured to route `/ai`:

1. Send `/ai /worker-fail` through that hook. The example recognizes the final
   `/worker-fail` word and fails **before any reply is sent**.
2. Inspect `quarantine` (Go) or `Worker.quarantine()` (Elixir). The entry is retained
   while unrelated work can continue.
3. Drain the managed worker. The store remains alive in the console/example
   supervisor. Verify local status rather than assuming a last monitor sample is
   current.
4. Use **one** explicit recovery action: send an operator-chosen replacement,
   invoke your own application recovery callback, or resolve an externally handled
   entry without sending anything. Failure leaves the entry retained.
5. Restart with the same store, or exit/shut down after resolving the retained work.

The controls are intentionally configured as follows:

| Control | Example choice and reason |
| --- | --- |
| Concurrency | Two occupied message slots, ordered per conversation. |
| Handler budget | 30 seconds across processing/retries; cooperative expiry keeps an unfinished slot owned. |
| Handler attempts | **One**. Sending a reply/partial stream is a side effect, so the example never automatically replays the handler. |
| Quarantine | Explicit store: 100 entries / 8 MiB encoded messages, retained across managed-run drain/restart. |
| Cancellation | Opt in to server cancellation/expiry signals and use the context/token during work. |
| HTTP ownership | Graceful mode enables existing lease renewal while handlers run. |
| Reporting | Opt-in runtime and handler-failure reports; callbacks/logs avoid message bodies, tokens and raw error details. |
| Shutdown | Finish/retire the current batch before cancellation; preserve recovery state until deliberate process/supervisor exit. |

A real send or partial stream can fail **after Telegram accepted some work**.
The artificial failure marker is safe precisely because it happens before sending;
do not generalize that to network errors. Inspect [delivery diagnostics](delivery-diagnostics.md)
and application side effects before recovery. `recover_text` may fail if the
original request expired, completed, was cancelled, or is still sending. It never
creates a replacement request or silently switches to a push.

Quarantine is not durable. Process/VM/store restart loses entries. `resolve` is a
deliberate acknowledgement, not a retry. Lost acknowledgements can replay already
processed deliveries; these examples add no exactly-once or automatic compensation
promise. Add local handler retries only when your application operations are safe
to repeat. For more detail, see [quarantine](handler-quarantine.md),
[deadlines](handler-deadlines.md), and [runtime reporting](client-runtime-reporting.md).
Reports stop with the managed run; after draining, the monitor can retain an old
stale observation while local recovery changes the store. A restarted worker will
report the latest store counts under its new session.

## Chat feature examples

Both workers accept `EXIRON_FEEDBACK=true|false` (default `false`). Elixir also
accepts `feedback: true` in `ExironExampleWorker.start/1`. Opt-in startup checks
`inline_keyboards` and `callback_queries` before consuming work. Invalid flags
fail locally. Existing `EXIRON_REPLY_MODE=one-shot|stream` and transport choices
remain unchanged. In stream mode the example shows rating buttons during updates.

Enabled workers append a rating row to their normal answers and recognize rating
callbacks before rejecting unsupported message types. They acknowledge a vote
without another rating keyboard. This demonstrates delivery and parsing, not a
vote database; add your own storage/deduplication policy before retaining votes.
Ordinary application callbacks still require application-specific handling.

Inherited follow-ups are labelled “Follow-up received” using their optional
origin request link. The examples do not fabricate conversation history or retain
message bodies. Explicit commands keep their ordinary behavior. Operator-chosen
quarantine recovery replies remain plain text without automatic rating buttons.
