ARG ELIXIR_VERSION=1.20
ARG ALPINE_RUNNER_VERSION=3.24

ARG BUILDER_IMAGE="elixir:${ELIXIR_VERSION}-alpine"
ARG RUNNER_IMAGE="alpine:${ALPINE_RUNNER_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apk add --no-cache build-base ca-certificates git npm openssl && \
    update-ca-certificates

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"
ARG PHX_FORCE_SSL=false
ENV PHX_FORCE_SSL=${PHX_FORCE_SSL}

# install mix dependencies
COPY mix.exs mix.lock VERSION ./
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

COPY config/*.exs config/
COPY assets assets
COPY clients/contract clients/contract
COPY lib lib
COPY priv priv
COPY rel rel

# Compile the release
RUN mix compile
RUN mix assets.deploy

ARG EXIRON_BUILD_COMMIT=""
ARG EXIRON_BUILD_DIRTY=unknown
RUN EXIRON_BUILD_COMMIT="${EXIRON_BUILD_COMMIT}" EXIRON_BUILD_DIRTY="${EXIRON_BUILD_DIRTY}" mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

RUN apk add --no-cache libstdc++ ncurses-libs openssl && \
    addgroup -S nonroot && \
    adduser -S nonroot -G nonroot

WORKDIR "/app"

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nonroot:nonroot /app/_build/${MIX_ENV}/rel/exiron ./

USER nonroot

CMD ["/app/bin/exiron", "start"]
