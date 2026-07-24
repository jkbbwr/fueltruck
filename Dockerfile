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
# Runtime uses a newer glibc (trixie, 2.41) so the steamree binary (needs GLIBC_2.38)
# runs. The ERTS built on bookworm (2.36) is forward-compatible with newer glibc.
ARG RUNNER_IMAGE="debian:trixie-slim"

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

# Compile first so the LiveView colocated hooks/CSS
# (phoenix-colocated/fueltruck/colocated.css) exist before tailwind/esbuild bundle.
RUN mix compile
RUN mix assets.deploy

COPY config/runtime.exs config/
RUN mix release

# ---- runtime ----
FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
    && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates dumb-init util-linux \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

# Run as a normal user (not `nobody`): the Arma server's Steam integration segfaults
# under uid 65534. Home is the /data volume so Steam's getpwuid() home is writable.
RUN groupadd -g 1000 arma \
    && useradd -u 1000 -g 1000 -d /data/home -s /bin/bash arma

WORKDIR /app
RUN chown arma:arma /app

# Persistent volume: server install, workshop store, deploys, backups, logs, sqlite db.
ENV FUELTRUCK_DATA_DIR="/data" \
    DATABASE_PATH="/data/fueltruck.db" \
    STEAMREE_BIN="steamree" \
    PHX_SERVER="true" \
    MIX_ENV="prod"

RUN mkdir -p /data && chown arma:arma /data
VOLUME /data

# steamree downloader (Linux x86-64 glibc — matches this runtime, hence non-alpine).
COPY steamree /usr/local/bin/steamree
RUN chmod 0755 /usr/local/bin/steamree

COPY --from=builder --chown=arma:arma /app/_build/prod/rel/fueltruck ./
COPY --chown=root:root entrypoint.sh /app/entrypoint.sh
RUN chmod 0755 /app/entrypoint.sh

EXPOSE 4000

# dumb-init is PID1 (reaps zombies from spawned arma/HC processes, forwards signals).
# entrypoint.sh runs as root to prep the volume, then drops to `arma` for the release.
ENTRYPOINT ["/usr/bin/dumb-init", "--", "/app/entrypoint.sh"]
