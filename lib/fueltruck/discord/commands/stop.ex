defmodule Fueltruck.Discord.Commands.Stop do
  @moduledoc "`/stop` — stop the running deploy."
  @behaviour Nosedrum.ApplicationCommand

  alias Fueltruck.Arma
  alias Fueltruck.Discord.Commands

  @impl true
  def type, do: :slash

  @impl true
  def description, do: "Stop the running deploy"

  @impl true
  def options, do: []

  @impl true
  def command(_interaction) do
    case Arma.status() do
      %{phase: :idle} ->
        Commands.reply("Nothing is running.")

      %{deploy: deploy} ->
        Commands.run_async("Stop #{deploy.name}", fn -> Arma.stop_deploy() end)
        Commands.reply("⏳ Stopping **#{deploy.name}**…")
    end
  end
end
