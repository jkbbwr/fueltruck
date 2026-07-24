defmodule Fueltruck.Catalog.Mod do
  @moduledoc """
  A workshop mod downloaded once into the shared store. Deploys reference mods
  through `Fueltruck.Deploys.DeployMod` join rows that carry per-deploy flags
  (enabled / server-only / load order).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "mods" do
    field :workshop_id, :string
    field :name, :string
    field :size_bytes, :integer, default: 0
    field :store_path, :string
    field :version_tag, :string
    field :last_updated_at, :utc_datetime
    field :installed_at, :utc_datetime
    field :update_available, :boolean, default: false

    has_many :deploy_mods, Fueltruck.Deploys.DeployMod

    timestamps()
  end

  @doc false
  def changeset(mod, attrs) do
    mod
    |> cast(attrs, [
      :workshop_id,
      :name,
      :size_bytes,
      :store_path,
      :version_tag,
      :last_updated_at,
      :installed_at,
      :update_available
    ])
    |> validate_required([:workshop_id, :name])
    |> unique_constraint(:workshop_id)
  end
end
