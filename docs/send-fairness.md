# Per-hook delivery capacity

Protocol 1.8 advertises `send_fairness`. Exiron limits active delivery operations
both globally and per authenticated hook. The defaults are **100 global** and
**10 per hook**, so one busy hook cannot occupy every global slot with the default
settings. Both checks run in the existing Hub; no additional queue or process
layer is introduced.

| Setting | Default | Meaning |
| --- | --- | --- |
| `EXIRON_MAX_IN_FLIGHT_SENDS` | `100` | Global active delivery cap. |
| `EXIRON_MAX_IN_FLIGHT_SENDS_PER_HOOK` | `10` | Active delivery cap for each hook, shared across its clients. |

Both settings accept positive integers and take effect at application startup.
The effective hook limit is the smaller of the two. Keep the hook limit below the
global limit to leave room for other hooks. To restore the previous global-only
capacity behavior, set the per-hook limit equal to or above the global limit.
These settings are independent of inbound pending-request and payload queue caps.

## What occupies a slot

Responses, pushes, completed-reply edits, chat actions, and background unavailable
or overload notices all count toward their hook's limit. A logical operation
holds one slot until it completes, times out, is cancelled, or its worker exits.
Waiting for Telegram's per-bot coordinator or rate-limit cooldown also occupies
a slot. Multipart text, caption overflow and multi-chat pushes retain one slot for
the whole operation, rather than reserving a slot for every individual send.

The caps bound capacity consumption; they are not a round-robin scheduler or a
bandwidth guarantee. If several hooks fill the global cap, new operations still
wait for callers to retry. Hooks using the same Telegram bot share its serialized
send queue and cooldowns. Different bots can continue independently. Unused slots
are not reserved for particular hooks, and a hook cannot borrow beyond its cap.

## Overload responses and retrying

Rejected operations do not start a send task or make a Telegram request. A
response rejection does not consume its pending request; a rejected stream update
keeps its existing receipt. Completed edits also remain available. Rejections do
not increment Telegram send-failure counters.

The HTTP API returns **503** with `Retry-After: 1` and a structured body:

```json
{
  "code": "hook_send_queue_full",
  "error": "hook send queue full",
  "retry_after_ms": 1000
}
```

When the global cap is full, the existing `send_queue_full` code takes precedence
and receives the same retry hint. The delay is a backoff suggestion, not a
reservation or a promise that capacity will be available. Retry explicitly, with
bounded attempts and jitter, while respecting cancellation and request deadlines.
Background notices are dropped when saturated; they are not queued for replay.

Both SDKs preserve the code and retry hint and provide a classifier:

```elixir
ExironClient.Error.send_capacity_exceeded?(error)
error.retry_after_ms
```

```go
exiron.IsSendCapacityExceeded(err)
// errors.As(err, &apiError) exposes apiError.RetryAfterMS.
```

Mutation calls and streaming helpers do not automatically retry overload errors.
After a rejected stream update, retry the latest full text using the same request
ID; do not restart a stream helper from its beginning, since prior updates may
already be visible. Preserve any response options chosen when the stream began.
A transport failure, partial delivery, or `telegram_delivery_timeout` is a
different outcome: inspect [delivery diagnostics](delivery-diagnostics.md) before
retrying. The overload classifier intentionally excludes those errors.

## Visibility

The monitor shows active sends against the effective limit for each hook and a
separate send-capacity rejection counter. These values are also included in the
authenticated `/api/status` hook health record:

- `in_flight_sends`: active operations, including coordinator waits.
- `in_flight_send_limit`: effective per-hook limit.
- `send_capacity_rejections`: operations rejected by either send-capacity check.

The Go client exposes these as `HookStatus.Health`; the Elixir status map retains
the same fields. Counters reset with Hub state and are scoped to configured hooks.
Request traces record rejected response/edit/action attempts without changing
pending ownership or retaining their payloads.

Prometheus exports:

- `exiron_in_flight_sends_limit`
- `exiron_hook_in_flight_sends{hook="assistant"}`
- `exiron_hook_in_flight_sends_limit{hook="assistant"}`
- `exiron_hook_send_capacity_rejections_total{hook="assistant"}`

For example, graph send-capacity rejections with
`sum by (hook) (rate(exiron_hook_send_capacity_rejections_total[5m]))` alongside
active sends and their limits. Labels contain configured hook names only.

[Outgoing send byte budgets](send-byte-budget.md) additionally limit retained payload and client-option bytes globally and per hook, using the same capacity rejection codes.
