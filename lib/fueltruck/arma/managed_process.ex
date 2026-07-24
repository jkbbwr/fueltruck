defmodule Fueltruck.Arma.ManagedProcess do
  @moduledoc """
  A `gen_statem` that owns exactly one OS process (the server or one headless client)
  via `MuonTrap.Daemon`.

  * Every stdout line is streamed to the process's log source (batched downstream).
  * On an unexpected exit it auto-restarts with exponential backoff, giving up after
    `max_attempts` (→ `:failed`). A fueltruck-initiated stop suppresses restart.
  * Readiness is inferred from a log line pattern; the orchestrator waits for the
    server to be ready before starting headless clients.
  * Exposes an OS pid + cgroup path so metrics can be sampled accurately.

  The daemon is monitored (not linked), so a daemon crash is a `:DOWN` message we
  decide how to act on, while a supervisor shutdown terminates us normally.

  States: `:stopped`, `:running`, `:restarting`, `:failed`.
  """
  @behaviour :gen_statem

  require Logger
  alias Fueltruck.{Arma, Logs, Storage}
  alias Fueltruck.Arma.CommandLine

  @default_max_attempts 10
  @default_backoff_base 1_000
  @default_backoff_cap 60_000
  @default_stable_ms 60_000
  @default_readiness ~r/Host identity created|Dedicated host created|Game Port:/

  defstruct [
    :source,
    :argv,
    :cwd,
    :readiness_re,
    :daemon_pid,
    :daemon_ref,
    :os_pid,
    :cgroup_path,
    :cgroup_controllers,
    :started_mono,
    :last_error,
    max_attempts: @default_max_attempts,
    backoff_base: @default_backoff_base,
    backoff_cap: @default_backoff_cap,
    stable_ms: @default_stable_ms,
    attempts: 0,
    ready: false
  ]

  ## Client API

  def child_spec(opts) do
    source = Keyword.fetch!(opts, :source)

    %{
      id: {__MODULE__, source},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  def start_link(opts) do
    source = Keyword.fetch!(opts, :source)
    :gen_statem.start_link(via(source), __MODULE__, opts, [])
  end

  defp via(source), do: {:via, Registry, {Fueltruck.Arma.Registry, source}}

  @doc "Locate a managed process by source."
  def whereis(source) do
    case Registry.lookup(Fueltruck.Arma.Registry, source) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Start (or resume) the OS process. Synchronous."
  def start(source), do: call(source, :start)

  @doc "Stop the OS process; suppresses auto-restart. Synchronous."
  def stop(source), do: call(source, :stop)

  @doc "Restart the OS process (user-initiated; resets backoff)."
  def restart(source), do: call(source, :restart)

  @doc "Current status map."
  def status(source), do: call(source, :status)

  @doc "Handle used by the metrics sampler: %{os_pid, cgroup_path, ...}."
  def metrics_handle(source), do: call(source, :metrics)

  defp call(source, msg) do
    case whereis(source) do
      nil -> {:error, :not_found}
      pid -> :gen_statem.call(pid, msg)
    end
  end

  ## gen_statem

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(opts) do
    data = %__MODULE__{
      source: Keyword.fetch!(opts, :source),
      argv: Keyword.fetch!(opts, :argv),
      cwd: Keyword.fetch!(opts, :cwd),
      readiness_re: Keyword.get(opts, :readiness_re, @default_readiness),
      max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
      backoff_base: Keyword.get(opts, :backoff_base, @default_backoff_base),
      backoff_cap: Keyword.get(opts, :backoff_cap, @default_backoff_cap),
      stable_ms: Keyword.get(opts, :stable_ms, @default_stable_ms),
      cgroup_controllers: Keyword.get(opts, :cgroup_controllers, default_controllers())
    }

    if Keyword.get(opts, :autostart, false) do
      {:ok, :stopped, data, [{:next_event, :internal, :spawn}]}
    else
      {:ok, :stopped, data}
    end
  end

  # --- start ---

  @impl true
  def handle_event({:call, from}, :start, state, data) when state in [:stopped, :failed] do
    case spawn_daemon(reset_attempts(data)) do
      {:ok, data} ->
        broadcast(:running, data)
        {:next_state, :running, data, [{:reply, from, :ok}]}

      {:error, reason, data} ->
        broadcast(:failed, data)
        {:next_state, :failed, data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, :start, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_running}}]}
  end

  def handle_event(:internal, :spawn, _state, data) do
    case spawn_daemon(data) do
      {:ok, data} ->
        broadcast(:running, data)
        {:next_state, :running, data}

      {:error, _reason, data} ->
        broadcast(:failed, data)
        {:next_state, :failed, data}
    end
  end

  # --- readiness ---

  def handle_event(:info, :ready, :running, %{ready: false} = data) do
    data = %{data | ready: true}
    broadcast(:ready, data)
    {:keep_state, data}
  end

  def handle_event(:info, :ready, _state, _data), do: :keep_state_and_data

  # --- stop ---

  def handle_event({:call, from}, :stop, _state, data) do
    data = kill_daemon(data)
    broadcast(:stopped, data)
    {:next_state, :stopped, %{data | ready: false}, [{:reply, from, :ok}]}
  end

  # --- restart (user) ---

  def handle_event({:call, from}, :restart, _state, data) do
    data = data |> kill_daemon() |> Map.put(:ready, false) |> reset_attempts()

    case spawn_daemon(data) do
      {:ok, data} ->
        broadcast(:running, data)
        {:next_state, :running, data, [{:reply, from, :ok}]}

      {:error, reason, data} ->
        broadcast(:failed, data)
        {:next_state, :failed, data, [{:reply, from, {:error, reason}}]}
    end
  end

  # --- status / metrics ---

  def handle_event({:call, from}, :status, state, data) do
    {:keep_state_and_data, [{:reply, from, status_map(state, data)}]}
  end

  def handle_event({:call, from}, :metrics, _state, data) do
    handle = %{
      source: data.source,
      os_pid: data.os_pid,
      cgroup_path: data.cgroup_path,
      cgroup_controllers: data.cgroup_controllers,
      daemon_pid: data.daemon_pid
    }

    {:keep_state_and_data, [{:reply, from, handle}]}
  end

  # --- daemon down ---

  def handle_event(
        :info,
        {:DOWN, ref, :process, pid, reason},
        :running,
        %{daemon_ref: ref, daemon_pid: pid} = data
      ) do
    data = %{data | daemon_pid: nil, daemon_ref: nil, os_pid: nil, ready: false}
    handle_daemon_down(reason, data)
  end

  # Stale DOWN from a superseded daemon: ignore.
  def handle_event(:info, {:DOWN, _ref, :process, _pid, _reason}, _state, _data),
    do: :keep_state_and_data

  # --- backoff fired ---

  def handle_event(:state_timeout, :restart, :restarting, data) do
    case spawn_daemon(data) do
      {:ok, data} ->
        broadcast(:running, data)
        {:next_state, :running, data}

      {:error, _reason, data} ->
        handle_daemon_down(:spawn_error, data)
    end
  end

  def handle_event(_type, _content, _state, _data), do: :keep_state_and_data

  @impl true
  def terminate(_reason, _state, data) do
    _ = kill_daemon(data)
    :ok
  end

  ## Internals

  defp handle_daemon_down(reason, data) do
    Logger.warning("#{Logs.source_key(data.source)} exited: #{inspect(reason)}")

    data = maybe_reset_stable(data)
    attempts = data.attempts + 1
    data = %{data | attempts: attempts, last_error: reason}

    if attempts <= data.max_attempts do
      delay = backoff_delay(data)
      broadcast(:crashed, data)
      broadcast({:restarting, delay, attempts}, data)

      Logs.marker(
        data.source,
        "process exited (#{inspect(reason)}); restart ##{attempts} in #{delay}ms"
      )

      {:next_state, :restarting, data, [{:state_timeout, delay, :restart}]}
    else
      broadcast(:failed, data)
      Logs.marker(data.source, "process failed after #{data.max_attempts} restart attempts")
      {:next_state, :failed, data}
    end
  end

  # If the process ran long enough to be considered stable, forget prior failures.
  defp maybe_reset_stable(%{started_mono: nil} = data), do: data

  defp maybe_reset_stable(data) do
    uptime = System.monotonic_time(:millisecond) - data.started_mono
    if uptime >= data.stable_ms, do: %{data | attempts: 0}, else: data
  end

  defp reset_attempts(data), do: %{data | attempts: 0, last_error: nil}

  defp backoff_delay(%{attempts: n, backoff_base: base, backoff_cap: cap}) do
    min(base * Integer.pow(2, n - 1), cap)
  end

  defp spawn_daemon(data) do
    {exe, args} = data.argv
    opts = daemon_opts(data)

    case MuonTrap.Daemon.start_link(exe, args, opts) do
      {:ok, pid} ->
        # Monitor rather than link so a daemon crash is a decision, not our death.
        Process.unlink(pid)
        ref = Process.monitor(pid)

        os_pid =
          case MuonTrap.Daemon.os_pid(pid) do
            n when is_integer(n) -> n
            _ -> nil
          end

        {:ok,
         %{
           data
           | daemon_pid: pid,
             daemon_ref: ref,
             os_pid: os_pid,
             cgroup_path: opts[:cgroup_path],
             started_mono: System.monotonic_time(:millisecond),
             ready: false
         }}

      {:error, reason} ->
        {:error, reason, %{data | last_error: reason}}
    end
  rescue
    e -> {:error, e, %{data | last_error: e}}
  end

  defp daemon_opts(data) do
    me = self()
    source = data.source
    re = data.readiness_re

    logger_fun = fn line ->
      Logs.append(source, line)
      if re && Regex.match?(re, line), do: send(me, :ready)
    end

    base = [
      cd: data.cwd,
      stderr_to_stdout: true,
      logger_fun: logger_fun,
      # Arma boots Steam via $HOME/.steam/sdk64/steamclient.so; the base image's
      # HOME=/nonexistent makes that fail and segfault, so point it at a writable dir.
      env: [{"HOME", Storage.steam_home()}],
      # SIGTERM, then SIGKILL after a grace period so Arma can flush profiles.
      delay_to_sigkill: 5_000
    ]

    if linux?() and data.cgroup_controllers != [] and cgroups_writable?() do
      base ++
        [
          cgroup_controllers: data.cgroup_controllers,
          cgroup_path: "fueltruck/" <> Logs.source_key(source)
        ]
    else
      base
    end
  end

  # Containers don't get cgroup write access unless delegated, and MuonTrap's cgroup
  # setup fails hard if the fs is read-only. Probe once and cache — if we can't create a
  # cgroup, run without it (the process still gets muontrap's kill-on-exit guarantee;
  # metrics fall back to ps).
  defp cgroups_writable? do
    case :persistent_term.get({__MODULE__, :cgroups_writable}, :unknown) do
      :unknown ->
        result = probe_cgroups()
        :persistent_term.put({__MODULE__, :cgroups_writable}, result)
        result

      result ->
        result
    end
  end

  defp probe_cgroups do
    probe = "/sys/fs/cgroup/.fueltruck_probe"

    case File.mkdir(probe) do
      :ok ->
        File.rmdir(probe)
        true

      {:error, :eexist} ->
        true

      _ ->
        false
    end
  end

  defp kill_daemon(%{daemon_pid: nil} = data), do: data

  defp kill_daemon(%{daemon_pid: pid, daemon_ref: ref} = data) do
    if ref, do: Process.demonitor(ref, [:flush])

    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :shutdown, 10_000)
      catch
        :exit, _ -> :ok
      end
    end

    %{data | daemon_pid: nil, daemon_ref: nil, os_pid: nil}
  end

  defp status_map(state, data) do
    %{
      source: data.source,
      label: Logs.source_label(data.source),
      state: state,
      ready: data.ready,
      os_pid: data.os_pid,
      attempts: data.attempts,
      last_error: data.last_error && inspect(data.last_error),
      command: CommandLine.to_string(data.argv),
      argv: data.argv
    }
  end

  defp broadcast(event, data), do: Arma.broadcast_status(status_from_event(data, event))

  defp status_from_event(data, event) do
    base = %{
      source: data.source,
      label: Logs.source_label(data.source),
      os_pid: data.os_pid,
      attempts: data.attempts,
      last_error: data.last_error && inspect(data.last_error)
    }

    case event do
      :running ->
        Map.merge(base, %{state: :running, ready: false, event: :running})

      :ready ->
        Map.merge(base, %{state: :running, ready: true, event: :ready})

      :stopped ->
        Map.merge(base, %{state: :stopped, ready: false, event: :stopped})

      :crashed ->
        Map.merge(base, %{state: :running, ready: false, event: :crashed})

      :failed ->
        Map.merge(base, %{state: :failed, ready: false, event: :failed})

      {:restarting, delay, attempt} ->
        Map.merge(base, %{
          state: :restarting,
          ready: false,
          event: {:restarting, delay, attempt}
        })
    end
  end

  defp default_controllers do
    if linux?(), do: ["cpu", "memory"], else: []
  end

  defp linux?, do: match?({:unix, :linux}, :os.type())
end
