# Cooperative handler cancellation

Protocol 1.10 advertises `cooperative_cancellation`. Managed Go and Elixir clients
can opt in to observing server cancellation or expiry while a handler runs. The
existing handler signatures, one-shot responses, streamed responses and explicit
cancellation helpers remain available. The default is disabled and adds no traffic.

## Go

```go
runner := client.NewRunner(exiron.RunnerOptions{
    CooperativeCancellation: true,
    Handler: func(ctx context.Context, message exiron.Message) error {
        // Pass ctx to HTTP requests, generators and stream producers.
        // A server cancellation or expiry cancels this request's context.
        return generateReply(ctx, message)
    },
})
err := runner.Run(ctx)
```

Within the handler, `context.Cause(ctx)` matches `exiron.ErrRequestCancelled` or
`exiron.ErrRequestExpired` using `errors.Is`. Parent context cancellation still
means runner shutdown. `OnRequestCancelled` optionally receives a
`RequestCancellation` with `RequestID` and `Reason` (`cancelled` or `expired`).
This callback must return promptly; watcher cleanup waits for it.

## Elixir

```elixir
{ExironClient.Poller,
 client: client,
 cooperative_cancellation: true,
 handler: fn message ->
   token = ExironClient.Cancellation.current()
   receive do
     {:exiron_request_cancelled, id, reason} when id == message.req_id ->
       stop_producer(reason)
   after
     100 ->
       unless ExironClient.Cancellation.cancelled?(token), do: continue_work(message)
   end
 end}
```

`Cancellation.current/0` returns a token scoped to the handler. Pass the token to
another process if that process needs to check `cancelled?/1` or `reason/1`.
Reasons are `:cancelled`, `:expired`, or `nil`. A handler also receives
`{:exiron_request_cancelled, req_id, reason}`. The optional
`:on_request_cancelled` callback receives `%{request_id: id, reason: reason}`;
it must return promptly and may run in the watcher process. It can notify an
external producer. Handler completion stops the watcher and clears its token.

## Behavior and limits

Both managed HTTP polling and WebSocket delivery use the same authenticated HTTP
state check. Opting in requires the server capability before consuming work,
using a shared [discovery lookup](capability-discovery.md) across enabled features.
Deploy the server first, then enable clients. Checks run once before each routed
handler and every second while it runs. Configure Go `CancellationInterval` or
Elixir `:cancellation_interval_ms` to change the interval (minimum 100 ms).
Listeners do not run cancellation checks. At the default interval, 24 concurrently
running handlers add roughly 24 state checks per second, plus initial checks.
Allow for this traffic in API rate limits. Control checks use short network
timeouts; outages can delay detection.

Cancellation is cooperative: handlers and their producers must observe the
context, signal or token and return. Clients never forcibly kill handlers. A
confirmed cancelled or expired handler is not retried and does not block processing
its batch siblings or acknowledging the batch. Cancellation during a retry wait
also stops further attempts. Completed or closed state stops the watcher without
cancelling the handler. Normal handler completion cleans up its watcher.

Network errors, authorization errors, rate limits, malformed responses and missing
state do not imply cancellation. No deadline is inferred from the last observed
expiry time. The server retains the latest 500 expiry receipts and latest 500
cancellation receipts in memory, independently of activity trace retention.
Restart or receipt eviction can therefore make cancellation unobservable. This
matches Exiron's accepted in-memory delivery model.

## Request state endpoint

`GET /api/request-state?req_id=...` uses the hook bearer token and returns:

```json
{"req_id":"req-1","state":"expired","expires_in_ms":null}
```

States are `active`, `cancelled`, `expired`, `completed`, and `closed`. Active
requests include their remaining server TTL in milliseconds; terminal states use
`null`. The endpoint neither consumes work nor renews a client lease. Another
hook's retained request returns 409; unretained IDs return 404; invalid IDs return
400. Go exposes `client.RequestState(ctx, id)`; Elixir exposes
`ExironClient.request_state(client, message_or_id)` for manual checks.

Stopping a producer cannot undo Telegram sends already accepted. Existing
[cancellation delivery certainty](request-cancellation.md) continues to apply.

Elixir `stream_text/4` checks its managed cancellation token before consuming a
producer, after each yielded chunk, and before partial/final sends. It returns
`request_cancelled` or `request_expired` when that signal is observed. It cannot
interrupt an enumerable that never yields, and cancellation cannot undo an HTTP
mutation already in flight. Without a managed token, streaming is unchanged.
