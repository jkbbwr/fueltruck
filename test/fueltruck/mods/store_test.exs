defmodule Fueltruck.Mods.StoreTest do
  use ExUnit.Case, async: true

  alias Fueltruck.Mods.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "ft-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "Addons"))
    File.write!(Path.join([dir, "Addons", "MyMod.pbo"]), "data")
    File.write!(Path.join(dir, "Mod.cpp"), ~s(name = "Cool Mod";))
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "lowercases the tree and is idempotent via the marker", %{dir: dir} do
    Store.lowercase_if_needed(dir)

    # On case-sensitive filesystems the names become lowercase; on case-insensitive
    # ones they resolve identically. Either way the lowercase paths must resolve.
    assert File.dir?(Path.join(dir, "addons"))
    assert File.exists?(Path.join([dir, "addons", "mymod.pbo"]))
    assert File.exists?(Path.join(dir, "mod.cpp"))

    # Marker written; a second call is a no-op (does not raise).
    assert File.exists?(Path.join(dir, ".fueltruck"))
    assert Store.lowercase_if_needed(dir) == :ok
  end
end
