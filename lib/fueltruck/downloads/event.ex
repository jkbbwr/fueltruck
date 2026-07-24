defmodule Fueltruck.Downloads.Event do
  @moduledoc """
  Normalizes a line of steamree JSON output into a common shape. steamree's exact
  keys are not yet fixed, so this accepts a range of common field names and degrades
  gracefully: any line that isn't recognizable JSON becomes a plain message event.
  """

  @type t :: %{
          id: String.t() | nil,
          progress: number() | nil,
          status: String.t() | nil,
          message: String.t() | nil,
          raw: String.t()
        }

  @doc "Parse one output line into a normalized event."
  @spec parse(String.t()) :: t()
  def parse(line) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) -> from_map(map, line)
      _ -> %{id: nil, progress: nil, status: nil, message: line, raw: line}
    end
  end

  defp from_map(map, raw) do
    %{
      id: first(map, ["id", "workshop_id", "item", "publishedfileid", "fileid"]) |> to_str(),
      progress: normalize_progress(first(map, ["progress", "percent", "pct"])),
      status: first(map, ["status", "state", "event", "type"]) |> to_str(),
      message: first(map, ["message", "msg", "text", "error"]) |> to_str(),
      raw: raw
    }
  end

  defp first(map, keys), do: Enum.find_value(keys, fn k -> Map.get(map, k) end)

  # Accept 0..1 fractions or 0..100 percentages; clamp to 0..100.
  defp normalize_progress(nil), do: nil

  defp normalize_progress(p) when is_number(p) do
    pct = if p <= 1.0, do: p * 100, else: p
    ((pct |> max(0) |> min(100)) / 1) |> Float.round(1)
  end

  defp normalize_progress(p) when is_binary(p) do
    case Float.parse(p) do
      {f, _} -> normalize_progress(f)
      :error -> nil
    end
  end

  defp normalize_progress(_), do: nil

  defp to_str(nil), do: nil
  defp to_str(v) when is_binary(v), do: v
  defp to_str(v), do: to_string(v)
end
