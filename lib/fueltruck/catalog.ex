defmodule Fueltruck.Catalog do
  @moduledoc "Context for the shared mod store catalog."
  import Ecto.Query, warn: false
  alias Fueltruck.Repo
  alias Fueltruck.Catalog.Mod

  @doc "List all mods, newest first."
  def list_mods do
    Repo.all(from m in Mod, order_by: [asc: m.name])
  end

  def get_mod!(id), do: Repo.get!(Mod, id)

  def get_mod_by_workshop_id(workshop_id) do
    Repo.get_by(Mod, workshop_id: to_string(workshop_id))
  end

  @doc """
  Insert or update a mod keyed by `workshop_id`. Used when importing presets and
  after steamree downloads report installed content.
  """
  def upsert_mod(attrs) do
    attrs = normalize(attrs)
    workshop_id = Map.fetch!(attrs, :workshop_id)

    case get_mod_by_workshop_id(workshop_id) do
      nil -> %Mod{}
      mod -> mod
    end
    |> Mod.changeset(attrs)
    |> Repo.insert_or_update()
  end

  def update_mod(%Mod{} = mod, attrs) do
    mod |> Mod.changeset(attrs) |> Repo.update()
  end

  def delete_mod(%Mod{} = mod), do: Repo.delete(mod)

  def change_mod(%Mod{} = mod, attrs \\ %{}), do: Mod.changeset(mod, attrs)

  @doc "Mark a set of workshop ids as having updates available."
  def flag_updates(workshop_ids) when is_list(workshop_ids) do
    ids = Enum.map(workshop_ids, &to_string/1)

    from(m in Mod, where: m.workshop_id in ^ids)
    |> Repo.update_all(set: [update_available: true])
  end

  defp normalize(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_atom(k), v} end)
    |> Map.update!(:workshop_id, &to_string/1)
  end

  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k) when is_binary(k), do: String.to_existing_atom(k)
end
