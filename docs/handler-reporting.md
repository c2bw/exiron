# Client handler failure visibility

Protocol 1.12 advertises `handler_failure_reporting`. Both managed clients can
opt in to reporting failed attempts and recovery to the request activity monitor.
Reporting is disabled by default. Existing handler signatures, local error
callbacks, retry limits, acknowledgements, one-shot replies and streaming remain
available with the same behavior.

## Enable reporting

Go:

```go
runner := client.NewRunner(exiron.RunnerOptions{
    ReportHandlerFailures: true,
    HandlerMaxAttempts: 3,
    Handler: handler,
    OnHandlerError: onLocalFailure,
})
err := runner.Run(ctx)
```

Elixir (HTTP and WebSocket):

```elixir
{ExironClient.Poller,
 client: client,
 handler: handler,
 handler_max_attempts: 3,
 report_handler_failures: true,
 on_handler_error: on_local_failure}
```

Deploy the server first. Opted-in clients check its capability before consuming
work and fail clearly if it is unsupported. Both clients share one
[capability discovery](capability-discovery.md) lookup across enabled features.
No capability lookup or report traffic is added when no feature requires it.

## What appears in the monitor

A routed request can show **Handler retrying**, **Handler retries exhausted**, or
**Handler recovered**, with its attempt and retry limit. Retrying and exhausted
states are available in the Outcome filter as the last handler report, even
after a disconnect requeues delivery or a reply completes. Selecting a request shows the latest
client report and timeline steps. Reports remain frozen with a paused request
activity snapshot. An exhausted pending handler is highlighted immediately.

Failure reports use only these fixed categories:

| Category | Meaning |
| --- | --- |
| `handler_error` | A handler returned an application failure. |
| `client_error` | A handler returned a normalized Exiron SDK error. |
| `exception` | The Elixir handler raised an exception. Go panic handling is unchanged; panics are not converted to reports. |

Reports contain no application error messages, exception names, stack traces,
request bodies, reply content, or credentials. Existing local callbacks still
receive their original error details; protect any logs written by those callbacks.
Successful first attempts send no report. A successful local retry sends a
recovery report. Listen messages are excluded. Confirmed cooperative cancellation
and expiry use their existing terminal handling and do not become handler failures.

A report is an observation from the client, not proof of current computation or
successful Telegram delivery. Under the default stop-on-failure policy, an exhausted handler leaves its batch
unacknowledged. The optional [quarantine policy](handler-quarantine.md) can instead
retain that failed message locally and let remaining work finish before acknowledgement. Requests still expire normally,
and other delivery and cancellation rules still apply. Late reports cannot reopen
terminal request outcomes; a completed reply can coexist with a later handler
failure if the application failed after sending its response.

## Failure and retention behavior

Reports are synchronous best effort. Go bounds each managed report with a
one-second context deadline; Elixir uses short HTTP connection, pool and response
timeouts. Report calls are not retried, and any error is ignored by the managed
handler loop. Reporting therefore adds bounded latency around failed attempts
and recovery, but does not change the chosen retry count or original failure
result. User-configured HTTP adapters must honor their timeout/context contracts.
For long HTTP handlers, the existing three-second client lease remains relevant;
enable optional [HTTP lease renewal](http-lease-renewal.md) or use WebSocket delivery
when processing can outlast it.

Reports neither renew that lease nor acknowledge a batch. HTTP lease expiry,
client takeover, network failures, rate limits or trace eviction can prevent a
report from being recorded. Missing reports do not mean the handler succeeded.
The endpoint shares API rate limits; defaults add no report traffic.

Diagnostics live in the existing 500-request / 32-step trace history. Duplicate
and older attempts within the same retained batch are ignored. A new batch can
begin a fresh sequence. This is bounded, in-memory diagnostic history; restart
loss and replay semantics remain unchanged. It is not an audit log.

## Endpoint

`POST /api/handler-reports` authenticates with the hook bearer token:

```json
{
  "req_id": "req-1",
  "client_id": "worker",
  "delivery_id": "delivery-1",
  "attempt": 1,
  "max_attempts": 3,
  "state": "retrying",
  "category": "handler_error"
}
```

`attempt` and `max_attempts` are 1–10, with `attempt <= max_attempts`. `retrying`
requires attempts remaining; `exhausted` requires the last attempt. `recovered`
requires attempt 2 or later and omits `category`. Unknown fields and categories
are rejected. IDs are limited to 128 bytes. Reports must match the hook, current
client ID, and a retained explicit delivery batch containing the routed request.
A hook token cannot report another hook's requests or batches.

Success (including ignored duplicate/older attempts) returns `{"ok":true}`.
Invalid reports return 400, missing traces 404, and mismatched ownership or stale
batches 409. Acknowledged batches cannot submit further reports. The server does
not create traces for evicted IDs or change queue, pending-request or send state.
