# Shared buffered-payload budget

`EXIRON_MAX_BUFFERED_BYTES` limits encoded payload bytes retained across **all**
hook queues and unacknowledged HTTP/WebSocket batches. The default is
**256 MiB (268,435,456 bytes)**. It applies alongside the existing per-hook count,
per-hook byte and global pending-request limits.

```sh
EXIRON_MAX_BUFFERED_BYTES=268435456
```

The equivalent Hub option is `max_buffered_bytes`; values use the existing positive
integer runtime-setting rules. Environment changes take effect through the normal
startup/runtime configuration loading path. Existing work is never evicted to
make room for a new request. If a changed limit is below current usage, new work
is rejected until enough retained payload has been released.

## Admission and listener copies

Routed requests and button callbacks must fit the shared budget before a pending
request or encoded client payload is created. Regular routed requests use the
existing overload notification and record `max_buffered_bytes` as the overload
reason. Button callbacks keep their existing unavailable response when admission
fails. Rejected updates are not accepted pending work or a durable retry queue.

A routed request gets admission priority before listener fanout from the same
incoming message. `listen: all` continues to receive both copies when they fit;
its routed request now precedes its listen copy. Each listener copy consumes
capacity independently. Listener hooks are considered in sorted name order.
When the global budget is full, a new listener copy is dropped without trimming
existing queues. Each rejected copy increments its own counter.

The existing per-hook policy may still replace stale listen messages. Listener
churn can no longer evict an accepted routed request at a per-hook limit.
Request ordering within routed queues, delivery acknowledgements, streaming and
one-shot client APIs remain intact.

## Accounting and release

Usage is derived from the current queue and delivery records rather than a
second mutable counter. Moving payload from a queue to an unacknowledged batch
keeps the same charge. Repeated polls do not double count. A stale WebSocket
acknowledgement cannot free an HTTP batch owned by a replacement client.

Acknowledgement releases batch payload. Cancellation releases retained request
payload from queues and deliveries. Disconnect/reconnect requeues pending routed
items without creating extra capacity; lossy listener items are discarded during
recovery as before. Route removal and Hub reset release the corresponding buffers.
Expired items still physically retained in an unacknowledged batch remain charged
until existing delivery cleanup removes them.

This is an **encoded payload budget**, not a cap on BEAM resident memory. It counts
base64 data bytes per retained delivery copy, even when binaries share underlying
storage. Message metadata, pending-request records, history/image previews,
active Telegram sends, in-transit HTTP bodies and VM overhead are outside this
budget and retain their separate limits. Upload limits remain independent; see
[payload limits](payload-limits.md).

## Monitor and Prometheus

The authenticated monitor's Delivery health panel shows total usage and limit,
a progress bar, bytes awaiting acknowledgement, and request/listener rejection
counts. The admin Hub status includes `buffer_capacity` with the same totals.
Hook-scoped API status does not expose this global object or other hooks' usage;
no client SDK or wire-protocol update is required.

Prometheus adds fixed-cardinality global series:

| Metric | Meaning |
| --- | --- |
| `exiron_buffered_bytes` | Queued plus unacknowledged encoded payload bytes |
| `exiron_buffered_bytes_limit` | Configured shared budget |
| `exiron_buffered_awaiting_ack_bytes` | Bytes held in unacknowledged batches |
| `exiron_buffer_request_rejections_total` | Routed request/callback rejections at the global budget |
| `exiron_buffer_listener_rejections_total` | Listener-copy rejections at the global budget |

Counters reset when Hub state is replaced/restarted. Normal acknowledgements,
client disconnects and route reconciliation do not erase them. The local monitoring
rules include sustained shared-buffer pressure and request rejection alerts.
Existing per-hook gauges and rejection counters remain available.
