# Opt-in handler quarantine

Both managed SDKs can retain a message whose application handler exhausts its
configured attempts, then continue the rest of the batch. The default remains
**stop on failure**. HTTP and WebSocket, serial/concurrent handlers, conversation
ordering, one-shot replies and streaming remain available. This is a local SDK
feature and requires no new server capability.

Quarantine is an explicit transfer of responsibility to a bounded, in-memory
store supplied by the application. It is not a successful application response,
a Telegram delivery receipt, persistence, or an automatic retry queue.

## Go

Create a store once per logical hook/application consumer and reuse it when
replacing its runner:

```go
quarantine, err := exiron.NewQuarantine(exiron.QuarantineOptions{
    MaxMessages: 100,
    MaxBytes:    8 * 1024 * 1024,
})
if err != nil { return err }

runner := client.NewRunner(exiron.RunnerOptions{
    Handler:              handler,
    HandlerMaxAttempts:   3,
    HandlerFailurePolicy: exiron.HandlerFailureQuarantine,
    Quarantine:           quarantine,
    OnQuarantined: func(ctx context.Context, entry exiron.QuarantineEntry) {
        // Metadata only; notify your application that explicit recovery is needed.
        log.Printf("quarantined entry=%d attempts=%d", entry.ID, entry.Attempts)
    },
})
err = runner.Run(ctx)
```

Zero limits select 100 messages and 8 MiB. Negative limits are rejected. The
quarantine policy requires a store created with `NewQuarantine`; supplying a
store alone does not enable the policy. `HandlerFailureStop` explicitly selects
the default behavior. Invalid policies/stores fail before fetching work.

`quarantine.Entries()` returns metadata sorted by local ID: `ID`, `RequestID`,
`Attempts`, encoded `Bytes`, `CreatedAt` and `Recovering`. It excludes message
contents and raw handler errors. To access the retained message, supply an
explicit recovery callback:

```go
entries := quarantine.Entries()
if len(entries) > 0 {
    err := quarantine.Recover(recoveryCtx, entries[0].ID,
        func(ctx context.Context, original exiron.Message) error {
            // Decide whether replying, compensating, or discarding is appropriate.
            // Check request expiry and any side effects from earlier attempts.
            return recoverMessage(ctx, original)
        })
    if err != nil { return err } // The entry remains if callback/context failed.
}
```

Only a nil callback result with a live context removes the entry. Concurrent
recovery of one entry returns `ErrQuarantineBusy`; missing IDs return
`ErrQuarantineNotFound`. Recovery runs synchronously in the caller, outside store
locks. Panics propagate while releasing the claim and retaining the entry. A
callback that ignores its context can delay `Recover`; Go cannot kill it.

The store serializes the original message before the first handler attempt, so
mutations to nested message slices or pointers cannot alter later recovery.
Each recovery decodes a fresh copy, including raw data, media items and reply
metadata. A failed recovery cannot mutate the retained copy. Raw error objects
are never stored. Notification callbacks run in the occupied managed handler slot;
return promptly and coordinate drain/recovery from outside that slot. `Stats()` and normal store formatting expose counts, not payloads.

## Elixir

Start the store separately from its poller, for example as a child in the same
`:one_for_one` supervisor, and pass its PID to each replacement poller:

```elixir
{:ok, store} = Supervisor.start_child(supervisor, {
  ExironClient.Quarantine, max_messages: 100, max_bytes: 8 * 1024 * 1024
})

{:ok, poller} = Supervisor.start_child(supervisor, {
  ExironClient.Poller,
  client: client,
  transport: :http, # or :websocket
  handler: &MyHandler.handle/1,
  handler_max_attempts: 3,
  handler_failure_policy: :quarantine,
  quarantine: store,
  on_quarantined: fn entry -> MyRecovery.notify(entry.id) end
})
```

Limits default to 100 messages and 8 MiB and must be positive integers. The
policy is `:stop` by default; `:quarantine` requires a running
`ExironClient.Quarantine` PID. Invalid local options fail before server discovery
or fetching work. The store performs no network calls or application callbacks
inside its GenServer; payloads are retained as encoded binaries.

**Quarantine-enabled poller child specs use `restart: :temporary`.** Fatal failures,
including a full/unavailable quarantine, leave the poller stopped for explicit
application recovery instead of repeatedly restarting against the same full
store. Internal recoverable transport reconnects still run normally. The existing
disconnect callback receives the stop reason; monitor the poller for its exit.
Free capacity and start a replacement poller with the same live store when ready.
Applications that supply their own restart policy take responsibility for avoiding
restart loops. Default-mode pollers retain their existing restart policy.

```elixir
{:ok, entries} = ExironClient.Quarantine.entries(store)

case entries do
  [entry | _] ->
    ExironClient.Quarantine.recover(store, entry.id, fn original ->
      MyRecovery.handle(original) # Return :ok only when responsibility is resolved.
    end)
  [] -> :ok
end
```

