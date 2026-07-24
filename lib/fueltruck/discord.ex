defmodule Fueltruck.Discord do
  @moduledoc """
  Optional Discord integration, started only when `DISCORD_ENABLED=true`.

  Supervises (in order):

    1. `Nosedrum.Storage.Dispatcher` — stores + dispatches slash-command interactions.
    2. `Fueltruck.Discord.Consumer` — the Nostrum gateway consumer (registers commands
       on `:READY`, dispatches on `:INTERACTION_CREATE`).
    3. `Fueltruck.Discord.Notifier` — posts server lifecycle + download events to a
       channel.
    4. `Fueltruck.Discord.Connector` — opens the gateway *last*, so the consumer is
       already listening when Discord sends `:READY` (no missed registration).

  Nostrum itself is started separately by `Fueltruck.Application` (with
  `num_shards: :manual`, so nothing connects until the connector runs).
  """
  use Supervisor

  @dispatcher Nosedrum.Storage.Dispatcher

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The registered Nosedrum dispatcher name."
  def dispatcher, do: @dispatcher

  @doc "Guild id slash commands are registered to, or `:global` when unset."
  def command_scope do
    case config(:guild_id) do
      nil -> :global
      id -> id
    end
  end

  @doc "Channel id for lifecycle notifications, or nil."
  def notify_channel_id, do: config(:notify_channel_id)

  defp config(key) do
    :fueltruck
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key)
  end

  @impl true
  def init(_opts) do
    children = [
      {Task.Supervisor, name: Fueltruck.Discord.TaskSupervisor},
      {@dispatcher, name: @dispatcher},
      Fueltruck.Discord.Consumer,
      Fueltruck.Discord.Notifier,
      Fueltruck.Discord.Connector
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
