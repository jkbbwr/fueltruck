defmodule FueltruckWeb.ProfileController do
  use FueltruckWeb, :controller

  alias Fueltruck.{Backups, Deploys, Profiles, Repo}

  @doc "Download a deploy's profile file (`vars` or `main`)."
  def download(conn, %{"id" => id, "kind" => kind}) when kind in ["vars", "main"] do
    deploy = Deploys.get_deploy!(id)
    kind_atom = String.to_existing_atom(kind)

    case Profiles.find(deploy, kind_atom) do
      path when is_binary(path) ->
        send_download(conn, {:file, path}, filename: Profiles.filename(deploy, kind_atom))

      nil ->
        conn |> put_status(:not_found) |> text("No #{kind} profile yet for this deploy")
    end
  end

  @doc "Download a var.profiles backup archive."
  def backup(conn, %{"id" => id, "backup_id" => backup_id}) do
    deploy = Deploys.get_deploy!(id)
    backup = Repo.get_by!(Backups.Backup, id: backup_id, deploy_id: deploy.id)

    if File.regular?(backup.path) do
      send_download(conn, {:file, backup.path}, filename: Path.basename(backup.path))
    else
      conn |> put_status(:not_found) |> text("Backup file missing")
    end
  end
end
