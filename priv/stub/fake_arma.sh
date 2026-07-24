#!/usr/bin/env bash
# A stand-in for the Arma dedicated server / headless client used for local dev and
# tests. It emits a readiness line, then heartbeat logs, and handles signals so
# MuonTrap can stop it cleanly. Env:
#   FAKE_ARMA_READY_DELAY  seconds before printing the readiness line (default 0)
#   FAKE_ARMA_EXIT_AFTER   exit non-zero after N seconds (to exercise auto-restart)
set -u

ready_delay="${FAKE_ARMA_READY_DELAY:-0}"
exit_after="${FAKE_ARMA_EXIT_AFTER:-0}"

trap 'echo "received SIGTERM, shutting down"; exit 0' TERM
trap 'echo "received SIGINT, shutting down"; exit 0' INT

echo "fake-arma starting with args: $*"
sleep "$ready_delay"
echo "Host identity created."

i=0
start=$(date +%s)
while true; do
  i=$((i + 1))
  echo "heartbeat $i pid=$$ ts=$(date +%s)"
  if [ "$exit_after" -gt 0 ]; then
    now=$(date +%s)
    if [ $((now - start)) -ge "$exit_after" ]; then
      echo "fake-arma exiting non-zero to simulate a crash"
      exit 1
    fi
  fi
  sleep 0.2
done
