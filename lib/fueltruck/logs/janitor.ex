defmodule Fueltruck.Logs.Janitor do
  @moduledoc """
  Periodic log housekeeping:

  * gzip segments of ended runs (the active run is left untouched),
  * keep only the last N run directories per deploy,
  * enforce a global byte budget across the whole logs tree, oldest runs first.
  """
  use GenServer
  require Logger
  alias Fueltruck.Storage

  @sweep_interval :timer.minutes(30)
  @default_keep_runs 30
  @default_max_total_bytes 20 * 1024 * 1024 * 1024

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Run a sweep now (used by tests and manual triggers)."
  def sweep_now, do: GenServer.call(__MODULE__, :sweep, 30_000)

  @impl true
  def init(opts) do
    state = %{
      keep_runs: Keyword.get(opts, :keep_runs, @default_keep_runs),
      max_total_bytes: Keyword.get(opts, :max_total_bytes, @default_max_total_bytes),
      interval: Keyword.get(opts, :interval, @sweep_interval)
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    {:reply, sweep(state), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(state)
    schedule(state)
    {:noreply, state}
  end

  defp schedule(state), do: Process.send_after(self(), :sweep, state.interval)

  defp sweep(state) do
    logs_root = Path.join(Storage.data_dir(), "logs")
    protected = protected_dirs()

    if File.dir?(logs_root) do
      logs_root
      |> list_dirs()
      |> Enum.each(&sweep_deploy(&1, protected, state))

      enforce_budget(logs_root, protected, state)
    end

    :ok
  rescue
    e ->
      Logger.warning("log janitor sweep failed: #{inspect(e)}")
      {:error, e}
  end

  defp sweep_deploy(deploy_dir, protected, state) do
    runs = deploy_dir |> list_dirs() |> Enum.sort()

    # gzip segments in ended (non-protected) runs
    Enum.each(runs, fn run ->
      unless run in protected, do: gzip_run(run)
    end)

    # keep only the last N ended runs
    ended = Enum.reject(runs, &(&1 in protected))
    to_drop = Enum.drop(ended, -state.keep_runs)
    Enum.each(to_drop, &File.rm_rf/1)
  end

  defp gzip_run(run_dir) do
    run_dir
    |> Path.join("**/*.log")
    |> Path.wildcard()
    |> Enum.each(&gzip_file/1)
  end

  defp gzip_file(path) do
    data = File.read!(path)
    File.write!(path <> ".gz", :zlib.gzip(data))
    File.rm(path)
  rescue
    e -> Logger.warning("gzip failed for #{path}: #{inspect(e)}")
  end

  defp enforce_budget(logs_root, protected, state) do
    all_runs =
      logs_root
      |> list_dirs()
      |> Enum.flat_map(&list_dirs/1)
      |> Enum.reject(&(&1 in protected))
      |> Enum.sort()

    total = Enum.reduce(all_runs, 0, fn dir, acc -> acc + dir_size(dir) end)
    drop_until_under(all_runs, total, state.max_total_bytes)
  end

  defp drop_until_under([], _total, _budget), do: :ok

  defp drop_until_under(_runs, total, budget) when total <= budget, do: :ok

  defp drop_until_under([oldest | rest], total, budget) do
    size = dir_size(oldest)
    File.rm_rf(oldest)
    drop_until_under(rest, total - size, budget)
  end

  defp protected_dirs do
    Fueltruck.Arma.Orchestrator.protected_log_dirs()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp list_dirs(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries |> Enum.map(&Path.join(dir, &1)) |> Enum.filter(&File.dir?/1)

      _ ->
        []
    end
  end

  defp dir_size(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reduce(0, fn path, acc ->
      case File.stat(path) do
        {:ok, %{size: s, type: :regular}} -> acc + s
        _ -> acc
      end
    end)
  end
end
