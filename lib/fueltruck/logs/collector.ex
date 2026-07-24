defmodule Fueltruck.Logs.Collector do
  @moduledoc """
  Per-source log collector.

  * **Hot path** — `append/2` is a cast. Each line is pushed into a bounded in-memory
    ring (for the live tail + late-joiner snapshots) and appended to a segmented disk
    file (for full history + reverse scroll). Disk writes use `:delayed_write` so they
    are cheap.
  * **Broadcast** — lines accumulate into a pending batch flushed on a timer, so many
    lines coalesce into a single PubSub message and LiveViews render batches, not
    per-line diffs.
  """
  use GenServer
  alias Fueltruck.Logs

  @default_ring_cap 50_000
  @default_max_segment_bytes 8_000_000
  @default_flush_interval 150

  defstruct [
    :source,
    :topic,
    :dir,
    :device,
    :seg_index,
    :seg_bytes,
    :max_segment_bytes,
    :flush_interval,
    ring: :queue.new(),
    ring_size: 0,
    ring_cap: @default_ring_cap,
    seq: 0,
    pending: []
  ]

  ## Client

  def start_link(opts) do
    source = Keyword.fetch!(opts, :source)
    GenServer.start_link(__MODULE__, opts, name: via(source))
  end

  defp via(source), do: {:via, Registry, {Logs.registry(), source}}

  @doc "Append a raw line (hot path)."
  def append(pid, line), do: GenServer.cast(pid, {:append, line})

  @doc "Most recent `n` lines as `[{seq, line}]`, oldest → newest."
  def recent(pid, n), do: GenServer.call(pid, {:recent, n})

  ## Server

  @impl true
  def init(opts) do
    source = Keyword.fetch!(opts, :source)
    run_dir = Keyword.fetch!(opts, :run_dir)
    dir = Path.join(run_dir, Logs.source_key(source))
    File.mkdir_p!(dir)

    state =
      %__MODULE__{
        source: source,
        topic: Logs.topic(source),
        dir: dir,
        seg_index: 0,
        seg_bytes: 0,
        max_segment_bytes: Keyword.get(opts, :max_segment_bytes, @default_max_segment_bytes),
        flush_interval: Keyword.get(opts, :flush_interval, @default_flush_interval),
        ring_cap: Keyword.get(opts, :ring_cap, @default_ring_cap)
      }
      |> open_next_segment()

    schedule_flush(state)
    {:ok, state}
  end

  @impl true
  def handle_cast({:append, line}, state) do
    seq = state.seq + 1
    entry = {seq, line}

    state =
      state
      |> push_ring(entry)
      |> write_disk(line)
      |> Map.update!(:pending, &[entry | &1])
      |> Map.put(:seq, seq)

    {:noreply, state}
  end

  @impl true
  def handle_call({:recent, n}, _from, state) do
    lines =
      state.ring
      |> :queue.to_list()
      |> take_last(n)

    {:reply, lines, state}
  end

  @impl true
  def handle_info(:flush, state) do
    state = flush(state)
    schedule_flush(state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = flush(state)

    case state.device do
      nil -> :ok
      device -> File.close(device)
    end

    :ok
  end

  ## Internals

  defp push_ring(state, entry) do
    ring = :queue.in(entry, state.ring)
    size = state.ring_size + 1

    if size > state.ring_cap do
      {_, ring} = :queue.out(ring)
      %{state | ring: ring, ring_size: state.ring_cap}
    else
      %{state | ring: ring, ring_size: size}
    end
  end

  defp write_disk(state, line) do
    data = [line, ?\n]
    :ok = IO.binwrite(state.device, data)
    bytes = state.seg_bytes + IO.iodata_length(data)

    if bytes >= state.max_segment_bytes do
      File.close(state.device)
      open_next_segment(%{state | seg_bytes: bytes})
    else
      %{state | seg_bytes: bytes}
    end
  end

  defp open_next_segment(state) do
    index = state.seg_index + 1
    path = Path.join(state.dir, segment_name(index))
    {:ok, device} = File.open(path, [:append, :delayed_write, :binary])
    %{state | device: device, seg_index: index, seg_bytes: 0}
  end

  defp segment_name(index) do
    "#{index |> Integer.to_string() |> String.pad_leading(6, "0")}.log"
  end

  defp flush(%{pending: []} = state), do: state

  defp flush(state) do
    batch = Enum.reverse(state.pending)
    Phoenix.PubSub.broadcast(Fueltruck.PubSub, state.topic, {:logs, state.source, batch})
    %{state | pending: []}
  end

  defp schedule_flush(state) do
    Process.send_after(self(), :flush, state.flush_interval)
  end

  defp take_last(list, n) do
    len = length(list)
    if len <= n, do: list, else: Enum.drop(list, len - n)
  end
end
