defmodule Fueltruck.Arma.CommandLineTest do
  use ExUnit.Case, async: true

  alias Fueltruck.Arma.CommandLine
  alias Fueltruck.Deploys.Deploy

  defp deploy(attrs) do
    Map.merge(
      %Deploy{
        name: "T",
        slug: "t",
        port: 2302,
        profile_name: "fueltruck",
        settings: %{},
        extra_server_args: "",
        extra_hc_args: ""
      },
      attrs
    )
  end

  test "tokenize honors quoting and empties" do
    assert CommandLine.tokenize(nil) == []
    assert CommandLine.tokenize("") == []
    assert CommandLine.tokenize("-a -b") == ["-a", "-b"]
    assert CommandLine.tokenize(~s(-mod="@a b" -x)) == ["-mod=@a b", "-x"]
  end

  test "server argv routes client vs server-only mods and appends extras" do
    d = deploy(%{extra_server_args: "-autoInit -world=empty"})
    {exe, args} = CommandLine.server(d, ["/m/@cba", "/m/@ace"], ["/m/@srv"])

    assert is_binary(exe)
    assert "-port=2302" in args
    assert Enum.any?(args, &String.starts_with?(&1, "-name="))
    assert Enum.any?(args, &String.starts_with?(&1, "-config="))

    mod = Enum.find(args, &String.starts_with?(&1, "-mod="))
    assert mod =~ "@cba" and mod =~ "@ace"
    assert Enum.find(args, &String.starts_with?(&1, "-serverMod=")) =~ "@srv"
    assert "-autoInit" in args
    assert "-world=empty" in args
  end

  test "headless argv connects locally, loads client mods, and uses the game password" do
    d = deploy(%{settings: %{"password" => "secret"}})
    {_exe, args} = CommandLine.headless(d, 2, ["/m/@cba"])

    assert "-client" in args
    assert "-connect=127.0.0.1" in args
    assert "-name=fueltruck_hc2" in args
    assert "-password=secret" in args
    assert Enum.find(args, &String.starts_with?(&1, "-mod=")) =~ "@cba"
    # HCs never load server-only mods.
    refute Enum.any?(args, &String.starts_with?(&1, "-serverMod="))
  end

  test "enabled Creator DLC folders are added to -mod (server and HC)" do
    d = deploy(%{cdlc: ["gm", "vn"], settings: %{}})

    {_exe, server_args} = CommandLine.server(d, ["/m/@cba"], [])
    server_mod = Enum.find(server_args, &String.starts_with?(&1, "-mod="))
    assert server_mod =~ "gm" and server_mod =~ "vn" and server_mod =~ "@cba"

    {_exe, hc_args} = CommandLine.headless(d, 0, ["/m/@cba"])
    hc_mod = Enum.find(hc_args, &String.starts_with?(&1, "-mod="))
    assert hc_mod =~ "gm" and hc_mod =~ "vn"
  end

  test "to_string quotes tokens containing spaces or semicolons" do
    str = CommandLine.to_string({"/bin/arma", ["-mod=/a;/b", "-name=hc"]})
    assert str =~ ~s("-mod=/a;/b")
    assert str =~ "-name=hc"
  end
end
