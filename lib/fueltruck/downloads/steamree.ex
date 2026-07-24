defmodule Fueltruck.Downloads.Steamree do
  @moduledoc """
  Adapter for the external `steamree` downloader — the single integration point for
  its command line. steamree manages its own parallelism and update checking; we hand
  it what to fetch and consume its JSON event stream.

  The exact flags are centralized here (and overridable via config) so they can be
  adjusted when the binary lands without touching the queue.

      config :fueltruck, Fueltruck.Downloads,
        steamree_bin: "/opt/steamree/steamree",
        steamree_extra_args: ["--login", "anonymous"]
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

  @doc "Argv to install/update the dedicated server."
  def server_argv do
    args =
      [
        "app",
        "--appid",
        Integer.to_string(@server_app_id),
        "--dir",
        Storage.server_dir(),
        "--json"
      ] ++ extra_args()

    {bin(), args}
  end

  @doc "Argv to install/update a set of workshop mods (checks + updates)."
  def mods_argv(workshop_ids) do
    ids = Enum.map(workshop_ids, &to_string/1)

    args =
      [
        "workshop",
        "--appid",
        Integer.to_string(@workshop_app_id),
        "--dir",
        Storage.workshop_dir(),
        "--json"
      ] ++ extra_args() ++ ids

    {bin(), args}
  end
end
