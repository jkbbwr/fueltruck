defmodule Fueltruck.Arma.CDLC do
  @moduledoc """
  Registry of Arma 3 Creator DLCs. A CDLC is enabled on the server the same way a mod
  is — its folder (installed in the game directory) is added to `-mod=`. The folder key
  is relative to the install dir, so it drops straight into the command line.
  """

  # app_id is only used for (future) steamree downloads; the folder `key` is what goes
  # into `-mod`. Expeditionary Forces' app_id is unconfirmed → nil until verified.
  @cdlc [
    %{key: "csla", name: "CSLA Iron Curtain", app_id: 1_294_440},
    %{key: "ef", name: "Expeditionary Forces", app_id: nil},
    %{key: "gm", name: "Global Mobilization", app_id: 1_042_220},
    %{key: "rf", name: "Reaction Forces", app_id: 2_647_760},
    %{key: "vn", name: "S.O.G. Prairie Fire", app_id: 1_227_700},
    %{key: "spe", name: "Spearhead 1944", app_id: 1_175_380},
    %{key: "ws", name: "Western Sahara", app_id: 1_681_170}
  ]

  @doc "All known Creator DLCs."
  def all, do: @cdlc

  @doc "Valid CDLC folder keys."
  def keys, do: Enum.map(@cdlc, & &1.key)

  @doc "Look up a CDLC by folder key."
  def get(key), do: Enum.find(@cdlc, &(&1.key == key))

  @doc "Filter a list of keys down to the recognised ones, preserving registry order."
  def sanitize(keys) when is_list(keys) do
    set = MapSet.new(keys)
    for c <- @cdlc, MapSet.member?(set, c.key), do: c.key
  end

  def sanitize(_), do: []
end
