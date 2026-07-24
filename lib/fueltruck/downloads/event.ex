defmodule Fueltruck.Downloads.Event do
  @moduledoc """
  Parses a line of steamree `--json` output. steamree emits JSON Lines on stdout as
  discrete milestones (continuous byte-progress is a stderr TUI that is suppressed when
  not attached to a terminal), so events are keyed by a `type` field:

    * `app`             — an app download started: `{app_id, name, branch, os}`
    * `depots_selected` — `{bytes, count, depots}` (server total size + depot count)
    * `resolved`        — `{resolved, bytes, unavailable}` (items resolved + total bytes)
    * `item`            — a workshop item finished: `{id, title, status, bytes, files}`
    * `summary`         — `{current, downloaded, failed, bytes}`

  Anything else is treated as a plain log line.
  """

  @type t :: %{type: String.t(), data: map(), raw: String.t()}

  @spec parse(String.t()) :: t()
  def parse(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => type} = data} -> %{type: type, data: data, raw: line}
      {:ok, data} when is_map(data) -> %{type: "unknown", data: data, raw: line}
      _ -> %{type: "log", data: %{}, raw: line}
    end
  end
end
