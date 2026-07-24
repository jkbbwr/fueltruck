defmodule Fueltruck.Mods.Store do
  @moduledoc """
  Manages the shared mod store on disk: the Linux case-sensitivity lowercasing pass
  and finalizing a mod in the catalog after a download.

  Lowercasing runs once per content version — a marker file records a cheap content
  signature (size + file count) so unchanged mods are skipped on subsequent runs.
  """
  require Logger
  alias Fueltruck.Catalog
  alias Fueltruck.Storage

  @marker ".fueltruck"

  @doc """
  Finalize a freshly downloaded workshop mod: lowercase its tree (idempotent),
  compute its size, and upsert the catalog entry. Preserves an existing display name.
  """
  def finalize(workshop_id, opts \\ []) do
    id = to_string(workshop_id)
    dir = Storage.mod_store_dir(id)

    if File.dir?(dir) do
      lowercase_if_needed(dir)
      {size, count} = signature(dir)
      tag = "#{size}-#{count}"

      name =
        opts[:name] ||
          case Catalog.get_mod_by_workshop_id(id) do
            nil -> mod_name_from_meta(dir) || "mod-#{id}"
            mod -> mod.name
          end

      Catalog.upsert_mod(%{
        workshop_id: id,
        name: name,
        size_bytes: size,
        store_path: dir,
        version_tag: tag,
        installed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        update_available: false
      })
    else
      {:error, :not_downloaded}
    end
  end

  @doc "Lowercase a mod tree only if its content signature changed since last time."
  def lowercase_if_needed(dir) do
    {size, count} = signature(dir)
    sig = "#{size}-#{count}"
    marker_path = Path.join(dir, @marker)

    case File.read(marker_path) do
      {:ok, ^sig} ->
        :ok

      _ ->
        lowercase_tree(dir)
        File.write(marker_path, sig)
        :ok
    end
  end

  @doc """
  Recursively lowercase every file and directory name under `dir` (depth-first, so
  directories are renamed after their contents). Safe to run repeatedly.
  """
  def lowercase_tree(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          next = lowercase_entry(dir, entry)
          if File.dir?(next), do: lowercase_tree(next)
        end)

      _ ->
        :ok
    end
  end

  # Rename a single entry to lowercase (in place), returning the resulting path.
  defp lowercase_entry(dir, entry) do
    if entry == @marker do
      Path.join(dir, entry)
    else
      lower = String.downcase(entry)
      src = Path.join(dir, entry)
      dest = Path.join(dir, lower)

      cond do
        lower == entry -> src
        File.exists?(dest) and not same_file?(src, dest) -> case_clash(src, dest)
        true -> rename(src, dest)
      end
    end
  end

  defp rename(src, dest) do
    case File.rename(src, dest) do
      :ok -> dest
      {:error, _} -> src
    end
  end

  # On case-insensitive filesystems `src` and `dest` resolve to the same inode;
  # renaming is still fine (it fixes the stored case) and is not a real clash.
  defp same_file?(src, dest) do
    with {:ok, %{inode: i1}} <- File.stat(src),
         {:ok, %{inode: i2}} <- File.stat(dest) do
      i1 == i2 and i1 != 0
    else
      _ -> false
    end
  end

  # A genuinely different file already occupies the lowercase name (case-sensitive
  # FS collision). Leave the original in place and warn.
  defp case_clash(src, dest) do
    Logger.warning("case clash lowercasing #{src} -> #{dest}; leaving original")
    src
  end

  # Content signature: total regular-file bytes + count (stable across lowercasing).
  defp signature(dir) do
    Path.join(dir, "**")
    |> Path.wildcard(match_dot: false)
    |> Enum.reduce({0, 0}, fn path, {bytes, count} ->
      case File.stat(path) do
        {:ok, %{type: :regular, size: s}} -> {bytes + s, count + 1}
        _ -> {bytes, count}
      end
    end)
  end

  # Try to read a friendly name from mod.cpp / meta.cpp if present.
  defp mod_name_from_meta(dir) do
    candidates = Path.wildcard(Path.join(dir, "{mod.cpp,meta.cpp,Mod.cpp,Meta.cpp}"))

    Enum.find_value(candidates, fn path ->
      with {:ok, body} <- File.read(path),
           [_, name] <- Regex.run(~r/name\s*=\s*"([^"]+)"/i, body) do
        name
      else
        _ -> nil
      end
    end)
  end
end
