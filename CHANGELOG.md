# Changelog

## Unreleased

### Server and operations

- Show media captions in the Overview traffic log, preserving line breaks and retaining full captions in activity events.

- Preserve optional Telegram sticker `file_unique_id` through request/listen delivery, replay, activity events and both SDKs; retain sendable `sticker_id` behavior.

- Capability discovery and protocol 1.20 support, with additive client controls.
- Bounded queues, buffered payload/send byte budgets, fair sends and overload diagnostics.
- Request tracing, delivery certainty diagnostics, cancellation and client runtime visibility.
- Configuration validation, controlled reload, history and explicit rollback.
- Graceful drain and a release helper that verifies a new boot and Hub readiness.
- Isolated release smoke verification and Linux CI coverage.
- Opt-in Telegram Status/Cancel cards, reply-based follow-ups and chat-scoped help.
- Explicit user access lists and request-control administrators (configuration schema 2).
- Dedicated hook workspaces, reviewed manual messages and sanitized diagnostic downloads.
- Workspace failure explanations link to the exact retained delivery diagnostic.
- Composer destination memory and unsent-draft navigation warnings within a browser tab.
- Owner-bound command buttons in chat help, with current routing and access checks.
- Guided command reply prompts preserve owner, bot, chat and topic scope.
- Dashboard composer supports reviewed photo/file uploads and literal captions.
- Monitor filters and inspectors synchronize with shareable URLs and browser history.
- Hook views display the connected SDK and its reported package version.

### Go and Elixir SDKs

- Enable managed SDK runtime reporting automatically when capability discovery advertises support, with explicit opt-out options and compatibility with older servers.
- Optional bounded concurrency, per-conversation ordering, cooperative cancellation,
  local handler deadlines, lease renewal, graceful drain and handler reports.
- Explicit bounded in-memory quarantine, manual recovery and runtime observations.
- Selectable one-shot/streamed text, rich messages and optional idempotent mutations.
- Safe diagnostics, distinct timeout/control classifications and optional sanitized
  API completion hooks. Raw error fields remain available for explicit inspection.
- Shared executable HTTP/WebSocket lifecycle scenarios and runnable reference workers.
- Reference workers demonstrate optional feedback and follow-up links with both reply modes.
- Elixir streamed replies check managed cancellation before updates/finalization.
- Follow-up request links are exposed to both SDKs through optional `followup_req_id`.
- Optional feedback keyboard builders and rating parsers using existing callbacks.
- Automatic package version reporting on HTTP requests and WebSocket connections.
- Elixir WebSocket retry budgets reset only after server acceptance, and connected
  sessions report disconnect once on shutdown or failure.

### Compatibility and upgrade notes

- Existing transports, one-shot replies and explicit streaming remain supported.
- Lifecycle features remain opt-in; the reference workers enable several deliberately.
- Deploy a capable server before enabling SDK features requiring negotiation.
- Wire protocol `1.20`, package versions and configuration schema `2` are separate; schema `1` remains supported without access lists.
- Delivery, quarantine, reports and receipts remain in memory and are lost on restart.

See the [upgrade guide](docs/upgrading.md) for coordinated updates and rollback
limits, and [compatibility](docs/compatibility.md) for protocol and SDK versions.
