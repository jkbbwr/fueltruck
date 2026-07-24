#!/bin/sh
# PID2 under dumb-init. Runs as root so it can prepare the mounted volume, then drops
# to the unprivileged `arma` user to run the release.
#
# Why not `nobody`: the Arma dedicated server's Steam integration (steamclient.so)
# segfaults on boot when run as uid 65534 (the kernel overflow / nobody uid), even
# with a valid HOME. A normal uid (arma:1000) boots fine, so we run as that instead.
set -e

# Ensure the Steam HOME exists and is owned by arma (getpwuid home = /data/home).
mkdir -p /data/home
chown arma:arma /data /data/home 2>/dev/null || true

# The volume may have been created under a previous uid (e.g. nobody). Migrate
# ownership once; a sentinel keeps subsequent restarts from re-walking the whole tree.
if [ ! -e /data/.owner-arma ]; then
  echo "entrypoint: migrating /data ownership to arma (first boot)…"
  chown -R arma:arma /data
  touch /data/.owner-arma && chown arma:arma /data/.owner-arma
fi

# Drop privileges (no fork, no PAM) and hand off to the release in the foreground.
exec setpriv --reuid arma --regid arma --init-groups /app/bin/fueltruck start
