defmodule Fueltruck.Metrics.System do
  @moduledoc "System-wide CPU / memory / disk sampling via OTP's `:os_mon`."
  alias Fueltruck.Storage

  @type t :: %{
          cpu_pct: float() | nil,
          mem_total: non_neg_integer() | nil,
          mem_used: non_neg_integer() | nil,
          disk_total: non_neg_integer() | nil,
          disk_used: non_neg_integer() | nil,
          disk_free: non_neg_integer() | nil
        }

  @spec sample() :: t()
  def sample do
    %{
      cpu_pct: cpu(),
      mem_total: mem()[:total],
      mem_used: mem()[:used]
    }
    |> Map.merge(disk())
  end

  defp cpu do
    case :cpu_sup.util() do
      util when is_number(util) -> Float.round(util / 1, 1)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp mem do
    data = :memsup.get_system_memory_data()
    total = data[:total_memory] || data[:system_total_memory]
    free = data[:free_memory]

    cond do
      is_integer(total) and is_integer(free) -> %{total: total, used: total - free}
      is_integer(total) -> %{total: total, used: nil}
      true -> %{total: nil, used: nil}
    end
  rescue
    _ -> %{total: nil, used: nil}
  catch
    _, _ -> %{total: nil, used: nil}
  end

  defp disk do
    data_dir = Storage.data_dir()

    case best_mount(:disksup.get_disk_data(), data_dir) do
      {total_kb, pct_used} ->
        total = total_kb * 1024
        used = round(total * pct_used / 100)
        %{disk_total: total, disk_used: used, disk_free: total - used}

      nil ->
        %{disk_total: nil, disk_used: nil, disk_free: nil}
    end
  rescue
    _ -> %{disk_total: nil, disk_used: nil, disk_free: nil}
  catch
    _, _ -> %{disk_total: nil, disk_used: nil, disk_free: nil}
  end

  # Pick the mount whose path is the longest prefix of the data dir.
  defp best_mount(entries, data_dir) do
    entries
    |> Enum.map(fn {mount, total_kb, pct} -> {to_string(mount), total_kb, pct} end)
    |> Enum.filter(fn {mount, _, _} -> String.starts_with?(data_dir, mount) end)
    |> Enum.max_by(fn {mount, _, _} -> String.length(mount) end, fn -> nil end)
    |> case do
      nil -> nil
      {_mount, total_kb, pct} -> {total_kb, pct}
    end
  end
end
