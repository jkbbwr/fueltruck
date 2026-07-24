defmodule Fueltruck.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Fueltruck.Storage.ensure_layout!()

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
      Fueltruck.Metrics.Sampler,
      # Serve requests (typically last)
      FueltruckWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Fueltruck.Supervisor]
    Supervisor.start_link(children, opts)
  end

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
