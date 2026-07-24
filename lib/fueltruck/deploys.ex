defmodule Fueltruck.Deploys do
  @moduledoc "Context for deploys and their mod selections."
  import Ecto.Query, warn: false
  alias Fueltruck.Repo
  alias Fueltruck.Arma.CommandLine
  alias Fueltruck.Deploys.{Deploy, DeployMod, Materializer}
  alias Fueltruck.Catalog.Mod

  @doc "List deploys, with mod counts preloaded lazily by callers as needed."
  def list_deploys do
    Repo.all(from d in Deploy, order_by: [asc: d.name])
  end

  @doc "List deploys with the `mod_count` virtual field populated."
  def list_deploys_with_counts do
    counts =
      Repo.all(from dm in DeployMod, group_by: dm.deploy_id, select: {dm.deploy_id, count(dm.id)})
      |> Map.new()

    list_deploys()
    |> Enum.map(fn d -> %{d | mod_count: Map.get(counts, d.id, 0)} end)
  end

  def get_deploy!(id), do: Repo.get!(Deploy, id)

  def get_deploy(id), do: Repo.get(Deploy, id)

  def get_deploy_by_slug(slug), do: Repo.get_by(Deploy, slug: slug)

  @doc "Load a deploy with mods (ordered) and their catalog entries."
  def get_deploy_with_mods!(id) do
    Repo.get!(Deploy, id)
    |> Repo.preload(deploy_mods: {from(dm in DeployMod, order_by: dm.load_order), :mod})
  end

  @doc "The single active deploy, if any."
  def active_deploy do
    Repo.one(from d in Deploy, where: d.is_active == true, limit: 1)
  end

  def create_deploy(attrs \\ %{}) do
    %Deploy{} |> Deploy.changeset(attrs) |> Repo.insert()
  end

  def update_deploy(%Deploy{} = deploy, attrs) do
    deploy |> Deploy.changeset(attrs) |> Repo.update()
  end

  def delete_deploy(%Deploy{} = deploy), do: Repo.delete(deploy)

  def change_deploy(%Deploy{} = deploy, attrs \\ %{}), do: Deploy.changeset(deploy, attrs)

  @doc """
  Mark `deploy` as the active one, clearing the flag on all others. This only records
  intent in the DB; the orchestrator drives the actual process lifecycle.
  """
  def set_active(%Deploy{} = deploy) do
    Repo.transaction(fn ->
      Repo.update_all(from(d in Deploy, where: d.is_active == true), set: [is_active: false])

      {:ok, updated} =
        deploy |> Ecto.Changeset.change(is_active: true) |> Repo.update()

      updated
    end)
  end

  def clear_active do
    Repo.update_all(from(d in Deploy, where: d.is_active == true), set: [is_active: false])
    :ok
  end

  ## Mod selection

  @doc "The ordered, enabled mod join rows for a deploy, mods preloaded."
  def deploy_mods(%Deploy{} = deploy) do
    Repo.all(
      from dm in DeployMod,
        where: dm.deploy_id == ^deploy.id,
        order_by: [asc: dm.load_order],
        preload: [:mod]
    )
  end

  @doc "Attach a mod to a deploy (idempotent on the unique [deploy_id, mod_id])."
  def add_mod(%Deploy{} = deploy, %Mod{} = mod, attrs \\ %{}) do
    max_order =
      Repo.one(
        from dm in DeployMod, where: dm.deploy_id == ^deploy.id, select: max(dm.load_order)
      ) ||
        -1

    %DeployMod{deploy_id: deploy.id, mod_id: mod.id}
    |> DeployMod.changeset(Map.put_new(attrs, :load_order, max_order + 1))
    |> Repo.insert(
      on_conflict: {:replace, [:enabled, :server_only, :updated_at]},
      conflict_target: [:deploy_id, :mod_id]
    )
  end

  def update_deploy_mod(%DeployMod{} = dm, attrs) do
    dm |> DeployMod.changeset(attrs) |> Repo.update()
  end

  def remove_mod(%DeployMod{} = dm), do: Repo.delete(dm)

  @doc """
  Preview the command lines a deploy would boot with, as argv tuples `{exe, args}`
  (server + each HC), without materializing anything to disk.
  """
  def command_preview(%Deploy{} = deploy) do
    plan = Materializer.plan(deploy)

    %{
      server: CommandLine.server(deploy, plan.mod_paths, plan.server_mod_paths),
      hcs:
        for i <- 0..(deploy.headless_client_count - 1)//1 do
          CommandLine.headless(deploy, i, plan.mod_paths)
        end
    }
  end

  @doc "Set explicit load order from an ordered list of deploy_mod ids."
  def reorder_mods(%Deploy{} = deploy, ordered_ids) do
    Repo.transaction(fn ->
      ordered_ids
      |> Enum.with_index()
      |> Enum.each(fn {id, idx} ->
        Repo.update_all(
          from(dm in DeployMod, where: dm.id == ^id and dm.deploy_id == ^deploy.id),
          set: [load_order: idx]
        )
      end)
    end)
  end
end
