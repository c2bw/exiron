# Exiron Backend Specification

This document explains how the Exiron backend is organized, how messages move
through the system, and which contracts each backend module is responsible for.
It is intended for maintainers who need to change routing, Telegram polling,
HTTP client behavior, or the dashboard-facing status model.

## Purpose

Exiron is a Phoenix application that connects Telegram chats to HTTP clients.
Telegram messages are matched against configured routes, queued for an
authenticated hook client, and optionally answered back into Telegram. Clients
authenticate with hook tokens and poll for work over HTTP.

The backend has four main jobs:

- Load and validate YAML configuration.
- Poll Telegram and normalize incoming updates into internal messages.
- Route messages to connected HTTP hook clients.
- Expose API and dashboard status endpoints.

## Runtime Supervision

`Exiron.Application` starts the Phoenix endpoint, PubSub, Finch, the hub process,
the Telegram poller supervisor, and the rate-limit cleaner.

The central runtime process is `Exiron.Hub`, a GenServer that owns all mutable
hub state:

- whether the hub is enabled
- loaded router and Telegram configuration
- active polling client leases
- queued messages per hook
- pending routed requests awaiting responses
- recent event snapshots for the dashboard
- recent client lifecycle events for the dashboard and status API
- Telegram polling status

The hub is deliberately stateful because routing and request ownership need to
be serialized. HTTP controllers, Telegram pollers, and dashboard views talk to
the hub through its public functions rather than sharing mutable data directly.

## Configuration Model

Configuration is read from the path configured in `:exiron, :hub, :config_path`.
The default development path is `config/config.yml`.

The YAML document requires `version: "1"` at the top level and has four
conceptual sections:

- `telegram.bots`: Telegram bot tokens and chat aliases.
- `routes`: chat aliases mapped to middleware names and push capability.
- `middlewares`: reusable hook routing rules.
- `hooks`: hook names mapped to SHA-256 token digests (`sha256:<64-hex>`).

`Exiron.Hub.Configuration` parses the full application YAML. Telegram bot
entries also define the chat alias table used by routing, so the parser builds
both the Telegram send/poll configuration and router definitions in one pass.

`Exiron.Hub.Router` validates and compiles the routing subset. It turns aliases,
middlewares, and hooks into route snapshots with stable IDs. Duplicate
hook/chat definitions are merged, and ambiguous prefixes in the same chat are
rejected so routing stays deterministic.

`Exiron.Hub.RouteConfiguration` is a dashboard support module. It keeps the
source YAML and derives denormalized summaries for UI rendering, such as bot
summaries, hook summaries, route counts, middleware usage, and resolved routes.
It also contains narrow YAML editing helpers used by the configuration UI.
`Exiron.Hub.RouteConfiguration.TelegramChatAliases` owns the bot-selection
policy used when those edits add a chat alias, while
`Exiron.Hub.RouteConfiguration.TelegramProjection` builds the corresponding
bot and chat summaries for display.

## Message Model

`Exiron.Hub.Message` is the internal normalized message struct. It is used for
both incoming Telegram content and outgoing Telegram sends.

Supported datatypes are:

- `text`
- `audio`
- `video`
- `image`
- `file`
- `sticker`

Messages carry the service ID, chat ID, optional bot instance, payload data,
Telegram message IDs, reply metadata, sender metadata, sticker emoji metadata,
and a derived `emoji_list` of similar emoji when available.

When a message is sent to an HTTP client, binary payload data is base64 encoded.
When a client responds or pushes a message through the HTTP API, the controller
decodes the base64 payload before handing it to the hub. Sticker responses and
pushes may include `sticker_emoji`, which is preserved in status events and
passed to Telegram as the sticker emoji.

## Telegram Integration

`Exiron.Hub.Telegram` owns Telegram send configuration. It maps chats to default
bot tokens and validates explicitly selected bot instances. Text messages are
sent with Markdown parse mode first; if Telegram rejects Markdown entity parsing,
the send is retried as plain text.

`Exiron.Hub.BotIdentity` resolves Telegram bot metadata, while
`Exiron.Hub.BotMemberships` owns membership lookup results and membership-change
state.

`Exiron.Hub.Telegram.Poller` is a GenServer started once per unique bot token
when Telegram polling is enabled. It owns long-poll scheduling, retry behavior,
and the Telegram update offset. `Exiron.Hub.Telegram.Poller.UpdateProcessor`
normalizes supported update content, downloads Telegram files with `Req`, and
forwards accepted messages to `Exiron.Hub`.

File downloads are bounded by a byte limit. The poller uses a Req streaming
collector so oversized Telegram files can be halted before the full body is
accumulated in memory.

## Routing Flow

Incoming Telegram messages enter the hub through
`Exiron.Hub.incoming_service_message/1`.

For each incoming message, the hub:

1. Records an incoming event for status and dashboard history.
2. Sends listen-style copies to connected clients that requested `listen=true`.
3. Attempts to match the message against the router.
4. If no route matches, leaves state unchanged after the incoming event.
5. If a route matches and the hook is available, creates a pending request.
6. If a route matches and the hook is unavailable, sends a Telegram unavailable
   notice back to the chat.

