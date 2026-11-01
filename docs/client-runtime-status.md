# Managed client runtime status

Both SDKs expose a local snapshot for managed HTTP and WebSocket clients. Reading
status performs no HTTP request, consumes no messages, renews no lease, and does
not wait for a handler, lifecycle callback, or reconnect sleep. Existing callbacks,
streaming replies, one-shot replies, and shutdown APIs retain their behavior.
No server capability or option is required.

## Go

```go
status := runner.Status()
fmt.Printf("phase=%s connected=%t active=%d batch=%d/%d age=%s\n",
    status.Phase, status.Connected, status.ActiveHandlers,
    status.BatchCompleted, status.BatchSize, status.BatchAge)

if status.Phase == "backing_off" {
    fmt.Printf("retry in %s; last error category=%s\n",
        status.RetryIn, status.LastError.Kind)
}
```

`Runner.Status()` returns an independent `RunnerStatus` value. It is safe to call
concurrently, including from handlers and callbacks. Before the first `Run` its
phase is `idle`; after `Run` returns it is `stopped`. The final snapshot stays
available on that runner, and the next `Run` resets it. `LastError` is a value
containing only `Kind`, optional `HTTPStatus` (zero when absent), and `At`.
Missing times are Go zero times. Durations are `time.Duration` values and use
monotonic time; missing countdowns are zero.

## Elixir

```elixir
case ExironClient.Poller.status(poller_pid) do
  {:ok, status} ->
    Logger.info("client phase=#{status.phase} active=#{status.active_handlers} " <>
      "batch=#{status.batch_completed}/#{status.batch_size}")

  {:error, :not_running} ->
    Logger.info("client process is unavailable")
end
```

`Poller.status/1` accepts the managed process PID for either transport and returns
`{:ok, map}`. The snapshot remains readable while the default HTTP poller executes
a synchronous handler. Each poller owns a small anonymous ETS table, shared with
its handler tasks; there is no additional status process. Owner exit deletes the
table automatically. After exit, or for a PID without a managed-client snapshot,
the API returns `{:error, :not_running}`. Use the existing disconnect callback or
an OTP monitor to retain terminal outcomes outside the poller.

Timestamp fields are Unix milliseconds; elapsed and remaining durations use
monotonic time and have `_ms` suffixes. Missing timestamps/countdowns are `nil`;
`batch_age_ms` is zero outside processing. `last_error`, when present, contains
only `kind`, optional `http_status`, and `at` (Unix milliseconds).

## Fields and interpretation

| Go | Elixir | Meaning |
| --- | --- | --- |
| `Phase` | `phase` | Current activity, described below. |
| `Connected` | `connected?` | Server connection confirmed for this connected stretch; HTTP means a successful poll, WebSocket means the server connected frame. |
| `HandlerTimeout` | `handler_timeout_ms` | Configured per-message budget; zero disables it. |
| `OverdueHandlers` | `overdue_handlers` | Occupied slots past their local budget. |
| `OldestOverdueFor` | `oldest_overdue_ms` | Elapsed time beyond the oldest active overdue deadline. |
| `BatchTimedOut` | `batch_timed_out` | Observed budget expiries in the current/last batch. See [handler deadlines](handler-deadlines.md). |
| `ActiveHandlers` | `active_handlers` | Occupied message-handler slots, including local retries, cancellation checks and handler error callbacks. |
| `BatchSize` | `batch_size` | Number of messages in the most recently started batch. |
| `BatchCompleted` | `batch_completed` | Messages released locally, including work skipped through cooperative cancellation or retained by the opt-in quarantine policy. |
| `BatchQuarantined` | `batch_quarantined` | Successful quarantine insertions in this batch; normally contribute to the completed count. |
| `Quarantine` | `quarantine` | Bounded-store counts, bytes, limits and recovery claims; see [handler quarantine](handler-quarantine.md). |
| `BatchAge` | `batch_age_ms` | Elapsed processing time for the active batch, zero once processing ends. |
| `LastConnectedAt` | `last_connected_at` | Most recent confirmed connection time; preserved through a reconnect wait. |
| `LastError` | `last_error` | Most recent bounded error summary; retained after recovery. |
| `RetryAt`, `RetryIn` | `retry_at`, `retry_in_ms` | Scheduled managed-loop reconnect time and countdown. |
| `DrainStartedAt` | `drain_started_at` | Time a graceful drain began. |
| `DrainDeadline`, `DrainRemaining` | `drain_deadline`, `drain_remaining_ms` | Graceful drain deadline and countdown, when supplied. |

Phases are `connecting`, `polling` (HTTP request in progress), `handling`,
`waiting` (healthy idle or interval wait), `backing_off` (managed reconnect wait),
and `draining`. Go also reports `idle` and `stopped`. Elixir uses atoms with the
same names. Draining takes precedence over handling; counts and age still show
progress while the batch finishes. Concurrent Go drain callers show the earliest
supplied deadline because any caller's deadline can cancel the run.

Retry timing describes the outer managed reconnect loop. It does not expose
individual HTTP library retries or per-message retry sleeps. During those sleeps
the phase remains `polling` or `handling`, respectively. An elapsed retry timer
can show zero while the process resumes or a custom retry wait remains blocked.
A connection timestamp is not a heartbeat or proof that the network is healthy
at the instant of a read.

Batch counters describe local processing, not confirmed Telegram delivery or
server acknowledgement. They reset at the next batch, and do not accumulate a
history. Failed or cancelled processing can leave completed smaller than size.
Snapshots are diagnostic observations; especially in Elixir, counters and phase
can change between field reads. Do not use them to synchronize work or decide
whether replay is safe. Use [graceful shutdown](client-shutdown.md) to wait for
batch retirement.

## Bounded, sanitized output

The snapshot contains no message bodies, request/batch/client IDs, tokens, URLs,
raw exceptions, error messages, response bodies, or stack traces. Unknown errors
become a generic category; arbitrary server error strings and codes are never
copied. Handler failures become `handler_error`, including failures whose nested
reason contains credentials or application data. Known connection categories
include `transport_error`, `hook_already_connected`, and `client_lease_lost`.
There is one last-error summary, not an unbounded event history. Existing error
callbacks still receive their original error values for application handling.

Optional [runtime reporting](client-runtime-reporting.md) makes a bounded subset visible in the server monitor. Reading local status itself still performs no network I/O.
