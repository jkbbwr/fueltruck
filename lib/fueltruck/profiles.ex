defmodule Fueltruck.Profiles do
  @moduledoc """
  Manages a deploy's Arma 3 profile files.

  We pass `-profiles=<deploy_dir>/profiles`, which redirects Arma's profile/save tree
  under the deploy dir instead of the user's home. Verified layout (with `-name=antistasi`):
  `<deploy_dir>/profiles/home/antistasi/antistasi.Arma3Profile`. `-name` is the deploy
  slug (see `Storage.profile_dir/2`). The relevant files:

    * `<name>.Arma3Profile` (a.k.a. `<name>.armaprofile`) — profile config
    * `<name>.vars.Arma3Profile` — persistent variables (mission save state)

  Extensions and casing still vary by platform/version, so **reads glob** the profile
  dir and match profile files case-insensitively. Uploads are written into the same
  dir, keyed to the deploy name, preserving the uploaded file's extension.
  """
  alias Fueltruck.Deploys.Deploy
  alias Fueltruck.Storage

  @type kind :: :main | :vars

  # Matches `.armaprofile`, `.arma3profile`, and `.vars.` variants, case-insensitively.
  @profile_re ~r/\.(vars\.)?arma3?profile$/i
  @vars_re ~r/\.vars\./i

  @doc "Directory Arma writes this deploy's profile into (`<deploy_dir>/profiles/home/<name>`)."
  def profiles_dir(%Deploy{} = deploy) do
    Storage.profile_dir(deploy.slug, deploy.profile_name)
  end

  @doc "Expected filename for a kind (based on the profile name)."
  def filename(%Deploy{} = deploy, :main), do: "#{deploy.profile_name}.Arma3Profile"
  def filename(%Deploy{} = deploy, :vars), do: "#{deploy.profile_name}.vars.Arma3Profile"

  @doc """
  Locate an existing profile file of the given kind anywhere under the profile dir,
  preferring one whose name matches the deploy's profile name. Returns a path or nil.
  """
  @spec find(Deploy.t(), kind()) :: Path.t() | nil
  def find(%Deploy{} = deploy, kind) do
    deploy
    |> candidates(kind)
    |> prefer(deploy)
  end

  @doc "Does a profile file of this kind exist?"
  def exists?(%Deploy{} = deploy, kind), do: find(deploy, kind) != nil

  @doc "Size + mtime of the located profile file, or nil."
  def info(%Deploy{} = deploy, kind) do
    with path when is_binary(path) <- find(deploy, kind),
         {:ok, %{size: size, mtime: mtime}} <- File.stat(path, time: :posix) do
      %{size: size, mtime: DateTime.from_unix!(mtime), path: path}
    else
      _ -> nil
    end
  end

  @doc """
  Store an uploaded profile file. Classifies vars vs main by filename and writes it to
  the deploy's profile dir keyed to the deploy name, preserving the source extension.
  Returns the detected kind.
  """
  def put_upload(%Deploy{} = deploy, filename, source_path) do
    kind = if Regex.match?(@vars_re, filename), do: :vars, else: :main
    dir = profiles_dir(deploy)
    File.mkdir_p!(dir)
    File.cp!(source_path, Path.join(dir, target_name(deploy, kind, filename)))
    kind
  end

  # Build `<name>.armaprofile` / `<name>.vars.armaprofile`, keeping the source's ext.
  defp target_name(deploy, kind, filename) do
    ext =
      case Regex.run(~r/(\.arma3?profile)$/i, filename) do
        [_, e] -> e
        _ -> ".Arma3Profile"
      end

    suffix = if kind == :vars, do: ".vars", else: ""
    "#{deploy.profile_name}#{suffix}#{ext}"
  end

  defp candidates(deploy, kind) do
    files =
      deploy
      |> profiles_dir()
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: false)
      |> Enum.filter(fn p -> File.regular?(p) and Regex.match?(@profile_re, p) end)

    case kind do
      :vars -> Enum.filter(files, &Regex.match?(@vars_re, &1))
      :main -> Enum.reject(files, &Regex.match?(@vars_re, &1))
    end
  end

  defp prefer([], _deploy), do: nil

  defp prefer(paths, deploy) do
    name = to_string(deploy.profile_name)
    Enum.find(paths, hd(paths), &String.starts_with?(Path.basename(&1), name))
  end
end
