defmodule Fueltruck.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Fueltruck.Storage.ensure_layout!()
    discord_ready? = maybe_start_nostrum()

    children = [
      FueltruckWeb.Telemetry,
      Fueltruck.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:fueltruck, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:fueltruck, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Fueltruck.PubSub},
      # Log pipeline
      {Registry, keys: :unique, name: Fueltruck.Logs.Registry},
      Fueltruck.Logs.Index,
      {DynamicSupervisor, strategy: :one_for_one, name: Fueltruck.Logs.Supervisor},
      Fueltruck.Logs.Janitor,
      # Arma process management
      {Registry, keys: :unique, name: Fueltruck.Arma.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Fueltruck.Arma.ProcSupervisor},
      Fueltruck.Arma.Orchestrator,
      # Downloads + metrics
      Fueltruck.Downloads.Queue,
      Fueltruck.Metrics.Sampler
    ]

    # Discord (optional): nostrum is already started by maybe_start_nostrum/0 (with
    # num_shards: :manual, so it's booted but not connected). Our supervisor adds the
    # dispatcher + consumer + notifier and opens the gateway. Endpoint stays last so
    # requests are served after everything.
    children = children ++ discord_children(discord_ready?) ++ [FueltruckWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Fueltruck.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # nostrum is `runtime: false` (no auto-start). When Discord is enabled, bring it and
  # its deps (gun, etc.) up via ensure_all_started. A failure here (e.g. a bad
  # DISCORD_TOKEN) is logged and Discord is skipped — it must not take down the server,
  # which manages Arma regardless. Returns whether Discord may start.
  defp maybe_start_nostrum do
    if Application.get_env(:fueltruck, :discord_enabled, false) do
      case Application.ensure_all_started(:nostrum) do
        {:ok, _apps} ->
          true

        {:error, reason} ->
          Logger.error(
            "Discord is enabled but Nostrum failed to start (check DISCORD_TOKEN): #{inspect(reason)}"
          )

          false
      end
    else
      false
    end
  end

  defp discord_children(true), do: [Fueltruck.Discord]
  defp discord_children(false), do: []

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FueltruckWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
