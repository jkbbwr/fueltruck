defmodule FueltruckWeb.Router do
  use FueltruckWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FueltruckWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FueltruckWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/deploys", DeploysLive, :index
    live "/deploys/new", DeploysLive, :new
    live "/deploys/:id", DeployLive, :show
    live "/deploys/:id/edit", DeployLive, :edit
    live "/downloads", DownloadsLive, :index

    get "/deploys/:id/preset", PresetController, :export
    get "/deploys/:id/profile/:kind", ProfileController, :download
    get "/deploys/:id/backups/:backup_id", ProfileController, :backup
  end

  # Other scopes may use custom stacks.
  # scope "/api", FueltruckWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:fueltruck, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FueltruckWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
