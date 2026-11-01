# Startup capability discovery

Protocol 1.15 adds authenticated `GET /api/capabilities` and advertises
`capability_discovery`. Both managed clients use it when opt-in features require
server support. A startup with cooperative cancellation, handler failure reporting
and HTTP lease renewal enabled makes **one shared discovery lookup**, rather than
separate legacy authentication calls for those features.

No setting is needed to select the new endpoint. Existing feature options keep
their defaults. When all three features are disabled, managed startup adds no
capability lookup. Local configuration is validated before negotiation, and
required support is checked before polling or connecting to consume work.

## Rate limits and state

The endpoint requires the hook bearer token and uses the normal API budgets:
1200 requests/minute per hashed token and 60,000/minute per IP. It does not consume
the separate `/api/auth` budget of 10 requests/minute per IP. That legacy
unauthenticated authentication policy remains unchanged.

Discovery returns only protocol metadata:

```json
{
  "protocol_version": "1.15",
  "capabilities": ["http_auth", "websocket", "capability_discovery"]
}
```

The actual list includes every supported capability. Responses use
`Cache-Control: no-store`. Discovery does not create or renew a client lease,
consume queued work, acknowledge a batch, change request history, or expose other
hooks' state. Missing or invalid credentials return 401; normal API rate limits
and disabled-Hub responses still apply.

## Compatibility and failures

If the discovery route returns **404 or 405**, clients perform one legacy
`POST /api/auth` lookup and use its advertised capabilities. Enabled features
share that result too. Older servers can therefore keep working when they support
the requested features, but their legacy authentication rate limit still applies.
Updating the server removes that startup bottleneck.

There is **no fallback** for 401, 403, 429, server errors, malformed successful
responses or transport failures. Such responses do not justify bypassing discovery
with another authentication route. Missing required support also fails startup
without consuming work. Discovery does not infer support from version numbers.

Negotiation is scoped to each runner/poller startup. No global cache or
credential-sharing cache is introduced; a new startup checks its server again.
Existing connection lifecycle callbacks, reconnect behavior, handlers, one-shot
replies, streams and batch acknowledgement semantics are unchanged. Configured
transport retry policies can retry a logical lookup; fallback itself is only for
the missing/unsupported route statuses above.

## Manual inspection

Go:

```go
protocol, err := client.Capabilities(ctx)
if err != nil {
    return err
}
if protocol.Supports("http_lease_renewal") {
    // The server advertised support.
}
```

Elixir:

```elixir
{:ok, protocol} = ExironClient.capabilities(client)
ExironClient.Protocol.supports?(protocol, "http_lease_renewal")
```

These helpers perform a lookup when called; they do not populate a persistent
cache. Managed clients already negotiate enabled features, so a separate manual
lookup is unnecessary unless the application wants to inspect metadata. `Auth`
/ `auth` remain available for explicit legacy authentication and hook identity,
with their existing limits.
