# Delivery guarantees

Exiron keeps delivery state in a single Hub process and its supervised workers.
Queues, pending work and delivery tracking are held in memory and do not survive
Hub or application restarts.

## What clients can rely on

| Event | Current behavior |
| --- | --- |
| Managed client disconnects or loses an acknowledgement | Unacknowledged routed deliveries can be replayed while the Hub retains the pending request and it has not expired. Handlers must tolerate duplicates. |
| Delivery batch is acknowledged | The transport batch is released; this is not confirmation that a Telegram response was sent. Response completion and request expiry are tracked separately. |
| Listen traffic is interrupted or queues fill | Listen events are best effort and may be dropped; they are not recovered like routed requests. |
| Hub/VM crashes or application restarts | Queues, pending work, client leases, deduplication and delivery tracking are lost. There is no durable replay guarantee, including during planned deployment. |
| Telegram accepts an update and the Hub later restarts | Work associated with that update may never reach the downstream client. Telegram must not be treated as a backup of acknowledged work. |
| Telegram send times out | Delivery is unknown, even after the local task is terminated. Do not blindly retry unless duplicates are acceptable. |
| Request expires or admission limits are reached | Work can expire or be rejected independently of crashes. A live process is not a promise of eventual delivery. |
| Configuration is saved | YAML is persisted with atomic replacement and conflict checks. Save success does not imply reload success; check the activation result. |

These are bounded, in-memory delivery semantics, not a durable at-least-once
service or exactly-once processing. Explicit acknowledgement mode is required
for replay semantics; legacy destructive polling does not provide the same
protection. Pending requests default to a ten-minute lifetime.

## Operating assumptions

Run one active Exiron instance for a given bot set. Node discovery does not
coordinate bot ownership or replicate queues. The Hub supervision subtree
intentionally restarts its workers together so stale workers do not continue
against replacement state.

For planned restarts, use [graceful drain](graceful-drain.md) to pause new work
and wait for pending requests, queues, active sends and client acknowledgements.
A timeout leaves intake paused. This reduces interrupted work without changing
the in-memory contract; zero tracked work does not guarantee successful Telegram
delivery or completed external client side effects.

## Scope and limits

Applications that require work to survive restarts, durable audit history or
shared delivery across active instances need a persistence layer and ownership
coordination beyond Exiron's current delivery model.

Use the [benchmark harness](../benchmarks/README.md) with representative traffic
and deployment hardware to measure throughput and latency. Synthetic results do
not establish production capacity.

[Optional idempotency keys](idempotency.md) replay retained response/push results
within one Hub lifetime. Their bounded, expiring receipts do not add durability
or exactly-once delivery.
