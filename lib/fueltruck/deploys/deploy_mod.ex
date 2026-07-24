defmodule Fueltruck.Deploys.DeployMod do
  @moduledoc """
  Join row linking a deploy to a mod, carrying the per-deploy flags. `server_only`
  routes the mod to `-serverMod=` instead of `-mod=`; disabled rows are excluded
  from the command line entirely. `load_order` controls mod ordering (matters for
  Arma dependencies).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "deploy_mods" do
    field :enabled, :boolean, default: true
    field :server_only, :boolean, default: false
    field :load_order, :integer, default: 0

    belongs_to :deploy, Fueltruck.Deploys.Deploy
    belongs_to :mod, Fueltruck.Catalog.Mod

    timestamps()
  end

  @doc false
  def changeset(deploy_mod, attrs) do
    deploy_mod
    |> cast(attrs, [:enabled, :server_only, :load_order, :mod_id])
    |> validate_required([:enabled, :server_only, :load_order])
    |> unique_constraint([:deploy_id, :mod_id])
  end
end
