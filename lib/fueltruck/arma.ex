defmodule Fueltruck.Arma do
  @moduledoc """
  Facade + PubSub topics for the Arma process layer. Lifecycle control lives in
  `Fueltruck.Arma.Orchestrator`; this module is the stable entry point for the web
  layer and the place topics are defined.
  """
  alias Fueltruck.Arma.Orchestrator

  @procs_topic "procs"

  @doc "Topic carrying `{:proc_status, source, status}` events for all processes."
  def procs_topic, do: @procs_topic

  def subscribe_procs, do: Phoenix.PubSub.subscribe(Fueltruck.PubSub, @procs_topic)

  @doc false
  def broadcast_status(status) do
    Phoenix.PubSub.broadcast(
      Fueltruck.PubSub,
      @procs_topic,
      {:proc_status, status.source, status}
    )
  end

  ## Lifecycle facade

  defdelegate start_deploy(deploy), to: Orchestrator
  defdelegate stop_deploy(), to: Orchestrator
  defdelegate restart_deploy(), to: Orchestrator
  defdelegate restart_server(), to: Orchestrator
  defdelegate restart_hc(index), to: Orchestrator
  defdelegate status(), to: Orchestrator
end
