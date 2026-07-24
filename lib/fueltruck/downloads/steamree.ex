defmodule Fueltruck.Downloads.Steamree do
  @moduledoc """
  Adapter for the external `steamree` downloader.

      steamree app <APP_ID> --json -o <root>        # install/update an app (233780 = server)
      steamree app <APP_ID> --branch creatordlc …   # Creator DLC server data
      steamree download <IDS…> --json -o <root>     # workshop items

  `-o <root>` is the content root: apps land in `<root>/<appid>`, workshop items in
  `<root>/<appid>/<pubfileid>` — matching `Fueltruck.Storage` paths. `--json` emits a
  JSON Lines stream on stdout (progress/logs stay on stderr). Extra args (e.g.
  `--user <name>` for auth, or `STEAM_USERNAME` in the env) come from config.
  """
  alias Fueltruck.Storage

  @server_app_id 233_780
  @workshop_app_id 107_410

  @doc "The steamree executable path (from config / STEAMREE_BIN)."
  def bin do
    Application.fetch_env!(:fueltruck, Fueltruck.Downloads)[:steamree_bin]
  end

  defp extra_args do
    Application.get_env(:fueltruck, Fueltruck.Downloads, [])
    |> Keyword.get(:steamree_extra_args, [])
  end

  @doc """
  Argv to install/update the dedicated server for a given stage:

    * `:base` — the default branch, i.e. the full base game. The `creatordlc` branch
      alone ships an inconsistent/incomplete core game (Arma reports the base `A3` mod
      as `NOT FOUND`), so the base must be installed first.
    * `:creatordlc` — overlays the free Creator DLC server data on top of the base.

  Both write to the same content root, so the server download runs `:base` then
  `:creatordlc` in sequence (see `Fueltruck.Downloads.Queue`).
  """
  def server_argv(stage \\ :creatordlc) do
    args =
      ["app", Integer.to_string(@server_app_id)] ++
        branch_args(stage) ++
        ["--json", "-o", Storage.steam_root()] ++
        extra_args()

    {bin(), args}
  end

  defp branch_args(:base), do: []
  defp branch_args(:creatordlc), do: ["--branch", "creatordlc"]

  @doc "Argv to install/update a set of workshop mods by published-file id."
  def mods_argv(workshop_ids) do
    ids = Enum.map(workshop_ids, &to_string/1)

    args =
      [
        "download",
        "--json",
        "-o",
        Storage.steam_root(),
        "--app",
        Integer.to_string(@workshop_app_id)
      ] ++
        extra_args() ++ ids

    {bin(), args}
  end
end
