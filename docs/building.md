# Building and deploying Exiron

See the [README](../README.md) for initial configuration and running from source
or Docker. This guide covers production builds, container images and build
identity. See [upgrading](upgrading.md) when replacing a running instance.

## Build from source

Use Elixir and Erlang/OTP versions supported by the [CI matrix](../.github/workflows/ci.yml).
Build on an OS and architecture compatible with the target: Mix releases include
the Erlang runtime and native dependencies.

From the repository root:

```sh
mix setup
mix precommit
MIX_ENV=prod mix deps.get --only prod --check-locked
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite
```

The executable is `_build/prod/rel/exiron/bin/exiron`. Configure the application
through its environment and a writable configuration directory. At minimum,
set `SECRET_KEY_BASE`, `EXIRON_DASHBOARD_PASSWORD`, and `PHX_HOST`, then enable
the web server when starting:

```sh
PHX_SERVER=true _build/prod/rel/exiron/bin/exiron start
```

Keep secrets outside build artifacts and source control. See the
[runtime configuration reference](../README.md#configuration) and
[network setup](../README.md#network-access-and-reverse-proxies).

## Container images

The [CI workflow](../.github/workflows/ci.yml) builds AMD64 and ARM64 images after
all tests and the isolated release smoke job pass on pushes to `main`.
Pull requests, other branches and tag pushes do not build images.

The image is `ghcr.io/c2bw/exiron`, with `latest` and `sha-<full-commit>` tags.
`latest` follows successful builds of `main`. Use an image digest when a
deployment or rollback must select exactly the same artifact.

For a local build:

```sh
docker build -t exiron:local .
```

The [Docker instructions](../README.md#run-with-docker) describe secrets,
configuration mounts, permissions and Compose. CI uses its `GITHUB_TOKEN` for
GHCR authentication. Anonymous pulls require the GHCR package to be public.

## Build identity

Server and SDK versions are separate from protocol and configuration schema
versions; see [compatibility](compatibility.md). Release assembly writes
`releases/<version>/build-info.json` containing the server version, protocol,
source commit, working-tree state and build Elixir/OTP versions.

Inspect the identity of a running release:

```sh
bin/exiron rpc 'IO.inspect(Exiron.BuildInfo.current())'
```

Source runs and builds without Git metadata may report unknown provenance.
Docker excludes `.git` from the context, so supply build metadata explicitly:

```sh
docker build \
  --build-arg EXIRON_BUILD_COMMIT="$(git rev-parse HEAD)" \
  --build-arg EXIRON_BUILD_DIRTY=false \
  -t exiron:local .
```

Use `false` only for a clean checkout, `true` for modified source, or `unknown`
when the state cannot be established. These arguments record build-time
assertions, not signed proof of the source contents. GitHub CI supplies the
checked-out commit and clean state automatically.

Mix builds are platform dependent and do not promise byte-identical archives.
Keep the built artifact and its checksum for deployment and rollback. Container
builds can pin the Dockerfile's builder and runner image arguments to chosen
image digests.

## Verify a build

Run the isolated release smoke test:

```sh
MIX_ENV=test mix run --no-start scripts/release_smoke.exs
```

This starts a temporary test release and checks packaged metadata and readiness.
It does not verify production secrets, TLS routing or Telegram connectivity.

Check a production artifact's metadata against the checkout:

```sh
MIX_ENV=test mix run --no-start scripts/check_versions.exs -- \
  --release _build/prod/rel/exiron --require-clean
```

`--require-clean` requires a known source commit and a clean working tree at
build time. This metadata check does not start the artifact. After deployment,
check [readiness](health-checks.md), worker connections and intended routing.
