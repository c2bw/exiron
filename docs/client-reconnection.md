# Client retries and reconnection

Go and Elixir clients randomize ordinary retry delays by default. For an
exponential backoff interval B (capped by the configured maximum), the wait is
chosen from B/2 through B. The interval doubles after ordinary failures and resets
after recovery. This spreads workers' reconnect attempts after an outage.
Successful HTTP polling keeps its configured interval; handler retry timing is
unchanged.

## Rate limits and server hints

Safe HTTP requests can retry transport failures and HTTP 429 within their retry
budget. `Retry-After` supports integer seconds and HTTP dates. A positive JSON
`retry_after_ms` is also honored on 429 and on existing hook ownership conflicts.
When both header and body supply a delay, clients keep the longer one.

Server hints are minimum waits: jitter and the ordinary maximum delay never
shorten them. A hint beyond the remaining request budget returns the error without
sleeping or sending again. Missing, malformed, zero and past header hints use
ordinary backoff. Authentication errors and other HTTP errors keep their existing
failure behavior. HTTP 5xx responses are not automatically retried.

Automatic request retries remain limited to read-only GET/HEAD/OPTIONS requests,
explicit-delivery polling, and legacy authentication. The destructive one-shot
polling endpoint remains excluded. Responses, stream updates, pushes, lease
renewals, acknowledgements and other mutations are never automatically replayed,
including requests with idempotency keys. A rejected stream stops at that update.
Applications still decide whether to retry a delivery operation explicitly.

## Managed clients and budgets

Both HTTP polling loops retain their long-running recovery behavior for transport
failures and hook ownership conflicts, now with increasing randomized delays
between failed polling cycles. Successful polls reset that delay. Each HTTP
request still has its own retry budget, capped by the managed poller's disconnect
timeout. An exhausted HTTP 429 request ends the managed loop instead of silently
starting a fresh rate-limit budget.

WebSocket reconnects use randomized backoff and a retry budget for consecutive
failures. **Go runners now enforce `RetryPolicy.MaxElapsed` for WebSocket
reconnects too**; previously their outer reconnect loop was unbounded. A healthy
connection resets the failure stretch. Applications that supervise runners can
choose whether to start a new runner after exhaustion.

Go reads `Retry-After` from rejected WebSocket handshakes. Elixir's current
WebSockex dependency discards headers for rejected handshakes; HTTP 429 handshakes
therefore use ordinary randomized backoff within its existing reconnect budget.
Elixir still honors `retry_after_ms` in ownership-conflict frames.

Go's default waits observe context cancellation. Elixir's existing configurable
sleep hook can return `{:error, reason}` to stop retrying, and pollers remain
supervised processes. A custom sleep hook must return promptly when its caller
needs to stop. Budgets are checked before waiting and HTTP requests recheck the
budget after the wait; they do not interrupt an already-running network call.
Network timeouts remain separately configurable.

## Deterministic timing

To disable jitter while retaining backoff, hints and budgets:

Go:

```go
client, err := exiron.New(url, exiron.WithRetryPolicy(exiron.RetryPolicy{
    DisableJitter: true,
    InitialDelay: 250 * time.Millisecond,
    MaxDelay: 30 * time.Second,
    MaxElapsed: 30 * time.Second,
}))
```

Elixir:

```elixir
client = ExironClient.new(
  base_url: url,
  token: token,
  reconnect_backoff: [jitter: false]
)
```

No server configuration, protocol upgrade or handler API change is required.
One-shot replies, streaming, opt-in handler features and delivery acknowledgements
retain their existing APIs and semantics.
