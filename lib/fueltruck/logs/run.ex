defmodule Fueltruck.Logs.Run do
  @moduledoc """
  Records one run of a deploy (server + its HCs share a run id) so historical logs
  remain browsable after container restarts. The actual log lines live on disk under
  `log_dir`; this row is the index entry.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "log_runs" do
    field :run_id, :string
    field :log_dir, :string
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime

    belongs_to :deploy, Fueltruck.Deploys.Deploy

    timestamps()
  end

  @doc false
  def changeset(run, attrs) do
    run
    |> cast(attrs, [:run_id, :log_dir, :started_at, :ended_at, :deploy_id])
    |> validate_required([:run_id, :log_dir, :started_at, :deploy_id])
    |> unique_constraint(:run_id)
  end
end
