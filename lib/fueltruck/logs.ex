defmodule Fueltruck.Logs do
  @moduledoc """
  Public API for the log pipeline.

  A *source* is one log stream: `:server` or `{:hc, index}`. Each source has a
  `Fueltruck.Logs.Collector` that keeps a large in-memory ring for the live tail,
  appends every line to disk (segmented, for rollover), and broadcasts batched
  updates over PubSub so LiveViews never re-render per line.

  Collectors live for the length of a deploy *session* (start_deploy → stop_deploy)
  so log history stays continuous across process auto-restarts.
  """
  alias Fueltruck.Logs.Collector

  @registry Fueltruck.Logs.Registry
  @supervisor Fueltruck.Logs.Supervisor

  @type source :: :server | {:hc, non_neg_integer()}

  @doc "Stable string key for a source, used in filenames and PubSub topics."
  @spec source_key(source()) :: String.t()
  def source_key(:server), do: "server"
  def source_key({:hc, n}), do: "hc-#{n}"

  @doc "Human label for a source."
  @spec source_label(source()) :: String.t()
  def source_label(:server), do: "Server"
  def source_label({:hc, n}), do: "Headless Client #{n}"

  @doc "Parse a source key string back into a source term."
  @spec source_from_key(String.t()) :: source()
  def source_from_key("server"), do: :server
  def source_from_key("hc-" <> n), do: {:hc, String.to_integer(n)}

  @doc "PubSub topic carrying batched log lines for a source."
  @spec topic(source()) :: String.t()
  def topic(source), do: "logs:" <> source_key(source)

  @doc "Subscribe the calling process to a source's log batches."
  def subscribe(source), do: Phoenix.PubSub.subscribe(Fueltruck.PubSub, topic(source))
  def unsubscribe(source), do: Phoenix.PubSub.unsubscribe(Fueltruck.PubSub, topic(source))

  @doc "Start a collector for a source writing segments under `run_dir`."
  def start_collector(source, run_dir, opts \\ []) do
    spec = {Collector, Keyword.merge([source: source, run_dir: run_dir], opts)}
    DynamicSupervisor.start_child(@supervisor, spec)
  end

  @doc "Stop the collector for a source (flushes and closes files first)."
  def stop_collector(source) do
    case whereis(source) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@supervisor, pid)
    end
  end

  @doc "Locate a running collector for a source."
  @spec whereis(source()) :: pid() | nil
  def whereis(source) do
    case Registry.lookup(@registry, source) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Append a raw line to a source (hot path — a cast to the collector)."
  def append(source, line) do
    case whereis(source) do
      nil -> :ok
      pid -> Collector.append(pid, line)
    end
  end

  @doc "Append an internal marker line (e.g. restart notices) to a source."
  def marker(source, text) do
    append(source, "—— #{text} ——")
  end

  @doc "Most recent `n` lines for a source as `[{seq, line}]` (oldest → newest)."
  def recent(source, n \\ 2_000) do
    case whereis(source) do
      nil -> []
      pid -> Collector.recent(pid, n)
    end
  end

  @doc "Registry name (for child_spec via tuples)."
  def registry, do: @registry
end
