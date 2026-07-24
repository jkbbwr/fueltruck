# Fueltruck — Arma 3 Server Manager

Fueltruck runs inside a container (with `dumb-init` as real PID1) and manages a single
active Arma 3 dedicated server plus 0..m headless clients. It provides a Phoenix LiveView
dashboard for lifecycle control, live log streaming, deploy/mod management, and resource
metrics.

## Core decisions

- **Process supervision:** `MuonTrap` wraps every managed OS process in its own cgroup (v2
  on Linux) so children are guaranteed to die with the BEAM and so we can read accurate
  per-process CPU/mem. On non-Linux dev hosts cgroups are skipped and metrics fall back to
  `ps`. Children are OTP `:temporary`; restart decisions belong to the orchestrator.
- **One active deploy at a time.** Many deploys are stored; exactly one runs. Switching =
  stop current → repoint → start.
- **Server auto-restarts** on crash (exponential backoff, giveup) unless stopped by a user.
  HCs auto-restart the same way. Stopping the server cascades to HCs. Server down ⇒ HCs
  paused; server back ⇒ HCs resume.
- **Downloads** go through `steamree` (custom, JSON event stream, manages its own
  parallelism + update checks). One invocation at a time.
- **Mods live once** in a content store keyed by workshop id; deploys are directories of
  symlinks + generated configs + collected BattlEye keys. A post-download **lowercasing**
  pass fixes Linux case-sensitivity, idempotent per mod version.
- **Presets** = Arma Launcher `.html` mod-list import **and** export.
- **Logs:** RAM ring buffer (large, ~50k lines/source) for live tail + append-only disk
  files per run with a sparse offset index for reverse-scroll history + rollover/retention.
- **No auth** (trusted LAN) for now.

## Supervision tree

```
Fueltruck.Application
├── Fueltruck.Repo (SQLite)
├── Phoenix.PubSub
├── Fueltruck.Logs.Registry            # {source} -> LogCollector
├── Fueltruck.Logs.Supervisor          # DynamicSupervisor of LogCollectors
├── Fueltruck.Logs.Janitor             # rollover + retention sweeps
├── Fueltruck.Metrics.Sampler          # cgroup / ps + :os_mon -> PubSub
├── Fueltruck.Downloads.Queue          # single steamree runner
├── Fueltruck.Arma.ProcSupervisor      # DynamicSupervisor of ManagedProcess
├── Fueltruck.Arma.Orchestrator        # owns active deploy, lifecycle + cascade
└── FueltruckWeb.Endpoint
```

## Milestones

1. Storage/config + Ecto schemas & contexts (Deploys, Mods).
2. Process core: backend, ManagedProcess (gen_statem), Orchestrator, ProcSupervisor.
3. Logs: LogCollector (ring + disk + index), Janitor, PubSub batching.
4. Downloads: steamree Queue + JSON parsing + progress.
5. Mod store: lowercasing, deploy materialize (symlinks + configs + keys), command line.
6. Presets import/export.
7. Metrics: cgroup/ps sampler + os_mon, sparkline history.
8. LiveView dashboard + JS hooks (log stream, reverse scroll, sparklines) + UI polish.
