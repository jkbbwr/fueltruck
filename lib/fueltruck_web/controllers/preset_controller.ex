defmodule FueltruckWeb.PresetController do
  use FueltruckWeb, :controller

  alias Fueltruck.{Deploys, Presets}

  def export(conn, %{"id" => id}) do
    deploy = Deploys.get_deploy!(id)
    html = Presets.export(deploy)
    filename = "#{deploy.slug}-preset.html"

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, html)
  end
end