A hook is available when either:

- a polling client currently has an active lease for that hook, or
- the hook has already claimed a pending request and has not responded yet.

The second rule lets a slow worker keep replying after its short polling lease
expires. It also prevents new routed work from immediately bouncing while a
worker still owns outstanding work.

## Managed Clients and Leases

Managed clients connect with `GET /api/socket` by default or poll with
`GET /api/requests` as an HTTP fallback. Both paths use a bearer hook token and
the required `client_id` query parameter to identify the client instance holding
the hook lease.

`Exiron.Hub.ClientSessions` coordinates client lifecycle, while
`Exiron.Hub.ClientState` owns session records and
`Exiron.Hub.ClientDeliveries` owns queued batch, acknowledgement, and requeue
behavior.

Each hook token allows one active managed client at a time across websocket and
HTTP polling transports:

- the same `client_id` may reconnect, replace its previous socket, or renew the
  polling lease
- a different `client_id` receives `409 hook already connected`
- the error includes `retry_after_ms` when the server can estimate when the
  active connection will clear

Websocket clients receive raw JSON frames:

- `{"type":"connected","hook":"assistant","client_id":"...","listen":true,"server_version":"..."}`
- `{"type":"messages","delivery_id":"...","messages":[...]}`
- `{"type":"ack","delivery_id":"..."}` from the client after successful handling
- `{"type":"error","error":"hook already connected","retry_after_ms":3000}`
- `{"type":"pong"}` in response to client `{"type":"ping"}`

Message arrays use the same item shape as `/api/requests`. Draining queued
items marks routed request items as claimed in the hub state. The hub retains
routed items until the client acknowledges the delivery ID. If the connection
ends first, those requests return to the front of the queue and become
unclaimed. Listen items are lossy and are not requeued.

The official HTTP pollers use `delivery_mode=explicit`. The response includes a
`delivery_id`, and the next poll sends it as `delivery_ack` only after every
handler in the batch succeeds. An unacknowledged batch is returned again.

The default HTTP polling lease timeout is three seconds and can be configured
with `EXIRON_CLIENT_TIMEOUT_MS`. Websocket clients stay connected until the
socket terminates or is replaced.

The hub records client lifecycle events when a managed client first establishes
an active connection and when that connection clears. Repeated polls or
same-client reconnects do not add duplicate connect events. Lifecycle events
include the hook name, client ID, listen mode, action, and timestamp.

## Pending Requests and Responses

When a routed message is assigned to a hook, the hub creates a pending request
with:

- generated request ID
- original Telegram address
- destination hook
- expiry timer
- claimed flag

Pending requests expire after ten minutes. Expiry removes the pending record but
does not send a Telegram notification.

The hub also applies in-memory safety caps:

- `EXIRON_MAX_PENDING` limits total pending routed requests.
- `EXIRON_MAX_QUEUE_PER_HOOK` limits queued messages for each hook.
- `EXIRON_MAX_QUEUE_BYTES_PER_HOOK` limits encoded queued payload bytes for each
  hook.
- `EXIRON_MAX_IN_FLIGHT_SENDS` limits Telegram sends currently awaiting a
  delivery result.
- `EXIRON_SEND_TIMEOUT_MS` limits how long response and push callers wait for a
  Telegram delivery result. When this timeout is reached, the caller learns that
  the delivery result is unknown, the supervised send task is terminated, and
  its in-flight capacity is reclaimed. Telegram may already have accepted the
  send before termination, so callers must still treat delivery as unknown.

When a routed request would exceed a cap, Exiron rejects the newest request,
sends an overload notice back to Telegram, records an overload event, and leaves
existing queued or pending work intact. Listen queues are lossy by design: when
they exceed hook count or byte caps, Exiron drops oldest listen messages so
listeners stay near real time.

Messages handed to a managed client remain charged against the hook count and
byte caps until that client acknowledges the delivery batch. Only one batch is
in flight per client. Routed delivery is therefore at least once: reconnects
can repeat work when handling succeeded but its acknowledgement was lost, so
handlers should be idempotent. Listen delivery remains lossy by design.

Clients respond with `POST /api/responses`, including:

- bearer hook token
- `req_id`
- `datatype`
- base64 `data`
- optional `sticker_emoji` for sticker payloads

The hub validates that the request exists and belongs to the authenticated hook.
It then sends the response through the configured Telegram bot, cancels the
expiry timer, removes the pending request, records an outgoing event, and
broadcasts updated status.

If the caller receives `504 telegram delivery result timed out`, the hub
terminates the local Telegram send task. Telegram may already have accepted the
request before cancellation, so clients must treat delivery as unknown.
Retrying the same response can create a duplicate Telegram message.

## Push Flow

Clients can push new messages with `POST /api/push`. Pushes are only allowed to
Telegram chats that are routed to the authenticated hook and marked `push: true`
in configuration.

If no `chat_id` is supplied, the hub sends to every push-enabled chat for that
hook. If `chat_id` is supplied, it must be an integer and must be one of the
push-enabled targets.

