# Go and Elixir client reference

Both SDKs retain HTTP/WebSocket, one-shot and streamed replies, rich messages,
media, callbacks, pushes and explicit recovery. These are **SDK defaults**; the
[reference workers](managed-worker-examples.md) deliberately enable extra controls.

## Lifecycle options

| Control | Go | Elixir | Default / prerequisite |
| --- | --- | --- | --- |
| Transport | `Config.Transport` | `transport:` | WebSocket; HTTP supported. |
| Poll interval | `PollInterval` | `interval_ms:` | 1 second. |
| Disconnect target | `DisconnectTimeout` | `disconnect_timeout_ms:` | 2 seconds. |
| Parallel messages | `HandlerConcurrency` | `handler_concurrency:` | 1; range 1–64 within a batch. |
| Conversation ordering | `HandlerOrderByChat` | `handler_order_by_chat:` | Off; optional service/chat/topic order within a batch. |
| Handler attempts | `HandlerMaxAttempts` | `handler_max_attempts:` | 1; range 1–10. More attempts require repeatable application operations. |
| Handler retry delay | `HandlerRetryDelay` | `handler_retry_delay_ms:` | 250 ms. |
| Execution budget | `HandlerTimeout` | `handler_timeout_ms:` | 0, disabled; cooperative expiry. |
| Failure policy | `HandlerFailurePolicy` | `handler_failure_policy:` | Stop; quarantine requires an explicit live store. |
| Quarantine limits | `QuarantineOptions` | `Quarantine` options | Explicit store defaults: 100 messages / 8 MiB encoded payloads, in memory. |
| Server cancellation | `CooperativeCancellation` | `cooperative_cancellation:` | Off; capability `cooperative_cancellation`. |
| Cancellation interval | `CancellationInterval` | `cancellation_interval_ms:` | 1 second; minimum 100 ms. |
| HTTP lease renewal | `HTTPLeaseRenewal` | `http_lease_renewal:` | Off; HTTP and capability `http_lease_renewal`. |
| Graceful shutdown | `GracefulShutdown` | `graceful_shutdown:` | Off; capability `client_retirement`; also enables HTTP lease renewal for HTTP. |
| Handler failure reports | `ReportHandlerFailures` | `report_handler_failures:` | Off; capability `handler_failure_reporting`. |
| Runtime reports | `RuntimeReporting` | `runtime_reporting:` | Off; capability `client_runtime_reporting`. |
| API observations | `Config.OnRequest` | Client `on_request:` | Off; local callback, no capability or added network traffic. |

Go timings use `time.Duration`; Elixir timings use milliseconds. Go zero-valued
concurrency/attempt options select defaults; Elixir explicit values must satisfy
its ranges. Local options are validated before managed startup negotiates required capabilities.
Unsupported opt-ins fail before consuming work. Ordinary constructors make no HTTP calls.

## Replies, limits and retries

| Concern | Behavior |
| --- | --- |
| One-shot text | Go `ReplyText`; Elixir `reply_text/3`. |
| Streamed text | Go `StreamText`; Elixir `stream_text/4`. Separate explicit choice; default update interval 500 ms. |
| Partial update | Go `UpdateText`; Elixir `update_text/4`. |
| Request body limit | 51 MiB including JSON/base64 overhead. |
| Response/frame limit | 128 MiB. |
| Safe request retry backoff | Starts at 250 ms, caps at 30 seconds, with a 30-second retry budget; respects retry hints. |
| Mutation retries | Responses, pushes, edits, retirement and other mutations are not automatically retried. |
| Idempotency | Optional keys use dedicated routes. Reuse the original key and exact operation to replay a retained result; no unkeyed fallback. |

See [payload limits](payload-limits.md), [rich messages](rich-messages.md),
[idempotency](idempotency.md) and [reconnection](client-reconnection.md). An explicit
managed HTTP delivery poll can be retried safely; ordinary destructive polling
cannot. Retry budgets do not impose per-attempt transport timeouts: configure the
Go HTTP client/context or Elixir Req options separately. WebSocket loss before acknowledgement can replay the batch and application
side effects. Neither transport provides exactly-once application execution.

