defmodule Fueltruck.Logs.History do
  @moduledoc """
  Reads historical log lines from disk for reverse-scroll pagination and search.

  Line numbering matches the collector's `seq`: the Nth line ever written for a
  source has `seq == N`, spread across ordered, byte-bounded segment files. That lets
  the live tail (ring, seq-numbered) and disk history share one coordinate space.
  """
  alias Fueltruck.Logs
  alias Fueltruck.Logs.Index

  @doc """
  Directory holding a source's segments for a given run log dir.
  """
  def source_dir(run_log_dir, source), do: Path.join(run_log_dir, Logs.source_key(source))

  @doc "Sorted segment paths (oldest → newest) for a source dir, incl. gzipped ones."
  def segments(dir) do
    case File.dir?(dir) do
      true ->
        (Path.wildcard(Path.join(dir, "*.log")) ++ Path.wildcard(Path.join(dir, "*.log.gz")))
        |> Enum.sort()

      false ->
        []
    end
  end

  @doc """
  Return up to `limit` lines with `seq < before_seq`, as `[{seq, line}]`
  (oldest → newest). Reads only the segments overlapping the requested range.
  Pass `before_seq` = the oldest seq currently shown to page further back.
  """
  @spec page_before(Path.t(), pos_integer(), pos_integer()) :: [{pos_integer(), String.t()}]
  def page_before(dir, before_seq, limit) when before_seq > 1 do
    hi = before_seq - 1
    lo = max(1, before_seq - limit)

    segments(dir)
    |> annotate_ranges()
    |> Enum.filter(fn {_path, start_line, end_line} ->
      end_line >= lo and start_line <= hi
    end)
    |> Enum.flat_map(fn {path, start_line, _end_line} ->
      path
      |> read_lines()
      |> Enum.with_index(start_line)
      |> Enum.filter(fn {_line, seq} -> seq >= lo and seq <= hi end)
      |> Enum.map(fn {line, seq} -> {seq, line} end)
    end)
  end

  def page_before(_dir, _before_seq, _limit), do: []

  @doc """
  Search all history for a source dir, case-insensitively. Returns up to `limit`
  most-recent matches as `[{seq, line}]` (oldest → newest).
  """
  @spec search(Path.t(), String.t(), pos_integer()) :: [{pos_integer(), String.t()}]
  def search(dir, query, limit \\ 500) do
    needle = String.downcase(query)

    segments(dir)
    |> annotate_ranges()
    |> Enum.flat_map(fn {path, start_line, _end} ->
      path
      |> read_lines()
      |> Enum.with_index(start_line)
      |> Enum.filter(fn {line, _seq} -> String.contains?(String.downcase(line), needle) end)
      |> Enum.map(fn {line, seq} -> {seq, line} end)
    end)
    |> take_last(limit)
  end

  @doc "Total line count across a source dir."
  def total_lines(dir) do
    segments(dir) |> Enum.reduce(0, fn path, acc -> acc + Index.line_count(path) end)
  end

  # Attach the [start_line, end_line] global-seq range to each segment.
  defp annotate_ranges(paths) do
    {annotated, _} =
      Enum.map_reduce(paths, 0, fn path, offset ->
        count = Index.line_count(path)
        start_line = offset + 1
        end_line = offset + count
        {{path, start_line, end_line}, end_line}
      end)

    annotated
  end

  defp read_lines(path) do
    case File.read(path) do
      {:ok, ""} -> []
      {:ok, data} -> data |> maybe_gunzip(path) |> String.split("\n") |> drop_trailing_empty()
      _ -> []
    end
  end

  defp maybe_gunzip(data, path) do
    if String.ends_with?(path, ".gz"), do: :zlib.gunzip(data), else: data
  end

  # Files end in a trailing newline, so the final split element is "" — drop it,
  # but keep genuine blank lines in the middle.
  defp drop_trailing_empty(parts) do
    case List.last(parts) do
      "" -> Enum.drop(parts, -1)
      _ -> parts
    end
  end

  defp take_last(list, n) do
    len = length(list)
    if len <= n, do: list, else: Enum.drop(list, len - n)
  end
end
