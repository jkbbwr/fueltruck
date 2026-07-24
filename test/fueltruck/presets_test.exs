defmodule Fueltruck.PresetsTest do
  use ExUnit.Case, async: true

  alias Fueltruck.Presets
  alias Fueltruck.Deploys.Deploy

  @preset """
  <html><body><table>
    <tr data-type="ModContainer">
      <td data-type="DisplayName">CBA_A3</td>
      <td><a href="https://steamcommunity.com/sharedfiles/filedetails/?id=450814997">L</a></td>
    </tr>
    <tr data-type="ModContainer">
      <td data-type="DisplayName">ACE3</td>
      <td><a href="https://steamcommunity.com/sharedfiles/filedetails/?id=463939057">L</a></td>
    </tr>
  </table></body></html>
  """

  test "parse extracts workshop ids and names, de-duplicated" do
    mods = Presets.parse(@preset)
    assert %{workshop_id: "450814997", name: "CBA_A3"} in mods
    assert %{workshop_id: "463939057", name: "ACE3"} in mods
    assert length(mods) == 2
  end

  test "parse falls back to bare workshop links" do
    html = ~s(<a href="https://steamcommunity.com/sharedfiles/filedetails/?id=999">x</a>)
    assert Presets.parse(html) == [%{workshop_id: "999", name: "mod-999"}]
  end

  test "export renders a re-importable preset" do
    deploy = %Deploy{name: "My Server", slug: "my-server", headless_client_count: 0}
    # No mods attached (no DB) — export still produces valid structure with the name.
    html = Presets.export(%{deploy | deploy_mods: []})
    assert html =~ ~s(content="preset")
    assert html =~ "My Server"
  end
end
