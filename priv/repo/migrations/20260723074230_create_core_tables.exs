defmodule Fueltruck.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    create table(:mods, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workshop_id, :string, null: false
      add :name, :string, null: false
      add :size_bytes, :integer, default: 0, null: false
      add :store_path, :string
      # version marker used to skip re-lowercasing unchanged content
      add :version_tag, :string
      add :last_updated_at, :utc_datetime
      add :installed_at, :utc_datetime
      add :update_available, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:mods, [:workshop_id])

    create table(:deploys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :port, :integer, default: 2302, null: false
      add :headless_client_count, :integer, default: 0, null: false
      add :profile_name, :string, default: "fueltruck", null: false
      # generated config bodies (editable in UI)
      add :server_cfg, :text
      add :basic_cfg, :text
      # structured server settings used to generate server_cfg when not overridden
      add :settings, :map, default: %{}, null: false
      # free-text extra args appended to the generated command line
      add :extra_server_args, :string, default: ""
      add :extra_hc_args, :string, default: ""
      add :is_active, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:deploys, [:slug])

    create table(:deploy_mods, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :deploy_id, references(:deploys, type: :binary_id, on_delete: :delete_all), null: false

      add :mod_id, references(:mods, type: :binary_id, on_delete: :delete_all), null: false
      add :enabled, :boolean, default: true, null: false
      add :server_only, :boolean, default: false, null: false
      add :load_order, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:deploy_mods, [:deploy_id, :mod_id])
    create index(:deploy_mods, [:deploy_id])

    create table(:backups, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :deploy_id, references(:deploys, type: :binary_id, on_delete: :delete_all), null: false

      add :path, :string, null: false
      add :size_bytes, :integer, default: 0, null: false
      add :reason, :string

      timestamps(type: :utc_datetime)
    end

    create index(:backups, [:deploy_id])

    create table(:log_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :deploy_id, references(:deploys, type: :binary_id, on_delete: :delete_all), null: false

      add :run_id, :string, null: false
      add :log_dir, :string, null: false
      add :started_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:log_runs, [:run_id])
    create index(:log_runs, [:deploy_id])
  end
end
