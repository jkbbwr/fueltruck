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
  def server_dir, do: Path.join(data_dir(), "server")

  @doc "Absolute path to the server executable."
  @spec server_binary() :: Path.t()
  def server_binary do
    bin = Application.fetch_env!(:fueltruck, Fueltruck.Arma)[:server_binary]

    if Path.type(bin) == :absolute, do: bin, else: Path.join(server_dir(), bin)
  end

  @doc "Root of the shared workshop mod store."
  @spec workshop_dir() :: Path.t()
  def workshop_dir do
    app_id = Application.fetch_env!(:fueltruck, Fueltruck.Arma)[:workshop_app_id]
    Path.join([data_dir(), "workshop", Integer.to_string(app_id)])
  end

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
  Profile directory Arma writes to, keyed by the `-name` value: `<install>/<name>/`.
  On Linux `-profiles` is effectively ignored and the profile lands under the server
  install dir (the process cwd), so this is rooted there. Unique per-deploy `-name`
  (the slug) keeps deploys isolated. Holds `<name>.armaprofile` / var.profiles.
  """
  @spec profile_dir(String.t()) :: Path.t()
  def profile_dir(name), do: Path.join(server_dir(), to_string(name))

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
