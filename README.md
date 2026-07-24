# Fueltruck

An Arma 3 dedicated server manager. Fueltruck runs inside a container as the service
process (with `dumb-init` as real PID1) and manages one active Arma 3 server plus
`0..m` headless clients, with a Phoenix LiveView control dashboard.

## Features

- **Lifecycle control** — start / stop / restart the server and each headless client.
  The server and HCs auto-restart on crash (exponential backoff) unless you stop them;
  stopping the server cascades to the HCs, and HCs (re)start when the server is ready.
- **Deploys** — named configurations of settings, mods and presets. Many are stored;
  exactly one runs at a time.
- **Mods** — downloaded once into a shared store and symlinked into each deploy. Mark
  mods **server-only** (`-serverMod`) or **disabled**; reorder for load order. A Linux
  case-sensitivity lowercasing pass and BattlEye key collection run automatically.
- **Presets** — import and export Arma 3 Launcher `.html` mod lists.
- **Downloads** — via the external `steamree` downloader (server + workshop updates),
  serialized, with live per-mod progress.
- **Live logs** — each source (server + every HC) streams to its own panel without lag:
  a large in-memory ring for the live tail, batched broadcasts, reverse-scroll history
  from disk, and search. Logs roll over to disk with retention.
- **Metrics** — per-process CPU/memory via cgroups (Linux) plus system CPU/RAM/disk.
- **Backups** — timestamped `var.profiles` archives on stop / shutdown, keep-last-N.

## Development

```sh
mix setup                 # deps, db, assets
mix phx.server            # http://localhost:4000
mix test
```

The stub `priv/stub/fake_arma.sh` stands in for the real server binary in tests/dev.
Point `config :fueltruck, Fueltruck.Arma, server_binary: …` at it to click around locally.

## Configuration

| Env var | Purpose | Default |
| --- | --- | --- |
| `FUELTRUCK_DATA_DIR` | Persistent root (server install, mod store, deploys, backups, logs, db) | `priv/data` (dev) |
| `DATABASE_PATH` | SQLite database file | — (required in prod) |
| `STEAMREE_BIN` | Path to the `steamree` executable | `steamree` |
| `SECRET_KEY_BASE` | Phoenix secret | — (required in prod) |

steamree integration lives in `Fueltruck.Downloads.Steamree` — adjust the argv there
(or via `:steamree_extra_args`) when wiring up the real binary.

## Container

```sh
docker build -t fueltruck .
docker run -p 4000:4000 -v fueltruck-data:/data \
  -e SECRET_KEY_BASE=$(mix phx.gen.secret) fueltruck
```

`dumb-init` is PID1 so orphaned Arma/HC processes are reaped and SIGTERM triggers a
graceful shutdown (stop deploy → back up profiles → exit). Provide the `steamree`
binary on `PATH` (or `STEAMREE_BIN`); the Arma server and mods download into `/data`.

See `DESIGN.md` for the architecture.
