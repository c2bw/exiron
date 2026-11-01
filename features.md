# Exiron Features

## Overview

Exiron is a Phoenix-based message control plane that connects Telegram chats to
external HTTP clients. Telegram messages are normalized, matched against
configured command routes, delivered to an authenticated hook client, and can
then be answered back into Telegram. Hook clients can also listen to ambient
chat traffic or proactively push messages to approved chats.

The project includes:

- A Telegram long-polling and sending backend.
- Configurable chat, middleware, command-prefix, hook, and bot routing.
- Managed client delivery over raw JSON WebSockets or HTTP polling.
- A password-protected, real-time operations dashboard.
- An in-browser YAML configuration workspace and route simulator.
- Official Elixir and Go client libraries.
- OpenAPI documentation and a shared, versioned protocol contract.
- Queue, timeout, rate-limit, media, and concurrency protections.
- Release and Docker deployment support.

Exiron keeps its live routing state in memory rather than in a database. This
makes the hub responsive and keeps deployment simple, but queued and pending
work is not durable across a process or application restart.

## End-to-end message flow

For a typical routed request, Exiron performs the following work:

1. A configured Telegram bot receives a message through long polling.
2. Exiron normalizes the update and records it in recent activity history.
3. Any eligible hook client in listen mode receives an ambient copy.
4. Text is matched against the configured routes for that Telegram chat.
5. A matching message is queued for the destination hook if that hook is
   available.
6. The client receives the request over WebSocket or HTTP and handles it.
7. The client may submit a response using the request ID.
8. Exiron sends the response to the original Telegram chat with the appropriate
   bot and records the result.

If a route matches while its hook is unavailable, Exiron sends a
`Hook <name> is not connected.` notice to the originating chat. If the hook is
overloaded, Exiron preserves existing work, rejects the newest request, sends an
overload notice, and records an overload event for diagnostics.

## YAML configuration

Exiron uses a single YAML file, `config/config.yml` by default. The path can be
changed with `EXIRON_CONFIG`.

