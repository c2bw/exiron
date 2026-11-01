# HTTP lease renewal during handlers

Protocol 1.13 advertises `http_lease_renewal`. Both managed HTTP clients can opt in
to renewing their existing batch lease while handlers execute, retry, or stream.
The default remains disabled for compatibility. WebSocket clients already keep
their connection alive independently of handler execution.

## Enable it

Go:

```go
client, err := exiron.NewClient(exiron.Config{
    BaseURL: "http://127.0.0.1:4000",
    Token: hookToken,
    Transport: exiron.TransportHTTP,
})
// Handle err, then:
runner := client.NewRunner(exiron.RunnerOptions{
    HTTPLeaseRenewal: true,
    Handler: handler,
})
err = runner.Run(ctx)
```

Elixir:

```elixir
{ExironClient.Poller,
 client: client,
 transport: :http,
 http_lease_renewal: true,
 handler: handler}
```

Deploy the server first. Opted-in clients require the capability before consuming
work, using one shared [discovery lookup](capability-discovery.md). Enabling the option with WebSocket transport is rejected.
Omitting the option adds no capability requests or lease-renewal traffic. Existing
one-shot polling and reply APIs remain available with their previous behavior.

A nonempty explicit batch gets an initial renewal, periodic renewals roughly
every third of the server-advertised lease timeout, and a final renewal before
the normal acknowledgement poll. At the default three-second timeout, periodic
renewals occur about once per second. Empty/idle polls have no renewal worker.
Fast batches still incur initial and final calls. These calls share bearer API
rate limits; account for them when choosing polling and batch workloads.

The polling interval must be shorter than the advertised lease timeout. Each
periodic request has a bounded time budget of roughly a quarter of that timeout,
capped at one second. An initial call has a one-second outer budget and must also
complete within the server-derived budget once the response is known. Elixir
runs control requests in bounded tasks so a stalled adapter cannot block renewal
cleanup indefinitely; Go HTTP transports must honor request contexts.

## Ownership and delivery behavior

Renewal verifies the hook token, client ID, HTTP transport, current batch ID, and
an unexpired lease timer. It neither reclaims an expired lease nor takes over a
different client or batch. It rotates the expiry generation so an old queued
expiry message cannot invalidate a renewed lease. Client IDs should still identify
one instance; two processes deliberately sharing the same client ID and batch
cannot be distinguished by this protocol.

A successful renewal changes only the lease timer/generation and observed contact
timestamp/kind. It does not fetch, consume, replay or acknowledge messages, extend
request deadlines, change listener settings, or alter pending replies and streams.
It remains available during server drain. Contact appears as `lease_renewal` in
client visibility; idle heartbeats do not publish full status snapshots.

Cancellation can remove all items from a retained HTTP batch while its handlers
are still cleaning up. The server retains that batch's identity for renewal until
its next polling transition or lease expiry. This does not retain cancelled
payloads or make a cancelled request available again. Acknowledging or replacing
the batch invalidates its old renewal identity.

Concurrency, per-conversation ordering, local retries, handler reports,
cooperative cancellation, streamed text and one-shot replies remain supported.
Only one batch is in flight. The final renewal protects the ordinary polling
delay before acknowledgement; it is not itself an acknowledgement.

## When renewal cannot be confirmed

Clients stop dispatching queued handlers on **any** renewal failure, including a
409 ownership rejection, timeout, malformed response, authentication failure,
rate limit or server error. They do not retry the control call or automatically
reclaim/replay the batch. This is intentionally conservative: a network error
means ownership is uncertain, even if the server accepted the renewal.

Go cancels the batch's handler contexts. Inside a handler:

```go
if errors.Is(context.Cause(ctx), exiron.ErrClientLeaseLost) {
    // Stop this handler's producer and return.
}
```

Elixir gives each active handler a batch token and sends a message:

```elixir
token = ExironClient.Lease.current()
receive do
  {:exiron_client_lease_lost, batch_id} -> stop_producer(batch_id)
end
# Or check ExironClient.Lease.lost?(token) from a producer process.
```

Tokens are scoped to each managed handler and may be passed to another process
for checking. A failed renewal is not reported as an application handler failure
and does not consume further local retry attempts. The clients wait for active
handlers to return, then stop with `client_lease_lost` and leave the batch
unacknowledged. Go exposes `exiron.IsClientLeaseLost(err)` and Elixir exposes
`ExironClient.Error.client_lease_lost?(error)`. Existing disconnect callbacks run
when the managed client stops. A failed final renewal also withholds acknowledgement.

Handlers must cooperate with contexts, signals, or tokens. Clients do not forcibly
kill application handlers on lease loss; an uncooperative handler can delay shutdown.
Elixir cleans up the renewal worker when its owner process exits. External producers
remain application-owned. A supervisor may restart a stopped poller according to
its existing restart policy, after that poller's active handlers have returned.

Renewal cannot prevent lease expiry during a VM pause, long network outage or
process crash. It is not a fencing token for Telegram or application side effects:
old work may still have produced a result, and pending unacknowledged work can be
replayed after expiry. Continue to tolerate duplicates under the
[in-memory delivery contract](delivery-guarantees.md).

## Endpoint

`POST /api/client-lease` uses the hook bearer token:

```json
{"client_id":"worker","delivery_id":"batch"}
```

Success returns `{"ok":true,"lease_timeout_ms":3000}`. Malformed IDs return 400;
missing/invalid authentication returns 401; stale, expired, mismatched or
WebSocket ownership returns 409 with code `client_lease_lost`. Rate limits and
unavailability retain their normal API responses. The endpoint never creates a
client lease when no matching active HTTP session exists.

Manual helpers are `client.RenewLease(ctx, batchID)` in Go and
`ExironClient.renew_http_lease(client, batch_id)` in Elixir. They perform one call;
applications using them directly own scheduling, deadlines and loss handling.
