defmodule Fueltruck.Discord.Commands.Status do
  @moduledoc "`/status` — current server state, deploy, and headless clients."
  @behaviour Nosedrum.ApplicationCommand

  alias Fueltruck.Arma
  alias Fueltruck.Discord.Commands

  @impl true
  def type, do: :slash

  @impl true
  def description, do: "Show the running deploy and server status"

  @impl true
  def options, do: []

  @impl true
  def command(_interaction) do
    Commands.reply(render(Arma.status()))
  end

  defp render(%{phase: :idle}), do: "🟤 No deploy is running."

  defp render(status) do
    deploy = status.deploy
    server = status.server

    header = "**#{deploy.name}** — phase `#{status.phase}`"
    server_line = "Server: #{emoji(server.state)} `#{server.state}`#{ready_note(server)}"

    hc_lines =
      status.hcs
      |> Enum.map(fn hc -> "#{emoji(hc.state)} #{hc.label}: `#{hc.state}`" end)

    ([header, server_line] ++ hc_lines)
    |> Enum.join("\n")
  end

  defp ready_note(%{ready: true}), do: " (ready)"
  defp ready_note(_), do: ""

  defp emoji(:running), do: "🟢"
  defp emoji(:restarting), do: "🟠"
  defp emoji(:failed), do: "🔴"
  defp emoji(_), do: "⚪"
end