Metadata contains `id`, `request_id`, `attempts`, encoded `bytes`, `created_at`
(Unix milliseconds) and `recovering?`. Only `:ok` removes an entry; `{:error, reason}`,
exceptions, exits caught by the caller, or another return value retain it.
Another return value yields `{:error, :invalid_recovery_result}`. The callback
runs in the calling process; it is not a managed handler task. Concurrent recovery
returns `{:error, :quarantine_busy}`. Missing entries return
`{:error, :quarantine_not_found}`. The store monitors recovery callers and releases
their claims if they die. Recovery operations add no automatic timeouts around
application callbacks; coordinate their deadlines in the application.

`Quarantine.stats(store)` reads count/byte/claim metadata without a mailbox round
trip. Stopped stores return `{:error, :quarantine_unavailable}`. Store OTP status
output excludes retained messages and request identifiers.

## Capacity, acknowledgements and failure behavior

- Local handler retries and existing failure callbacks/reports happen first.
  Only exhausted application failures are eligible for quarantine. Confirmed
  cancellation/expiry follows existing handling; loss of an HTTP lease is never
  turned into a quarantined success. Optional [local handler deadlines](handler-deadlines.md)
  stop overdue work without automatically quarantining it.
- A retained message releases its managed handler slot. Remaining messages still
  execute normally. The batch is acknowledged only after all its work succeeds,
  is skipped through existing cancellation handling, or is explicitly retained.
  One successful quarantine never acknowledges an unfinished sibling.
- Both count and encoded-message byte limits are enforced atomically across
  concurrent producers. Recovering entries keep their capacity reservation.
  Limits measure retained encoded messages; metadata, runtime/encoding overhead,
  in-flight batches and copies held by recovery callbacks use additional memory.
- No existing entry is evicted, expired, silently dropped, or automatically replayed
  to make room. Full or unavailable storage stops batch processing and leaves it
  unacknowledged. Active concurrent siblings finish under existing batch rules;
  queued dispatch stops. Earlier quarantine entries remain in the separate store.
  Go returns a handler failure wrapping `ErrQuarantineFull` for count/byte capacity;
  Elixir reports `{:quarantine_failed, :quarantine_full, original_reason}` or
  `{:quarantine_failed, :quarantine_unavailable, original_reason}` locally.
- A full store does not prevent healthy messages from succeeding. After freeing
  capacity, explicitly start/restart a consumer as appropriate. Quarantine recovery
  itself never fetches another batch or sends an acknowledgement.

The original routed request remains subject to its server deadline after its
batch is acknowledged. Quarantine does not renew that deadline, fail or cancel the
request, or promise that a later reply will be accepted. For long HTTP processing,
use the existing [lease renewal](http-lease-renewal.md) option; quarantine does not
enable it automatically. Planned server drain can still wait on these pending
requests until they complete, expire, or are [explicitly cancelled](request-cancellation.md).

## Recovery and delivery guarantees

Quarantine never invokes recovery automatically. Explicit recovery is a single
callback invocation, with no managed retry loop, lease renewal, handler reporting,
request-state watcher, or conversation ordering guarantee. It can overlap normal
processing. A recovered message can run after later messages in its conversation;
normal ordered dispatch still preserves its original invocation order.

Inspect earlier side effects and [delivery diagnostics](delivery-diagnostics.md)
before deciding what the callback should do. Earlier attempts may already have
sent a partial stream or completed a reply before failing. Blindly running the
original handler can duplicate Telegram messages or application side effects.
An explicit callback returning success without replay can intentionally resolve
an entry whose work was already completed or deliberately discarded.

Quarantine insertion and server acknowledgement are separate operations. A lost
acknowledgement or reconnect can replay already processed/quarantined deliveries
and create additional entries; there is no deduplication or exactly-once promise.
A recovery callback can complete an external side effect and then fail, lose its
response, or die: retained work still needs an application decision before retry.
If the store/process itself restarts or disappears, retained data is lost; even
callbacks finishing afterward cannot restore it. IDs are local to one store's
lifetime and are not durable handles. This follows Exiron's accepted in-memory
restart-loss model.

## Runtime status and existing monitor reports

[Runtime status](client-runtime-status.md) adds `BatchQuarantined` and `Quarantine`
(Go), or `batch_quarantined` and `quarantine` (Elixir). The store snapshot includes
current count, encoded bytes, limits and active recovery claims. Elixir includes
`available?` and reports unavailability without contacting the store's mailbox.
Go reports zero store counts when no store was supplied; Elixir reports `nil`
when the policy is disabled. Status includes no payloads, request IDs or raw errors.

`BatchCompleted` / `batch_completed` normally includes messages released into
quarantine; the separate quarantined counter distinguishes them from ordinary
completion. A later cancellation, lease loss or notification callback failure
can stop processing after insertion, leaving a retained entry without a completed
handler slot.
Store counts survive a runner reset/poller replacement when the same store is
reused. Batch counters still reset per batch.

Existing optional [handler reports](handler-reporting.md) continue to record
retrying/exhausted attempts, including a failure subsequently quarantined. The
server monitor does not claim that a local quarantine succeeded or that a later
manual recovery completed: acknowledged batches cannot report further handler
updates. Use the local notification callback and store/status APIs for recovery.
