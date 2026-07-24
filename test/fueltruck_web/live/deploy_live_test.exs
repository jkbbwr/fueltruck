defmodule FueltruckWeb.DeployLiveTest do
  use FueltruckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Fueltruck.Deploys

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Fueltruck.Repo, {:shared, self()})
    {:ok, deploy} = Deploys.create_deploy(%{name: "Manage Me", headless_client_count: 1})
    %{deploy: deploy}
  end

  test "new deploys default profile_name to the slug (unique per deploy)" do
    {:ok, d} = Deploys.create_deploy(%{name: "Cool Ops"})
    assert d.slug == "cool-ops"
    assert d.profile_name == "cool-ops"
  end

  test "deleting from the manage page removes the deploy", %{conn: conn, deploy: deploy} do
    {:ok, view, _html} = live(conn, ~p"/deploys/#{deploy.id}")
    render_click(element(view, "button[title='Delete deploy']"))
    assert Deploys.get_deploy(deploy.id) == nil
  end

  test "renders and switches across every tab", %{conn: conn, deploy: deploy} do
    {:ok, view, _html} = live(conn, ~p"/deploys/#{deploy.id}")

    assert has_element?(view, "#settings-form")

    render_click(element(view, "button", "server.cfg / basic.cfg"))
    assert has_element?(view, "#config-form")

    render_click(element(view, "button", "Mods & Presets"))
    assert render(view) =~ "Launcher preset"

    render_click(element(view, "button", "Profiles & Backups"))
    assert render(view) =~ "var.profiles"
  end

  test "saving settings persists structured server.cfg values", %{conn: conn, deploy: deploy} do
    {:ok, view, _html} = live(conn, ~p"/deploys/#{deploy.id}")

    view
    |> form("#settings-form", %{
      "deploy" => %{"name" => "Renamed", "port" => "2402"},
      "settings" => %{"hostname" => "My Host", "max_players" => "50"}
    })
    |> render_submit()

    updated = Deploys.get_deploy!(deploy.id)
    assert updated.name == "Renamed"
    assert updated.port == 2402
    assert updated.settings["hostname"] == "My Host"
  end

  test "generating server.cfg includes headless client whitelisting", %{
    conn: conn,
    deploy: deploy
  } do
    {:ok, view, _html} = live(conn, ~p"/deploys/#{deploy.id}")

    render_click(element(view, "button", "server.cfg / basic.cfg"))
    render_click(element(view, "button", "Generate from settings"))

    cfg = Deploys.get_deploy!(deploy.id).server_cfg
    assert cfg =~ "headlessClients[] = {\"127.0.0.1\"};"
    assert cfg =~ "BattlEye = 0;"
  end
end
