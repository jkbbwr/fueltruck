defmodule Fueltruck.Discord.Commands do
  @moduledoc """
  Registry of slash commands and shared helpers for the Discord integration.

  Control actions (start/stop/restart) can take longer than Discord's 3-second
  interaction deadline, so `run_async/2` performs them in a Task and reports failures to
  the notification channel — the command itself replies immediately. Successful outcomes
  surface through `Fueltruck.Discord.Notifier` (server up/down events).
  """
  require Logger

  alias Fueltruck.Arma
  alias Fueltruck.Discord
  alias Nostrum.Api.Message

  @commands %{
    "status" => Fueltruck.Discord.Commands.Status,
    "deploys" => Fueltruck.Discord.Commands.Deploys,
    "start" => Fueltruck.Discord.Commands.Start,
    "stop" => Fueltruck.Discord.Commands.Stop,
    "restart" => Fueltruck.Discord.Commands.Restart
  }

  @doc "Map of command name → module."
  def all, do: @commands

  @doc "Fetch an interaction option value by name, or nil."
  def option(interaction, name) do
    (interaction.data.options || [])
    |> Enum.find(&(&1.name == name))
    |> case do
      nil -> nil
      opt -> opt.value
    end
  end

  @doc "An ephemeral text reply (only the invoker sees it)."
  def reply(content), do: [content: content, ephemeral?: true]

  @doc """
  Run a control action off the interaction process so we reply within Discord's 3s
  window. `fun` returns `:ok | {:error, reason}`; failures are posted to the notify
  channel (and always logged).
  """
  def run_async(label, fun) when is_function(fun, 0) do
    Task.Supervisor.start_child(Fueltruck.Discord.TaskSupervisor, fn ->
      case safe(fun) do
        :ok ->
          :ok

        {:error, reason} ->
          msg = "❌ #{label} failed: #{Arma.format_error(reason)}"
          Logger.error("Discord: #{msg}")
          notify(msg)
      end
    end)

    :ok
  end

  defp safe(fun) do
    fun.()
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp notify(content) do
    if channel = Discord.notify_channel_id() do
      Message.create(channel, content)
    end
  end
end
