# Versions and compatibility

Exiron has independently versioned components:

| Component | Version source | Purpose |
| --- | --- | --- |
| Server | Root `VERSION` | Identifies the running application. |
| Elixir SDK | `clients/elixir/VERSION` | Identifies the SDK through `ExironClient.Version.current/0`. |
| Go SDK | `clients/go/VERSION` | Identifies the SDK through `exiron.Version()`. |
| Wire protocol | `clients/contract/manifest.json` | Describes API capabilities shared by server and clients. |
| Configuration schema | YAML `version` field | Selects the configuration format. Schema 1 and 2 are supported. |

SDKs are installed from Git. Pin the selected source in the application's
`mix.lock`, or `go.mod` and `go.sum`; see the [Elixir](../clients/elixir/README.md#installation)
and [Go](../clients/go/README.md#installation) installation instructions.
The SDK version shown in the dashboard identifies the SDK version file, not
the consuming application's Git commit. Keep dependency lockfiles to identify
the exact SDK source used in a build.

## Feature negotiation

Use [capability discovery](capability-discovery.md) to determine which features
the server supports. SDK and server version strings do not replace negotiation.
Optional lifecycle controls can require explicit server capabilities. Automatic
[runtime reporting](client-runtime-reporting.md) negotiates support separately
from SDK version reporting.

Install server support before enabling new client features. Existing HTTP and
WebSocket transports, one-shot replies and explicit streaming remain supported.
See [upgrading](upgrading.md) for coordinated updates and rollback limits.

## Development checks

`mix precommit` validates component versions, compiled server identity, protocol
fixtures, configuration examples and Go module paths, alongside the server and
SDK test suites. When changing a component version, update its version source,
affected fixtures and compatibility notes together. Use
[build identity](building.md#build-identity) to inspect an assembled application.
