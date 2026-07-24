defmodule Fueltruck.Metrics.Proc do
  @moduledoc """
  Per-managed-process resource sampling.

  If the process runs inside a MuonTrap cgroup (available + writable), we read
  `memory.current` and `cpu.stat` for exact subtree accounting. Otherwise — the common
  container case, where cgroups aren't delegated — the OS pid is the muontrap *wrapper*,
  so we sum CPU + RSS across its whole process tree (wrapper → arma → any children) via
  `/proc`; each process's utime/stime already aggregates its threads. On non-Linux dev
  hosts we fall back to `ps` on the single pid.
  """

  @cgroup_root Application.compile_env(
                 :fueltruck,
                 [Fueltruck.Metrics, :cgroup_root],
                 "/sys/fs/cgroup"
               )

  # Standard Linux jiffy + page size; good enough for the metrics we surface.
  @clk_tck 100
  @page_size 4096

  @type prev :: map() | nil
  @type sample :: %{cpu_pct: float() | nil, mem_bytes: non_neg_integer() | nil}

  @doc "Sample a process from its metrics handle, given the previous CPU reading."
  @spec sample(map(), prev()) :: {sample(), prev()}
  def sample(%{cgroup_path: cg}, prev) when is_binary(cg) do
    mem = read_int(Path.join([@cgroup_root, cg, "memory.current"]))
    cpu_usec = read_cpu_usec(Path.join([@cgroup_root, cg, "cpu.stat"]))
    cpu_from_usec(cpu_usec, mem, prev)
  end

  def sample(%{os_pid: pid}, prev) when is_integer(pid) do
    if linux?(), do: sample_tree(pid, prev), else: sample_ps(pid, prev)
  end

  def sample(_handle, prev), do: {%{cpu_pct: nil, mem_bytes: nil}, prev}

  ## /proc process-tree sampling (no cgroups)

  defp sample_tree(root_pid, prev) do
    table = proc_table()
    pids = subtree(root_pid, table)

    {ticks, rss_bytes} =
      Enum.reduce(pids, {0, 0}, fn pid, {t, r} ->
        case Map.get(table, pid) do
          %{ticks: pt, rss: pr} -> {t + pt, r + pr}
          _ -> {t, r}
        end
      end)

    now_us = System.monotonic_time(:microsecond)

    cpu_pct =
      case prev do
        %{cpu_ticks: prev_ticks, mono_us: prev_mono} when now_us > prev_mono ->
          secs = (now_us - prev_mono) / 1_000_000
          ((ticks - prev_ticks) / @clk_tck / secs * 100) |> max(0.0) |> Float.round(1)

        _ ->
          nil
      end

    {%{cpu_pct: cpu_pct, mem_bytes: rss_bytes}, %{cpu_ticks: ticks, mono_us: now_us}}
  end

  # All descendant pids of `root` (inclusive), from a pid→stat table.
  defp subtree(root, table) do
    children =
      Enum.reduce(table, %{}, fn {pid, %{ppid: ppid}}, acc ->
        Map.update(acc, ppid, [pid], &[pid | &1])
      end)

    collect([root], children, [])
  end

  defp collect([], _children, acc), do: acc

  defp collect([pid | rest], children, acc) do
    collect(Map.get(children, pid, []) ++ rest, children, [pid | acc])
  end

  # %{pid => %{ppid, ticks (utime+stime), rss (bytes)}} for every process on the host.
  defp proc_table do
    case File.ls("/proc") do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn e ->
          case Integer.parse(e) do
            {pid, ""} -> read_stat(pid) |> wrap(pid)
            _ -> []
          end
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp wrap(nil, _pid), do: []
  defp wrap(stat, pid), do: [{pid, stat}]

  defp read_stat(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, data} -> parse_stat(data)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc false
  # comm (field 2) may contain spaces/parens, so split after the final ')'. Post-comm
  # fields (0-indexed): 1 ppid, 11 utime, 12 stime, 21 rss (pages).
  def parse_stat(data) do
    case :binary.matches(data, ")") do
      [] ->
        nil

      matches ->
        idx = matches |> List.last() |> elem(0)
        fields = data |> binary_part(idx + 1, byte_size(data) - idx - 1) |> String.split()

        %{
          ppid: int_at(fields, 1),
          ticks: int_at(fields, 11) + int_at(fields, 12),
          rss: int_at(fields, 21) * @page_size
        }
    end
  end

  defp int_at(fields, i) do
    with s when is_binary(s) <- Enum.at(fields, i),
         {n, _} <- Integer.parse(s) do
      n
    else
      _ -> 0
    end
  end

  defp sample_ps(pid, prev) do
    case ps(pid) do
      {:ok, cpu_pct, rss_kb} -> {%{cpu_pct: cpu_pct, mem_bytes: rss_kb * 1024}, prev}
      :error -> {%{cpu_pct: nil, mem_bytes: nil}, prev}
    end
  end

  defp linux?, do: match?({:unix, :linux}, :os.type())

  defp cpu_from_usec(nil, mem, prev), do: {%{cpu_pct: nil, mem_bytes: mem}, prev}

  defp cpu_from_usec(cpu_usec, mem, prev) do
    now_us = System.monotonic_time(:microsecond)

    cpu_pct =
      case prev do
        %{cpu_usec: prev_usec, mono_us: prev_mono} when now_us > prev_mono ->
          ((cpu_usec - prev_usec) / (now_us - prev_mono) * 100) |> max(0.0) |> Float.round(1)

        _ ->
          nil
      end

    {%{cpu_pct: cpu_pct, mem_bytes: mem}, %{cpu_usec: cpu_usec, mono_us: now_us}}
  end

  defp read_int(path) do
    case File.read(path) do
      {:ok, data} ->
        case Integer.parse(String.trim(data)) do
          {n, _} -> n
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp read_cpu_usec(path) do
    with {:ok, data} <- File.read(path),
         [_, usec] <- Regex.run(~r/usage_usec\s+(\d+)/, data) do
      String.to_integer(usec)
    else
      _ -> nil
    end
  end

  defp ps(pid) do
    case System.cmd("ps", ["-o", "rss=,%cpu=", "-p", Integer.to_string(pid)],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case out |> String.trim() |> String.split(~r/\s+/, trim: true) do
          [rss, cpu] ->
            with {rss_kb, _} <- Integer.parse(rss), {cpu_pct, _} <- Float.parse(cpu) do
              {:ok, cpu_pct, rss_kb}
            else
              _ -> :error
            end

          _ ->
            :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end
end
