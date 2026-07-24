defmodule Fueltruck.Discord.Commands.Start do
  @moduledoc "`/start deploy:<name|slug>` — materialize and launch a deploy."
  @behaviour Nosedrum.ApplicationCommand

  alias Fueltruck.{Arma, Deploys}
  alias Fueltruck.Discord.Commands

  @impl true
  def type, do: :slash

  @impl true
  def description, do: "Start a deploy (server + headless clients)"

  @impl true
  def options do
    [
      %{
        type: :string,
        name: "deploy",
        description: "Deploy name or slug",
        required: true
      }
    ]
  end

  @impl true
  def command(interaction) do
    query = Commands.option(interaction, "deploy")

    case resolve(query) do
      nil ->
        Commands.reply("No deploy matches `#{query}`. Use `/deploys` to list them.")

      deploy ->
        Commands.run_async("Start #{deploy.name}", fn -> Arma.start_deploy(deploy) end)
        Commands.reply("⏳ Starting **#{deploy.name}**… watch the channel for status.")
    end
  end

  # Match by exact slug first, then case-insensitive name.
  defp resolve(query) do
    Deploys.get_deploy_by_slug(query) ||
      Enum.find(Deploys.list_deploys(), fn d ->
        String.downcase(d.name) == String.downcase(query)
      end)
  end
end
