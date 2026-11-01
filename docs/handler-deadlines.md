# Optional managed handler deadlines

Both SDKs support an opt-in **per-message execution budget**. It starts when a
message obtains a handler slot and spans setup checks, all local handler attempts,
retry waits, and callbacks within that slot. Waiting in the batch or a conversation
lane does not consume the message's budget. Each newly dispatched message gets
its own budget. Zero disables the feature, preserving existing behavior.

Expiry is cooperative. It signals the handler, stops queued dispatch once expiry
is observed, and makes the batch fail without acknowledgement. An overdue handler
keeps its slot until it actually returns; active siblings remain owned and finish
under existing concurrency rules. No replacement handler is started to bypass an
occupied slot. A handler returning success after expiry still fails its budget.

This is local SDK behavior. No server capability lookup is added by this option
alone. Existing one-shot replies, streaming, handler ordering, quarantine, lease
renewal, server cancellation and graceful shutdown remain available.

## Go

```go
runner := client.NewRunner(exiron.RunnerOptions{
    HandlerTimeout:    30 * time.Second, // 0 disables; negative values are invalid.
    HandlerMaxAttempts: 3,
    Handler: func(ctx context.Context, message exiron.Message) error {
        // Pass this context to network calls, streams and application work.
        _, err := client.StreamText(ctx, message.ReqID, produceChunks(ctx))
        return err
    },
})
err := runner.Run(ctx)
if errors.Is(err, exiron.ErrHandlerDeadlineExceeded) {
    // The local handler budget expired. This batch was not acknowledged.
}
```

The handler receives a deadline-bearing context. The effective context deadline
is the earlier of the local budget and its parent deadline. Local expiry sets
`context.Cause(handlerCtx)` to an error matching `ErrHandlerDeadlineExceeded`.
The error also matches `context.DeadlineExceeded` with `errors.Is`. An earlier
parent cancellation remains a parent cancellation and is not counted as a local
handler timeout.

The budget is shared across retries rather than reset for each attempt. Default
retry waits observe the context. A callback or custom wait that ignores its
context can overrun; after it returns, the loop rejects late success and starts
no new local attempt. The message context is cancelled when its slot finishes,
including on successful processing. Context callbacks/timers are joined or
stopped before the managed slot is released.

`StreamText` already observes the supplied context while waiting for chunks and
before updates/finalization. A local timeout stops the stream without a final
update. Chunk producers and other application goroutines must also observe that
context. A custom HTTP transport must honor the standard request-context contract.

Go cannot forcibly kill a goroutine. `Run` can remain blocked on an uncooperative
handler, with its slot visible as overdue. A graceful drain caller can reach its
own deadline and return while that handler still runs, as documented in
[client shutdown](client-shutdown.md). Do not start a replacement consumer while
old application work is still executing.

## Elixir

```elixir
{ExironClient.Poller,
 client: client,
 handler: &MyHandler.handle/1,
 handler_timeout_ms: 30_000, # 0 disables; must be a non-negative integer.
 handler_max_attempts: 3}
```

Inside a managed handler, `ExironClient.HandlerDeadline.current/0` returns a token.
It is nil when disabled. `expired?/1` and `remaining_ms/1` default to the current
token. Expiry sends the executing handler process:

```elixir
{:exiron_handler_deadline, token.ref}
```

A handler waiting for its own application work can handle that signal explicitly:

```elixir
def handle(message) do
  token = ExironClient.HandlerDeadline.current()
  ref = token.ref # This example enables :handler_timeout_ms.

  receive do
    {:result, text} -> reply(message, text)
    {:exiron_handler_deadline, ^ref} ->
      {:error, ExironClient.HandlerDeadline.error()}
  end
end
```

Use `HandlerDeadline.check/0` to check the current budget during a loop, or
`HandlerDeadline.wait/1` for a wait that wakes on local expiry or existing server
cancellation. The default local retry wait uses this helper. After expiry, handlers
return `{:error, %ExironClient.Error{reason: :handler_deadline_exceeded}}` even if
the application ignores the signal and eventually returns `:ok`.
`ExironClient.Error.handler_deadline_exceeded?/1` identifies that error.

Tokens use monotonic milliseconds; `deadline_ms` is not a Unix timestamp.
`remaining_ms` is nil with no active budget or for a successfully finished token,
and zero for an expired budget. Tokens, deadline notifications and watcher
processes are cleaned up before a message slot is released. A captured finished
token cannot later mark a new batch overdue.

