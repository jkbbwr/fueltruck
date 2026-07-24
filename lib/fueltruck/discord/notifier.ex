defmodule Fueltruck.Discord.Notifier do
  @moduledoc """
  Posts server lifecycle and download events to the configured notification channel
  (`DISCORD_CHANNEL_ID`). Subscribes to the Arma process topic and the downloads topic.
  If no channel is configured it still runs but stays quiet.
  """
  use GenServer
  require Logger

  alias Fueltruck.Arma
  alias Fueltruck.Discord
  alias Fueltruck.Downloads.Queue
  alias Nostrum.Api.Message

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Arma.subscribe_procs()
    Queue.subscribe()
    {:ok, %{deploy_name: nil}}
  end

  # Only the server proc drives notifications (HC churn would be noisy).
  @impl true
  def handle_info({:proc_status, :server, status}, state) do
    state = remember_name(state)

    case message_for(status, state.deploy_name) do
      nil -> :ok
      content -> post(content)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:download_done, info}, state) do
    {level, message} = Queue.done_message(info)
    post("#{level_emoji(level)} #{message}")
    {:noreply, state}
  end

  # Ignore HC status, progress snapshots, and anything else.
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp remember_name(state) do
    case Arma.status().deploy do
      %{name: name} -> %{state | deploy_name: name}
      _ -> state
    end
  end

  defp message_for(%{event: :ready}, name), do: "🟢 **#{who(name)}** is up and ready"

  defp message_for(%{event: :crashed, attempts: n}, name),
    do: "🟠 **#{who(name)}** crashed — restarting (attempt #{n})"

  defp message_for(%{event: :failed} = s, name),
    do: "🔴 **#{who(name)}** failed to start#{err(s)}"

  defp message_for(%{event: :stopped}, name), do: "⏹️ **#{who(name)}** stopped"

  # :running (pre-ready) and :restarting are interim; skip to avoid double-posting.
  defp message_for(_status, _name), do: nil

  defp who(nil), do: "Server"
  defp who(name), do: name

  defp err(%{last_error: e}) when is_binary(e), do: " (#{e})"
  defp err(_), do: ""

  defp level_emoji(:error), do: "🔴"
  defp level_emoji(_), do: "🔵"

  defp post(content) do
    if channel = Discord.notify_channel_id() do
      case Message.create(channel, content) do
        {:ok, _} -> :ok
        error -> Logger.warning("Discord: notify failed: #{inspect(error)}")
      end
    end
  end
end
