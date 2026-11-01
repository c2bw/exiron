# Exiron

**Connect Telegram bots to your own workers, with routing and a dashboard in one place.**

Exiron is a self-hosted Telegram gateway built with Elixir and Phoenix. It routes
incoming messages to named **hooks** and sends your workers' replies back to the
right chat. Workers connect over WebSocket or HTTP
using a hook token. Included Go and Elixir SDKs handle authentication, connection
management, payload encoding, and delivery acknowledgements.

Use it to share Telegram bots across several services, keep bot credentials out
of workers, or inspect requests and connections without digging through logs.

```text
Telegram chats → Exiron → Go, Elixir, or custom workers
                ↑    ←   one-shot or streamed replies
                │
           Web dashboard
```

[Getting started](#getting-started) · [Connect a worker](#connect-a-worker) ·
[Docker](#run-with-docker) · [Configuration](#configuration) ·
[Documentation](#documentation) · [Development](#development)

## What you get

- **Routing across bots and chats.** Match commands to hooks, share middleware
  groups, control access, and choose which chats allow worker-initiated messages.
- **One-shot and streamed replies.** Send text, images, audio, video, files,
  stickers, and albums, with support for topics, captions, inline buttons,
  callbacks, and editing replies.
- **A browser dashboard.** See hook connections and SDK versions, inspect request
  timelines and delivery failures, filter activity, and compose manual messages.
- **Configuration management.** Review changes, validate routes, reload without
  restarting, and restore saved configuration revisions.
- **Managed workers.** Both SDKs support optional concurrency, conversation
  ordering, cancellation, handler deadlines, quarantine, and graceful shutdown.
  Runtime reporting turns on automatically when the server advertises support.
- **Operational controls.** Bounded queues and send budgets, overload diagnostics,
  health checks, graceful drain, and token-protected Prometheus metrics.

## Delivery model

**Delivery state lives in memory.** A Hub crash or application restart can lose
queued and pending work, delivery tracking, and idempotency receipts. Run one
active Exiron instance for a given set of Telegram bots; queues and bot ownership
are not coordinated across instances.

Managed SDKs acknowledge routed batches after successful processing. An
unacknowledged batch can be replayed while its pending work is still retained
and valid, so handlers must tolerate duplicates. Listen traffic is best effort.
This is not a durable queue or an exactly-once processing service.

If a Telegram send times out, delivery is **unknown**: Telegram may already have
accepted it. Avoid blind retries unless duplicate messages are acceptable.
See [delivery guarantees](docs/delivery-guarantees.md) for the full contract.

## Getting started

### 1. Start Exiron from source

You need Git and Elixir **1.20** with a compatible Erlang/OTP installation. The
[CI matrix](.github/workflows/ci.yml) uses Elixir 1.20.1 with OTP 27.3 and 28.0.
Go **1.24.5 or newer** is needed for the Go SDK and the complete project checks.
For a container build instead, see [Run with Docker](#run-with-docker).

From the repository root:

```sh
mix setup
mix phx.server
```

Open [localhost:4000](http://localhost:4000) and sign in with the development
password `exiron`. Set `EXIRON_DASHBOARD_PASSWORD` to change it.

Development binds to loopback and **does not poll Telegram by default**. To
receive real Telegram messages, stop the server and restart it with:

```sh
EXIRON_TELEGRAM_POLLERS_ENABLED=true mix phx.server
```

### 2. Configure a bot and a hook

In the dashboard's **Configuration** page (`/config`):

1. Add your Telegram bot token and the chat IDs it should serve.
2. Create a hook, such as `assistant`, and keep its worker authentication token.
3. Add a middleware route mapping a command, such as `/ask`, to that hook.
4. Enable the middleware group for the intended chat, then save and activate
   the configuration. Check the activation result before sending traffic.

Exiron starts with empty configuration when its configuration file is absent.
You can also prepare YAML directly using
[`config/config.example.yml`](config/config.example.yml); see
[Configuration](#configuration) below.

### 3. Connect a worker and send a message

Start one of the [included workers](#connect-a-worker) in a separate terminal
using the hook token. Confirm the hook is connected in the dashboard, then send
`/ask hello` in a configured Telegram chat with polling enabled. The example
worker replies to text requests.

Only **one managed client can own a hook at a time** across both transports.
Use separate hooks for independent workers. A competing client receives
`409 hook already connected` with a retry hint.

## Connect a worker

Both SDKs default to **WebSocket transport and one-shot replies**. HTTP polling
and streamed text remain available as explicit choices. The runnable reference
workers demonstrate additional lifecycle controls; they require a server that
advertises the corresponding capabilities.

Set your hook token in the terminal where you will run the worker:

```sh
export EXIRON_HOOK_TOKEN='your-hook-token'
export EXIRON_BASE_URL='http://localhost:4000'
```

### Go

From the repository root:

```sh
cd clients/go
go run ./cmd/exiron-worker
```

To choose HTTP and streamed replies instead:

```sh
EXIRON_TRANSPORT=http EXIRON_REPLY_MODE=stream go run ./cmd/exiron-worker
```

### Elixir

From the repository root:

```sh
cd clients/elixir
mix deps.get
iex -S mix run examples/managed_worker.exs
```

Then start the example in IEx:

```elixir
ExironExampleWorker.start()
```

To choose HTTP and streamed replies, set `EXIRON_TRANSPORT=http` and
`EXIRON_REPLY_MODE=stream` before starting IEx.

The Go module path is `github.com/c2bw/exiron/clients/go`.
For integration into your own application, see the [Go SDK](clients/go/README.md),
[Elixir SDK](clients/elixir/README.md), and
[client reference](docs/client-reference.md). The
[worker run guide](docs/managed-worker-examples.md) covers status inspection,
quarantine recovery, and shutdown. The SDKs are included in this repository;
install them directly from Git and pin the chosen commit in your application
lockfiles. See the [Go](clients/go/README.md#installation) and
[Elixir](clients/elixir/README.md#installation) installation instructions.

## Run with Docker

Build the included Dockerfile locally; this does not require access to a
prebuilt image registry:

```sh
docker build -t exiron:local .
```

The following example uses a POSIX shell on Linux, Docker, and OpenSSL. Generate
the signing secret once and retain the same value across container recreations
if existing dashboard sessions should remain valid:

```sh
export SECRET_KEY_BASE="$(openssl rand -hex 64)"
export EXIRON_DASHBOARD_PASSWORD='replace-with-a-strong-password'

docker run --rm --name exiron \
  --user "$(id -u):$(id -g)" \
  -p 127.0.0.1:4000:4000 \
  -v "$PWD/config:/app/config" \
  -e PHX_SERVER=true \
  -e PHX_HOST=localhost \
  -e SECRET_KEY_BASE \
  -e EXIRON_DASHBOARD_PASSWORD \
  exiron:local
```

Open [localhost:4000](http://localhost:4000). Production containers enable
Telegram polling by default. The mounted `config` directory keeps configuration
and revision history outside the container. Matching the host directory owner's
UID/GID lets the non-root process save dashboard changes.

A [Compose file](docker-compose.yml) is also included, with a readiness health
check and restart policy. It references `ghcr.io/c2bw/exiron:latest`; to use the
local build instead, change its `image:` to `exiron:local`, then run:

```sh
HOST_UID="$(id -u)" HOST_GID="$(id -g)" docker compose up -d
```

That command uses the secrets exported above. Compose defaults to UID/GID
`1000:1000`; override them to match your configuration directory's owner.
See [building and deploying](docs/building.md) for production artifacts and
container build identity.

GitHub CI publishes AMD64 and ARM64 images to GHCR only after tests pass on
pushes to `main`, tagged `latest` and `sha-<full-commit>`. Other branches, pull
requests, and tag pushes do not build images. See
[container images](docs/building.md#container-images) for image access and
deployment pinning.

### Network access and reverse proxies

Development and the examples above expose port 4000 on **loopback only**.
Compose also defaults to `127.0.0.1`; `EXIRON_PORT` changes its host port.
For remote access, place Exiron behind a TLS reverse proxy or use an equivalently
trusted private network. Set Compose's `EXIRON_BIND_ADDRESS` only when intended.

Set `PHX_HOST` to the public hostname and `EXIRON_TRUSTED_PROXIES` to the proxy's
IP addresses or CIDR ranges, separated by commas. For a proxy on the same host,
that might be `127.0.0.1/32,::1/128`. Trust only actual proxy peers: Exiron uses
this setting to validate forwarded client addresses and HTTPS scheme information.

Production builds can opt into forced HTTPS with the **build-time** setting
`PHX_FORCE_SSL=true` (a Docker build argument). A TLS-terminating proxy must be
trusted for its forwarded HTTPS information to take effect.

## Configuration

Exiron reads `config/config.yml` by default; `EXIRON_CONFIG` selects another path.
The file contains four main sections:

| Section | Purpose |
| --- | --- |
| `telegram.bots` | Bot credentials and named chat IDs. |
| `routes` | Middleware groups, push permissions, and bot selection for each chat. |
| `middlewares` | Command-to-hook routing rules. |
| `hooks` | Named worker credentials, stored as SHA-256 token digests. |

Start from the annotated [schema 2 example](config/config.example.yml). Schema 1
remains supported. Bot names identify the source as `instance` in worker payloads;
when a name is omitted and polling is enabled, Exiron attempts to resolve the
bot username through Telegram.

Use the dashboard to create or rotate hook tokens; it hashes them automatically.
Keep bot tokens, worker tokens, dashboard passwords, and deployment secrets out
of source control. Saved configuration and active configuration are separate:
check the activation result after saving, and use
[history and rollback](docs/configuration-history.md) to restore a saved revision.
See also [reload behavior](docs/configuration-reload.md) and
[configuration diagnostics](docs/configuration-diagnostics.md).

<details>
<summary>Runtime environment variables and capacity defaults</summary>

| Variable | Default | Purpose |
| --- | --- | --- |
| `EXIRON_ENABLED` | `true` | Set to `false`, `0`, `no`, or `off` to boot the app with the hub disabled. |
| `EXIRON_GROUP_ALBUMS` | `false` | Opt in to collecting incoming media albums into grouped requests. Leave disabled for existing individual-media handlers. |
| `EXIRON_CONFIG` | `config/config.yml` | YAML file containing Telegram bot, route, middleware, and hook token configuration. |
| `EXIRON_CLIENT_TIMEOUT_MS` | `3000` | Positive integer milliseconds before an idle polling client instance lease expires. Hooks with outstanding routed work remain available until that work expires. |
| `EXIRON_PENDING_TIMEOUT_MS` | `600000` | Positive integer milliseconds before an unanswered routed request expires. |
| `EXIRON_SEND_TIMEOUT_MS` | `30000` | Positive integer milliseconds a response or push caller waits for Telegram delivery to complete before receiving a timeout result. Timeout means the delivery result is unknown; Telegram may still receive the message after the caller gets the timeout. |
| `EXIRON_MAX_PENDING` | `1000` | Maximum number of pending routed requests kept in memory. New routed requests are rejected with an overload notice once the cap is reached. |
| `EXIRON_MAX_QUEUE_PER_HOOK` | `100` | Maximum queued messages per hook. Routed requests reject newest; listen queues drop oldest stale messages. |
| `EXIRON_MAX_BUFFERED_BYTES` | `268435456` | Shared encoded payload byte budget across every hook queue and unacknowledged HTTP/WebSocket batch. Rejects new work when full. |
| `EXIRON_MAX_QUEUE_BYTES_PER_HOOK` | `52428800` | Maximum encoded queued payload bytes per hook. Routed requests that would exceed the cap are rejected. |
| `EXIRON_MAX_EVENT_IMAGE_PREVIEW_BYTES` | `8388608` | Maximum raw image payload bytes eligible for a dashboard/status preview. Set to `0` to disable image previews. This does not limit message delivery. |
| `EXIRON_MAX_EVENT_IMAGE_HISTORY_BYTES` | `67108864` | Maximum Base64 data-URI bytes retained across event history. Older previews are discarded while event metadata remains. Set to `0` to disable image previews. |
| `EXIRON_API_BODY_LENGTH` | `53477376` | Maximum JSON/urlencoded request body bytes accepted by the API parser. Fixed 51 MiB default, independent of per-hook queue capacity. |
| `EXIRON_MAX_IN_FLIGHT_SEND_BYTES` | `268435456` | Global active-send payload and option byte budget, including coordinator waits. |
| `EXIRON_MAX_IN_FLIGHT_SEND_BYTES_PER_HOOK` | `67108864` | Per-hook active-send byte budget; also bounded by the global budget. |
| `EXIRON_MAX_IN_FLIGHT_SENDS` | `100` | Global active delivery cap; saturated sends return `send_queue_full` with a retry hint. |
| `EXIRON_MAX_IN_FLIGHT_SENDS_PER_HOOK` | `10` | Active delivery cap per hook across responses, pushes, edits, chat actions and background notices. Saturated hooks return `hook_send_queue_full`; the global cap still applies. |
| `EXIRON_DASHBOARD_PASSWORD` | required in prod | Password for browser dashboard access. |
| `EXIRON_DASHBOARD_SESSION_MAX_AGE_SECONDS` | `5184000` | Maximum dashboard session and persistent login-cookie lifetime in seconds (60 days by default). Existing sessions are also invalidated when the dashboard password changes. |
| `EXIRON_TRUSTED_PROXIES` | empty | Comma-separated proxy IPs or CIDRs trusted for forwarded client addresses and HTTPS scheme reporting. |
| `EXIRON_TELEGRAM_POLLERS_ENABLED` | `false` in dev; `true` in prod | Enable incoming Telegram polling. |
| `EXIRON_METRICS_TOKEN` | unset | Enable `/metrics` using a dedicated bearer token. |
| `EXIRON_METRICS_TOKEN_FILE` | unset | Read the metrics token from a file; a direct token takes precedence. |

</details>

## API

Workers authenticate with `Authorization: Bearer <hook-token>`. The SDKs manage
these headers and encode binary payloads as Base64. Custom clients can use the
same API and raw JSON WebSocket transport.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/status` | Return hub status, hook states, routes, recent message events, and recent client lifecycle events. |
| `POST` | `/api/auth` | Validate a hook token and return its configured hook. |
| `GET` | `/api/socket` | Open a raw JSON websocket for managed clients. Requires `client_id`; accepts optional boolean `listen`. |
| `GET` | `/api/requests` | Poll queued Telegram requests and renew the identified client instance lease. Requires `client_id`; accepts optional `listen`, `delivery_mode`, and `delivery_ack`. |
| `POST` | `/api/responses` | Send a one-shot response, or explicitly update an unfinished text reply. |
| `POST` | `/api/actions` | Send typing/upload indicators for an owned pending request. |
| `POST` | `/api/edits` | Edit a retained completed text reply by request ID. |
| `POST` | `/api/push` | Push a message from the hook to all push-enabled routed chats, or one when `chat_id` is supplied. |

This is a selection of endpoints. See the [protocol specification](SPEC.md) and
[capability discovery](docs/capability-discovery.md) before implementing a custom
client. SDK package versions, wire protocol versions, and configuration schema
versions are separate; negotiate capabilities instead of inferring them from a
package version.

`POST /api/auth` is strictly IP rate limited. Bearer API requests have an
independent `1200/min` limit per hashed token and a separate `60000/min` IP abuse
ceiling. See [client reconnection](docs/client-reconnection.md) for retry hints
and budgets. Configure trusted proxies so IP limits see the intended client address.

## Operating Exiron

- **Check health:** `/health/live` tests whether the endpoint responds;
  `/health/ready` checks Hub initialization. Readiness does not verify Telegram
  credentials or promise delivery. See [health checks](docs/health-checks.md).
- **Inspect work:** `/monitor` shows request activity, delivery failures, queue
  pressure, and client state. Open a hook's workspace for its routes, requests,
  connection details, SDK version, and client-reported runtime.
- **Keep metric history:** follow the [Prometheus setup](monitoring/README.md).
  `/metrics` stays disabled until a dedicated metrics token is configured.
- **Restart deliberately:** use [graceful drain](docs/graceful-drain.md) before a
  planned restart. Releases include `bin/exiron-safe-restart`; it verifies a new
  boot and readiness but does not automatically roll back a failed deployment.
- **Size for your workload:** use the [benchmark harness](benchmarks/README.md)
  with representative traffic and hardware. Synthetic results do not establish
  production capacity.

## Documentation

| Area | Guides |
| --- | --- |
| Client integration | [Go](clients/go/README.md), [Elixir](clients/elixir/README.md), [option reference](docs/client-reference.md), [runnable workers](docs/managed-worker-examples.md) |
| Replies and media | [Rich messages and streaming](docs/rich-messages.md), [long text](docs/long-text.md), [captions](docs/media-captions.md), [reply context](docs/reply-context.md), [payload limits](docs/payload-limits.md) |
| Telegram interactions | [Inline buttons and callbacks](docs/inline-buttons.md), [in-chat controls](docs/chat-interactions.md), [response feedback](docs/response-feedback.md) |
| Worker lifecycle | [Concurrency and conversation ordering](docs/client-concurrency.md), [cancellation](docs/cooperative-cancellation.md), [deadlines](docs/handler-deadlines.md), [lease renewal](docs/http-lease-renewal.md), [shutdown](docs/client-shutdown.md), [reconnection](docs/client-reconnection.md) |
| Worker recovery | [Handler reports](docs/handler-reporting.md), [quarantine](docs/handler-quarantine.md), [local runtime status](docs/client-runtime-status.md), [runtime reporting](docs/client-runtime-reporting.md) |
| Delivery and limits | [Guarantees](docs/delivery-guarantees.md), [idempotency](docs/idempotency.md), [request cancellation](docs/request-cancellation.md), [send fairness](docs/send-fairness.md), [buffer budget](docs/buffer-budget.md), [send byte budgets](docs/send-byte-budget.md) |
| Telegram sends | [Outbound coordination](docs/telegram-sending.md), [rejection suppression](docs/telegram-rejection-suppression.md), [delivery diagnostics](docs/delivery-diagnostics.md) |
| Dashboard and diagnostics | [Request tracing](docs/request-tracing.md), [shareable views](docs/monitor-views.md), [client visibility](docs/client-visibility.md), [manual messages](docs/manual-messages.md), [diagnostic exports](docs/request-diagnostics.md) |
| Configuration | [Example YAML](config/config.example.yml), [reload](docs/configuration-reload.md), [history and rollback](docs/configuration-history.md), [diagnostics](docs/configuration-diagnostics.md) |
| Monitoring and operations | [Health](docs/health-checks.md), [operational visibility](docs/operational-visibility.md), [Prometheus](monitoring/README.md), [graceful drain](docs/graceful-drain.md) |
| Protocol and compatibility | [Specification](SPEC.md), [capability discovery](docs/capability-discovery.md), [shared lifecycle scenarios](clients/contract/lifecycle/README.md) |
| Builds and compatibility | [Build and deploy](docs/building.md), [compatibility](docs/compatibility.md), [upgrading](docs/upgrading.md), [changelog](CHANGELOG.md) |

## Development

```sh
mix setup
mix precommit
```

`mix precommit` checks formatting, compilation warnings, version and protocol
consistency, contract fixtures, benchmark smoke workloads, server tests, and
both SDK test suites. It also runs Go formatting checks and `go vet`.
The [CI workflow](.github/workflows/ci.yml) runs the complete gate on Linux with
OTP 27.3 and 28.0 and builds an isolated Linux test release.

For an isolated release smoke test:

```sh
MIX_ENV=test mix run --no-start scripts/release_smoke.exs
```

This checks a temporary test release, not a production deployment or real
Telegram connectivity. See [building and deploying](docs/building.md) for production
build and verification steps.

## License

Exiron is available under the [MIT License](LICENSE).
