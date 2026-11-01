# Outgoing send byte budgets

Active outgoing sends are bounded by payload bytes as well as operation count.
The defaults are **256 MiB globally** and **64 MiB per hook**:

```sh
EXIRON_MAX_IN_FLIGHT_SEND_BYTES=268435456
EXIRON_MAX_IN_FLIGHT_SEND_BYTES_PER_HOOK=67108864
```

Equivalent Hub options are `max_in_flight_send_bytes` and
`max_in_flight_send_bytes_per_hook`. They use the existing positive-integer runtime
setting rules and startup configuration path. A hook's effective byte limit is
the smaller of the global and per-hook byte limits. Existing active-send count
limits still apply independently.

## Accounting

A logical send is charged for its source data bytes plus the Erlang external-term
size of its client options. This includes potentially large captions, entities and
keyboard options without allocating another encoded copy of the file. Media
albums are charged for their source album JSON, including base64 member data.
A push is one logical operation: its source payload is charged once while it sends
sequentially to its configured targets, rather than multiplied by target count.

Responses, pushes, retained-reply edits, chat actions and background notices all
participate. Waiting for a Telegram bot's coordinator or rate-limit cooldown keeps
the charge. Multipart deliveries, caption overflow and streaming updates retain
it for the lifetime of each logical operation.

Usage is derived from admitted send records. Completion, failure, cancellation,
timeout and abnormal worker exit remove those records through existing cleanup
paths. A task that cannot start is never charged. Deferred effects recheck capacity
against the current records, so several background sends in one transition cannot
oversubscribe the budget or erase earlier admissions.

Admission accepts exact equality. It checks existing operation-count limits first,
then global bytes and per-hook bytes. Rejection occurs before a worker or Telegram
request starts. Existing active work is not killed to make room. Lowering a budget
below current usage blocks new admissions until enough work finishes.

This is a **logical send-payload budget, not a VM memory ceiling**. Temporary album
decoding, HTTP/multipart encoding, inherited reply metadata, process overhead,
network buffers and caller-held request bodies are not measured by it. The shared
[queue/batch budget](buffer-budget.md), [HTTP upload limits](payload-limits.md),
preview-history limits and VM memory metrics remain separate.

## Errors and client compatibility

The existing capacity codes and retry hints remain unchanged:

- `send_queue_full` for global capacity.
- `hook_send_queue_full` for hook capacity.
- HTTP 503, `Retry-After: 1` and `retry_after_ms: 1000`.

Responses remain pending and rejected stream updates preserve their receipts.
Completed edits remain available. Both SDKs' existing capacity-error classifiers
continue to work, and mutations/streams are not automatically replayed. A retry
hint is a backoff suggestion, not a capacity reservation. If a single operation
exceeds the configured byte budget, reduce its payload/options or explicitly
increase the budget; retrying the same payload alone cannot make it fit.

Byte-capacity rejections contribute to the existing send-capacity counter, and
also to a separate byte-capacity counter. If operation count and bytes are both
exhausted, the admission contributes to both capacity observations. These are
admission rejections, not Telegram send failures or unknown delivery results.

Hook-scoped API status adds optional health fields:

| Field | Meaning |
| --- | --- |
| `in_flight_send_bytes` | Charged active payload and option bytes for this hook |
| `in_flight_send_bytes_limit` | Effective hook byte limit |
| `send_byte_capacity_rejections` | Admissions rejected with byte capacity exhausted |

The Go `HookDeliveryHealth` model includes these fields; older servers leave them
at zero. Elixir preserves them in its existing status maps. Global `send_capacity`
remains admin-only; hook clients do not receive other hooks' usage or the global
object. Existing one-shot, media, streaming, idempotency and handler APIs remain
available; no new capability negotiation is required.

## Monitor and Prometheus

The monitor shows global outgoing payload usage/limit, a progress bar and byte
rejections, plus each hook's byte usage, effective limit and rejection count.

Prometheus exports:

- `exiron_in_flight_send_bytes`
- `exiron_in_flight_send_bytes_limit`
- `exiron_send_byte_capacity_rejections_total`
- `exiron_hook_in_flight_send_bytes`
- `exiron_hook_in_flight_send_bytes_limit`
- `exiron_hook_send_byte_capacity_rejections_total`

Counters reset with Hub state replacement/restart. The global counter survives
ordinary route reconciliation; per-hook health follows configured hooks as before.
The local rules include sustained global byte pressure and send-byte rejection
alerts. See the [monitoring guide](../monitoring/README.md) for setup and validation.
