# Bounded client handler concurrency

Both managed clients support an optional concurrency limit for messages **within
one delivery batch**. The default remains one handler, with serial execution and
existing retry/stop behavior. The server architecture and wire protocol do not
change. No server capability lookup is needed for this client-only option.

## Enable it

Go:

```go
runner := client.NewRunner(exiron.RunnerOptions{
    HandlerConcurrency: 4,
    HandlerMaxAttempts: 3,
    Handler: handler,
})
err := runner.Run(ctx)
```

Go accepts 1–64; zero selects the default of 1. Other values fail validation before
polling or authentication.

Elixir:

```elixir
{ExironClient.Poller,
 client: client,
 handler: handler,
 handler_concurrency: 4,
 handler_max_attempts: 3}
```

Elixir accepts 1–64; omitting the option selects 1. Invalid values raise an
`ArgumentError` during poller setup. Both HTTP polling and WebSocket delivery use
the same configured limit.

## Scheduling and acknowledgement

The limit includes the handler, its local retry waits, and optional diagnostic
report or cancellation watcher cleanup. A slow handler holds one slot while
another slot can process a later message in the same batch. No more than the
configured number of handlers run at once. Requests and listen messages share
this limit.

The client keeps **one batch in flight**. It acknowledges that batch only when
all its handlers have finished successfully or have been handled under the
existing terminal cancellation rules. Handlers can still return without sending
a reply; an acknowledgement confirms handling, not Telegram delivery.

After an exhausted handler failure is observed, queued handlers stop starting.
Handlers already active continue through their own retry policy and finish before
the batch returns an error. The batch remains unacknowledged, and the client stops
under the existing failure policy. Work that started before failure observation
can therefore still produce a reply. If several handlers fail, the returned error
is the first failure observed; their individual error callbacks still run.

Successful siblings are not rerun during local retries. Reconnection can replay
unacknowledged pending requests under the existing in-memory contract. Keep
handlers idempotent; concurrency does not provide exactly-once side effects.

This option helps batches containing multiple messages. It does **not** pipeline
batches, fetch extra work while a batch runs, open more hook connections, or make
later batches overtake a slow one. Single-message batches gain no parallelism.

## Handler and callback behavior

At a limit of 1, handlers continue to run in their original caller context.
Above 1, Go runs handlers in separate goroutines; Elixir runs them in separate
linked tasks. Elixir tasks do not inherit the poller's process dictionary or
mailbox. Pass application context in closures or arguments, and use a process
that owns shared state when necessary.

Handlers, local failure callbacks and cancellation callbacks can run concurrently.
Go applications must synchronize mutable shared state, including maps, counters,
custom HTTP adapters and callbacks. Elixir callbacks that previously relied on
`self()` being the poller should send explicitly to a captured owner PID.
Lifecycle connection callbacks remain transport lifecycle notifications.

Parallel handlers have no conversation ordering guarantee by default. Enable
[conversation ordering](#conversation-ordering) to serialize each chat/topic
while allowing unrelated conversations to run concurrently. Choose a limit
consistent with downstream capacity and the server's existing per-hook send cap;
overload behavior is unchanged.

One-shot responses and streamed responses remain available for every handler.
Each handler keeps its own request ID, retries, reporting metadata and cooperative
cancellation context/token. Cancelling or expiring one request does not cancel
its siblings or consume their retry budget.

## Conversation ordering

Enable the optional ordering alongside concurrency:

```go
runner := client.NewRunner(exiron.RunnerOptions{
    HandlerConcurrency: 4,
    HandlerOrderByChat: true,
    Handler: handler,
})
```

```elixir
{ExironClient.Poller,
 client: client,
 handler: handler,
 handler_concurrency: 4,
 handler_order_by_chat: true}
```

Both default to false; Elixir rejects non-boolean values. The limit of 1 keeps
its original fully serial execution regardless of the ordering option.

The conversation key is `(service_id, chat_id, message_thread_id)`. A chat's
non-topic messages form one group; different topics can run concurrently. Bot
instance/name is deliberately excluded: messages from the same conversation
remain ordered when multiple bots deliver them. Messages missing a nonzero
numeric service or chat ID share one fallback group. Ordering between that
fallback group and correctly addressed messages cannot be inferred.

Messages in a group follow their order in the received batch. Each group uses
at most one handler slot; retries, reporting and watcher cleanup finish before
its next handler starts. A cancelled/expired request handled by cooperative
cancellation releases the group for its next message without cancelling that
message. Groups are dispatched in order of first appearance. Queued messages
from a busy group do not occupy extra slots, so later independent conversations
can start. A running group retains its slot until it finishes; this is not a
time-sliced fairness scheduler.

An exhausted failure stops queued messages across all groups, including later
messages in the failed conversation. Already active handlers finish normally;
the client still withholds the batch acknowledgement. Connection and shutdown
behavior remains the same as ordinary bounded concurrency.

This preserves **handler invocation order**, not exactly-once delivery or a global
Telegram ordering guarantee. A handler must wait for its own streams, replies
and producers to finish before returning when their order matters. Detached
producers, separate client instances or hooks, and replay can still produce
interleaved or repeated side effects. Batch order is the client's received order,
not a sort by Telegram message ID. No additional batches are fetched in parallel,
and no cross-batch state or unbounded conversation cache is retained.

## Shutdown and delivery limits

Go stops dispatching when the runner context is cancelled and waits for active
handlers to return. Handlers must observe that context or otherwise finish;
uncooperative handlers are not forcibly killed. WebSocket reconnect also waits
for active work, preserving the existing no-overlap behavior.

Elixir's concurrent handler tasks are linked to their owning delivery worker or
HTTP poller. Stopping that owner cleans up its active tasks; they do not continue
as detached handlers. Ordinary handler exceptions still use the existing retry
policy. Unhandled exits or throws remain process failures, not successful batch
completion. External producers started by handlers remain application-owned.

For long HTTP batches, concurrency alone does not renew the server's client
lease. Enable optional [HTTP lease renewal](http-lease-renewal.md) or prefer
WebSocket transport when a batch can outlast that lease. Server drain, request expiry, cancellation, rate
limits and send capacity retain their existing behavior.

See [handler failure reporting](handler-reporting.md),
[cooperative cancellation](cooperative-cancellation.md), and
[delivery guarantees](delivery-guarantees.md).
