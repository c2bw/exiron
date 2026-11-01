# Request tracing and monitor filters

Open the authenticated `/monitor` dashboard and use **Request activity**.
Each accepted routed request uses the same request ID (`req_id`) that the client
receives. Select an ID to inspect its timeline:

- Hub receipt, route selection and queueing.
- Delivery to a client, replay after a disconnect, and explicit batch acknowledgement.
- Response submission and send-task start.
- Telegram attempts, rate-limit cooldowns, completion, failure or unknown delivery.
- Expiry, session resets and removal of a destination hook.

Timestamps are measured from Hub acceptance using monotonic elapsed time. Telegram
attempts mean the outbound sender was invoked; successful completion is the
sender's success result. Acknowledgement confirms client batch handling, **not**
that the application produced a response or that Telegram received it. Client
handler failures stay local by default. Opt-in [handler reporting](handler-reporting.md)
adds bounded client observations to the timeline; the Hub cannot inspect handler internals.

The history retains the **500 most recently accepted routed requests**, with
**32 steps per request**. When a long timeline fills, its first three steps and
most recent steps are retained, with an omitted-step count. A busy instance can
evict a trace while its underlying request is still pending. Restart/reconfigure
clears history. This is diagnostic history, not an audit log or delivery queue.

Traces contain request/message/route IDs, hook, chat, bot name, latest client ID,
outcome, delivery count and timings. They omit payload bodies, files and
credentials. They are available to the authenticated dashboard, not added to the
hook-scoped status API. Pushes, listen events, unmatched messages and arrivals
rejected before request admission are outside this request timeline; existing
activity and rejection counters still cover those operations.

Hook and chat dropdowns include configured destinations and retained request history.
Chats display their configured aliases alongside their IDs. These dropdowns and
outcome use exact selections; client ID and request ID remain case-insensitive
substring searches. Selecting “All hooks” or “All chats” removes that filter.
Choices stay frozen with the paused monitor snapshot. Removed selections reset to
“All” when they no longer appear in configuration or retained history.

All retained matches (up to 500) are available in a scrollable list, newest first.
The list supports keyboard scrolling and keeps the visible request in place during
live updates; changing filters returns to the newest match. Other monitor panels
keep their aggregate meaning.

Each row and its detail panel show the UTC arrival timestamp, current age, time
in the current waiting phase, and the remaining expiry time for pending work.
“Last event +…” remains the offset of the latest lifecycle event; it is separate
from age. Age and phase waits use the server's monotonic clock, and countdowns
read the pending request's actual timer. The monitor refreshes these values and
relative time filters every five seconds, even when no lifecycle event occurs.
Completed or otherwise closed requests have no expiry countdown or waiting phase.

The Received dropdown offers the last five minutes, last hour, or all retained
history, based on time since arrival. The retained-history bound still applies.
Pausing freezes ages, countdowns, phase indicators, and the time-range window along
with the captured snapshot. Resuming refreshes them from current state.

Rows receive an informational highlight after a minute waiting for client pickup,
a client response or an explicit retry, or after 15 seconds waiting for Telegram
delivery. Pending requests with 30 seconds or less remaining show “Expiring soon”.
A Telegram wait includes coordinator queueing and cooldowns; it does not prove an
HTTP request is stuck. These display thresholds are troubleshooting hints, not
service guarantees, and do not change deadlines, cancel work, or retry anything.

**Pause live updates** freezes all monitor panels. Filters and request inspection
use a bounded snapshot of the retained traces captured when pausing. **Resume live
updates** reloads current status and trace history; no unbounded notification
backlog is accumulated.

A **send failed** request can remain pending for an explicit response retry;
**failed** denotes a terminal send failure or cancellation. **Delivery unknown**
means the send deadline elapsed: Telegram may have accepted the request. Do not
blindly retry an unknown result unless duplicate messages are acceptable.

## Client handler failure policy

Both official clients default to **one handler attempt** and stop on failure,
leaving the batch unacknowledged. Opt in to 2..10 attempts to retry the failing
message locally, with a default 250 ms delay. Successful siblings earlier in
that batch are not invoked again during those local retries. With the default serial dispatch, later messages are
processed only after that message succeeds. Optional [bounded concurrency](client-concurrency.md)
lets active siblings finish and stops queued dispatch after exhaustion. Exhaustion stops processing and
does not acknowledge or silently discard the batch.

Use `on_handler_error` (Elixir) or `OnHandlerError` (Go) for per-attempt failure
reporting. Reports include request ID, attempt, maximum attempts, retry decision
and the underlying reason. These local callbacks retain application error details. Optional
[handler reporting](handler-reporting.md) sends only fixed categories and attempt
metadata to the server. Protect any logs you write from callback reasons.

Retries can repeat handler side effects; handlers must remain idempotent.
Connection loss, a new client process or restart can still replay already
handled work. By default HTTP polling does not renew its lease while executing a handler;
keep the combined handler/retry duration within the lease, enable optional
[HTTP lease renewal](http-lease-renewal.md), or use WebSocket transport for long handlers. Listen messages remain best effort.

Inspected pending requests also offer [cancellation](request-cancellation.md#monitor-action),
with delivery certainty and confirmed Telegram IDs shown before and after the action.
Resume live updates before cancelling from a paused monitor.

Pending requests also show the [last recipient and observed client contact](client-visibility.md),
including explicit WebSocket disconnects and HTTP leases that expired while work
remains outstanding. Contact evidence does not prove that a handler is executing.
