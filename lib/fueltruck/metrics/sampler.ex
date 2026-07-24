defmodule Fueltruck.Metrics.Sampler do
  @moduledoc """
  Polls per-process (cgroup/ps) and system (os_mon) metrics on an interval, keeps a
  short history per source for sparklines, and broadcasts the latest snapshot.
  """
  use GenServer

  alias Fueltruck.Arma.ManagedProcess
  alias Fueltruck.Logs
  alias Fueltruck.Metrics.{Proc, System}

  @topic "metrics"
  @default_interval 1_000
  @history_cap 300

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def topic, do: @topic
  def subscribe, do: Phoenix.PubSub.subscribe(Fueltruck.PubSub, @topic)

  @doc "Most recent snapshot."
  def latest, do: GenServer.call(__MODULE__, :latest)

  @doc "History samples for a source: `[%{cpu_pct, mem_bytes}]` oldest → newest."
  def history(source), do: GenServer.call(__MODULE__, {:history, source})

  ## Server

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule(interval)

    {:ok,
     %{
       interval: interval,
       prev: %{},
       history: %{},
       latest: %{procs: [], system: System.sample()}
     }}
  end

  @impl true
  def handle_call(:latest, _from, state), do: {:reply, state.latest, state}

  def handle_call({:history, source}, _from, state) do
    {:reply, Enum.reverse(Map.get(state.history, source, [])), state}
  end

  @impl true
  def handle_info(:sample, state) do
    {procs, prev} =
      list_sources()
      |> Enum.map_reduce(state.prev, fn source, prev_acc ->
        sample_source(source, prev_acc)
      end)

    system = System.sample()
    history = update_history(state.history, procs)
    latest = %{procs: procs, system: system}

    Phoenix.PubSub.broadcast(Fueltruck.PubSub, @topic, {:metrics, latest})
    schedule(state.interval)
    {:noreply, %{state | prev: prev, history: history, latest: latest}}
  end

  ## Internals

  defp sample_source(source, prev_acc) do
    case ManagedProcess.metrics_handle(source) do
      {:error, :not_found} ->
        {%{source: source, label: Logs.source_label(source), cpu_pct: nil, mem_bytes: nil},
         prev_acc}

      handle ->
        {sample, new_prev} = Proc.sample(handle, Map.get(prev_acc, source))

        entry =
          Map.merge(sample, %{source: source, label: Logs.source_label(source)})

        {entry, Map.put(prev_acc, source, new_prev)}
    end
  end

  defp list_sources do
    Registry.select(Fueltruck.Arma.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  defp update_history(history, procs) do
    Enum.reduce(procs, history, fn p, acc ->
      point = %{cpu_pct: p.cpu_pct, mem_bytes: p.mem_bytes}
      series = [point | Map.get(acc, p.source, [])] |> Enum.take(@history_cap)
      Map.put(acc, p.source, series)
    end)
  end

  defp schedule(interval), do: Process.send_after(self(), :sample, interval)
end
