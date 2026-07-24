defmodule Fueltruck.Storage do
  @moduledoc """
  Central definition of Fueltruck's on-disk layout, rooted at a single `data_dir`
  (the persistent container volume). Every other component asks this module for
  paths rather than building them ad hoc.

      <data_dir>/
        server/                      # arma3 dedicated server install (steamree target)
        workshop/<workshop_app_id>/  # shared mod store, one dir per workshop id
        deploys/<deploy-slug>/       # materialized deploy: symlinks + configs + keys + profile
        backups/<deploy-slug>/       # timestamped var.profiles archives
        logs/<deploy-slug>/<run>/    # captured stdout per run, with rollover
  """

  @doc "Absolute path to the persistent data root."
  @spec data_dir() :: Path.t()
  def data_dir do
    Application.fetch_env!(:fueltruck, __MODULE__)[:data_dir]
  end

  @doc "Arma dedicated server install directory (steamree downloads here)."
  @spec server_dir() :: Path.t()
  def server_dir, do: Path.join(steam_root(), Integer.to_string(server_app_id()))

  @doc """
  Steam content root passed to steamree as `-o`. steamree writes app content to
  `<root>/<appid>` and workshop items to `<root>/<appid>/<pubfileid>`, so this is the
  parent of both the server install and the workshop store.
  """
  @spec steam_root() :: Path.t()
  def steam_root, do: Path.join(data_dir(), "steam")

  @doc "Absolute path to the server executable."
  @spec server_binary() :: Path.t()
  def server_binary do
    bin = Application.fetch_env!(:fueltruck, Fueltruck.Arma)[:server_binary]

    if Path.type(bin) == :absolute, do: bin, else: Path.join(server_dir(), bin)
  end

  @doc """
  Writable HOME for the Arma processes. The base image runs as `nobody` with
  `HOME=/nonexistent`, but Arma's Steam integration `dlopen`s
  `$HOME/.steam/sdk64/steamclient.so` on boot — with no readable HOME it fails
  SteamAPI init and then segfaults (exit 139). Point HOME at a writable dir on the
  data volume instead.
  """
  @spec steam_home() :: Path.t()
  def steam_home, do: Path.join(data_dir(), "home")

  @doc """
  Ensure the Steam SDK layout Arma expects exists under `steam_home/.steam`.
  Symlinks the `steamclient.so` shipped in the server install into `sdk64` (and
  `sdk32`, harmlessly) so SteamAPI init succeeds without a steamcmd login or any
  Steam credentials at runtime. Idempotent; a no-op if the server isn't downloaded.
  """
  @spec ensure_steam_sdk!() :: :ok
  def ensure_steam_sdk! do
    src =
      [Path.join(server_dir(), "linux64/steamclient.so"), Path.join(server_dir(), "steamclient.so")]
      |> Enum.find(&File.regular?/1)

    if src do
      for sdk <- ["sdk64", "sdk32"] do
        dir = Path.join([steam_home(), ".steam", sdk])
        File.mkdir_p!(dir)
        link = Path.join(dir, "steamclient.so")
        File.rm(link)
        File.ln_s(src, link)
      end
    end

    :ok
  end

  @doc "Root of the shared workshop mod store (`<steam_root>/<workshop_app_id>`)."
  @spec workshop_dir() :: Path.t()
  def workshop_dir, do: Path.join(steam_root(), Integer.to_string(workshop_app_id()))

  defp server_app_id, do: Application.fetch_env!(:fueltruck, Fueltruck.Arma)[:server_app_id]
  defp workshop_app_id, do: Application.fetch_env!(:fueltruck, Fueltruck.Arma)[:workshop_app_id]

  @doc "Store directory for a single workshop mod (by its numeric id)."
  @spec mod_store_dir(String.t() | integer()) :: Path.t()
  def mod_store_dir(workshop_id), do: Path.join(workshop_dir(), to_string(workshop_id))

  @doc "Root of all materialized deploys."
  @spec deploys_dir() :: Path.t()
  def deploys_dir, do: Path.join(data_dir(), "deploys")

  @doc "Materialized directory for a deploy."
  @spec deploy_dir(String.t()) :: Path.t()
  def deploy_dir(slug), do: Path.join(deploys_dir(), slug)

  @doc """
  A deploy's `-profiles=` root: `<deploy_dir>/profiles`. Passing `-profiles` redirects
  Arma's whole profile/save tree here instead of the user's XDG home, so each deploy's
  profile sits next to its config/mods/keys (and inside its backups) rather than in some
  opaque home directory. Survives re-materialize (only `mods/` and `keys/` are rebuilt).
  """
  @spec profiles_root(String.t()) :: Path.t()
  def profiles_root(slug), do: Path.join(deploy_dir(slug), "profiles")

  @doc """
  Concrete directory Arma writes a given `-name`'s profile files into, under a deploy's
  `-profiles` root. Verified layout on Linux (this server version):

      <deploy_dir>/profiles/home/<name>/<name>.Arma3Profile
                                        /<name>.vars.Arma3Profile

  Keyed by `-name`, so the server (`profile_name`) and each HC (`<name>_hcN`) get their
  own folder here.
  """
  @spec profile_dir(String.t(), String.t()) :: Path.t()
  def profile_dir(slug, name) do
    Path.join([profiles_root(slug), "home", to_string(name)])
  end

  @doc "Directory holding collected BattlEye `.bikey` files for a deploy."
  @spec keys_dir(String.t()) :: Path.t()
  def keys_dir(slug), do: Path.join(deploy_dir(slug), "keys")

  @doc "Backups root for a deploy."
  @spec backups_dir(String.t()) :: Path.t()
  def backups_dir(slug), do: Path.join([data_dir(), "backups", slug])

  @doc "Logs root for a deploy."
  @spec logs_dir(String.t()) :: Path.t()
  def logs_dir(slug), do: Path.join([data_dir(), "logs", slug])

  @doc "Log directory for a specific run of a deploy."
  @spec run_log_dir(String.t(), String.t()) :: Path.t()
  def run_log_dir(slug, run_id), do: Path.join(logs_dir(slug), run_id)

  @doc """
  Ensure the base directory skeleton exists. Safe to call repeatedly; called on boot.
  """
  @spec ensure_layout!() :: :ok
  def ensure_layout! do
    for dir <- [data_dir(), server_dir(), workshop_dir(), deploys_dir()] do
      File.mkdir_p!(dir)
    end

    :ok
  end
end
