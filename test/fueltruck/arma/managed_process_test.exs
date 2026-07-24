defmodule Fueltruck.Arma.ManagedProcessTest do
  use ExUnit.Case, async: false

  alias Fueltruck.Arma.ManagedProcess
  alias Fueltruck.{Arma, Logs}

  @stub Path.join(File.cwd!(), "priv/stub/fake_arma.sh")
  @source {:hc, 0}

  setup do
    # Fresh collector per test so we can observe streamed lines.
    run_dir = Path.join(System.tmp_dir!(), "ft-mp-#{System.unique_integer([:positive])}")
    {:ok, _} = Logs.start_collector(@source, run_dir)
    on_exit(fn -> Logs.stop_collector(@source) end)
    %{run_dir: run_dir}
  end

  defp start_proc(env_argv, opts \\ []) do
    base = [source: @source, argv: {@stub, env_argv}, cwd: File.cwd!()]
    pid = start_supervised!({ManagedProcess, Keyword.merge(base, opts)})
    pid
  end

  test "starts, streams logs, reports ready, and stops" do
    Arma.subscribe_procs()
    Logs.subscribe(@source)
    start_proc(["--server"])

    assert :ok = ManagedProcess.start(@source)
    assert_receive {:proc_status, @source, %{event: :ready}}, 5_000

    # Streamed log batch arrives via PubSub.
    assert_receive {:logs, @source, batch}, 2_000
    assert Enum.any?(batch, fn {_seq, line} -> line =~ "fake-arma starting" end)

    status = ManagedProcess.status(@source)
    assert status.state == :running
    assert status.ready
    assert is_integer(status.os_pid)

    assert :ok = ManagedProcess.stop(@source)
    assert ManagedProcess.status(@source).state == :stopped
  end

  test "auto-restarts on crash with backoff" do
    Arma.subscribe_procs()
    # Crash ~1s after start; tiny backoff so the test is quick.
    start_proc(["--server"],
      backoff_base: 100,
      backoff_cap: 200,
      readiness_re: ~r/Host identity created/
    )

    System.put_env("FAKE_ARMA_EXIT_AFTER", "1")
    on_exit(fn -> System.delete_env("FAKE_ARMA_EXIT_AFTER") end)

    assert :ok = ManagedProcess.start(@source)
    assert_receive {:proc_status, @source, %{event: :crashed}}, 5_000
    assert_receive {:proc_status, @source, %{event: {:restarting, _delay, attempt}}}, 1_000
    assert attempt >= 1
    # It comes back up after the backoff.
    assert_receive {:proc_status, @source, %{event: :running}}, 3_000

    ManagedProcess.stop(@source)
  end
end
