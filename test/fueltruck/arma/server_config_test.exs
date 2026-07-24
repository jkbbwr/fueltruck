defmodule Fueltruck.Arma.ServerConfigTest do
  use ExUnit.Case, async: true

  alias Fueltruck.Arma.ServerConfig
  alias Fueltruck.Deploys.Deploy

  test "generate includes headless whitelist and BattlEye off by default" do
    cfg =
      ServerConfig.generate_server_cfg(%Deploy{
        name: "T",
        settings: %{},
        headless_client_count: 2
      })

    assert cfg =~ ~s(headlessClients[] = {"127.0.0.1"};)
    assert cfg =~ ~s(localClient[] = {"127.0.0.1"};)
    assert cfg =~ "BattlEye = 0;"
  end

  test "parse reads the known values out of a server.cfg body" do
    cfg = """
    hostname = "My Cool Server";
    password = "joinpw";
    passwordAdmin = "adminpw";
    maxPlayers = 64;
    persistent = 1;
    BattlEye = 1;
    verifySignatures = 2;
    motd[] = {"Line one", "Line two"};
    """

    parsed = ServerConfig.parse(cfg)
    assert parsed["hostname"] == "My Cool Server"
    assert parsed["password"] == "joinpw"
    assert parsed["admin_password"] == "adminpw"
    assert parsed["max_players"] == "64"
    assert parsed["battleye"] == "1"
    assert parsed["motd"] == "Line one\nLine two"
  end

  test "parse does not confuse passwordAdmin for password" do
    parsed = ServerConfig.parse(~s(passwordAdmin = "onlyadmin";\n))
    assert parsed["admin_password"] == "onlyadmin"
    refute Map.has_key?(parsed, "password")
  end
end
