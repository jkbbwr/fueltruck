# syntax=docker/dockerfile:1
#
# Fueltruck runs as the container's service with `dumb-init` as real PID1, so it
# reaps zombies and forwards signals (SIGTERM → graceful deploy shutdown + backup).
#
# The Arma dedicated server binary and workshop mods are NOT baked in — they are
# downloaded by steamree into the mounted /data volume at runtime. Provide the
# steamree executable on PATH (or via STEAMREE_BIN) and mount /data as a volume.

ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.1.2
ARG DEBIAN_VERSION=bookworm-20241016-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

RUN mix assets.deploy
RUN mix compile

COPY config/runtime.exs config/
RUN mix release

# ---- runtime ----
FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
    && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates dumb-init \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

# Persistent volume: server install, workshop store, deploys, backups, logs, sqlite db.
ENV FUELTRUCK_DATA_DIR="/data" \
    DATABASE_PATH="/data/fueltruck.db" \
    STEAMREE_BIN="steamree" \
    PHX_SERVER="true" \
    MIX_ENV="prod"

RUN mkdir -p /data && chown nobody /data
VOLUME /data

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/fueltruck ./

USER nobody
EXPOSE 4000

# dumb-init is PID1: reaps zombies from spawned arma/HC processes and forwards signals.
ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["/app/bin/fueltruck", "start"]
