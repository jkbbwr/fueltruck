defmodule Fueltruck.Backups.Backup do
  @moduledoc "A timestamped archive of a deploy's `var.profiles` / profile directory."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "backups" do
    field :path, :string
    field :size_bytes, :integer, default: 0
    field :reason, :string

    belongs_to :deploy, Fueltruck.Deploys.Deploy

    timestamps()
  end

  @doc false
  def changeset(backup, attrs) do
    backup
    |> cast(attrs, [:path, :size_bytes, :reason, :deploy_id])
    |> validate_required([:path, :deploy_id])
  end
end
