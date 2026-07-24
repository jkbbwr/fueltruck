defmodule FueltruckWeb.DashboardLiveTest do
  use FueltruckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Fueltruck.{Arma, Deploys}

  @stub Path.join(File.cwd!(), "priv/stub/fake_arma.sh")

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Fueltruck.Repo, {:shared, self()})
    prev = Application.get_env(:fueltruck, Fueltruck.Arma)
    Application.put_env(:fueltruck, Fueltruck.Arma, Keyword.put(prev, :server_binary, @stub))

    on_exit(fn ->
      Arma.stop_deploy()
      Application.put_env(:fueltruck, Fueltruck.Arma, prev)
    end)

    :ok
  end

  test "idle dashboard offers deploys to start", %{conn: conn} do
    {:ok, _d} = Deploys.create_deploy(%{name: "Idle Deploy", headless_client_count: 0})
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "No deploy is running"
    assert html =~ "Idle Deploy"
  end

  test "starting a deploy shows process cards and log panels", %{conn: conn} do
    {:ok, deploy} = Deploys.create_deploy(%{name: "Live Deploy", headless_client_count: 1})

    {:ok, view, _html} = live(conn, ~p"/")
    Arma.subscribe_procs()

    render_click(element(view, "button[phx-value-id='#{deploy.id}']"))

    # Wait for the server to report ready so the render reflects a running deploy.
    assert_receive {:proc_status, :server, %{event: :ready}}, 5_000
    render(view)

    assert has_element?(view, "#log-server")
    assert has_element?(view, "#log-hc-0")
    assert render(view) =~ "Live logs"
  end
end