The response includes the number of messages successfully sent.

If a push returns `504 telegram delivery result timed out`, delivery is also
unknown. The push may still complete after the client receives the timeout, so
blind retries can duplicate Telegram messages.

## HTTP API Contracts

`ExironWeb.ExironController` exposes the backend API:

- `GET /api/status`: returns status scoped to the authenticated hook, including
  only that hook's routes, chats, pending count, message and overload history,
  memberships, failures, and client lifecycle history. Dashboard status remains
  global and is not exposed to hook tokens.
- `POST /api/auth`: validates a hook token from the body or bearer header.
- `GET /api/socket`: opens a raw JSON websocket for managed clients.
- `GET /api/requests`: polls queued requests and renews the client lease.
- `POST /api/responses`: answers a pending routed request.
- `POST /api/push`: sends a new message to push-enabled Telegram chats.

Errors are rendered as JSON with an `error` field. Expected domain errors map to
specific HTTP statuses, while unexpected downstream errors are logged and
returned as `500 internal error`.

## Dashboard Status

Hub status is broadcast on the PubSub topic `hub:status` whenever state changes
in a way the dashboard should display.

`Exiron.Hub.Status` composes global and hook-scoped payloads, while
`Exiron.Hub.Status.Telegram` projects Telegram poller health and per-chat state.

The status snapshot includes:

- enabled flag
- version
- Telegram polling state
- last poll timestamp
- pending request count
- hook connectivity, listening state, and queued count
- route snapshots
- recent message events
- recent client lifecycle events

The global `telegram_polling` flag is true only while polling is enabled and
all configured bot pollers are active. Each chat's polling flag applies the
same rule to the bots configured for that chat. Terminal authorization failures
and poller process exits turn the affected status false; a replacement poller
turns it true again when polling starts.

Message events and client lifecycle events are newest first and capped at 100
entries each. Image message events include a browser-renderable data URL when
the payload has a recognized image signature. `Exiron.Hub.EventImage` validates
those signatures and enforces the per-preview and total history byte budgets.
Client lifecycle events are recorded for real connect/disconnect transitions,
not every heartbeat renewal.

`ExironWeb.MonitorLive` derives per-chat stream-name atoms from configured
Telegram chat IDs. This is an accepted use of dynamic atoms because the input is
the bounded, administrator-controlled chat configuration, not untrusted or
unbounded request data. It is therefore not considered an atom-exhaustion risk
under the configuration model. If chat IDs ever become an unbounded runtime
input, the stream representation must be changed before relaxing this
invariant.

## Managed Client Lifecycle

The official managed clients expose local lifecycle callbacks from their
polling loops:

- Elixir `ExironClient.Poller` accepts `:on_connect` and `:on_disconnect`.
- Go `Client.NewRunner` accepts `OnConnect` and `OnDisconnect`.

Connect callbacks run after the first successful poll in a connected stretch.
Disconnect callbacks run when a previously connected poller/runner stops
maintaining the lease, including request errors, handler errors, context
cancellation, or process termination. Managed clients target a local disconnect
within two seconds of the previous healthy poll when the server cannot be
reached. The disconnect callback receives the stop reason. These callbacks
describe the managed client's local polling health; the server's authoritative
disconnect event is still emitted when the lease expires.

## Rate Limiting

`ExironWeb.Plugs.RateLimit` applies sliding-window identity rate limiting using ETS.
`ExironWeb.Plugs.RateLimit.Cleaner` creates the ETS table and periodically
removes stale entries.

The authentication endpoint is strictly rate limited to protect hook token
guessing. Bearer API endpoints receive an independent budget of 1200 requests
per minute per hashed token, so unrelated clients behind one IP do not interfere
with each other. A coarse 60000-request-per-minute IP ceiling limits callers that
rotate arbitrary tokens. Raw bearer credentials are never stored in ETS. When a
limit is exceeded, the API returns `429` with a `retry-after` header and a JSON
error body.

## Testing Expectations

Run the complete project gate before committing:

```sh
mix precommit
```

Backend behavior is covered by:

- `test/exiron/hub/*`: configuration, router, hub, Telegram, and poller behavior.
- `test/exiron_web/controllers/*`: API contracts and dashboard-protected routes.
- `test/exiron_web/plugs/*`: rate limiting.

Tests that interact with GenServers should prefer `start_supervised!/1`,
monitoring, or `:sys.get_state/1` synchronization over sleeps. Controller and
LiveView tests should assert against stable elements or response contracts
rather than incidental HTML.

## Change Guidelines

When changing backend behavior:

- Keep routing decisions inside `Exiron.Hub.Router`.
- Keep mutable runtime ownership inside `Exiron.Hub`.
- Keep Telegram API normalization inside `Exiron.Hub.Telegram.Poller`.
- Keep HTTP status and JSON error mapping inside `ExironWeb.ExironController`.
- Use `Req` for HTTP calls.
- Preserve base64 encoding at the HTTP boundary for binary payloads.
- Add comments only when they explain a domain rule, state transition, or data
  shape that is not obvious from function names.
