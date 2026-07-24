defmodule Fueltruck.Discord.Commands.Restart do
  @moduledoc "`/restart` — restart the running deploy (server + headless clients)."
  @behaviour Nosedrum.ApplicationCommand

  alias Fueltruck.Arma
  alias Fueltruck.Discord.Commands

  @impl true
  def type, do: :slash

  @impl true
  def description, do: "Restart the running deploy"

  @impl true
  def options, do: []

  @impl true
  def command(_interaction) do
    case Arma.status() do
      %{phase: :idle} ->
        Commands.reply("Nothing is running to restart.")

      %{deploy: deploy} ->
        Commands.run_async("Restart #{deploy.name}", fn -> Arma.restart_deploy() end)
        Commands.reply("⏳ Restarting **#{deploy.name}**…")
    end
  end
end