No process is killed merely because its local budget expired. A handler blocked
in arbitrary code, a producer, a custom sleep, or a network adapter can remain
alive and occupy its slot. Application-spawned processes do not automatically
inherit the process-local token; pass it to cooperative child work and coordinate
that work's cancellation/lifetime in the application. Budget cleanup does not
undo application side effects or stop detached processes.

### HTTP and streaming behavior

`stream_text` checks the token between chunks. It stops on expiry without sending
another update or final response. A producer blocked in its own code must observe
the token/notification to return a chunk or finish; the SDK cannot interrupt an
arbitrary enumerable. SDK HTTP requests check the budget before each attempt and
after the request returns, and pool/receive timeouts shrink to the remaining
budget. HTTP retry waits do not retry early when a server retry hint exceeds the
remaining budget; they return the local deadline error instead.

Connection settings remain those of the configured Req/Finch pool. They are not
changed for each decreasing budget value, which would create separate pools and
conflict with custom named Finch pools. An in-flight connection or adapter that
does not honor its timeouts can still overrun. Requests already sent may complete
after expiry. Their handler remains owned, and the batch is not acknowledged
on late return. Existing HTTP payload/response limits still apply.

The option does not change poller supervision policy. Default-mode pollers can
restart after a fatal deadline error under their existing `:permanent` child spec;
normal replay semantics then apply. Applications requiring an operator decision
before restart can supply a `:temporary` child spec. Graceful and quarantine
modes keep their existing `:transient`/`:temporary` policies. Recoverable network
reconnects within a running poller remain available.

## Failure, delivery and other controls

- Local deadline errors stop the managed batch. They are not ordinary application
  failures eligible for automatic local retry or quarantine. An application
  failure quarantined **before** a later timeout/cancellation remains retained;
  expiry does not roll back that earlier transfer of responsibility.
- Existing server cancellation and HTTP lease-loss checks still apply. A local
  budget does not extend a server request deadline or reclaim a lost lease.
  Concurrent cancellation/expiry observations can both occur; in every case,
  unfinished work remains unacknowledged.
- An overdue HTTP handler continues to occupy its owned batch. If lease renewal
  is enabled, the existing renewal loop stays alive while it runs. This option
  does not enable lease renewal automatically. WebSocket worker/heartbeat behavior
  is unchanged. A timeout is not permission to overlap a replacement worker.
- Graceful drain still has its own whole-batch deadline. Explicit drain timeout,
  process termination and supervisor shutdown retain their existing behavior;
  those operations are separate from the cooperative local budget.
- Explicit quarantine recovery adds no managed budget of its own. Use a Go
  recovery context or application deadline coordination in Elixir. Calling
  recovery from an already managed scope can inherit that scope's context/token.

A timeout cannot retract a partial stream, a Telegram send, or another external
side effect. Inspect [delivery diagnostics](delivery-diagnostics.md) before
retrying. Neither these budgets nor quarantine add exactly-once delivery,
persistence or automatic compensation. Lost acknowledgements, supervisor/app
restarts and request expiry retain their existing semantics.

## Runtime visibility

[Managed client runtime status](client-runtime-status.md) adds:

| Go | Elixir | Meaning |
| --- | --- | --- |
| `HandlerTimeout` | `handler_timeout_ms` | Configured budget; zero when disabled. |
| `OverdueHandlers` | `overdue_handlers` | Active message slots whose local budget expired. |
| `OldestOverdueFor` | `oldest_overdue_ms` | Time beyond the oldest active overdue deadline; zero if none. |
| `BatchTimedOut` | `batch_timed_out` | Local budget expiries observed in the current/last batch. |

Active slots remain counted while overdue. Once a handler actually returns, the
overdue count drops, while the batch timeout count remains until the next batch.
Last error summaries use the fixed `handler_deadline_exceeded` category and expose
no request IDs, message content, tokens or exception text. Status reads remain
local and available while a handler is blocked.

These are diagnostic observations. Clock-based overdue visibility can precede a
timer's counter update, and concurrent fields may change between observations.
Existing server-side handler reports can show the last application retry or
failure before a local timeout; this feature does not add server trace states
or report an expired budget as a retryable application failure.
