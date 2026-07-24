defmodule Fueltruck.Repo.Migrations.AddCdlcToDeploys do
  use Ecto.Migration

  def change do
    alter table(:deploys) do
      add :cdlc, {:array, :string}, default: [], null: false
    end
  end
end
