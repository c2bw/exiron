# Managed client shutdown

Protocol 1.16 adds the `client_retirement` capability and authenticated
`POST /api/client-retire`. Both SDKs offer an **opt-in** graceful shutdown mode for
managed HTTP and WebSocket clients. Existing immediate cancellation/termination,
one-shot replies, streaming and other handler features remain available.

Enable the mode before startup. Enabled features share the existing capability
discovery lookup. A server that does not advertise retirement support fails
startup before the client consumes work; there is no fallback to acknowledging
and fetching another batch. HTTP graceful mode also automatically enables lease
renewal and requires `http_lease_renewal` support.

## Go

```go
runner := client.NewRunner(exiron.RunnerOptions{
    GracefulShutdown: true,
    Handler: func(ctx context.Context, message exiron.Message) error {
        // Use this context for streams, network calls and cancellable work.
        _, err := client.ReplyText(ctx, message.ReqID, "done")
        return err
    },
})

runCtx, cancelRun := context.WithCancel(context.Background())
defer cancelRun()
done := make(chan error, 1)
go func() { done <- runner.Run(runCtx) }()

// On an application shutdown signal, from outside the handler/callback:
shutdownCtx, cancelShutdown := context.WithTimeout(context.Background(), 30*time.Second)
defer cancelShutdown()
err := runner.Drain(shutdownCtx)
```

Drain stops subsequent polls, allows the current batch to finish, confirms its
retirement, then disconnects. The runner returns nil after successful draining;
`OnDisconnect` receives nil for that clean stop. Handler errors, lost ownership,
retirement errors and network failures are returned without reconnecting during
drain. Retirement POSTs are never automatically retried.

A deadline/cancellation on the drain context cancels the run and returns promptly.
Go cannot forcibly stop handler goroutines: handlers must observe their contexts.
`Run` still waits for active handlers to return, so a handler that ignores
cancellation can delay its completion. The transport is closed/cancelled and late
handler completion does not acknowledge the batch. Do not start a replacement
runner while application handlers from the old run are still executing.
Concurrent drain callers wait for the same run; an earlier caller deadline can
cancel that run. A runner rejects concurrent `Run` calls.

## Elixir

```elixir
{ExironClient.Poller,
 client: client,
 transport: :http, # or :websocket
 graceful_shutdown: true,
 handler: &MyHandler.handle/1}

# From an application shutdown coordinator, outside the handler:
:ok = ExironClient.Poller.drain(poller_pid, 30_000)
```

The default deadline is 30 seconds. Successful draining returns `:ok` after the
poller stops normally. It returns `{:error, reason}` on failure or timeout.
Immediate process/supervisor shutdown remains available. A concurrent second drain
request returns `{:error, :already_draining}` and does not reset the first deadline.
Graceful poller child specs use `restart: :transient`, so a clean drain does not
immediately restart the worker. The optional [quarantine policy](handler-quarantine.md) instead uses `:temporary`
to leave fatal failures stopped for application recovery. Default-mode child specs keep their existing
restart policy; applications can still supply their own child spec.

In opt-in HTTP mode a linked batch worker executes handlers while the poller
remains responsive to drain requests. Poll transport runs in an owned task and
can be stopped during idle drain. Existing handler concurrency, ordering,
reporting and cancellation options are passed through. WebSocket mode retains
its existing worker/heartbeat architecture. A drain deadline stops owned work
without acknowledging unfinished batches; application-owned processes or external
side effects cannot be undone by stopping the poller.

## Batch, lease and acknowledgement behavior

The **whole current batch** is the acknowledgement unit. Serial/concurrent
handlers can finish its remaining messages under the deadline, including streams.
The mode does not add per-message acknowledgements. A batch already being fetched
when drain starts may become the current batch; no subsequent polling begins.
Unstarted/unhandled deliveries are never acknowledged merely to shut down.

Managed HTTP retirement uses a control request capped at one second (and the
remaining drain deadline), immediately after a final lease renewal. A failed or
unconfirmed retirement stops the client without reconnecting or retrying it.
HTTP batch leases keep renewing while handlers run. WebSocket pings continue
while its current worker runs. After successful handling, retirement confirms the
batch without fetching more work, removes its session, and releases its lease or
monitor. An idle WebSocket closes its own connection; an idle HTTP client with no
completed batch identity stops polling and lets its existing short lease expire.

Retirement requires the bearer credential, client ID, a live session and a random
batch identity. It accepts either that session's current batch or its last
acknowledged batch. This handles the race where a normal acknowledgement already
caused the server to assign a newer batch: the newer **unfinished** batch is
requeued, not acknowledged, before retiring. A replaced session starts without
the old acknowledgement fence, even if it reuses the same client ID. Stale calls
cannot retire a replacement session or another hook's delivery. A cancelled empty
HTTP batch retains its fenced identity so it can still be retired safely.

The endpoint uses normal bearer API limits and returns `{"ok": true}` on success.
Invalid input returns 400, missing/invalid credentials 401, and lost ownership or
stale batch/session 409 (`client_lease_lost`). Repeating a completed retirement is
not an idempotent receipt lookup. If its response is lost, the client reports an
error rather than blindly retrying or consuming another batch.

There is no persistence or exactly-once delivery guarantee. Unacknowledged work
can be redelivered after disconnect/lease expiry; handlers must remain safe for
existing at-least-once behavior. A retirement response lost after server acceptance
has an uncertain acknowledgement outcome, even though handler work completed.
