defmodule Fueltruck.Discord.Commands.Deploys do
  @moduledoc "`/deploys` — list configured deploys, marking the running one."
  @behaviour Nosedrum.ApplicationCommand

  alias Fueltruck.{Arma, Deploys}
  alias Fueltruck.Discord.Commands

  @impl true
  def type, do: :slash

  @impl true
  def description, do: "List configured deploys"

  @impl true
  def options, do: []

  @impl true
  def command(_interaction) do
    running = Arma.status().deploy

    case Deploys.list_deploys() do
      [] ->
        Commands.reply("No deploys configured.")

      deploys ->
        deploys
        |> Enum.map(fn d -> line(d, running) end)
        |> Enum.join("\n")
        |> Commands.reply()
    end
  end

  defp line(d, %{id: id}) when d.id == id, do: "🟢 **#{d.name}** (`#{d.slug}`) — running"
  defp line(d, _), do: "• #{d.name} (`#{d.slug}`)"
end
