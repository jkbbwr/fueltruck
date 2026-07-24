defmodule Fueltruck.Metrics.ProcTest do
  use ExUnit.Case, async: true

  alias Fueltruck.Metrics.Proc

  test "parse_stat pulls ppid, utime+stime, and rss from a /proc stat line" do
    # pid (comm) state ppid ... utime stime ... rss(pages) ...
    line =
      "1234 (arma3server_x6) S 1200 1234 1234 0 -1 4194304 100 0 0 0 500 300 0 0 20 0 25 0 12345 2048000000 15000 rest ignored"

    assert %{ppid: 1200, ticks: 800, rss: rss} = Proc.parse_stat(line)
    assert rss == 15_000 * 4096
  end

  test "parse_stat handles a comm containing spaces and parentheses" do
    line =
      "42 (weird (name) x) R 7 42 42 0 -1 0 0 0 0 0 10 20 0 0 20 0 4 0 99 100 200 rest"

    assert %{ppid: 7, ticks: 30, rss: rss} = Proc.parse_stat(line)
    assert rss == 200 * 4096
  end
end
