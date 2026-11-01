# Client runtime reporting in the monitor

Protocol 1.17 adds the `client_runtime_reporting` capability, optional session
references in explicit HTTP poll responses and WebSocket connected frames, and
`POST /api/client-runtime`. Both managed SDKs now enable background reports
**automatically when startup capability discovery advertises support**. Existing
clients, reply APIs and delivery behavior remain supported. SDK version headers
are automatic independently of runtime reporting.

## Automatic reporting and explicit options

Go:

```go
runner := client.NewRunner(exiron.RunnerOptions{
    Handler:          handler,
    HandlerTimeout:   30 * time.Second, // Optional local execution budget.
    // For long HTTP handlers, separately enable HTTPLeaseRenewal: true.
})
err := runner.Run(ctx)
```

Elixir (HTTP or WebSocket):

```elixir
{ExironClient.Poller,
 client: client,
 handler: &MyHandler.handle/1,
 handler_timeout_ms: 30_000} # Optional local execution budget.
```

No reporting option is needed on current servers. Both HTTP and WebSocket managed
workers use the same negotiation. A client ID of 1–128 bytes is required; automatic
mode skips reporting for IDs outside that range. A generated default ID qualifies.

- Elixir: `runtime_reporting: false` opts out; omitted or `:auto` negotiates support;
  `true` requires support and fails startup if unavailable.
- Go: `DisableRuntimeReporting: true` opts out. Omitted options (including the zero
  value `RuntimeReporting: false`) negotiate support. `RuntimeReporting: true`
  requires support and fails startup if unavailable. Setting both booleans to true
  is rejected before any network calls. The original boolean field remains source
  compatible.

Automatic discovery shares the existing startup lookup when other features need
it. When runtime reporting is the only feature, discovery is best effort: absent
support or failed discovery leaves reporting off without preventing delivery.
Go bounds that optional lookup to one second; Elixir disables retries and uses
one-second connect, receive and pool timeouts for its discovery requests (a named
Finch pool keeps its configured connect timeout). Legacy discovery fallback may
also perform authentication. Discovery is retried on the next worker start, not
on every poll. Explicitly disabled clients add no report/discovery traffic solely
for this feature and do not create a reporter.

The server-issued session reference is required whenever reporting is enabled.
An advertised feature with a missing reference is an invalid session response;
clients do not send unfenced reports or dispatch that batch.

The first session reference wakes the reporter; subsequent attempts are spaced
at least **five seconds** apart. Each attempt reads the latest local snapshot.
Reports are not a queue or history: old observations are not replayed. Only one
report request is in flight per managed client, with a one-second request budget.
A failed report is ignored by the handler/reconnect loop and is not retried;
a later interval can send a new observation with a higher sequence.

Reporting runs outside handler slots, so blocked, overdue or draining handlers
remain observable. Go cancels and joins its reporter when `Run` ends; custom HTTP
transports must honor request contexts. Elixir monitors the poller and runs each
report in an owned task, stopping that task on timeout or owner exit. Report
errors never invoke application handler callbacks. Reporting does not inherit a
handler's expired context/token and does not kill or release a handler.

## What the monitor shows

Each hook's client card has a **Client-reported runtime** section:

- Current sampled phase, including handling, waiting, draining or backing off.
- Active and overdue handler slots.
- Quarantined messages and encoded bytes, with separate “Not configured” and
  “Unavailable” states.
- Server receipt time/age and a Fresh, Stale, or Stale · session ended indicator.

A missing report is shown explicitly, not represented as zero activity. The
monitor uses its existing five-second hook refresh rather than broadcasting a
full status update for each report. Pausing live updates freezes these values;
resuming fetches the latest observation. Short phases can occur between samples.

All these values are **client-reported observations**. They are displayed
separately from server-observed connection state, assigned requests and delivery
results. An active count is not proof that a handler is making progress, nor is
it a delivery receipt or an authoritative liveness check.

## Freshness and session fencing

A server-generated random `runtime_ref` identifies one client session. It stays
stable across ordinary live HTTP polls/lease renewals, and changes for a new or
replacement session, even when the replacement reuses the same client ID. Reports
require the hook's bearer token, matching client ID and that reference. They
cannot write another hook's or a replacement client's observation.

One latest report is retained per configured hook. A higher sequence replaces
it; duplicate and lower sequences are ignored **without refreshing receipt time**.
Removed hooks are pruned under existing configuration reconciliation, and Hub
restart loses observations. References/sequences are not exposed in the runtime
status observation returned to monitor/API readers.

Freshness uses server receipt time and a monotonic age, not a client clock. An
active session's report becomes stale after **15 seconds** without a newer report.
The last known session can still report after its lease/socket ends, provided no
replacement has claimed its identity. Such reports are always labelled
`session_inactive` / “Stale · session ended,” even if just received. This permits
useful overdue/backoff diagnostics without pretending that ownership is alive.
A replacement clears the old observation and immediately fences out late reports.

Reports never acquire or renew a lease, update the “last identified contact”
timestamp, claim/acknowledge a batch, consume a queue, or change request outcomes.
Long HTTP processing still needs the separate [lease renewal](http-lease-renewal.md)
option to retain delivery ownership. Reporting alone does not enable renewal.
Server cancellation, handler deadlines, graceful drain and delivery expiry keep
their existing semantics.

## Bounded payload and API

Reports contain only this closed set of fields:

```json
{
  "client_id": "worker",
  "runtime_ref": "server-issued-session-reference",
  "sequence": 1,
  "phase": "handling",
  "active_handlers": 2,
  "overdue_handlers": 1,
  "quarantined_messages": 3,
  "quarantine_bytes": 1024,
  "quarantine_enabled": true,
  "quarantine_available": true
}
```

No message content, request/batch IDs, application error text, exception names,
stack traces or credentials are included in the body. The normal bearer header
authenticates the request. Client ID and session reference are control identities;
other observations contain only the gauges and server freshness metadata.

Allowed phases are `idle`, `connecting`, `polling`, `handling`, `waiting`,
`backing_off`, `draining`, and `stopped`. Active/overdue counts are 0–64, with overdue
not exceeding active. Quarantine count is 0–1,000,000,000 and bytes are 0–1 TiB.
SDKs clamp these gauges to wire limits and normalize concurrent snapshot races.
Sequence is an integer from 1 through 2^53−1. Unknown/missing fields, invalid
phases, booleans, numbers and over-limit values are rejected. Reporting shares
the existing authenticated API size and rate limits; it does not bypass them.

The endpoint returns `{"ok":true}` for accepted or ignored older reports; 400 for
invalid payloads, 401 for invalid credentials, 409 (`client_lease_lost`) for a
reference/client mismatch, and the existing 429/503 responses for rate limiting
or unavailability. Reports do not expose a new administrative control surface.

Hook-scoped API status adds optional `client.runtime`. Go exposes it as
`HookClientPresence.Runtime` / `ClientRuntimeObservation`; Elixir preserves the
JSON map. It contains the sampled values plus `reported_at`, `age_ms`,
`stale_after_ms`, `stale`, and `status` (`fresh`, `stale`, `session_inactive`).
Legacy responses without the field continue to decode normally. Local
[SDK runtime status](client-runtime-status.md) remains available without enabling
reporting or contacting the server.
