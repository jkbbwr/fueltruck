defmodule Fueltruck.Metrics.Proc do
  @moduledoc """
  Per-managed-process resource sampling.

  On Linux the process runs inside a MuonTrap cgroup, so we read `memory.current` and
  `cpu.stat` for accurate accounting of the whole process subtree (threads included) —
  the OS pid is the muontrap wrapper, not the game process, so cgroup reads are the
  correct source. On other platforms we fall back to `ps` on the OS pid (dev only).
  """

  @cgroup_root Application.compile_env(
                 :fueltruck,
                 [Fueltruck.Metrics, :cgroup_root],
                 "/sys/fs/cgroup"
               )

  @type prev :: %{cpu_usec: non_neg_integer(), mono_us: integer()} | nil
  @type sample :: %{cpu_pct: float() | nil, mem_bytes: non_neg_integer() | nil}

  @doc "Sample a process from its metrics handle, given the previous CPU reading."
  @spec sample(map(), prev()) :: {sample(), prev()}
  def sample(%{cgroup_path: cg}, prev) when is_binary(cg) do
    mem = read_int(Path.join([@cgroup_root, cg, "memory.current"]))
    cpu_usec = read_cpu_usec(Path.join([@cgroup_root, cg, "cpu.stat"]))
    cpu_from_usec(cpu_usec, mem, prev)
  end

  def sample(%{os_pid: pid}, prev) when is_integer(pid) do
    case ps(pid) do
      {:ok, cpu_pct, rss_kb} -> {%{cpu_pct: cpu_pct, mem_bytes: rss_kb * 1024}, prev}
      :error -> {%{cpu_pct: nil, mem_bytes: nil}, prev}
    end
  end

  def sample(_handle, prev), do: {%{cpu_pct: nil, mem_bytes: nil}, prev}

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
