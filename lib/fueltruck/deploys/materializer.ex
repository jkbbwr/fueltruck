defmodule Fueltruck.Deploys.Materializer do
  @moduledoc """
  Renders a deploy to disk: writes `server.cfg`/`basic.cfg`, (re)builds mod symlinks
  from the shared store, and collects BattlEye keys. The profile directory (holding
  `var.profiles`) is preserved across materializations. Returns the resolved absolute
  mod path lists used to build the command line.

  `plan/1` is the pure path computation (no disk writes) used for command-line
  previews; `materialize/1` performs the plan and writes to disk.
  """
  require Logger
  alias Fueltruck.Arma.ServerConfig
  alias Fueltruck.Deploys
  alias Fueltruck.Deploys.Deploy
  alias Fueltruck.Storage

  @type plan :: %{mod_paths: [String.t()], server_mod_paths: [String.t()], links: [map()]}
  @type result :: %{
          mod_paths: [String.t()],
          server_mod_paths: [String.t()],
          missing: [String.t()]
        }

  @doc "Pure: compute the mod symlink paths a deploy *would* use. No disk writes."
  @spec plan(Deploy.t()) :: plan()
  def plan(%Deploy{} = deploy) do
    mods_dir = Path.join(Storage.deploy_dir(deploy.slug), "mods")

    {links, _used} =
      deploy
      |> Deploys.deploy_mods()
      |> Enum.filter(& &1.enabled)
      |> Enum.map_reduce(MapSet.new(), fn dm, used ->
        {name, used} = unique_link_name(dm.mod, used)

        link = %{
          dm: dm,
          mod: dm.mod,
          server_only: dm.server_only,
          path: Path.join(mods_dir, name),
          store: dm.mod.store_path || Storage.mod_store_dir(dm.mod.workshop_id)
        }

        {link, used}
      end)

    %{
      mod_paths: for(l <- links, not l.server_only, do: l.path),
      server_mod_paths: for(l <- links, l.server_only, do: l.path),
      links: links
    }
  end

  @spec materialize(Deploy.t()) :: {:ok, result()} | {:error, term()}
  def materialize(%Deploy{} = deploy) do
    slug = deploy.slug
    deploy_dir = Storage.deploy_dir(slug)
    mods_dir = Path.join(deploy_dir, "mods")
    keys_dir = Storage.keys_dir(slug)

    File.mkdir_p!(deploy_dir)
    # Ensure the profile dir (under the install, keyed by -name) exists so uploads and
    # the first run have a home; it lives outside the deploy dir and is never wiped.
    File.mkdir_p!(Storage.profiles_root(deploy.slug))

    # Rebuild mods + keys fresh to reflect the current selection.
    _ = File.rm_rf(mods_dir)
    _ = File.rm_rf(keys_dir)
    File.mkdir_p!(mods_dir)
    File.mkdir_p!(keys_dir)

    File.write!(Path.join(deploy_dir, "server.cfg"), ServerConfig.server_cfg(deploy))
    File.write!(Path.join(deploy_dir, "basic.cfg"), ServerConfig.basic_cfg(deploy))

    %{links: links} = plan(deploy)

    missing =
      Enum.reduce(links, [], fn link, missing ->
        if File.dir?(link.store) do
          make_symlink(link.store, link.path)
          collect_keys(link.store, keys_dir)
          missing
        else
          Logger.warning(
            "mod #{link.mod.workshop_id} (#{link.mod.name}) missing at #{link.store}"
          )

          [link.mod.workshop_id | missing]
        end
      end)

    # Bridge the mods dir into the install dir (cwd) so `-mod` can reference mods
    # relative to cwd — Arma won't load absolutely-pathed mods (they show as "Empty").
    bridge = Storage.mods_link(slug)
    _ = File.rm(bridge)
    _ = File.ln_s(mods_dir, bridge)

    present = fn path -> path not in missing_paths(links, missing) end

    {:ok,
     %{
       mod_paths: Enum.filter(for(l <- links, not l.server_only, do: l.path), present),
       server_mod_paths: Enum.filter(for(l <- links, l.server_only, do: l.path), present),
       missing: Enum.reverse(missing)
     }}
  rescue
    e -> {:error, e}
  end

  defp missing_paths(links, missing) do
    for l <- links, l.mod.workshop_id in missing, do: l.path
  end

  # Lowercase, filesystem-safe, `@`-prefixed link name, unique within this deploy.
  defp unique_link_name(mod, used) do
    base =
      mod.name
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]+/, "_")
      |> String.trim("_")

    base = if base == "", do: mod.workshop_id, else: base
    candidate = "@" <> base

    name =
      if MapSet.member?(used, candidate),
        do: "@" <> base <> "_" <> mod.workshop_id,
        else: candidate

    {name, MapSet.put(used, name)}
  end

  defp make_symlink(target, link_path) do
    _ = File.rm(link_path)

    case File.ln_s(target, link_path) do
      :ok -> :ok
      {:error, :eexist} -> :ok
    end
  end

  # Copy any BattlEye .bikey files shipped with the mod into the deploy keys dir.
  defp collect_keys(store, keys_dir) do
    for keydir <- [Path.join(store, "keys"), Path.join(store, "key"), Path.join(store, "Keys")],
        File.dir?(keydir),
        key <- Path.wildcard(Path.join(keydir, "*.bikey")) do
      File.cp(key, Path.join(keys_dir, Path.basename(key)))
    end

    :ok
  end
end
