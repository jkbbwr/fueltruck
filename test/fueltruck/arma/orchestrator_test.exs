defmodule Fueltruck.Arma.OrchestratorTest do
  use Fueltruck.DataCase, async: false

  alias Fueltruck.{Arma, Catalog, Deploys, Logs}

  @stub Path.join(File.cwd!(), "priv/stub/fake_arma.sh")

  setup do
    # The orchestrator + collectors run in their own processes; share the sandbox.
    Ecto.Adapters.SQL.Sandbox.mode(Fueltruck.Repo, {:shared, self()})

    prev = Application.get_env(:fueltruck, Fueltruck.Arma)
    Application.put_env(:fueltruck, Fueltruck.Arma, Keyword.put(prev, :server_binary, @stub))

    on_exit(fn ->
      Arma.stop_deploy()
      Application.put_env(:fueltruck, Fueltruck.Arma, prev)
    end)

    :ok
  end

  test "start_deploy launches the server, cascades to HCs, streams logs, then stops" do
    {:ok, deploy} =
      Deploys.create_deploy(%{name: "Test Deploy", headless_client_count: 1, port: 2302})

    Arma.subscribe_procs()
    assert :ok = Arma.start_deploy(deploy)

    # Server becomes ready.
    assert_receive {:proc_status, :server, %{event: :ready}}, 5_000

    # Readiness cascades to the single headless client.
    assert_receive {:proc_status, {:hc, 0}, %{event: :running}}, 5_000

    status = Arma.status()
    assert status.phase == :running
    assert status.server.state == :running
    assert length(status.hcs) == 1

    # Logs were captured for the server.
    Process.sleep(400)
    server_lines = Logs.recent(:server, 100)
    assert Enum.any?(server_lines, fn {_seq, line} -> line =~ "fake-arma starting" end)

    # The deploy is marked active.
    assert Deploys.active_deploy().id == deploy.id

    # Stop tears everything down and clears active.
    assert :ok = Arma.stop_deploy()
    assert Arma.status().phase == :idle
    assert Deploys.active_deploy() == nil
    assert stopped?(:server)
    assert stopped?({:hc, 0})
  end

  test "importing a preset attaches mods that appear in the command preview" do
    {:ok, deploy} = Deploys.create_deploy(%{name: "Preset Deploy"})

    html = """
    <html><body><table>
      <tr data-type="ModContainer">
        <td data-type="DisplayName">CBA_A3</td>
        <td><a href="https://steamcommunity.com/sharedfiles/filedetails/?id=450814997">link</a></td>
      </tr>
    </table></body></html>
    """

    assert {:ok, %{added: 1}} = Fueltruck.Presets.import_to_deploy(deploy, html)
    assert Catalog.get_mod_by_workshop_id("450814997").name == "CBA_A3"

    preview = Deploys.command_preview(deploy)
    {_exe, server_args} = preview.server
    assert "-port=2302" in server_args
  end

  defp stopped?(source) do
    Fueltruck.Arma.ManagedProcess.whereis(source) == nil
  end
end
