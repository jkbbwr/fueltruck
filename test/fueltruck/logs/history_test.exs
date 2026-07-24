defmodule Fueltruck.Logs.HistoryTest do
  use ExUnit.Case, async: false

  alias Fueltruck.Logs
  alias Fueltruck.Logs.{Collector, History}

  @source {:hc, 7}

  setup do
    run_dir = Path.join(System.tmp_dir!(), "ft-hist-#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Logs.start_collector(@source, run_dir, max_segment_bytes: 200, flush_interval: 20)

    on_exit(fn -> Logs.stop_collector(@source) end)
    %{run_dir: run_dir, pid: pid}
  end

  test "reverse-scroll paging and search read from disk across segments", %{
    run_dir: run_dir,
    pid: pid
  } do
    # Enough lines to force multiple segments (200-byte segments).
    for i <- 1..100, do: Collector.append(pid, "line #{i}")
    # Stop the collector so buffered (delayed_write) segments are flushed + closed —
    # this is the "browse history after the run" path.
    _ = :sys.get_state(pid)
    Logs.stop_collector(@source)

    dir = History.source_dir(run_dir, @source)
    assert History.total_lines(dir) == 100
    assert length(History.segments(dir)) > 1

    # Page the 10 lines immediately before seq 51 → lines 41..50.
    page = History.page_before(dir, 51, 10)
    assert length(page) == 10
    assert List.first(page) == {41, "line 41"}
    assert List.last(page) == {50, "line 50"}

    # Search finds a specific line with its global seq.
    assert [{88, "line 88"}] = History.search(dir, "line 88", 10)
  end

  test "recent returns the in-memory tail", %{pid: pid} do
    for i <- 1..30, do: Collector.append(pid, "l#{i}")
    _ = :sys.get_state(pid)

    recent = Collector.recent(pid, 5)
    assert length(recent) == 5
    assert List.last(recent) == {30, "l30"}
  end
end
