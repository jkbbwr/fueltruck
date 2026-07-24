defmodule Fueltruck.Arma.Orchestrator do
  @moduledoc """
  Owns the single active deploy and drives its lifecycle.

  * `start_deploy/1` materializes the deploy, opens a run (log dir + collectors),
    then starts the server. When the server reports *ready*, the headless clients are
    started. If the server later leaves the ready state (crash/restart), HCs are
    stopped and re-started once it is ready again.
  * `stop_deploy/0` stops HCs, then the server, backs up `var.profiles`, and closes
    the run.

  Individual process crashes are handled by each `ManagedProcess` (auto-restart with
  backoff); the orchestrator only handles cross-process cascade.
  """
  use GenServer
  require Logger

  alias Fueltruck.{Arma, Backups, Deploys, Logs, Storage}
  alias Fueltruck.Arma.{CommandLine, ManagedProcess}
  alias Fueltruck.Deploys.Materializer

  @proc_sup Fueltruck.Arma.ProcSupervisor

  ## Client API

  def child_spec(opts) do
    # Allow up to 45s on shutdown so a graceful SIGTERM can stop the deploy and
    # back up var.profiles before the container exits.
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 45_000}
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Make `deploy` active and start it (stopping any current deploy first)."
  def start_deploy(deploy), do: GenServer.call(__MODULE__, {:start_deploy, deploy.id}, 60_000)

  @doc "Stop the active deploy (HCs, then server) and back up profiles."
  def stop_deploy, do: GenServer.call(__MODULE__, :stop_deploy, 60_000)

  @doc "Restart the whole active deploy."
  def restart_deploy, do: GenServer.call(__MODULE__, :restart_deploy, 60_000)

  @doc "Restart just the server (HCs cascade automatically)."
  def restart_server, do: GenServer.call(__MODULE__, :restart_server, 60_000)

  @doc "Restart a single headless client."
  def restart_hc(index), do: GenServer.call(__MODULE__, {:restart_hc, index}, 60_000)

  @doc "Aggregate status of the active deploy and its processes."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Run log dirs the janitor must not touch."
  def protected_log_dirs do
    GenServer.call(__MODULE__, :protected_log_dirs)
  catch
    :exit, _ -> []
  end

  ## Server

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    Arma.subscribe_procs()

    {:ok,
     %{
       phase: :idle,
       deploy: nil,
       plan: nil,
       run_id: nil,
       run_dir: nil,
       log_run: nil,
       hc_count: 0,
       server_ready: false,
       hc_active: false
     }}
  end

  # Graceful shutdown (e.g. container SIGTERM): stop the active deploy, which stops
  # the server + HCs and backs up var.profiles before we exit.
  @impl true
  def terminate(_reason, %{phase: :idle}), do: :ok
  def terminate(_reason, state), do: do_stop(state) && :ok

  @impl true
  def handle_call({:start_deploy, deploy_id}, _from, state) do
    state = if state.phase != :idle, do: do_stop(state), else: state

    case do_start(deploy_id, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stop_deploy, _from, %{phase: :idle} = state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call(:stop_deploy, _from, state) do
    {:reply, :ok, do_stop(state)}
  end

  def handle_call(:restart_deploy, _from, %{phase: :idle} = state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call(:restart_deploy, _from, state) do
    deploy_id = state.deploy.id
    state = do_stop(state)

    case do_start(deploy_id, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:restart_server, _from, %{phase: :idle} = state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call(:restart_server, _from, state) do
    {:reply, ManagedProcess.restart(:server), state}
  end

  def handle_call({:restart_hc, index}, _from, state) do
    {:reply, ManagedProcess.restart({:hc, index}), state}
  end

  def handle_call(:status, _from, state) do
    {:reply, build_status(state), state}
  end

  def handle_call(:protected_log_dirs, _from, state) do
    {:reply, (state.run_dir && [state.run_dir]) || [], state}
  end

  # Cascade: react to the server's readiness.
  @impl true
  def handle_info({:proc_status, :server, status}, %{phase: phase} = state)
      when phase in [:starting, :running] do
    ready? = status.state == :running and status.ready

    state =
      cond do
        ready? and not state.hc_active ->
          start_hcs(state)

        not ready? and state.hc_active ->
          stop_hcs(state)

        true ->
          state
      end

    {:noreply,
     %{state | server_ready: ready?, phase: if(ready?, do: :running, else: state.phase)}}
  end

  def handle_info({:proc_status, _source, _status}, state), do: {:noreply, state}

  # Parent/supervisor shutdown while trapping exits → stop, so terminate/2 runs and
  # backs up the active deploy.
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}
  def handle_info(_msg, state), do: {:noreply, state}

  ## Lifecycle internals

  defp do_start(deploy_id, state) do
    deploy = Deploys.get_deploy!(deploy_id)

    with {:ok, plan} <- Materializer.materialize(deploy) do
      if plan.missing != [] do
        Logger.warning("deploy #{deploy.slug} missing mods in store: #{inspect(plan.missing)}")
      end

      run_id = gen_run_id()
      run_dir = Storage.run_log_dir(deploy.slug, run_id)
      File.mkdir_p!(run_dir)
      hc_count = deploy.headless_client_count

      {:ok, _} = Deploys.set_active(deploy)

      {:ok, log_run} =
        %Fueltruck.Logs.Run{}
        |> Fueltruck.Logs.Run.changeset(%{
          deploy_id: deploy.id,
          run_id: run_id,
          log_dir: run_dir,
          started_at: now()
        })
        |> Fueltruck.Repo.insert()

      # Start collectors for every source up front so log continuity survives restarts.
      Logs.start_collector(:server, run_dir)
      for i <- 0..(hc_count - 1)//1, do: Logs.start_collector({:hc, i}, run_dir)

      started = %{
        state
        | phase: :starting,
          deploy: deploy,
          plan: plan,
          run_id: run_id,
          run_dir: run_dir,
          log_run: log_run,
          hc_count: hc_count,
          server_ready: false,
          hc_active: false
      }

      # Steam depots don't preserve the executable bit; ensure the server binary is +x.
      ensure_executable(Storage.server_binary())
      # Expose steamclient.so at $HOME/.steam/sdk64 so Arma's Steam init doesn't segfault.
      Storage.ensure_steam_sdk!()

      {exe, args} = CommandLine.server(deploy, plan.mod_paths, plan.server_mod_paths)
      start_managed(:server, {exe, args}, Storage.server_dir())

      case ManagedProcess.start(:server) do
        :ok ->
          {:ok, started}

        {:error, reason} ->
          Logger.error("server failed to start: #{inspect(reason)}")
          {:error, reason, do_stop(started)}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  rescue
    e ->
      Logger.error("start_deploy crashed: #{Exception.message(e)}")
      Deploys.clear_active()
      {:error, e, %{state | phase: :idle}}
  end

  defp do_stop(%{deploy: nil} = state), do: %{state | phase: :idle}

  defp do_stop(state) do
    state = %{state | phase: :stopping}

    # Stop HCs first, then the server.
    for i <- 0..(state.hc_count - 1)//1, do: stop_managed({:hc, i})
    stop_managed(:server)

    # Back up profiles now that processes have flushed and exited.
    _ = Backups.create(state.deploy, "stop")

    # Close collectors (flush + close files) and finalize the run.
    Logs.stop_collector(:server)
    for i <- 0..(state.hc_count - 1)//1, do: Logs.stop_collector({:hc, i})
    finalize_run(state.log_run)
    Deploys.clear_active()

    %{
      state
      | phase: :idle,
        deploy: nil,
        plan: nil,
        run_id: nil,
        run_dir: nil,
        log_run: nil,
        hc_count: 0,
        server_ready: false,
        hc_active: false
    }
  end

  defp start_hcs(%{hc_count: 0} = state), do: state

  defp start_hcs(state) do
    for i <- 0..(state.hc_count - 1)//1 do
      {exe, args} = CommandLine.headless(state.deploy, i, state.plan.mod_paths)
      start_managed({:hc, i}, {exe, args}, Storage.server_dir())
      ManagedProcess.start({:hc, i})
    end

    Logs.marker(:server, "server ready — starting #{state.hc_count} headless client(s)")
    %{state | hc_active: true}
  end

  defp stop_hcs(state) do
    for i <- 0..(state.hc_count - 1)//1, do: stop_managed({:hc, i})
    %{state | hc_active: false}
  end

  defp start_managed(source, argv, cwd) do
    spec = {ManagedProcess, source: source, argv: argv, cwd: cwd}

    case DynamicSupervisor.start_child(@proc_sup, spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> other
    end
  end

  defp stop_managed(source) do
    case ManagedProcess.whereis(source) do
      nil ->
        :ok

      pid ->
        _ = ManagedProcess.stop(source)
        DynamicSupervisor.terminate_child(@proc_sup, pid)
    end
  end

  defp finalize_run(nil), do: :ok

  defp finalize_run(log_run) do
    log_run
    |> Fueltruck.Logs.Run.changeset(%{ended_at: now()})
    |> Fueltruck.Repo.update()
  end

  defp build_status(state) do
    %{
      phase: state.phase,
      run_id: state.run_id,
      run_dir: state.run_dir,
      hc_count: state.hc_count,
      deploy:
        state.deploy &&
          %{id: state.deploy.id, name: state.deploy.name, slug: state.deploy.slug},
      server: proc_status(:server),
      hcs: for(i <- 0..(state.hc_count - 1)//1, do: proc_status({:hc, i}))
    }
  end

  defp proc_status(source) do
    case ManagedProcess.status(source) do
      {:error, :not_found} -> %{source: source, label: Logs.source_label(source), state: :stopped}
      status -> status
    end
  end

  defp ensure_executable(path) do
    if File.regular?(path), do: File.chmod(path, 0o755)
    :ok
  end

  defp gen_run_id do
    stamp = now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    suffix = :rand.uniform(0xFFFFFF) |> Integer.to_string(16) |> String.downcase()
    "#{stamp}-#{suffix}"
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
