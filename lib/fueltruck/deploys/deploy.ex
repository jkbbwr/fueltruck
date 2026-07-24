defmodule Fueltruck.Deploys.Deploy do
  @moduledoc """
  A named configuration: server settings, selected mods (with flags), extra command
  line args, and a headless client count. Many deploys are stored; exactly one is
  active/running at a time.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "deploys" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :port, :integer, default: 2302
    field :headless_client_count, :integer, default: 0
    field :profile_name, :string
    field :server_cfg, :string
    field :basic_cfg, :string
    field :settings, :map, default: %{}
    field :cdlc, {:array, :string}, default: []
    field :extra_server_args, :string, default: ""
    field :extra_hc_args, :string, default: ""
    field :is_active, :boolean, default: false

    field :mod_count, :integer, virtual: true, default: 0

    has_many :deploy_mods, Fueltruck.Deploys.DeployMod, preload_order: [asc: :load_order]
    has_many :mods, through: [:deploy_mods, :mod]
    has_many :backups, Fueltruck.Backups.Backup

    timestamps()
  end

  @doc false
  def changeset(deploy, attrs) do
    deploy
    |> cast(attrs, [
      :name,
      :description,
      :port,
      :headless_client_count,
      :profile_name,
      :server_cfg,
      :basic_cfg,
      :settings,
      :cdlc,
      :extra_server_args,
      :extra_hc_args
    ])
    |> update_change(:cdlc, &Fueltruck.Arma.CDLC.sanitize/1)
    |> validate_required([:name])
    |> validate_number(:port, greater_than: 0, less_than: 65_536)
    |> validate_number(:headless_client_count,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 32
    )
    |> put_slug()
    |> put_profile_name()
    |> unique_constraint(:slug)
  end

  defp put_slug(changeset) do
    case get_field(changeset, :slug) do
      nil ->
        name = get_field(changeset, :name)
        if name, do: put_change(changeset, :slug, slugify(name)), else: changeset

      _ ->
        changeset
    end
  end

  # Default the Arma profile name (-name) to the slug so it's unique per deploy and
  # self-documenting, instead of a shared static default.
  defp put_profile_name(changeset) do
    if get_field(changeset, :profile_name) in [nil, ""] do
      case get_field(changeset, :slug) do
        nil -> changeset
        slug -> put_change(changeset, :profile_name, slug)
      end
    else
      changeset
    end
  end

  @doc "Turn a name into a filesystem-safe slug."
  def slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "deploy"
      slug -> slug
    end
  end
end
