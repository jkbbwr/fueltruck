defmodule Fueltruck.Arma.CommandLine do
  @moduledoc """
  Builds the exact argv used to boot the Arma server and each headless client.

  Mod, config and profile paths are absolute so the process can run with its cwd in
  the server install dir (where the binary + BattlEye live) while loading mods that
  are symlinked into the deploy directory. The generated command line is shown in the
  UI and the deploy's free-text `extra_*_args` are appended verbatim.
  """

  alias Fueltruck.Deploys.Deploy
  alias Fueltruck.Storage

  @type argv :: {String.t(), [String.t()]}

  @doc """
  Minimal, correct server argv:

      arma3server_x64 -port=… -config=server.cfg -cfg=basic.cfg -profiles=… -name=…
                      -mod=<client mods> -serverMod=<server-only mods> <extras>

  `mod_paths` are absolute paths for `-mod=` (client-side mods, also loaded by HCs and
  players) and `server_mod_paths` for `-serverMod=` (server-only). Both are omitted
  when empty. Anything beyond the minimum (e.g. `-autoInit`, `-filePatching`) goes in
  the deploy's extra args.
  """
  @spec server(Deploy.t(), [String.t()], [String.t()]) :: argv()
  def server(%Deploy{} = deploy, mod_paths, server_mod_paths) do
    slug = deploy.slug

    # `-profiles` redirects the profile/save tree under the deploy dir (verified working
    # on Linux); `-name` selects the profile folder within it (`<root>/home/<name>/`).
    args =
      [
        "-port=#{deploy.port}",
        "-config=#{rel(Path.join(Storage.deploy_dir(slug), "server.cfg"))}",
        "-cfg=#{rel(Path.join(Storage.deploy_dir(slug), "basic.cfg"))}",
        "-profiles=#{rel(Storage.profiles_root(slug))}",
        "-name=#{deploy.profile_name}"
      ]
      |> maybe_mods("-mod", cdlc_keys(deploy) ++ mod_refs(deploy, mod_paths))
      |> maybe_mods("-serverMod", mod_refs(deploy, server_mod_paths))
      |> Kernel.++(tokenize(deploy.extra_server_args))

    {Storage.server_binary(), args}
  end

  @doc """
  Minimal, correct headless-client argv for client index `n`:

      arma3server_x64 -client -connect=<host> -port=… [-password=…]
                      -profiles=… -name=hc_<n> -mod=<client mods> <extras>

  A headless client is the same binary run with `-client`, connecting to the server.
  It loads only the client `-mod` set (never `-serverMod`) and supplies the game
  password (from `server.cfg`) when one is set. The connect host defaults to
  `127.0.0.1` (same container) and can be overridden via the `connect_host` setting.
  """
  @spec headless(Deploy.t(), non_neg_integer(), [String.t()]) :: argv()
  def headless(%Deploy{} = deploy, n, mod_paths) do
    settings = deploy.settings || %{}
    password = settings["password"]
    host = blank_default(settings["connect_host"], "127.0.0.1")

    args =
      [
        "-client",
        "-connect=#{host}",
        "-port=#{deploy.port}"
      ]
      |> maybe_password(password)
      |> Kernel.++([
        "-profiles=#{rel(Storage.profiles_root(deploy.slug))}",
        "-name=#{hc_profile_name(deploy, n)}"
      ])
      |> maybe_mods("-mod", cdlc_keys(deploy) ++ mod_refs(deploy, mod_paths))
      |> Kernel.++(tokenize(deploy.extra_hc_args))

    {Storage.server_binary(), args}
  end

  @doc """
  Profile name (`-name`) for headless client `n`, scoped to the deploy so each HC gets
  its own profile folder and two deploys never share one: `<profile_name>_hc<n>`.
  """
  @spec hc_profile_name(Deploy.t(), non_neg_integer()) :: String.t()
  def hc_profile_name(%Deploy{} = deploy, n), do: "#{deploy.profile_name}_hc#{n}"

  @doc "Render an argv as a copy-pasteable command line string."
  @spec to_string(argv()) :: String.t()
  def to_string({exe, args}) do
    [exe | args] |> Enum.map_join(" ", &quote_if_needed/1)
  end

  defp maybe_mods(args, _flag, []), do: args

  defp maybe_mods(args, flag, paths) do
    args ++ ["#{flag}=#{Enum.join(paths, ";")}"]
  end

  # `-config`/`-cfg`/`-profiles` accept absolute paths (deploy configs live under
  # /data/deploys, outside cwd; a relative `../..` path is mangled by Arma). But `-mod`
  # is different: Arma will NOT load a mod given by absolute path (it shows "GAME DIR
  # (Empty)") — mod entries must be relative to cwd. So config-ish paths stay absolute…
  defp rel(path), do: Path.expand(path)

  # …and mods are referenced through the install-dir bridge symlink (see
  # `Storage.mods_link/1`) as `<bridge>/@mod`, which resolves relative to cwd.
  defp mod_refs(deploy, paths) do
    link = Storage.mods_link_name(deploy.slug)
    Enum.map(paths, fn path -> Path.join(link, Path.basename(path)) end)
  end

  # Enabled Creator DLC folder keys (e.g. "gm", "vn"), loaded like client mods. Their
  # folders sit in the install dir, so the bare key is a valid relative `-mod` entry.
  defp cdlc_keys(%Deploy{cdlc: keys}) when is_list(keys), do: Fueltruck.Arma.CDLC.sanitize(keys)
  defp cdlc_keys(_), do: []

  defp maybe_password(args, nil), do: args
  defp maybe_password(args, ""), do: args
  defp maybe_password(args, pw), do: args ++ ["-password=#{pw}"]

  defp blank_default(nil, default), do: default
  defp blank_default("", default), do: default
  defp blank_default(value, _default), do: value

  defp quote_if_needed(token) do
    if String.contains?(token, [" ", ";"]) do
      ~s("#{token}")
    else
      token
    end
  end

  @doc """
  Split a free-text argument string into tokens, honoring single/double quoting
  anywhere in a token (so `-mod="@a b"` becomes one arg `-mod=@a b`). Quote
  characters are stripped; unquoted whitespace separates tokens. Empty input → [].
  """
  @spec tokenize(String.t() | nil) :: [String.t()]
  def tokenize(nil), do: []
  def tokenize(""), do: []

  def tokenize(str), do: scan(String.to_charlist(str), nil, [], [])

  # scan(chars, quote_char_or_nil, current_token_reversed, tokens_reversed)
  defp scan([], _quote, [], tokens), do: Enum.reverse(tokens)
  defp scan([], _quote, cur, tokens), do: Enum.reverse([token(cur) | tokens])

  defp scan([q | rest], nil, cur, tokens) when q in [?", ?'], do: scan(rest, q, cur, tokens)
  defp scan([q | rest], q, cur, tokens), do: scan(rest, nil, cur, tokens)

  defp scan([c | rest], nil, cur, tokens) when c in [?\s, ?\t] do
    case cur do
      [] -> scan(rest, nil, [], tokens)
      _ -> scan(rest, nil, [], [token(cur) | tokens])
    end
  end

  defp scan([c | rest], quote, cur, tokens), do: scan(rest, quote, [c | cur], tokens)

  defp token(reversed), do: reversed |> Enum.reverse() |> List.to_string()
end
