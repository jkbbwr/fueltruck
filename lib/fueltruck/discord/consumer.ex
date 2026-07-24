defmodule Fueltruck.Discord.Consumer do
  @moduledoc """
  Nostrum gateway consumer. Registers our slash commands with Discord on `:READY`
  (guild-scoped when `DISCORD_GUILD_ID` is set, else global) and dispatches incoming
  interactions to the Nosedrum dispatcher.
  """
  use Nostrum.Consumer
  require Logger

  alias Fueltruck.Discord
  alias Fueltruck.Discord.Commands
  alias Nosedrum.Storage.Dispatcher

  @impl true
  def handle_event({:READY, _data, _ws}) do
    scope = Discord.command_scope()

    # Queue every command, then bulk-overwrite the scope's command set so stale
    # commands are removed and re-runs (reconnects) stay idempotent.
    for {name, module} <- Commands.all() do
      Dispatcher.queue_command(name, module, Discord.dispatcher())
    end

    case Dispatcher.process_queue(scope, Discord.dispatcher()) do
      {:ok, _} ->
        Logger.info("Discord: registered #{map_size(Commands.all())} commands (scope: #{inspect(scope)})")

      other ->
        Logger.error("Discord: command registration failed: #{inspect(other)}")
    end
  end

  @impl true
  def handle_event({:INTERACTION_CREATE, interaction, _ws}) do
    Dispatcher.handle_interaction(interaction, Discord.dispatcher())
  end

  # Ignore everything else.
  @impl true
  def handle_event(_event), do: :ok
end