## Error handling and recovery

Use Go `ClassifyError` / `SummarizeError`, or Elixir `Error.classify/1` /
`Error.summary/1`, for control categories and bounded log metadata. Original raw
errors remain available; their messages/bodies may contain application data.
See [safe diagnostics](client-diagnostics.md) and [classification](client-errors.md).

1. **Transport timeout or uncertain Telegram result:** inspect delivery diagnostics.
   Do not blindly resend a mutation. Replay a known keyed operation only when its
   original key and payload are available.
2. **Handler deadline:** stop cooperatively. An overdue slot remains occupied
   until its handler exits; unfinished work is not acknowledged or quarantined.
3. **Server cancellation/expiry:** stop replying. Elixir streams check the managed
   token before enumeration, yielded updates and finalization; Go streams check
   their context. Arbitrary producers that never yield cannot be interrupted.
4. **Lost lease:** stop dispatch and leave unfinished work unacknowledged. Runtime
   reporting does not renew a lease or establish ownership.
5. **Quarantine:** review earlier side effects, then explicitly recover or resolve.
   Reuse the store across replacement runs. Process/store restart loses entries.

## Instrumentation

Go `Config.OnRequest` and Elixir client `on_request:` receive method, sanitized
route, total duration, attempts, last HTTP status and error category. Query values,
credentials, IDs and bodies are excluded. Delivery lookup routes use a template.
Callbacks are synchronous, may run concurrently, and must return promptly through
a concurrency-safe sink; callback failures are isolated. See the
[instrumentation guide](client-instrumentation.md). These are API observations,
not Telegram delivery receipts or handler end-to-end timings.

## Ownership and shutdown

Managed runs own one batch at a time and bound parallel messages within it.
Transport adapters retain their own acknowledgement/connection behavior. Elixir's
ordinary HTTP loop executes handlers synchronously; graceful HTTP uses its owned
worker and poll task. WebSocket retains worker, heartbeat and read backpressure.

Call drain outside handlers. It waits for work and confirmed retirement before
stopping and preserves a separately owned quarantine. Join Go handlers before
starting a replacement; uncooperative code can delay exit. Elixir drain timeout
terminates owned work but cannot undo external side effects or application-owned
processes. See [client shutdown](client-shutdown.md).

The interactive Elixir example does not install OS shutdown handlers. Production
OTP applications should coordinate draining before supervisor shutdown. Server
maintenance is separate: the [release helper](graceful-drain.md) drains the server
and verifies a new application boot and Hub readiness. Public HTTP routing and
Telegram reachability require separate checks.

## Runnable examples and checks

Both workers preserve `EXIRON_REPLY_MODE=one-shot|stream` and
`EXIRON_TRANSPORT=http|websocket`. Optional `EXIRON_OBSERVE_REQUESTS=true` enables
safe API completion logs, disabled by default. Go help and loading the Elixir
module do not connect or send anything. See the [worker guide](managed-worker-examples.md).

[Shared lifecycle scenarios](../clients/contract/lifecycle/README.md) exercise
both SDKs/transports. `mix precommit` validates the server and both clients. The
[isolated release smoke](graceful-drain.md#automated-isolated-smoke-check) runs
locally or in Linux CI without Telegram traffic.

## Response feedback

Go `WithFeedback` / `ParseFeedback` and Elixir
`ExironClient.Feedback.keyboard/1` / `from_message/1` add optional ratings through
existing keyboards and callbacks. They preserve ordinary buttons and do not
change reply mode or transport. See [response feedback](response-feedback.md).

Follow-up requests optionally expose Go `Message.FollowupReqID` / Elixir
`Message.followup_req_id` (capability `followup_context`, protocol 1.18). The link
is to the immediate previous request, and never replaces the new request ID.
