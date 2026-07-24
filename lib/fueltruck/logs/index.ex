defmodule Fueltruck.Logs.Index do
  @moduledoc """
  Owns an ETS cache of per-segment line counts. Rotated (non-current) segment files
  never change, so their line counts are stable and safe to memoize — this keeps
  reverse-scroll pagination cheap instead of re-counting on every page.
  """
  use GenServer

  @table :fueltruck_log_index

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Line count for a segment file, memoized by `{path, size}`. A changed size (the
  still-growing current segment) invalidates the cached entry automatically.
  """
  @spec line_count(Path.t()) :: non_neg_integer()
  def line_count(path) do
    size =
      case File.stat(path) do
        {:ok, %{size: s}} -> s
        _ -> 0
      end

    case :ets.lookup(@table, path) do
      [{^path, ^size, count}] ->
        count

      _ ->
        count = count_lines(path)
        :ets.insert(@table, {path, size, count})
        count
    end
  end

  defp count_lines(path) do
    if String.ends_with?(path, ".gz") do
      count_gz(path)
    else
      count_plain(path)
    end
  end

  defp count_gz(path) do
    case File.read(path) do
      {:ok, data} -> data |> :zlib.gunzip() |> count_bytes(?\n)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp count_plain(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          count_stream(device, 0)
        after
          File.close(device)
        end

      _ ->
        0
    end
  end

  defp count_stream(device, acc) do
    case IO.binread(device, 65_536) do
      :eof -> acc
      {:error, _} -> acc
      data -> count_stream(device, acc + count_bytes(data, ?\n))
    end
  end

  defp count_bytes(data, byte) do
    data |> :binary.matches(<<byte>>) |> length()
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
