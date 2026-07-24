defmodule Fueltruck.Discord.Connector do
  @moduledoc """
  Opens the single Discord gateway shard once the rest of the Discord tree is up.

  Nostrum runs with `num_shards: :manual`, so no connection is made until we call
  `Nostrum.Shard.Supervisor.connect/2`. Starting this as the last child of
  `Fueltruck.Discord` guarantees the consumer is already subscribed before `:READY`
  arrives. It connects on init and then idles.
  """
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Logger.info("Discord: opening gateway connection")
    Nostrum.Shard.Supervisor.connect(0, 1)
    {:ok, %{}}
  end
end
