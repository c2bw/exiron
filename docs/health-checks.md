# Health endpoints

These public JSON endpoints return no credentials, configuration or message data.
Responses use `Cache-Control: no-store`.

| Endpoint | Success | Failure |
| --- | --- | --- |
| `GET /health/live` | `200 {"status":"alive"}` when the web endpoint responds | An HTTP/connection failure means the endpoint did not answer. It does not call the Hub. |
| `GET /health/ready` | `200 {"status":"ready","reason":"initialized"}` when the enabled Hub has initialized its router and Telegram state | `503` with `status: "not_ready"` and a bounded reason: `disabled`, `boot_failed`, `not_initialized`, or `hub_unavailable`. |

The readiness Hub call has a one-second timeout. Readiness is independent of
queue depth and transient Telegram connectivity; it does not contact Telegram,
verify credentials, require connected downstream clients, or promise delivery.

Use liveness to determine whether the application responds and readiness to
decide whether it has initialized for traffic. A deliberately disabled Hub is
live but not ready. The standard Compose service checks readiness every 30 seconds.
A Docker unhealthy status alone does not automatically restart a container.

For manual checks:

```sh
curl --fail http://127.0.0.1:4000/health/live
curl --fail http://127.0.0.1:4000/health/ready
```

For external checks, use your normal HTTPS URL when SSL enforcement is enabled.

During an operator [drain](graceful-drain.md), readiness returns 503 with reason `draining` until intake resumes. Liveness remains healthy. Keep response and acknowledgement traffic flowing to the draining instance.
