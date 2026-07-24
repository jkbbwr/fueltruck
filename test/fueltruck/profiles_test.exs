defmodule Fueltruck.ProfilesTest do
  use Fueltruck.DataCase, async: false

  alias Fueltruck.{Deploys, Profiles, Storage}

  setup do
    {:ok, deploy} = Deploys.create_deploy(%{name: "Profile Test"})
    on_exit(fn -> File.rm_rf(Storage.profile_dir(deploy.profile_name)) end)
    %{deploy: deploy}
  end

  test "profile dir is rooted at the install and keyed by name", %{deploy: deploy} do
    assert deploy.profile_name == "profile-test"
    assert Profiles.profiles_dir(deploy) == Path.join(Storage.server_dir(), "profile-test")
  end

  test "uploads are stored and then found by kind, regardless of source name", %{deploy: deploy} do
    src = Path.join(System.tmp_dir!(), "src-#{System.unique_integer([:positive])}")
    File.write!(src, "version=\"1\";")

    assert :main = Profiles.put_upload(deploy, "someoldserver.armaprofile", src)
    assert :vars = Profiles.put_upload(deploy, "someoldserver.vars.armaprofile", src)

    assert Profiles.exists?(deploy, :main)
    assert Profiles.exists?(deploy, :vars)
    assert Profiles.find(deploy, :vars) =~ ".vars."
    refute Profiles.find(deploy, :main) =~ ".vars."
    File.rm(src)
  end

  test "reads locate profiles nested under a Users/ subfolder", %{deploy: deploy} do
    nested = Path.join([Profiles.profiles_dir(deploy), "Users", "profile-test"])
    File.mkdir_p!(nested)
    File.write!(Path.join(nested, "profile-test.vars.Arma3Profile"), "x")

    assert Profiles.find(deploy, :vars) =~ "profile-test.vars.Arma3Profile"
  end
end
