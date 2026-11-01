# Telegram outbound coordination

Outbound sends through Exiron share a coordinator per bot token. Only one sender
for a particular bot executes at a time; different bots can send independently.
The coordinator stores bot digests and caller references, not credentials or
payloads. Callers remain subject to the existing send-capacity limit and deadline.
Killed or cancelled callers are monitored and removed from the wait queue.

A Telegram `429` with a positive integer `parameters.retry_after` establishes a
bot-wide cooldown. The rejected send can retry **at most twice**, and other sends
for that bot also wait for the cooldown. Each new valid rejection can extend the
cooldown. This follows Telegram's
[ResponseParameters contract](https://core.telegram.org/bots/api#responseparameters).

Timeouts, connection errors, server errors and `429` responses without a valid
delay are **not** automatically retried. The existing Markdown parse fallback and
alternate-bot fallback after explicit 401/403 rejection remain separate behavior.

Exiron uses a small Req-based ExGram adapter that preserves object-shaped error
parameters. It disables implicit HTTP retries and redirects, so retry policy stays
at the outbound coordinator. Media requests continue to use multipart encoding.

By default the adapter uses Req-managed HTTP/1 pools with its connection timeout.
If a custom `:finch` pool is supplied through ExGram's `adapter_opts`, connection
settings belong to that pool. Req does not allow a named pool and per-request
`connect_options` together.

The send deadline includes time waiting for another send and for cooldowns.
A timeout still returns an unknown delivery result; cancellation cannot undo a
request Telegram already accepted. Retrying rate-limit rejections does not create
an exactly-once guarantee. Request timelines show attempts and cooldowns without
recording credentials or payloads.

Send-failure counters count the final operation outcome. A recovered rate-limit
rejection is visible in its trace but is not counted as a failed send operation.
This feature coordinates outbound sends only; it does not change inbound Telegram
polling backoff or introduce durable queues.

Active operations also obey global and [per-hook capacity limits](send-fairness.md).
Waiting for a bot or its cooldown occupies a hook slot.
