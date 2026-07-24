defmodule Fueltruck.Discord.CommandsTest do
  # Guards the slash-command registry against typos/missing callbacks. Discord itself is
  # not booted in tests (DISCORD_ENABLED unset), so these exercise the pure command code.
  use ExUnit.Case, async: true

  alias Fueltruck.Discord.Commands

  test "registry lists the expected commands, each a valid slash command" do
    assert Map.keys(Commands.all()) |> Enum.sort() == ~w(deploys restart start status stop)

    for {name, mod} <- Commands.all() do
      Code.ensure_loaded!(mod)
      assert is_binary(name)
      assert function_exported?(mod, :command, 1), "#{inspect(mod)} missing command/1"
      assert function_exported?(mod, :description, 0), "#{inspect(mod)} missing description/0"
      assert mod.type() == :slash
      assert is_list(mod.options())
    end
  end

  test "status command renders an ephemeral reply when idle" do
    reply = Fueltruck.Discord.Commands.Status.command(nil)
    assert reply[:ephemeral?] == true
    assert is_binary(reply[:content])
  end

  test "option/2 extracts a named interaction option" do
    interaction = %{data: %{options: [%{name: "deploy", value: "antistasi"}]}}
    assert Commands.option(interaction, "deploy") == "antistasi"
    assert Commands.option(interaction, "missing") == nil
    assert Commands.option(%{data: %{options: nil}}, "deploy") == nil
  end
end
