defmodule Fueltruck.Backups do
  @moduledoc """
  Timestamped archives of a deploy's profile directory (which holds `var.profiles`).
  Backups are created on stop and on demand, with keep-last-N retention.
  """
  import Ecto.Query, warn: false
  require Logger
  alias Fueltruck.Repo
  alias Fueltruck.Backups.Backup
  alias Fueltruck.Deploys.Deploy
  alias Fueltruck.Storage

  @keep 20

  def list_backups(%Deploy{} = deploy) do
    Repo.all(from b in Backup, where: b.deploy_id == ^deploy.id, order_by: [desc: b.inserted_at])
  end

  @doc """
  Archive the deploy's profile directory into a timestamped `.tar.gz`. Returns
  `{:ok, backup}` or `{:error, reason}`. A missing profile dir is not an error —
  there is simply nothing to back up yet.
  """
  def create(%Deploy{} = deploy, reason \\ "manual") do
    profile = Storage.profile_dir(deploy.slug, deploy.profile_name)

    if File.dir?(profile) do
      dest_dir = Storage.backups_dir(deploy.slug)
      File.mkdir_p!(dest_dir)
      stamp = timestamp()
      dest = Path.join(dest_dir, "profile-#{stamp}.tar.gz")

      case archive(profile, dest) do
        :ok ->
          size = file_size(dest)

          result =
            %Backup{}
            |> Backup.changeset(%{
              deploy_id: deploy.id,
              path: dest,
              size_bytes: size,
              reason: reason
            })
            |> Repo.insert()

          with {:ok, backup} <- result do
            prune(deploy)
            {:ok, backup}
          end

        {:error, reason} ->
          Logger.error("backup failed for #{deploy.slug}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:ok, :nothing_to_backup}
    end
  end

  @doc "Delete backups beyond the retention limit (oldest first), on disk and in DB."
  def prune(%Deploy{} = deploy, keep \\ @keep) do
    stale =
      Repo.all(
        from b in Backup, where: b.deploy_id == ^deploy.id, order_by: [desc: b.inserted_at]
      )
      |> Enum.drop(keep)

    for backup <- stale do
      _ = File.rm(backup.path)
      Repo.delete(backup)
    end

    :ok
  end

  # Archive `source_dir` into `dest` (.tar.gz) using Erlang's :erl_tar so we don't
  # depend on a system tar being present in the container.
  defp archive(source_dir, dest) do
    base = Path.basename(source_dir)

    files =
      Path.join(source_dir, "**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn abs ->
        rel = Path.join(base, Path.relative_to(abs, source_dir))
        {String.to_charlist(rel), String.to_charlist(abs)}
      end)

    case :erl_tar.create(String.to_charlist(dest), files, [:compressed]) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, e}
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end
end
