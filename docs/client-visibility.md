# Client contact and outstanding work

Protocol 1.9 advertises `client_presence`. The monitor shows each hook's current
or last client ID, transport/session state, last identified contact, and counts
of requests awaiting that client's response or being sent to Telegram. Request
rows and details show the last recipient's connection state while work is pending.

These are observations of contact and delivery, **not proof that an application
handler is currently executing**. No new heartbeat endpoint, lease renewal rule,
or handler retry behavior is introduced. One-shot and streamed replies keep their
existing behavior.

## Client SDK versions

Protocol 1.19 advertises `client_versions`. Overview, Monitor and Hook Workspace
show the SDK and its package version, for example **Go SDK · 0.1.0**. Both included
SDKs automatically send their package identity with HTTP requests and WebSocket
handshakes; runtime reporting does not need to be enabled. Update and restart
existing workers to begin reporting. SDK versions are separate from the wire
protocol version; see [compatibility](compatibility.md).

Custom clients can send `x-exiron-sdk: go` or `elixir` together with
`x-exiron-sdk-version: 0.1.0` on `/api/requests` and `/api/ws`. The version must be
a valid SemVer string of at most 64 bytes. Missing, duplicate or invalid identity
headers are ignored; older clients continue working and show **Version not
reported**. These optional headers are also safe to send to older servers.

The authenticated status API exposes nullable `client_sdk` and `client_version`
fields on each hook's `client` object. The Go SDK exposes them as `ClientSDK` and
`ClientVersion`; the Elixir SDK retains them in the status map. Identity is
self-reported display metadata, never an authorization or compatibility check.
The last observed version remains visible after a lease expires or a socket
closes, alongside its inactive connection state. A replacement session uses its
own report; versions are not inferred from a previous client.

## Reading the states

| State | Meaning |
| --- | --- |
| HTTP poll lease active | The hook has a registered HTTP polling lease. |
| No recent HTTP poll | That client's poll lease expired. An HTTP handler can legitimately stop polling while processing a request; this is not proof of disconnection. |
| WebSocket connected | That client has a registered socket session. This alone does not prove that its handler is progressing. |
| WebSocket disconnected | The registered socket was closed, replaced or removed. Pending request rows are highlighted when they are waiting on a disconnected socket recipient. |
| Another client is connected | The pending request's last recipient differs from the client currently registered for the hook. The new client is not automatically credited with the old client's claimed work. |
| Not yet delivered to a client | The pending request has no recorded recipient yet. |
| No client contact recorded | No client identity has been observed for this hook. |

The existing green **Available** hook badge refers to admission availability.
A hook with claimed requests can remain available after its HTTP lease expires;
its separate client state explains that no recent poll was observed. This feature
does not change that delivery behavior or assume a stale worker is dead.

“Awaiting response” counts claimed requests assigned to that client and not
currently being sent to Telegram. It includes work a client may have queued
internally, slow handlers and abandoned work. “Sending” counts assigned requests
with a response operation in progress. Work assigned to a different or unknown
recipient is reported separately. Unclaimed queued work remains in the backlog.
Explicit-acknowledgement redelivery updates the recorded recipient when another
client receives the request; legacy destructive polling keeps its existing limits.

## Last identified contact

Successful HTTP polls, WebSocket connects, valid batch acknowledgements, and
application-level WebSocket `ping` frames update contact time. Pings and
acknowledgements must match the currently registered socket ID and process;
stale sockets cannot revive an old session. The existing pong frame is unchanged.

An HTTP response authenticated with a hook token does not identify a particular
client instance, so it is not attributed as contact from the last recipient.
Response progress remains visible in request timing and delivery details. Native
WebSocket control frames are not recorded as application-level pings.

The monitor refreshes contact details every five seconds and freezes them while
paused. Idle polls and pings update their observation without broadcasting a full
status update on every contact. Times are displayed in UTC.

There is one credential-free observation per configured hook, not an unbounded
history of client IDs. It survives lease expiry or socket removal until another
client contacts the hook, the hook is removed, or Hub state resets. After a client
is replaced, old per-client contact timestamps may no longer be retained; a pending
request still keeps its last recipient identity and transport. No bodies, bot
credentials, hook tokens, process IDs or monitor references are exposed.

## Status API and included clients

Authenticated `/api/status` responses include an optional `client` object on each
hook. The API remains scoped to the caller's own hook:

```json
{
  "client_id": "worker",
  "client_sdk": "go",
  "client_version": "0.1.0",
  "current_client_id": null,
  "transport": "http",
  "state": "http_lease_expired",
  "last_contact_at": "2026-10-27T12:00:00Z",
  "last_contact_kind": "poll",
  "disconnected_at": "2026-10-27T12:00:03Z",
  "awaiting_response": 1,
  "sending_requests": 0,
  "other_assigned_requests": 0
}
```

The Go SDK exposes `HookStatus.Client` as an optional `*HookClientPresence`, with
UTC times decoded as `*time.Time`. It stays nil when older servers omit the field.
The Elixir SDK preserves the `client` object in its status map. Neither client
needs a new option or changes to polling, handler execution, streaming or replies.

Opt-in [HTTP lease renewal](http-lease-renewal.md) records `lease_renewal` contact while a batch runs, without consuming or acknowledging work.

Optional [client runtime reporting](client-runtime-reporting.md) displays self-reported handler, overdue and quarantine gauges alongside these server observations. It uses a separate receipt timestamp and never renews a lease or changes last-contact observations.
