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

  @doc "Format a start/lifecycle failure reason into a human-readable message."
  def format_error(reason) do
    text = describe(reason)

    if text =~ ~r/enoent|no such file|not found|not_downloaded/i do
      text <> "\n\nThe Arma server doesn't appear to be installed — run Update server first."
    else
      text
    end
  end

  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe({%{__exception__: true} = e, stack}) when is_list(stack), do: Exception.message(e)
  defp describe({:exit, reason}), do: "process exited: #{inspect(reason, pretty: true)}"
  defp describe(reason), do: inspect(reason, pretty: true)
end
