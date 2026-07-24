defmodule Fueltruck.Presets do
  @moduledoc """
  Import and export Arma 3 Launcher HTML mod-list presets.

  Import parses the `ModContainer` rows (display name + workshop link), upserts the
  mods into the catalog, and attaches them to a deploy. Export renders the same format
  so players can one-click-subscribe to a deploy's client mods.
  """
  alias Fueltruck.{Catalog, Deploys}
  alias Fueltruck.Deploys.Deploy

  @doc "Parse a preset HTML string into `[%{workshop_id, name}]`."
  @spec parse(binary()) :: [%{workshop_id: String.t(), name: String.t()}]
  def parse(html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, doc} -> from_containers(doc) |> fallback_links(doc)
      _ -> []
    end
  end

  defp from_containers(doc) do
    doc
    |> Floki.find(~s(tr[data-type="ModContainer"]))
    |> Enum.map(fn tr ->
      name = tr |> Floki.find(~s(td[data-type="DisplayName"])) |> Floki.text() |> String.trim()
      href = tr |> Floki.find("a") |> Floki.attribute("href") |> List.first()
      {extract_id(href), name}
    end)
    |> Enum.filter(fn {id, _} -> id != nil end)
    |> Enum.map(fn {id, name} ->
      %{workshop_id: id, name: if(name == "", do: "mod-#{id}", else: name)}
    end)
    |> Enum.uniq_by(& &1.workshop_id)
  end

  # If no ModContainer rows matched, fall back to any workshop links in the document.
  defp fallback_links([], doc) do
    doc
    |> Floki.find("a")
    |> Floki.attribute("href")
    |> Enum.map(&extract_id/1)
    |> Enum.filter(& &1)
    |> Enum.uniq()
    |> Enum.map(&%{workshop_id: &1, name: "mod-#{&1}"})
  end

  defp fallback_links(mods, _doc), do: mods

  defp extract_id(nil), do: nil

  defp extract_id(href) do
    case Regex.run(~r/[?&]id=(\d+)/, href) || Regex.run(~r/filedetails\/\?id=(\d+)/, href) do
      [_, id] -> id
      _ -> nil
    end
  end

  @doc """
  Import a preset into a deploy: upsert each mod and attach it. Returns
  `{:ok, %{ids: [...], added: n}}`.
  """
  def import_to_deploy(%Deploy{} = deploy, html) do
    mods = parse(html)

    ids =
      Enum.map(mods, fn attrs ->
        {:ok, mod} = Catalog.upsert_mod(attrs)
        Deploys.add_mod(deploy, mod)
        mod.workshop_id
      end)

    {:ok, %{ids: ids, added: length(ids)}}
  end

  @doc "Render a deploy's enabled client mods as an Arma Launcher preset HTML file."
  def export(%Deploy{} = deploy) do
    mods =
      deploy
      |> load_deploy_mods()
      |> Enum.filter(&(&1.enabled and not &1.server_only))
      |> Enum.map(& &1.mod)

    rows =
      Enum.map_join(mods, "\n", fn mod ->
        url = "https://steamcommunity.com/sharedfiles/filedetails/?id=#{mod.workshop_id}"

        """
              <tr data-type="ModContainer">
                <td data-type="DisplayName">#{html_escape(mod.name)}</td>
                <td>
                  <span class="from-steam">Steam</span>
                </td>
                <td>
                  <a href="#{url}" data-type="Link">#{url}</a>
                </td>
              </tr>
        """
      end)

    """
    <?xml version="1.0" encoding="utf-8"?>
    <html>
      <!--Created by Fueltruck-->
      <head>
        <meta name="arma:Type" content="preset" />
        <meta name="arma:PresetName" content="#{html_escape(deploy.name)}" />
        <meta name="generator" content="Fueltruck" />
        <title>Arma 3 Preset #{html_escape(deploy.name)}</title>
      </head>
      <body>
        <h1>Arma 3 Preset <strong>#{html_escape(deploy.name)}</strong></h1>
        <div class="mod-list">
          <table>
    #{rows}
          </table>
        </div>
      </body>
    </html>
    """
  end

  defp load_deploy_mods(%Deploy{deploy_mods: dms}) when is_list(dms), do: dms
  defp load_deploy_mods(%Deploy{} = deploy), do: Deploys.deploy_mods(deploy)

  defp html_escape(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
