defmodule Fueltruck.Downloads.Queue do
  @moduledoc """
  Serializes steamree invocations (Steam locks forbid concurrent runs), tracks progress
  from its JSON milestone events, and runs post-download hooks (lowercasing + catalog
  upsert). One job runs at a time; further requests queue.

  steamree only reports per-item *completion* on stdout (no continuous byte progress),
  so the derived state is: overall `done/total` counts + per-item status
  (`queued → downloading → done`), plus server depot totals.
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

  @doc """
  Queue a server install/update. Runs two stages in sequence — the base game (default
  branch) then the Creator DLC overlay — since the creatordlc branch alone leaves an
  incomplete core game. A single call updates both.
  """
  def update_server do
    job = %{type: :server, label: server_label(:base), stages: [:base, :creatordlc], stage: 0}
    GenServer.call(__MODULE__, {:enqueue, job})
  end

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

  @doc """
  Human `{level, message}` for a `{:download_done, info}` completion event, e.g.
  all-up-to-date vs how many were downloaded/failed.
  """
  def done_message(%{result: :cancelled}), do: {:info, "Download cancelled"}
  def done_message(%{result: {:error, _}}), do: {:error, "Download failed to start"}

  def done_message(%{kind: :mods, summary: s} = info) when is_map(s) do
    dl = s["downloaded"] || 0
    failed = s["failed"] || 0
    un = (info[:unavailable] || 0) + failed

    cond do
      dl == 0 and un == 0 -> {:info, "All mods are already up to date"}
      un > 0 -> {:error, mods_line(dl, un)}
      true -> {:info, "Downloaded #{dl} mod(s)"}
    end
  end

  def done_message(%{kind: :mods}), do: {:info, "Mod download finished"}
  def done_message(%{kind: :server, summary: %{"downloaded" => 0}}), do: {:info, "Server is up to date"}
  def done_message(%{kind: :server}), do: {:info, "Server download finished"}
  def done_message(_), do: {:info, "Download complete"}

  defp mods_line(0, un), do: "#{un} mod(s) unavailable (removed / hidden / wrong id)"

  defp mods_line(dl, un),
    do: "Downloaded #{dl} mod(s); #{un} unavailable (removed / hidden / wrong id)"

  ## Server

  @impl true
  def init(_opts) do
    {:ok,
     reset(%{
       queue: [],
       daemon_pid: nil,
       ref: nil,
       log: [],
       last_result: nil,
       dirty: false,
       flush_scheduled: false
     })}
  end

  # Per-job fields reset between jobs.
  defp reset(state) do
    Map.merge(state, %{
      status: :idle,
      job: nil,
      cancelling: false,
      items: %{},
      depots: %{},
      phase: nil,
      total_bytes: nil,
      server: nil,
      summary: nil,
      unavailable: 0
    })
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
    state =
      state
      |> apply_event(Event.parse(line))
      |> Map.update!(:log, fn log -> [line | log] |> Enum.take(@log_cap) end)

    {:noreply, mark_dirty(state)}
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
    state = %{state | daemon_pid: nil, ref: nil}

    if not state.cancelling and reason == :normal and next_server_stage?(state.job) do
      # Base game finished cleanly — roll straight into the creatordlc overlay without
      # emitting a completion event (the download isn't done until both stages run).
      Logger.info("server download stage #{state.job.stage} done; starting next stage")
      {:noreply, advance_server_stage(state)}
    else
      result =
        cond do
          state.cancelling -> :cancelled
          reason == :normal -> finalize(state.job)
          true -> {:error, reason}
        end

      Logger.info("download job #{inspect(state.job[:type])} finished: #{inspect(result)}")

      Phoenix.PubSub.broadcast(
        Fueltruck.PubSub,
        @topic,
        {:download_done,
         %{
           kind: state.job[:type],
           result: result,
           summary: state.summary,
           unavailable: state.unavailable
         }}
      )

      state = %{state | cancelling: false, last_result: result}
      {:noreply, next_job(state)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Event handling — see Fueltruck.Downloads.Event for the shapes.

  defp apply_event(state, %{type: "app", data: d}) do
    %{
      state
      | server: %{name: d["name"], branch: d["branch"], total_bytes: nil, depots: nil},
        phase: :resolving
    }
  end

  defp apply_event(state, %{type: "depots_selected", data: d}) do
    server = Map.merge(state.server || %{}, %{total_bytes: d["bytes"], depots: d["count"]})
    %{state | server: server, total_bytes: d["bytes"], phase: :downloading}
  end

  defp apply_event(state, %{type: "resolved", data: d}) do
    %{
      state
      | total_bytes: d["bytes"],
        phase: :downloading,
        items: start_all(state.items),
        unavailable: d["unavailable"] || state.unavailable
    }
  end

  # A workshop item finishing — either downloaded, or unavailable (removed/hidden/bad id).
  # The count comes from the authoritative `resolved.unavailable`; here we just tag the
  # item so it renders distinctly.
  defp apply_event(state, %{type: "item", data: %{"status" => "unavailable"} = d}) do
    %{state | items: mark_item(state.items, d, "unavailable")}
  end

  defp apply_event(state, %{type: "item", data: d}) do
    %{state | items: mark_item(state.items, d, "done")}
  end

  # Throttled per-workshop-item progress: {id, completed_bytes, total_bytes}.
  defp apply_event(state, %{type: "item_progress", data: d}) do
    %{state | items: put_progress(state.items, d), phase: :downloading}
  end

  # Throttled per-depot progress for app/server downloads: {depot, completed_bytes, total_bytes}.
  defp apply_event(state, %{type: "depot_progress", data: d}) do
    entry = %{completed: d["completed_bytes"] || 0, total: d["total_bytes"] || 0}
    %{state | depots: Map.put(state.depots, d["depot"], entry), phase: :downloading}
  end

  defp apply_event(state, %{type: "summary", data: d}) do
    %{state | phase: :done, summary: d, last_result: {:summary, d}}
  end

  defp apply_event(state, _event), do: state

  defp start_all(items) do
    Map.new(items, fn {id, item} ->
      {id, if(item.status == "queued", do: %{item | status: "downloading"}, else: item)}
    end)
  end

  defp put_progress(items, d) do
    id = to_string(d["id"])
    prev = Map.get(items, id, blank_item(id, "mod-#{id}"))
    status = if prev.status == "done", do: "done", else: "downloading"

    Map.put(items, id, %{
      prev
      | completed_bytes: d["completed_bytes"] || prev.completed_bytes,
        total_bytes: max(d["total_bytes"] || 0, prev.total_bytes),
        status: status
    })
  end

  defp mark_item(items, d, status) do
    id = to_string(d["id"])
    prev = Map.get(items, id, blank_item(id, d["title"] || "mod-#{id}"))
    total = d["bytes"] || prev.total_bytes
    completed = if status == "done", do: total, else: prev.completed_bytes

    Map.put(items, id, %{
      prev
      | status: status,
        completed_bytes: completed,
        total_bytes: total,
        name: d["title"] || prev.name
    })
  end

  defp blank_item(id, name),
    do: %{id: id, name: name, status: "queued", completed_bytes: 0, total_bytes: 0}

  ## Job lifecycle

  defp start_job(job, state) do
    {exe, args} = argv(job)
    me = self()
    logger_fun = fn line -> GenServer.cast(me, {:line, line}) end

    case safe_start(exe, args, logger_fun) do
      {:ok, pid} ->
        Process.unlink(pid)
        ref = Process.monitor(pid)

        state =
          reset(state)
          |> Map.merge(%{
            status: :running,
            job: job,
            daemon_pid: pid,
            ref: ref,
            items: seed_items(job),
            log: [],
            last_result: nil
          })

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
    # No env override, so steamree inherits our environment — it reads Steam creds from
    # STEAM_USERNAME/STEAM_PASSWORD there (e.g. set in compose) or from a `.env` in its
    # cwd. cwd = data root so a persistent `.env` and its session cache live on the
    # volume. `--json` puts machine-readable JSON Lines on stdout and human progress on
    # stderr; capture stdout only for the parser.
    MuonTrap.Daemon.start_link(exe, args,
      logger_fun: logger_fun,
      cd: Fueltruck.Storage.data_dir()
    )
  rescue
    e -> {:error, e}
  end

  defp argv(%{type: :server} = job), do: Steamree.server_argv(current_stage(job))
  defp argv(%{type: :mods, ids: ids}), do: Steamree.mods_argv(ids)

  defp current_stage(%{stages: stages, stage: i}), do: Enum.at(stages, i)
  defp current_stage(_), do: :creatordlc

  # A server download runs base then creatordlc; is there another stage after this one?
  defp next_server_stage?(%{type: :server, stages: stages, stage: i}), do: i + 1 < length(stages)
  defp next_server_stage?(_), do: false

  defp advance_server_stage(%{job: job} = state) do
    next = job.stage + 1
    job = %{job | stage: next, label: server_label(Enum.at(job.stages, next))}
    start_job(job, state)
  end

  defp server_label(:base), do: "Server — base game"
  defp server_label(:creatordlc), do: "Server — Creator DLC"
  defp server_label(_), do: "Server"

  defp seed_items(%{type: :mods, ids: ids, names: names}) do
    Map.new(ids, fn id -> {id, blank_item(id, Map.get(names, id, "mod-#{id}"))} end)
  end

  defp seed_items(_), do: %{}

  # Best-effort: finalize the mods that made it to disk; unavailable ones (never
  # downloaded) are surfaced via item status + the completion notice, not as an error.
  defp finalize(%{type: :mods, ids: ids, names: names}) do
    Enum.each(ids, fn id -> Store.finalize(id, name: Map.get(names, id)) end)
    :ok
  end

  defp finalize(%{type: :server}), do: :ok
  defp finalize(_), do: :ok

  defp next_job(%{queue: []} = state) do
    state = reset(state)
    broadcast(state)
    state
  end

  defp next_job(%{queue: [job | rest]} = state) do
    start_job(job, %{state | queue: rest})
  end

  ## Broadcast + snapshot

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
    # Actively downloading (has a size/progress) at the top, then those still waiting to
    # start (steamree marks the whole batch "downloading" but only runs `--jobs` at a
    # time), then failures, with finished items sinking to the bottom; name breaks ties.
    items = state.items |> Map.values() |> Enum.sort_by(&{item_rank(&1), &1.name})
    total = length(items)
    done = Enum.count(items, &(&1.status == "done"))
    {completed_bytes, summed_total} = overall_bytes(state)
    total_bytes = state.total_bytes || pos(summed_total)

    %{
      status: state.status,
      kind: state.job && state.job.type,
      label: state.job && state.job.label,
      queue: Enum.map(state.queue, & &1.label),
      phase: state.phase,
      total_bytes: total_bytes,
      bytes_done: completed_bytes,
      bytes_pct: pct(completed_bytes, total_bytes),
      depots: map_size(state.depots),
      server: state.server,
      items: items,
      total: total,
      done: done,
      pct: if(total > 0, do: round(done / total * 100), else: nil),
      last_result: state.last_result,
      log: Enum.reverse(state.log)
    }
  end

  # Overall bytes downloaded / total, summed across depots (server) or items (mods).
  defp overall_bytes(%{depots: depots}) when map_size(depots) > 0 do
    Enum.reduce(depots, {0, 0}, fn {_, %{completed: c, total: t}}, {ac, at} -> {ac + c, at + t} end)
  end

  defp overall_bytes(%{items: items}) when map_size(items) > 0 do
    Enum.reduce(items, {0, 0}, fn {_, i}, {ac, at} ->
      {ac + (i.completed_bytes || 0), at + (i.total_bytes || 0)}
    end)
  end

  defp overall_bytes(_), do: {0, 0}

  defp pos(n) when is_integer(n) and n > 0, do: n
  defp pos(_), do: nil

  defp pct(c, t) when is_integer(c) and is_integer(t) and t > 0, do: min(100, round(c / t * 100))
  defp pct(_c, _t), do: nil

  # Rank an item for display order. A known size (`total_bytes > 0`) means steamree is
  # actually working on it, so it ranks above items merely marked "downloading" but not
  # yet started (waiting). Done sinks to the bottom.
  defp item_rank(%{status: "done"}), do: 3
  defp item_rank(%{status: s}) when s in ["unavailable", "failed"], do: 2
  defp item_rank(%{total_bytes: t}) when is_integer(t) and t > 0, do: 0
  defp item_rank(_), do: 1
end
