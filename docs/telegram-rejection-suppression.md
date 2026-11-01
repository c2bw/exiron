# Telegram rejection suppression

The existing Telegram send coordinator remembers definitive send rejections for
**60 seconds** so subsequent operations do not repeatedly start with the same
rejected bot:

- An observed **401** suppresses that token across chats.
- An observed **403** suppresses that token only for the rejected chat.

This policy uses actual `ExGram.Error` response codes, not error-message matching.
It applies to outgoing sends; polling behavior is unchanged. It adds no process,
durable queue, dependency or client option.

## Fallback and recovery

Every sender acquires the existing per-bot coordinator slot before checking the
rejection cache. The rejection is recorded before releasing that slot. Callers
already queued for that bot therefore see the new suppression before making an
HTTP attempt.

During cooldown, the sender is skipped and returns a local rejection with the
original 401/403 code and a fixed suppression message. Ordinary sends can then
use the existing alternate-bot fallback **within the same chat**. Other tokens
remain independent; a chat-scoped 403 does not block another chat for that token.

After the deadline, the next eligible send acts as a probe. The same coordinator
serializes probes and subsequent callers. A new definitive rejection restarts
cooldown before queued callers can attempt it. A successful send clears the
corresponding expired records and counts a confirmed recovery. A probe with an
uncertain result does not confirm recovery or create a new rejection: its expired
records are removed, and later independent operations use normal sending rules.
There is no background probe that generates synthetic Telegram messages.

Edits remain bound to their original token. Multipart continuations and caption
follow-ups also remain bound after the first successful part. A suppressed token
cannot cause these operations to switch bots and duplicate or edit the wrong
message. A blocked part is recorded as rejected without an HTTP attempt in the
existing delivery diagnostics.

Timeouts, transport failures, HTTP 5xx and other uncertain results never create
suppression or trigger alternate-bot fallback. Telegram 429 handling retains its
existing coordinator cooldown/retry policy. Existing response, push, one-shot,
streaming, cancellation, idempotency and SDK APIs remain available. Clients still
need to inspect partial or unknown delivery before choosing an explicit retry.

## Bounds and lifecycle

The cache holds at most **1,000 rejection records**. It stores token digests,
chat IDs, configured bot names, response codes and deadlines; it never retains
credentials, response bodies, message contents or sender functions. When full,
it evicts the record with the earliest retry deadline, so suppression is best
effort under cache-capacity pressure. Expired records can remain ready for a
future probe, within the same fixed record limit.

The cache is in memory. Coordinator restart and the trusted `Hub.configure`
state-reset operation clear records and counters. Normal route reconciliation
keeps records until they are probed or evicted. Rotating a credential produces a
new token digest and is unaffected by an old token's rejection. Membership
updates do not immediately override a send rejection; a retry becomes eligible
after its cooldown.

## Visibility

The authenticated monitor's **Telegram send protection** panel shows:

- Active cooldowns, skipped attempts, probes and confirmed recoveries.
- Up to 50 recent records with public bot name, scope, response code and retry time.
- The last confirmed recovery's bot name and timestamp.

The list uses LiveView streams and refreshes eligibility on the monitor's existing
five-second refresh. No token or digest appears in the panel or snapshots.
Global protection summaries and records are admin-only; hook-scoped API status
keeps its existing shape, so neither SDK requires changes.

Prometheus exports fixed-cardinality global series:

| Metric | Meaning |
| --- | --- |
| `exiron_telegram_suppression_available` | Coordinator snapshot availability |
| `exiron_telegram_suppressions` | Currently active cooldown records |
| `exiron_telegram_suppressed_attempts_total` | Attempts skipped without calling Telegram |
| `exiron_telegram_rejection_probes_total` | Attempts admitted after cooldown expiry |
| `exiron_telegram_recoveries_total` | Expired records cleared by a successful send |

Records, probes and recoveries are counted by scope, not unique bot identity.
Counters reset with cache/coordinator reset. The local monitoring rules alert on
sustained suppressed attempts. The separate byte/count send budgets continue to
apply to logical send operations, including any coordinator wait and fallback.
