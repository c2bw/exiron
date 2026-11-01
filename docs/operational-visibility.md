# Delivery health

The authenticated `/monitor` page shows a delivery health panel with live totals
and a row for each configured hook. The same data is available as
`delivery_health` in status snapshots and as `health` on each hook. Token-scoped
`GET /api/status` includes only that token's hook and its totals.

Counters and timestamps live in the Hub's memory. A Hub restart or explicit
`Hub.configure/2` reset clears them. Ordinary route and bot reloads preserve
records for retained hooks; removing a hook discards its record and removes it
from aggregate totals. Records do not contain message contents, client IDs or
credentials, and there is one fixed-size record per configured hook.

| Field | Meaning |
| --- | --- |
| `queued` | Messages currently in the outbound queue, including listen traffic. |
| `queued_bytes` | Payload bytes in that queue, using the existing queue bounds accounting. Excludes batches awaiting acknowledgement, pending-request metadata and total process memory. |
| `pending` | Accepted requests still awaiting a terminal response outcome or expiry. Includes requests that are queued, claimed or responding. |
| `in_flight_sends` | Running Telegram send operations for configured hooks, including responses, pushes and rejection notices. |
| `unavailable_rejections` | Routed messages rejected because their hook was unavailable. Counts the rejection even if its Telegram notice fails. |
| `overload_rejections` | Routed messages rejected by pending-request or queue admission limits. |
| `send_failures` | Failed send operations, including task start failures, task crashes, timeouts and partial push failures. Each failed operation counts once; a retried response can fail more than once. A push targeting multiple chats counts as one operation. API validation and preflight capacity rejections do not count. |
| `completed_responses` | Successfully sent responses with an acceptance timestamp. Pushes, listen traffic, expired requests and failed responses do not count. |
| `response_duration_ms` | Sum of successful response durations from request acceptance to observed Telegram send completion. Includes retries, queueing and client processing. |
| `average_response_ms` | Aggregate successful response duration divided by completed responses; `null` before the first completion. This is a lifetime average, not a percentile or a recent-window average. |
| `last_response_ms` | Most recent successful response duration for a hook, or `null`. |
| `last_connected_at` / `last_disconnected_at` | Most recent recorded connection transitions for a hook, in UTC; `null` when no transition has been recorded. HTTP disconnects are detected when the lease expires. Repeated polling does not change the connection timestamp. |

The existing `connected` flag represents hook availability for admission: a
client lease/socket or a claimed pending request can keep it available. The
monitor therefore labels it **Available** / **Unavailable**. New arrivals to an
unavailable hook continue to be rejected; this feature does not add offline
queueing. A send timeout still means the Telegram delivery outcome is unknown.

## Telemetry

`ExironWeb.Telemetry.metrics/0` exposes these measurements to the existing
Phoenix LiveDashboard metrics view. A protected Prometheus exporter and a local
setup with persistent history are described in [monitoring](../monitoring/README.md).
External reporters can also attach to the same events.

| Event (prefix `[:exiron, ...]`) | Measurements | Metadata |
| --- | --- | --- |
| `[:hub, :queue]` | `count`, `bytes`, `dropped` | `hook` |
| `[:hub, :pending]` | `count` | none |
| `[:hub, :sends]` | `count` | none |
| `[:hub, :delivery, :rejected]` | `count: 1` | `hook`, `reason` (`unavailable` or `overloaded`) |
| `[:hub, :send, :stop]` | `duration` in native monotonic units | `kind`, `outcome` (`ok`, `error`, `partial_error` or `timeout`) |
| `[:hub, :response, :stop]` | `duration` in native monotonic units | `hook` |

Queue, pending and send gauges are emitted during status publication, including
send starts and completions. Listener enqueueing also emits queue measurements
with the number of dropped listen messages; other gauge emissions use zero for
`dropped`. Removing a hook emits a zero queue gauge. Send timing covers running
tasks and includes Hub completion processing; a task that cannot start has no
send-stop event. Response timing is emitted only on success. Native durations
are converted to milliseconds by the metric definitions. Tags contain configured
hook names and bounded outcome values, never tokens, chat IDs or payloads.

Use offline rejections to identify availability problems; inspect pending work,
queued bytes and latency together to detect slow clients. Failed operations can
include recovered attempts, so they should not be interpreted as lost messages.
Historical graphs require Prometheus (or another reporter). Alert notifications
require a separately configured receiver.

[Request tracing](request-tracing.md) adds bounded per-request timelines, filters
and pause/resume inspection. [Health checks](health-checks.md) provide separate
liveness and readiness endpoints.

Hook workspaces summarize retained send failures with fixed explanations and
next steps derived from diagnostic categories. Uncertain or partial deliveries
warn about duplicate messages. **Inspect this delivery** opens that exact retained
operation in Monitor, including failed pushes without a request trace. Expired
links report that the diagnostic is unavailable; no retry or resend is triggered.