The configuration supports schema versions `"1"` and `"2"` and has four primary
sections. Schema 2 adds optional Telegram user access lists; see
[chat interactions](docs/chat-interactions.md#user-access-and-administrators).

- `telegram.bots` defines Telegram tokens, optional bot names, and the chat
  aliases each bot can access.
- `routes` enables middleware groups for each chat alias and controls whether
  the route can receive client-initiated pushes.
- `middlewares` maps reusable groups of command prefixes to hooks.
- `hooks` maps hook names to SHA-256 digests (`sha256:<64-hex>`) of their
  authentication tokens. Saving a hook via the `/config` UI automatically hashes
  plaintext tokens.

Example:

```yaml
version: "1"

telegram:
  bots:
    - name: assistant-bot
      token: "123:telegram-token"
      chats:
        family: -1001234567890

routes:
  family:
    middleware:
      - shared
    push: true
    default_bot: assistant-bot

middlewares:
  shared:
    routes:
      assistant:
        messages:
          - /ask
        passthrough: true

hooks:
  assistant: "sha256:6adeb00440a35c63b5ec5ddcbcfb6d4d3ccd15e2e9c3fd91977aaf4d8fa2e024"
```

### Multiple bots and chats

- Multiple Telegram bots can be configured.
- One bot can serve multiple chats, and a chat can be reachable through more
  than one configured bot.
- Human-readable aliases keep Telegram chat IDs out of routing definitions.
- Bot names are optional. When polling or identity lookups are enabled, Exiron
  can resolve an unnamed bot's Telegram username through `getMe`.
- Client messages expose the configured or resolved bot name as `instance`;
  Telegram bot tokens are not exposed to clients.
- A route can name a `default_bot` for its chat.
- Push calls can explicitly select a bot configured for that chat with the
  `bot` field; an unknown selection is rejected.
- Responses prefer the bot that received the original Telegram message, then
  apply the configured name/default selection rules if that bot is no longer
  available.
- When an outbound bot receives a Telegram `401` or `403`, Exiron can try other
  configured bots for the same chat before reporting failure.

### Middleware and route reuse

Middleware groups let several chats reuse the same hook and command-prefix
rules. A chat route can enable multiple middleware groups, and one middleware
can route different prefixes to different hooks.

During compilation, Exiron:

- Resolves aliases to integer Telegram chat IDs.
- Verifies that referenced middleware and hooks exist.
- Requires hook names and tokens to be non-empty.
- Requires hook tokens to be unique.
- Requires a bot name to identify only one token within a given chat.
- Rejects a chat alias that resolves to conflicting Telegram IDs.
- Merges duplicate definitions for the same chat and hook.
- Removes duplicate prefixes and checks field types.
- Assigns stable IDs to the effective routes.
- Rejects a prefix that points to different hooks in the same chat.

### Command matching

- Routing applies to text messages.
- Prefixes match complete commands: `/ask` matches `/ask` and `/ask hello`, but
  does not match `/asking`.
- The longest matching prefix wins.
- Telegram group commands addressed to a bot are normalized before matching, so
  `/ask@assistant_bot hello` can match a configured `/ask` prefix.
- When `passthrough: true` is enabled on a middleware route, Exiron strips the
  matched command prefix and leading whitespace and substitutes it with `/`, so
  `/chess board` is delivered to the hook as `/board`.
- The same prefix can route differently in different chats.
- Messages with no matching route are still visible in activity history and may
  still be delivered to listen-mode clients.

## Telegram integration

### Long polling

- Exiron starts one supervised poller per unique Telegram bot token.
- Pollers use Telegram long polling with a 25-second server timeout.
- Only `message` and `my_chat_member` updates are requested.
- Each poller tracks its update offset so processed updates are acknowledged in
  order.
- Failed transient media processing leaves the failed update unacknowledged and
  retries it after a delay.
- Poll transport failures are retried.
- Poller starts, stops, authorization failures, and process exits update the
  dashboard's global and per-chat polling health.
- Telegram polling can be disabled independently with
  `EXIRON_TELEGRAM_POLLERS_ENABLED`.

### Incoming message types

Exiron recognizes:

- Text messages.
- Captions when no supported media payload is selected.
- Audio and voice messages.
- Video and video-note messages.
- Photos, using the largest photo size supplied by Telegram.
- Documents and animations.
- Stickers, downloaded as file payloads with sticker ID and emoji metadata.

Incoming messages preserve useful Telegram context:

- Chat and service IDs.
- Bot instance name.
- Telegram message ID.
- Replied-to message ID.
- Sender ID, bot flag, first and last name, username, and language code.
- Sticker file ID and sticker emoji when present.
- A derived list of related emoji for known sticker emoji groups.

Binary files are downloaded with streaming size enforcement. The default
download ceiling is 50 MiB, and oversized downloads are halted before the whole
body is accumulated in memory. Duplicate incoming Telegram messages are
suppressed using recent `(service, chat, message ID)` keys.

### Outgoing message types

Responses and pushes support:

- `text`
- `audio`
- `video`
- `image`
- `file`
- `sticker`

Text is first sent with Telegram Markdown parsing enabled. If Telegram reports
an entity-parsing error, Exiron retries the same text as plain text. Media
payloads are uploaded with the corresponding Telegram send method. Sticker
payloads can be a Telegram sticker `file_id` or a supported sticker URL and can
include `sticker_emoji`.

### Bot identity and membership monitoring

- Exiron resolves missing bot identity data in supervised background tasks.
- Retryable identity failures are retried without blocking the hub.
- Membership lookups use Telegram's `getChatMember` API for each configured
  bot/chat pair.
- `my_chat_member` updates track when bots are added to or removed from chats.
- Current membership status and recent add/remove events are shown in the
  monitor and included in appropriately scoped status payloads.
- Telegram tokens are redacted from lookup errors and runtime status.

## Hook routing and client availability

Hooks are named client destinations protected by unique bearer tokens.

A hook is considered available when:

- A managed HTTP or WebSocket client currently owns its lease; or
- The hook has already claimed a pending request that has not yet received a
  response.

The second rule lets a slower handler respond after a short HTTP polling lease
expires and prevents new work from immediately bouncing while that handler
still owns outstanding requests.

Each hook token supports one active managed client identity at a time across
both transports:

- A stable `client_id` identifies the client process.
- The same client ID can renew an HTTP lease or replace its prior WebSocket.
- A different client ID receives `409 hook already connected`.
- Conflict responses include `retry_after_ms` when the server can estimate when
  the lease will clear.
- Changing or removing a hook token during configuration reload disconnects the
  affected client.

## Delivery modes

### Routed requests

Routed messages include a generated `req_id`. Pending request state records the
original Telegram address, assigned hook, expiry timer, claimed state, and
whether a response send is already in flight.

- A response is accepted only from the hook that owns the request.
- Concurrent responses to the same request are rejected.
- Successful delivery removes the pending request.
- Retryable Telegram send failures clear the responding state so the client may
  decide whether to try again.
- Terminal Telegram authorization failures and delivery-result timeouts close
  the pending request and are recorded as failures.
- Unanswered requests expire after `EXIRON_PENDING_TIMEOUT_MS`, ten minutes by
  default.

### Explicit acknowledgements and at-least-once delivery

The WebSocket transport and official HTTP pollers use delivery batches:

- Every non-empty batch receives a `delivery_id`.
- Only one batch is in flight for a managed client.
- The client acknowledges only after every handler in the batch succeeds.
- Routed requests remain charged to queue limits and remain claimable until the
  batch is acknowledged.
- If the connection ends before acknowledgement, routed items are returned to
  the front of the queue.

This provides at-least-once delivery for routed requests. A lost acknowledgement
can cause already completed work to be delivered again, so handlers should be
idempotent.

The legacy/default HTTP polling mode is also available without explicit
delivery IDs, while `delivery_mode=explicit` enables retained batches and
`delivery_ack` acknowledges the previous batch.

### Listen mode

A managed client can request ambient chat traffic:

- `listen=false` receives routed requests only.
- `listen=true` receives listen messages from chats reachable by the hook. If a
  message also routes to that same hook, only the routed request is delivered.
- `listen=all` intentionally receives both the routed request and a listen copy
  of a matching message.

Listen traffic is intended for monitoring and audit-style consumers. It is
lossy: unacknowledged listen items are not requeued, and old listen messages are
dropped when queue limits are reached so listeners remain close to real time.

## Client responses and pushes

### Responses

`POST /api/responses` answers a pending routed request. The request contains:

- `req_id`
- `datatype`
- Base64-encoded `data`
- Optional `sticker_emoji`

Exiron verifies token ownership, request assignment, datatype, payload, and
response state before starting the Telegram send. The reply follows the
original request's bot identity when possible.

### Pushes

`POST /api/push` sends a new message without a pending request:

- With no `chat_id`, Exiron sends to every push-enabled target for the hook.
- With `chat_id`, Exiron targets one authorized, push-enabled chat.
- A push cannot escape the chats routed to its authenticated hook.
- An optional `bot` selects a configured bot for the destination.
- The successful response reports how many chats received the message.
- Partial multi-chat failures are recorded per destination; the API reports the
  first failure rather than silently claiming full success.

### Ambiguous send timeouts

Response and push callers wait up to `EXIRON_SEND_TIMEOUT_MS`, 30 seconds by
default, for the Telegram result. On timeout Exiron terminates the local
supervised send task and returns `504 telegram_delivery_timeout`.

Telegram may already have accepted the request before the local timeout. The
delivery outcome is therefore unknown, and automatic blind retries can create
duplicate Telegram messages. The official clients deliberately do not
automatically retry responses or pushes.

## HTTP API

All normal client endpoints use JSON. Except for `/api/auth`, they require
`Authorization: Bearer <hook-token>`.

| Method | Path | Feature |
| --- | --- | --- |
| `POST` | `/api/auth` | Validates a hook token and returns hook, server version, protocol version, and capabilities. The token may be in `hook_token` or the bearer header. |
| `GET` | `/api/status` | Returns operational status scoped to the authenticated hook. |
| `GET` | `/api/socket` | Upgrades to the managed raw JSON WebSocket protocol. |
| `GET` | `/api/requests` | Polls queued messages and renews the HTTP client lease. |
| `POST` | `/api/responses` | Sends a response for a pending request. |
| `POST` | `/api/push` | Pushes to all or one authorized push-enabled chat. |
| `GET` | `/api/event-media/:id` | Retrieves an authorized image preview without caching it publicly. |
| `GET` | `/api/openapi` | Returns the generated OpenAPI document to authenticated dashboard users. |

Binary API data is Base64 encoded at the JSON boundary. API status is filtered
to the authenticated hook's routes, chats, queue and pending counts, message
history, failures, overloads, memberships, and client lifecycle events.
Dashboard status remains global.

Expected errors use stable HTTP statuses and a JSON body containing machine
`code` and human-readable `error` fields. The protocol defines errors for
missing or invalid tokens, invalid client IDs and payloads, assignment
conflicts, unavailable or saturated sends, unauthorized push targets, Telegram
failures, rate limits, and ambiguous delivery timeouts.

### OpenAPI and protocol negotiation

- OpenAPI Spex generates a schema-backed API document from the router.
- Development builds expose an authenticated Swagger UI at `/dev/swaggerui`.
- Authentication and WebSocket connection responses advertise protocol version
  `1.0` and a capability list.
- The capability list currently covers HTTP auth, hook-scoped status, HTTP
  polling and acknowledgements, responses, pushes, WebSockets, listen mode,
  sticker emoji, and Telegram bot selection.
- Shared JSON fixtures and scenario files define the server, Elixir client, and
  Go client contract.
- Protocol-derived client code is generated and checked for drift during
  `mix precommit`.

## Raw JSON WebSocket protocol

`GET /api/socket` requires a bearer token and `client_id`; it also accepts
`listen=false`, `true`, or `all`.

Server frames:

- `connected` confirms the hook, client ID, listen mode, server version,
  protocol version, and capabilities.
- `messages` contains `delivery_id` and a list of request/listen messages.
- `pong` answers a client ping.
- `error` contains the stable error code and message, plus fields such as
  `retry_after_ms` when relevant.

Client frames:

- `ping` checks the connection.
- `ack` acknowledges a successfully processed `delivery_id`.

The server ignores unsupported inbound frame shapes. A same-ID replacement
closes the previous socket cleanly, while a competing client receives the
protocol conflict error.

## Real-time dashboard

All dashboard pages require the configured dashboard password.

LiveViews subscribe to hub status through Phoenix PubSub. The first render uses
a complete snapshot; later updates use revisioned deltas. If a browser misses a
revision, it automatically requests a new full snapshot.

### Live overview

The main dashboard at `/` shows:

- Global Telegram polling state and last-poll time.
- Configured hook count.
- Connected managed-client count.
- Total queued messages.
- Number of pending routed requests.
- Every hook's connection, listen, and queue state.
- The resolved chat-to-hook command routes.
- Recent client connect and disconnect events.
- Recent overload rejections with reason, chat, and payload size.
- Recent incoming, forwarded, response, push, unavailable, overload, and failed
  message activity.
- Message metadata, including hook, bot, chat, message/reply IDs, datatype,
  sticker details, and payload preview.
- Image previews when the event payload passes type and size validation.

Message and client histories are newest-first and capped at 100 entries.
Overload, membership, and failure histories use their own bounded collections.

### Telegram monitor

The monitor at `/monitor` provides:

- Global polling health.
- A chat registry with IDs and aliases.
- Default and most recently active bot for each chat.
- Per-bot membership status for each chat.
- Per-chat polling health.
- Recent bot-added and bot-removed group events.
- Failed Telegram response and push sends with operation, reason, hook, bot,
  chat, datatype, timestamp, and payload preview.

### Image preview protection

- Only JPEG, PNG, GIF, and WebP signatures are accepted for dashboard previews.
- Per-image and total-history byte budgets are configurable.
- Preview bytes are stored in a bounded in-memory store under opaque random IDs.
- Oldest previews are evicted when the history budget is exceeded.
- A dashboard session can retrieve global previews.
- A bearer token can retrieve only media scoped to its own hook.
- Responses use `Cache-Control: private, no-store`.
- Event metadata remains available even when preview bytes are disabled,
  oversized, or evicted.

### Dashboard usability

- Responsive layouts support desktop and smaller screens.
- System, light, and dark themes are available.
- The user's explicit theme is stored locally and synchronized across tabs.
- System-theme mode follows operating-system changes.
- Loading progress and LiveView reconnect feedback are built in.
- Reduced-motion preferences disable nonessential transitions.

## Configuration workspace

The authenticated `/config` page is both an inspector and an editor.

### Configuration inspection

It displays:

- The active configuration path.
- Counts for bots, chats, resolved routes, middleware groups, and hooks.
- Telegram bots, names/tags, chat coverage, and redacted token fingerprints.
- Chat aliases, IDs, middleware, push state, and destinations.
- Middleware groups and their hook/prefix rules.
- Hooks, redacted token fingerprints, chat reach, middleware use, route counts,
  push counts, and prefix counts.
- The complete effective route map after aliases and middleware are resolved.

### YAML editor

- The unified YAML source can be expanded and edited in the browser.
- Every change is parsed and validated live.
- Validation shows either an error or updated bot/chat/route/middleware/hook
  counts.
- Saving first validates the complete configuration, writes it, reloads it from
  disk, and requests a live hub reload.
- If the hub is disabled, the valid file is still saved and the UI reports that
  reload was skipped.
- A boot-failed hub can recover when a corrected configuration is reloaded.

Configuration writes are serialized, use optimistic source checking to detect
an edit made elsewhere, and atomically rename a temporary file over the target.
Existing file permissions are preserved; a newly created configuration uses
mode `0600`.

### Quick Add forms

Structured forms can add or update:

- A Telegram bot with optional name and initial chat.
- A chat route with chat ID, bot token, middleware list, and push setting.
- A middleware route with destination hook and message prefixes.
- A hook and token.

Structured edits produce a canonical YAML file containing the supported
sections. Because they re-encode the document, comments and unsupported
top-level sections are not preserved; use the raw YAML editor when exact source
formatting matters.

### Route tester

The route tester evaluates configuration without sending Telegram traffic:

- Incoming mode selects a chat and accepts a fake text message.
- It applies the same command matching logic as the live router.
- The result identifies and highlights the effective destination route.
- Push mode selects a hook and lists every push-enabled chat it can target.

## Authentication and security

### Dashboard authentication

- Production requires `EXIRON_DASHBOARD_PASSWORD`.
- Password comparison uses constant-time secure comparison.
- Login renews and clears the previous session to prevent session fixation.
- Unauthenticated users are returned to their originally requested dashboard
  path after login.
- Logout clears and drops the session.
- Sessions have a configurable maximum age, 60 days by default.
- Changing the dashboard password invalidates existing sessions through a
  credential fingerprint tied to the Phoenix secret key.
- Production cookies are secure, HTTP-only, and SameSite Lax.
- Browser forms and LiveViews use CSRF protection and secure browser headers.

### Hook-token protection

- Hook API access uses bearer authentication.
- Hook tokens are compared in constant time.
- Hook tokens must be unique.
- Operational status and media are scoped to the authenticated hook.
- Raw bearer tokens are not placed in rate-limit storage.
- Bot and hook tokens are redacted or fingerprinted in operational views.
- Secret wrapper types keep tokens out of normal process inspection output.

### Rate limiting

The API uses ETS-backed sliding-window limits:

- Dashboard login and `/api/auth` share a limit of 10 attempts per minute per
  client IP to slow password and hook-token guessing.
- Authenticated API traffic: 1,200 requests per minute per hashed bearer token.
- Authenticated API traffic also has a 60,000 requests per minute IP ceiling to
  bound callers that rotate invalid tokens.
- Rejections return `429`, a stable `rate_limited` code, and `Retry-After`.
- A supervised cleaner removes stale rate-limit buckets.

### Trusted reverse proxies

`EXIRON_TRUSTED_PROXIES` accepts comma-separated IPv4/IPv6 addresses or CIDR
ranges. Exiron honors `X-Forwarded-For` only when the immediate peer is trusted
and walks proxy chains from right to left to find the original untrusted client.
Invalid trusted-proxy configuration fails during application startup.

### Input and resource limits

- The authentication body is limited to 16 KiB.
- Browser form bodies are limited to 64 KiB.
- The API body limit defaults to the 50 MiB queue-payload allowance plus 1 MiB
  of JSON envelope headroom.
- Elixir and Go clients limit HTTP responses and WebSocket frames to 128 MiB by
  default.
- Queue count, encoded payload bytes, pending requests, image history, Telegram
  downloads, and concurrent sends all have explicit bounds.

## Queue and overload controls

The hub protects its in-memory state with configurable caps:

- `EXIRON_MAX_PENDING` limits all pending routed requests.
- `EXIRON_MAX_QUEUE_PER_HOOK` limits queued and in-flight items per hook.
- `EXIRON_MAX_QUEUE_BYTES_PER_HOOK` limits Base64-encoded queued payload bytes
  per hook.
- `EXIRON_MAX_IN_FLIGHT_SENDS` limits concurrent Telegram send tasks.
- `EXIRON_SEND_TIMEOUT_MS` bounds caller wait time for Telegram delivery.

Routed requests use reject-newest behavior so accepted work is preserved.
Listen queues use drop-oldest behavior so monitoring consumers receive fresher
traffic. Queue drops, redeliveries, pending counts, send outcomes, and overloads
are observable through dashboard history and telemetry.

## Official Elixir client

The `clients/elixir` package provides:

- Client construction with base URL, hook token, stable client ID, listen mode,
  response-size limit, and retry settings.
- Typed auth, message, error, endpoint, and payload structures.
- Authentication and hook-scoped status requests.
- Low-level HTTP polling.
- Response helpers for every supported datatype.
- Text and sticker convenience helpers.
- Broadcast and single-chat push helpers.
- Optional Telegram bot selection.
- A supervised managed `ExironClient.Poller`.
- WebSocket transport by default with HTTP polling fallback.
- Explicit delivery acknowledgement after the full handler batch succeeds.
- Serial handler execution and inbound backpressure.
- WebSocket fragmentation/reassembly and frame-size enforcement.
- Transport lifecycle states for disconnected, connecting, connected, paused,
  and closing.
- Reconnect backoff and server `retry_after_ms` handling.
- `on_connect` and `on_disconnect` lifecycle callbacks.
- Error predicates for hook conflicts and ambiguous Telegram timeouts.
- Secure `wss://` certificate-chain and hostname verification using the OTP
  trust store.
- Custom TLS options for private certificate authorities.
- An explicit insecure TLS opt-out for local development and tests.

The poller can be placed directly in an OTP supervision tree. Fatal handler
errors stop the poller; applications can log recoverable per-message failures
and return success to continue.

## Official Go client

The `clients/go` package provides:

- Functional configuration options for URL, token, client ID, listen mode,
  transport, polling interval, disconnect timeout, and response-size limit.
- Context-aware authentication, status, polling, response, and push methods.
- Typed datatypes, wire structures, payloads, and API errors.
- Text and sticker convenience helpers.
- Broadcast and single-chat push helpers with optional bot selection.
- A managed `Runner` using WebSocket by default.
- HTTP polling fallback.
- Explicit batch acknowledgements and at-least-once routed delivery.
- Serial handler execution.
- Connection coordination, retry/backoff handling, and server
  `retry_after_ms` support.
- `OnConnect` and `OnDisconnect` callbacks.
- Error helpers for hook conflicts and ambiguous Telegram delivery timeouts.
- Context cancellation for clean shutdown.
- HTTP response and WebSocket frame-size enforcement.

Returning an error from the Go handler stops the runner. Applications can treat
recoverable message failures as handled by logging them and returning `nil`.

## Status, diagnostics, and telemetry

Global and hook-scoped status snapshots include:

- Enabled state and server version.
- Global and per-chat Telegram polling health.
- Last Telegram poll time where applicable.
- Pending request count.
- Hook connection, listen, and queue state.
- Resolved routes and chat metadata.
- Recent message, send-failure, overload, membership, and client events.
- A monotonically revised status version for real-time delta delivery.

Telemetry covers:

- Queue item count, bytes, and drops by hook.
- Total pending requests.
- Send duration, count, kind, and outcome.
- Status snapshot duration and encoded size by scope.
- Configuration reload duration and result.
- Bot lookup and Telegram poll duration and outcome.
- Delivery redelivery count by transport.
- Listener drops by hook and reason.
- Standard Phoenix endpoint/router/socket metrics.
- BEAM memory and run-queue metrics.

Development also exposes the authenticated Phoenix LiveDashboard at
`/dev/dashboard`.

## Runtime behavior and fault isolation

- A central GenServer serializes routing, leases, pending ownership, queues, and
  recent history.
- Telegram pollers, send tasks, identity lookups, membership lookups, the media
  store, rate-limit cleaner, PubSub, HTTP client pool, and Phoenix endpoint are
  supervised.
- Telegram sends run under a task supervisor so slow external calls do not
  block the hub.
- The send concurrency cap prevents unbounded task creation.
- Poller and socket process monitors update health promptly when a process
  exits.
- Configuration reload can update all configuration, routes only, or bots only.
- Reload reconciles active clients and preserves sessions whose hook credentials
  are unchanged.
- Setting `EXIRON_ENABLED=false` boots the web application with the hub disabled.
- A configuration boot failure also leaves the web application available in a
  disabled state so an operator can diagnose and correct it.
- Disabled APIs return a stable `503 server_disabled` response.

## Runtime configuration

Core environment settings:

| Variable | Default | Purpose |
| --- | ---: | --- |
| `EXIRON_ENABLED` | `true` | Enables or disables the in-memory hub. |
| `EXIRON_CONFIG` | `config/config.yml` | Selects the YAML configuration file. |
| `EXIRON_TELEGRAM_POLLERS_ENABLED` | enabled outside development | Enables Telegram polling, bot identity, and membership lookups. |
| `EXIRON_CLIENT_TIMEOUT_MS` | `3000` | Sets the HTTP client lease duration. |
| `EXIRON_PENDING_TIMEOUT_MS` | `600000` | Sets routed request expiry. |
| `EXIRON_SEND_TIMEOUT_MS` | `30000` | Bounds waiting for a Telegram send result. |
| `EXIRON_MAX_PENDING` | `1000` | Caps pending routed requests. |
| `EXIRON_MAX_QUEUE_PER_HOOK` | `100` | Caps queued/in-flight items per hook. |
| `EXIRON_MAX_QUEUE_BYTES_PER_HOOK` | `52428800` | Caps encoded queued payload bytes per hook. |
| `EXIRON_MAX_IN_FLIGHT_SENDS` | `100` | Caps concurrent Telegram send tasks. |
| `EXIRON_MAX_EVENT_IMAGE_PREVIEW_BYTES` | `8388608` | Caps one event image preview; `0` disables previews. |
| `EXIRON_MAX_EVENT_IMAGE_HISTORY_BYTES` | `67108864` | Caps all retained preview bytes; `0` disables previews. |
| `EXIRON_API_BODY_LENGTH` | `53477376` | Overrides the API JSON body limit. |
| `EXIRON_DASHBOARD_PASSWORD` | required in production | Protects all browser dashboard pages. |
| `EXIRON_DASHBOARD_SESSION_MAX_AGE_SECONDS` | `5184000` | Sets dashboard session lifetime. |
| `EXIRON_TRUSTED_PROXIES` | empty | Defines trusted proxy IPs/CIDRs. |

Phoenix deployment settings include `PHX_SERVER`, `PHX_HOST`, `PORT`,
`SECRET_KEY_BASE`, and optional `DNS_CLUSTER_QUERY`. Production builds can opt
into forced HTTPS with `PHX_FORCE_SSL`. If TLS terminates at a reverse proxy,
that proxy must be listed in `EXIRON_TRUSTED_PROXIES`; forwarded HTTPS headers
from untrusted peers are ignored. Secure session cookies are always enabled in
production.

## Deployment

- `mix setup` installs dependencies and builds assets for local development.
- `mix phx.server` starts the application on port 4000 by default.
- Production uses a Phoenix release served by Bandit.
- The multi-stage Dockerfile produces a compact Alpine runtime image.
- The release runs as a non-root user.
- Docker Compose mounts the configuration directory so dashboard edits persist.
- Compose can map the container process to the host configuration owner's UID
  and GID, allowing safe atomic configuration replacement.
- Compose binds to `127.0.0.1` by default and requires explicit opt-in for a
  public bind address.
- Compose requires both `SECRET_KEY_BASE` and the dashboard password.
- Static assets are compiled, minified, digested, and cached for production.

## Development and quality tooling

`mix precommit` is the complete project gate. It:

- Checks for unused dependency locks.
- Verifies Elixir formatting.
- Verifies generated client protocol code.
- Validates all shared HTTP/WebSocket contract fixtures and scenarios.
- Runs a smoke benchmark of hub hot paths.
- Compiles the server with warnings treated as errors.
- Runs the server test suite.
- Checks and compiles the Elixir client, then runs its tests.
- Checks Go formatting and runs `go vet`.
- Runs the Go test suite.

The test coverage includes configuration parsing and editing, route compilation,
Telegram polling and media handling, bot identity and memberships, hub state
transitions, queue bounds and redelivery, WebSocket and HTTP contracts,
authentication and sessions, status scoping, image authorization, rate
limiting, runtime configuration, and cross-language protocol conformance.

## Reproduction specification

The sections above describe Exiron's product features. This section adds the
implementation-level contracts needed to build a functionally compatible
replacement. A reproduction does not need the same module names, but it must
preserve the ownership boundaries, wire shapes, ordering, limits, and state
transitions below.

### Reference technology stack

The current implementation uses:

| Concern | Technology |
| --- | --- |
| Runtime | Elixir `~> 1.20` and OTP |
| Web framework | Phoenix `~> 1.8.8` |
| Real-time UI | Phoenix LiveView `~> 1.2` and PubSub |
| HTTP server | Bandit |
| Outbound HTTP | Req through a named Finch pool restricted to HTTP/1 |
| Telegram API | ExGram with its Req adapter |
| Configuration | YAML Elixir |
| API description | OpenAPI Spex |
| Front end | Tailwind CSS 4.3, esbuild, Heroicons |
| Serialization | Jason |
| Clustering hook | DNSCluster |

There is intentionally no Ecto dependency and no database. All queues,
deliveries, leases, pending requests, histories, rate-limit counters, and image
previews are runtime memory.

### Supervision and ownership model

The top-level supervisor uses `one_for_one` and starts these responsibilities:

1. Phoenix and VM telemetry.
2. Optional DNS clustering.
3. Phoenix PubSub under `Exiron.PubSub`.
4. A named Finch pool under `Exiron.Finch`.
5. The bounded event-media store.
6. The hub subsystem.
7. The ETS rate-limit cleaner.
8. The Phoenix endpoint.

The hub subsystem uses `one_for_all` so its coordinated processes restart
together:

1. A dynamic supervisor for Telegram pollers.
2. A task supervisor for Telegram sends.
3. A task supervisor for bot identity and membership lookups.
4. The lookup-task coordinator.
5. The central hub GenServer.

The central hub is the sole owner of:

- The compiled router and Telegram bot registry.
- Active Telegram poller identities and monitors.
- Per-hook queues and client sessions.
- In-flight HTTP and WebSocket delivery batches.
- Pending routed requests.
- In-flight Telegram send tasks.
- Bot identity and membership lookup state.
- Recent message, failure, overload, membership, and client histories.
- Incoming-message deduplication keys.
- The current dashboard status revision and last published snapshot.

Controllers, pollers, WebSockets, and LiveViews communicate with the hub through
calls, casts, process messages, and PubSub. They must not mutate hub-owned state
directly.

### Boot and reload rules

On enabled startup:

1. Read the configured YAML path. A missing file is treated as `{}`; a blank or
   malformed YAML document is invalid.
2. Parse Telegram bots and derive the alias-to-chat-ID map.
3. Compile and validate the router.
4. Build the Telegram bot registry.
5. Start one poller for every unique token when polling is enabled.
6. Initialize runtime limits.
7. Start missing bot identity and membership lookups.

If any boot step fails, keep the endpoint and dashboard running but initialize a
disabled, `boot_failed` hub. A later full reload retries the complete boot.

There are three reload operations:

- Routes-only reload recompiles the router and reconciles client credentials.
- Bots-only reload reconciles pollers and Telegram state.
- Full reload does both.

Poller reconciliation computes additions, name changes, and removals. It applies
them transactionally and attempts to undo already completed operations if a
later operation fails. A successful reload:

- Keeps clients whose hook name and token are unchanged.
- Disconnects clients whose hook was removed or whose token changed.
- Requeues unacknowledged routed deliveries from disconnected clients.
- Prunes memberships for removed bot/chat pairs.
- Starts new identity and membership lookups.
- Enforces current event-history limits.

### Exact configuration grammar

All keys below are YAML strings.

| Path | Type | Rules |
| --- | --- | --- |
| `telegram` | map, optional | Container for bot configuration. |
| `telegram.bots` | list, optional | Defaults to an empty list. |
| `telegram.bots[].token` | non-empty string | Required for every bot entry. |
| `telegram.bots[].name` | string or null | Trimmed; empty is treated as unnamed. |
| `telegram.bots[].chats` | map | Required; maps non-empty aliases to integer chat IDs. |
| `routes` | map, optional | Maps chat aliases to route settings. |
| `routes.<alias>.middleware` | list of strings | Defaults to an empty list. Every name must exist. |
| `routes.<alias>.push` | boolean | Defaults to `false`. |
| `routes.<alias>.default_bot` | non-empty string, optional | Preferred bot name for that chat route. |
| `middlewares` | map, optional | Maps reusable group names to route maps. |
| `middlewares.<name>.routes` | map | Maps hook names to requirements. |
| `middlewares.<name>.routes.<hook>.messages` | list of strings | After trimming and removing empty entries, at least one prefix is required. |
| `hooks` | map, optional | Maps non-empty hook names to unique non-empty string tokens. |

Additional invariants:

- Every alias referenced by `routes` must occur in at least one bot's `chats`.
- Repeated aliases may occur across bots only when they map to the same chat ID.
- Bot names are normalized without a leading `@` and must resolve to one token
  per chat.
- Every middleware route must reference a configured hook.
- `middleware`, `routes`, `middlewares`, and `hooks` must have the exact
  collection types above; type coercion is not performed.
- Effective routes are grouped by service, chat ID, alias, hook, push setting,
  and default bot. Their prefixes are merged and de-duplicated.
- Prefixes are sorted longest-first.
- Effective routes are sorted by service ID, chat ID, alias, and hook, then
  assigned sequential integer IDs starting at 1.

The only current service is Telegram, with `service_id: 222`.

### Opaque identifiers

Request IDs, delivery IDs, and runtime event IDs are generated from 16
cryptographically random bytes encoded as unpadded URL-safe Base64. Event-media
IDs use 24 random bytes with the same encoding. Consumers must treat every ID
as opaque.

### Canonical client message

Both HTTP polling and WebSocket delivery use the same message object:

| Field | Type | Meaning |
| --- | --- | --- |
| `msgtype` | `"request"` or `"listen"` | Delivery purpose. |
| `req_id` | string, request only | Pending request identifier; omitted for listen messages. |
| `service_id` | integer | `222` for Telegram. |
| `chat_id` | integer | Telegram chat ID. |
| `instance` | string or null | Configured or resolved bot name, never the token. |
| `datatype` | supported datatype string | Normalized payload type. |
| `data` | Base64 string | Raw payload encoded at the wire boundary. |
| `sticker_id` | string or null | Original sticker file ID when known. |
| `sticker_emoji` | string or null | Telegram sticker emoji when known. |
| `emoji_list` | list of strings | Derived related emoji; otherwise empty. |
| `message_id` | integer or null | Telegram message ID. |
| `reply_to_message_id` | integer or null | Telegram replied-to message ID. |
| `from` | object or null | Telegram sender metadata. |

When present, `from` contains integer `id`, boolean `is_bot`, string
`first_name`, and nullable `last_name`, `username`, and `language_code`.

Fields whose value is null are retained in the serialized client object, except
`req_id`, which is absent from listen messages.

### HTTP request and response contracts

#### Authentication

`POST /api/auth` accepts either:

```json
{"hook_token": "secret"}
```

or `Authorization: Bearer secret`. When both are supplied, the JSON
`hook_token` takes precedence. A successful response is:

```json
{
  "auth_response": "OK",
  "hook": "assistant",
  "msgtype": "auth",
  "server_version": "0.1.0",
  "protocol_version": "1.0",
  "capabilities": ["..."]
}
```

#### Polling

`GET /api/requests` requires non-empty `client_id`.

- `listen` accepts `true`, `"true"`, or `"all"`; every other value means off.
- Without `delivery_mode=explicit`, return `{"requests": [...]}` and drain the
  queue immediately.
- With `delivery_mode=explicit`, return
  `{"delivery_id": "<opaque-id-or-null>", "requests": [...]}`.
- `delivery_ack` acknowledges the prior explicit batch only when it exactly
  equals that batch's current delivery ID.
- With no correct acknowledgement, return the same retained batch.
- After a correct acknowledgement, clear it and start the next queued batch.

#### Responses

`POST /api/responses` requires:

```json
{"req_id": "opaque-id", "datatype": "text", "data": "Base64"}
```

`sticker_emoji` is optional. Success returns `{"ok": true}`.

#### Pushes

`POST /api/push` requires:

```json
{"datatype": "text", "data": "Base64"}
```

Optional fields are integer `chat_id`, string `bot`, and string
`sticker_emoji`. Success returns:

```json
{"ok": true, "sent": 1}
```

### Error contract

Every expected JSON error contains `code` and `error`. Additional fields such
as `retry_after_ms` are merged into that object.

| Code | HTTP | Message |
| --- | ---: | --- |
| `missing_token` | 401 | `missing bearer token` |
| `invalid_token` | 401 | `invalid token` |
| `invalid_client_id` | 400 | `invalid client id` |
| `server_disabled` | 503 | `exiron disabled` |
| `request_not_found` | 404 | `request not found` |
| `request_not_assigned` | 409 | `request not assigned` |
| `request_in_flight` | 409 | `request response in flight` |
| `hook_already_connected` | 409 | `hook already connected` |
| `chat_not_pushable` | 400 | `chat not pushable` |
| `invalid_chat_id` | 400 | `invalid chat id` |
| `invalid_datatype` | 400 | `invalid datatype` |
| `invalid_payload` | 400 | `invalid payload` |
| `invalid_base64_data` | 400 | `invalid base64 data` |
| `telegram_bot_not_configured` | 503 | `telegram bot not configured` |
| `telegram_bot_forbidden` | 503 | `telegram bot forbidden` |
| `telegram_bot_unauthorized` | 503 | `telegram bot unauthorized` |
| `send_queue_full` | 503 | `send queue full` |
| `send_unavailable` | 503 | `send unavailable` |
| `telegram_delivery_timeout` | 504 | `telegram delivery result timed out` |
| `telegram_file_path_empty` | 400 | `telegram file path empty` |
| `telegram_file_too_large` | 400 | `telegram file too large` |
| `rate_limited` | 429 | `too many requests` |
| `internal_error` | 500 | `internal error` |

An ExGram `403` maps to `telegram_bot_forbidden`. Unexpected atoms or values are
logged without exposing a secret and become `internal_error`.

### WebSocket compatibility rules

After the HTTP upgrade, initialization must either:

- Register the managed client and send a `connected` frame followed by a
  `messages` frame, even when the initial messages list is empty; or
- Send an `error` frame and close with code `4009` when registration fails.

The connected frame contains:

```json
{
  "type": "connected",
  "hook": "assistant",
  "client_id": "runner",
  "listen": false,
  "server_version": "0.1.0",
  "protocol_version": "1.0",
  "capabilities": ["..."]
}
```

A delivery frame is:

```json
{"type": "messages", "delivery_id": "opaque-or-null", "messages": []}
```

The server answers `{"type":"ping"}` with `{"type":"pong"}`. It accepts
`{"type":"ack","delivery_id":"..."}` only for the current delivery. Stale
acknowledgements, malformed JSON, and unknown text-frame shapes do not alter
delivery state.

When the same `client_id` opens a replacement WebSocket, close the old socket
with normal code `1000` and reason `replaced`. When a different ID owns the
hook, reject the new connection with `hook_already_connected`.

### Client lease state machine

The authoritative session key is the hook name; each session records client ID,
transport, listen mode, lease/monitor, connected timestamp, and at most one
transport-specific delivery.

| Current state | Operation | Result |
| --- | --- | --- |
| No session | HTTP poll by valid ID | Create timed HTTP lease. |
| HTTP lease by ID A | HTTP poll by A | Cancel old timer, preserve retained HTTP delivery, and renew lease. |
| HTTP lease by ID A | HTTP poll by B | `409` with remaining timer as `retry_after_ms`. |
| HTTP lease by ID A | WebSocket by A | Cancel HTTP lease and replace it with WebSocket ownership. |
| HTTP lease by ID A | WebSocket by B | `409`. |
| WebSocket by ID A | WebSocket by A | Replace old socket, preserving the logical connected stretch. |
| WebSocket by ID A | WebSocket by B | `409`. |
| WebSocket by ID A | HTTP poll, including A | `409`; HTTP cannot displace a live WebSocket. |

HTTP leases expire after `client_timeout`. WebSocket ownership ends on explicit
disconnect, monitored process exit, replacement, or reload reconciliation.

Record one `connected` event at the start of a connected stretch and one
`disconnected` event when it actually ends. Heartbeat polls and same-ID
replacements do not create duplicate connect events.

### Delivery state machine

For either explicit HTTP or WebSocket delivery:

1. Drain the hook queue in FIFO order.
2. Mark every routed request in that batch as claimed.
3. Retain the batch with its count and encoded-byte usage.
4. Refuse to start another batch while one is retained.
5. On matching acknowledgement, discard the retained batch.
6. On client removal before acknowledgement, keep only still-pending routed
   items, prepend them to the queue, and mark them unclaimed.
7. Never requeue listen items.

Queue count and byte limits include both queued items and the retained in-flight
batch.

The non-explicit HTTP mode drains and claims work without retaining a delivery
object. The pending request still exists and can be answered by `req_id`, but
that mode cannot redeliver work lost after the poll response.

### Pending-request state machine

Each pending request stores service/chat address, original bot token and name,
assigned hook, expiry timer, claimed flag, and lifecycle:

| State | Trigger | Next state |
| --- | --- | --- |
| `queued` | Delivered in a batch | `claimed` |
| `claimed` | Batch recovered after disconnect | `queued` |
| `queued` or `claimed` | Valid response begins | `responding` |
| `responding` | Non-terminal send failure | Previous claimed/queued state |
| Any | Successful response | Removed |
| Any | Expiry | Removed from pending and queue |
| `responding` | Telegram 401/403 or local delivery timeout | Removed and recorded as `response_failed` |

A response from another hook returns `request_not_assigned`. A second response
while the first send is active returns `request_in_flight`.

### Incoming dispatch algorithm

For every accepted, non-duplicate Telegram message, execute in this order:

1. Create a `received` history event.
2. Compute the route match.
3. Queue listen copies for connected, eligible listening hooks.
4. Suppress a same-hook listen copy for a routed match unless mode is `all`.
5. If no route matched, stop after history/listen processing.
6. If a route matched but the hook is unavailable, start a background
   `unavailable` Telegram send.
7. If the route would exceed a cap, record an overload item, add an `overloaded`
   client-target event, and start a background overload Telegram send.
8. Otherwise create the pending request, queue its client payload, and add a
   `request` client-target event.
9. Deliver any newly available WebSocket queues.
10. Broadcast status only when the public snapshot changed.

The unavailable and overload notices use the same bot identity as the incoming
message.

### Telegram update and send rules

- Poll immediately after a non-empty successful update batch.
- Wait 100 ms after an empty successful poll.
- Wait 1,000 ms after poll or transient update-processing failure.
- Stop a poller normally on Telegram `401`; other poll errors retry.
- Advance the offset to `update_id + 1` only after that update is processed.
- On retryable media failure, set the offset to the failed update ID so earlier
  updates are acknowledged and the failed one returns.
- Treat missing Telegram file paths and oversized files as permanent ignores.
- Retry HTTP `408`, `425`, `429`, and `5xx` media failures.
- Ignore unsupported update and message shapes.

Outgoing media mapping is:

| Datatype | Telegram operation |
| --- | --- |
| `text` | `sendMessage`, Markdown first and plain-text fallback only for entity parse errors |
| `audio` | `sendAudio` |
| `video` | `sendVideo` |
| `image` | `sendPhoto` |
| `file` | `sendDocument` |
| `sticker` | `sendSticker` |

Every send occupies one in-flight slot. Start failure returns
`send_unavailable`; a full slot map returns `send_queue_full`. Send tasks are
monitored and have a timer. Completion, abnormal task exit, and timeout must
remove the slot exactly once.

### Push result rules

Resolve push targets from effective routes, de-duplicated by service, chat, and
default bot. Process all targets even if one fails.

- All success: record one `push` event per sent chat and return the count.
- Partial success: record successful push events, record one send failure per
  failed destination, and return the first error.
- All failure: return the first error and record available per-destination
  failures.
- `401` and `403` are normalized to the stable Telegram authorization errors.
- A caller timeout returns the ambiguous timeout error; late task output must
  not mutate state after its slot has been removed.

### Status and history contract

The global snapshot contains:

- `enabled`, `telegram_polling`, `telegram_last_polled_at`, `version`,
  `requested`, and internal/public `revision`.
- Arrays named `chats`, `hooks`, `routes`, `events`, `send_failures`,
  `overload_events`, `membership_events`, `bot_memberships`, and
  `client_events`.

The hook-scoped snapshot contains the same top-level shape but:

- Includes only that hook and its routes.
- Includes only chats reachable through those routes.
- Counts only that hook's pending requests.
- Filters event, failure, overload, and client histories by hook.
- Filters membership data by reachable chat.
- Never exposes another hook's state.
- Sets `telegram_last_polled_at` to null.

Collection shapes:

| Collection | Essential fields |
| --- | --- |
| `hooks` | `name`, `connected`, `listening`, `queued` |
| `routes` | `id`, `service_id`, `chat_id`, `chat_alias`, `to`, `messages`, `push`, nullable `default_bot` |
| `chats` | `id`, aliases, nullable default/current bot, memberships, `polling`, nullable last-poll time |
| `events` | ID/time, direction, target, hook, kind, service/chat/bot, datatype, preview, image URL, sticker and Telegram message metadata |
| `send_failures` | ID/time, `reply` or `push`, hook/chat/bot/datatype, preview, redacted reason |
| `overload_events` | ID/time, hook, cap reason, service/chat/datatype, raw payload bytes |
| `membership_events` | ID/time, added/removed, chat title/ID, bot identity, old/new status |
| `bot_memberships` | chat and bot identity, status, presence, optional redacted error |
| `client_events` | ID/time, connected/disconnected, hook, client ID, listening boolean |

History ordering and limits are part of the contract:

| History | Limit |
| --- | ---: |
| Message events | 100 |
| Client lifecycle events | 100 |
| Send failures | 50 |
| Overload events | 50 |
| Membership events | 50 |
| Incoming deduplication keys | 500 |

All histories are newest-first.

Global Telegram polling is true only when polling is enabled, at least one bot
poller is required, and every configured unique bot token has a live tracked
poller. Per-chat polling applies the same rule to the bot tokens configured for
that chat.

### Status delta protocol for LiveViews

The initial page mount reads a complete snapshot. Every public state change
compares the new snapshot to the last published one:

- If unchanged, do not broadcast.
- If changed, increment the revision and broadcast a delta containing
  `base_revision`, `revision`, changed scalar values, changed collection
  operations, counts, and derived metrics.
- A LiveView applies a delta only when its current revision equals
  `base_revision`.
- On a mismatch, the LiveView fetches a complete snapshot and resets its
  streams.

This rule prevents a missed PubSub message from leaving the browser in a
silently inconsistent state.

### Dashboard route and access map

| Path | Access | Purpose |
| --- | --- | --- |
| `/login` | Anonymous only | Password login. |
| `/` | Dashboard session | Live overview. |
| `/monitor` | Dashboard session | Telegram chat, membership, and send diagnostics. |
| `/config` | Dashboard session | Configuration inspection, editing, quick add, and route testing. |
| `/logout` | Dashboard session, `DELETE` | Clear session. |
| `/api/openapi` | Dashboard session | OpenAPI JSON. |
| `/dev/dashboard` | Dashboard session, development only | Phoenix LiveDashboard. |
| `/dev/swaggerui` | Dashboard session, development only | Swagger UI. |

The event-media route is the exception: it accepts either a dashboard session
or a bearer token, then enforces media scope.

### Functional compatibility acceptance criteria

A reproduction is functionally complete when it can pass equivalent tests for:

1. Configuration parsing, validation, canonical editing, optimistic conflict
   detection, atomic writes, and reload rollback.
2. Prefix boundaries, longest-match selection, addressed Telegram commands,
   route merging, push target resolution, and ambiguous-prefix rejection.
3. Every supported incoming and outgoing datatype and Telegram metadata field.
4. File streaming limits, update offset behavior, poll retries, deduplication,
   identity lookup, and membership tracking.
5. One-client lease ownership across HTTP and WebSocket, including every
   takeover/conflict row above.
6. Explicit acknowledgement, redelivery, lossy listen behavior, queue accounting,
   and pending-request transitions.
7. Response and push success, partial failure, authorization failure, task exit,
   saturation, and ambiguous timeout behavior.
8. Exact HTTP payloads, error codes, WebSocket frames, protocol capabilities,
   and hook-scoped status filtering.
9. Dashboard authentication lifetime, password-change invalidation, CSRF,
   trusted proxies, rate limits, image authorization, and resource limits.
10. Full snapshot/delta recovery and all bounded history limits.
11. Equivalent Elixir and Go client behavior, including WebSocket-first managed
    operation, HTTP fallback, acknowledgements, retry hints, callback timing,
    TLS validation, and frame/response limits.
