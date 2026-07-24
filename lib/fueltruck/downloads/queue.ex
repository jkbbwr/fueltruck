defmodule Fueltruck.Downloads.Queue do
  @moduledoc """
  Serializes steamree invocations (Steam locks forbid concurrent runs), streams their
  JSON output as normalized progress, and runs post-download hooks (lowercasing +
  catalog upsert). One job runs at a time; further requests queue.
  """
  use GenServer
  require Logger

  alias Fueltruck.Downloads.{Event, Steamree}
  alias Fueltruck.Mods.Store

  @topic "downloads"
  @log_cap 500
  @flush_ms 200

  ## Client API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def topic, do: @topic
  def subscribe, do: Phoenix.PubSub.subscribe(Fueltruck.PubSub, @topic)

  @doc "Queue a server install/update."
  def update_server, do: GenServer.call(__MODULE__, {:enqueue, %{type: :server, label: "Server"}})

  @doc "Queue a workshop mod update for the given ids. `:names` maps id → display name."
  def update_mods(ids, opts \\ []) do
    ids = Enum.map(ids, &to_string/1)
    job = %{type: :mods, ids: ids, names: opts[:names] || %{}, label: "#{length(ids)} mod(s)"}
    GenServer.call(__MODULE__, {:enqueue, job})
  end

  @doc "Cancel the running job (queued jobs are kept)."
  def cancel, do: GenServer.call(__MODULE__, :cancel)

  @doc "Current snapshot of the download state."
  def get, do: GenServer.call(__MODULE__, :get)

  ## Server

  @impl true
  def init(_opts) do
    {:ok,
     %{
       status: :idle,
       job: nil,
       queue: [],
       daemon_pid: nil,
       ref: nil,
       cancelling: false,
       items: %{},
       log: [],
       last_result: nil,
       dirty: false,
       flush_scheduled: false
     }}
  end

  @impl true
  def handle_call({:enqueue, job}, _from, %{status: :idle} = state) do
    {:reply, :ok, start_job(job, state)}
  end

  def handle_call({:enqueue, job}, _from, state) do
    state = %{state | queue: state.queue ++ [job]}
    broadcast(state)
    {:reply, :queued, state}
  end

  def handle_call(:cancel, _from, %{status: :running, daemon_pid: pid} = state)
      when is_pid(pid) do
    state = %{state | cancelling: true}

    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :shutdown, 10_000)
      catch
        :exit, _ -> :ok
      end
    end

    {:reply, :ok, state}
  end

  def handle_call(:cancel, _from, state), do: {:reply, {:error, :not_running}, state}

  def handle_call(:get, _from, state), do: {:reply, snapshot(state), state}

  @impl true
  def handle_cast({:line, line}, state) do
    event = Event.parse(line)
    items = update_items(state.items, event)
    log = [line | state.log] |> Enum.take(@log_cap)
    {:noreply, mark_dirty(%{state | items: items, log: log})}
  end

  @impl true
  def handle_info(:flush, state) do
    state = %{state | flush_scheduled: false}

    if state.dirty do
      broadcast(state)
      {:noreply, %{state | dirty: false}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ref: ref} = state) do
    result =
      cond do
        state.cancelling -> :cancelled
        reason == :normal -> finalize(state.job)
        true -> {:error, reason}
      end

    Logger.info("download job #{inspect(state.job[:type])} finished: #{inspect(result)}")

    state = %{state | daemon_pid: nil, ref: nil, cancelling: false, last_result: result}
    {:noreply, next_job(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals

  defp start_job(job, state) do
    {exe, args} = argv(job)
    me = self()
    logger_fun = fn line -> GenServer.cast(me, {:line, line}) end

    case safe_start(exe, args, logger_fun) do
      {:ok, pid} ->
        Process.unlink(pid)
        ref = Process.monitor(pid)

        state = %{
          state
          | status: :running,
            job: job,
            daemon_pid: pid,
            ref: ref,
            cancelling: false,
            items: seed_items(job),
            log: [],
            last_result: nil
        }

        broadcast(state)
        state

      {:error, reason} ->
        Logger.error("steamree failed to start: #{inspect(reason)}")
        state = %{state | last_result: {:error, reason}}
        broadcast(state)
        next_job(state)
    end
  end

  defp safe_start(exe, args, logger_fun) do
    MuonTrap.Daemon.start_link(exe, args, stderr_to_stdout: true, logger_fun: logger_fun)
  rescue
    e -> {:error, e}
  end

  defp argv(%{type: :server}), do: Steamree.server_argv()
  defp argv(%{type: :mods, ids: ids}), do: Steamree.mods_argv(ids)

  defp seed_items(%{type: :mods, ids: ids, names: names}) do
    Map.new(ids, fn id ->
      {id,
       %{
         id: id,
         name: Map.get(names, id, "mod-#{id}"),
         progress: 0.0,
         status: "queued",
         message: nil
       }}
    end)
  end

  defp seed_items(_), do: %{}

  defp update_items(items, %{id: nil}), do: items

  defp update_items(items, event) do
    existing =
      Map.get(items, event.id, %{
        id: event.id,
        name: "mod-#{event.id}",
        progress: nil,
        status: nil,
        message: nil
      })

    updated =
      existing
      |> maybe_put(:progress, event.progress)
      |> maybe_put(:status, event.status)
      |> maybe_put(:message, event.message)

    Map.put(items, event.id, updated)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp finalize(%{type: :mods, ids: ids, names: names}) do
    results =
      Enum.map(ids, fn id ->
        {id, Store.finalize(id, name: Map.get(names, id))}
      end)

    failures = Enum.filter(results, fn {_id, r} -> match?({:error, _}, r) end)
    if failures == [], do: :ok, else: {:partial, failures}
  end

  defp finalize(%{type: :server}), do: :ok
  defp finalize(_), do: :ok

  defp next_job(%{queue: []} = state) do
    state = %{state | status: :idle, job: nil}
    broadcast(state)
    state
  end

  defp next_job(%{queue: [job | rest]} = state) do
    start_job(job, %{state | queue: rest})
  end

  defp mark_dirty(state) do
    if state.flush_scheduled do
      %{state | dirty: true}
    else
      Process.send_after(self(), :flush, @flush_ms)
      %{state | dirty: true, flush_scheduled: true}
    end
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(Fueltruck.PubSub, @topic, {:downloads, snapshot(state)})
  end

  defp snapshot(state) do
    %{
      status: state.status,
      job: state.job,
      queue: Enum.map(state.queue, & &1.label),
      items: state.items |> Map.values() |> Enum.sort_by(& &1.id),
      log: Enum.reverse(state.log),
      last_result: state.last_result
    }
  end
end
