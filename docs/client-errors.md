# Client error classification

Use `exiron.ClassifyError(err)` in Go or `ExironClient.Error.classify(error)` in
Elixir for a closed category. Existing errors, message/body fields, codes and
causes remain unchanged. Go supports wrapped errors; neither SDK parses error
message text to infer a timeout.

| Category | Meaning | Action |
| --- | --- | --- |
| `transport_timeout` | The API transport/request budget timed out. | A mutation may have been accepted. Inspect diagnostics or replay a known idempotent operation; do not blindly resend. |
| `handler_deadline_exceeded` | Local managed handler execution budget expired. | Let active work stop; unfinished work is not acknowledged or quarantined. |
| `request_cancelled` / `request_expired` | Server-side terminal control signal. | Stop producing replies. |
| `client_lease_lost` | Delivery ownership could not be confirmed. | Stop dispatch and leave unfinished work unacknowledged. |
| `transport_error` | Other transport failure. | Reads may be retried by the SDK's existing bounded policy; mutations are not automatically retried. |
| `client_error` | Other normalized API error. | Inspect existing code/classifier and sanitized delivery diagnostics. |

The existing Telegram delivery-timeout predicate remains separate: it describes
an uncertain downstream send, not an API transport timeout. Generic transport
timeouts also exclude local handler budgets even though Go handler deadlines
match `context.DeadlineExceeded` through `errors.Is`.

Go adds `IsTransportTimeout`, `IsHandlerDeadlineExceeded` and `IsRequestExpired`.
Elixir adds `transport_timeout?/1` and `request_expired?/1` alongside its existing
deadline/cancellation/lease predicates. `ClassifyError` also recognizes Go's
server-cancellation sentinels. A plain `context.Canceled` is caller cancellation,
not proof of a server-side terminal request; use `context.Cause` in handlers.

Classification is not a general retry decision. The method, ownership, delivery
certainty, idempotency receipt and earlier side effects still determine recovery.
Safe summaries report categories without raw message/body data.
