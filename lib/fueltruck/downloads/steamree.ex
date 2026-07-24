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
  Argv to install/update the dedicated server on the `creatordlc` branch — the full
  Creator DLC Build (base server + CDLC server data), which is the only branch we run.
  """
  def server_argv do
    args =
      [
        "app",
        Integer.to_string(@server_app_id),
        "--branch",
        "creatordlc",
        "--json",
        "-o",
        Storage.steam_root()
      ] ++ extra_args()

    {bin(), args}
  end

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
