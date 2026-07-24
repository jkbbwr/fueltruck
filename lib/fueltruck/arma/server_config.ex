defmodule Fueltruck.Arma.ServerConfig do
  @moduledoc """
  Generates `server.cfg` and `basic.cfg` bodies from a deploy's structured settings.
  If the deploy carries an explicit override body it is used verbatim, so operators
  can hand-tune the config in the UI.
  """
  alias Fueltruck.Deploys.Deploy

  @doc "Return the server.cfg body for a deploy."
  def server_cfg(%Deploy{server_cfg: cfg}) when is_binary(cfg) and cfg != "", do: cfg
  def server_cfg(%Deploy{} = deploy), do: generate_server_cfg(deploy)

  @doc "Return the basic.cfg body for a deploy."
  def basic_cfg(%Deploy{basic_cfg: cfg}) when is_binary(cfg) and cfg != "", do: cfg
  def basic_cfg(%Deploy{} = _deploy), do: default_basic_cfg()

  @doc """
  Parse the known structured values out of a `server.cfg` body into the settings map
  (string keys). Used to populate the settings UI when a full cfg is uploaded/edited,
  so the two views stay in sync. Only recognised keys are returned.
  """
  @spec parse(binary()) :: %{optional(String.t()) => term()}
  def parse(cfg) when is_binary(cfg) do
    %{}
    |> extract_str(cfg, "hostname", ~r/^\s*hostname\s*=\s*"([^"]*)"/mi)
    |> extract_str(cfg, "admin_password", ~r/^\s*passwordAdmin\s*=\s*"([^"]*)"/mi)
    |> extract_str(cfg, "password", ~r/^\s*password\s*=\s*"([^"]*)"/mi)
    |> extract_str(cfg, "max_players", ~r/^\s*maxPlayers\s*=\s*(\d+)/mi)
    |> extract_str(cfg, "verify_signatures", ~r/^\s*verifySignatures\s*=\s*(\d+)/mi)
    |> extract_str(cfg, "persistent", ~r/^\s*persistent\s*=\s*(\d+)/mi)
    |> extract_str(cfg, "battleye", ~r/^\s*BattlEye\s*=\s*(\d+)/mi)
    |> extract_motd(cfg)
  end

  def parse(_), do: %{}

  defp extract_str(acc, cfg, key, regex) do
    case Regex.run(regex, cfg) do
      [_, value] -> Map.put(acc, key, value)
      _ -> acc
    end
  end

  defp extract_motd(acc, cfg) do
    case Regex.run(~r/^\s*motd\[\]\s*=\s*\{([^}]*)\}/mi, cfg) do
      [_, body] ->
        lines =
          Regex.scan(~r/"([^"]*)"/, body)
          |> Enum.map_join("\n", fn [_, l] -> l end)

        Map.put(acc, "motd", lines)

      _ ->
        acc
    end
  end

  @doc "Generate a fresh server.cfg from settings (ignoring any override)."
  def generate_server_cfg(%Deploy{} = deploy) do
    s = deploy.settings || %{}

    ([
       kv("hostname", get(s, "hostname", deploy.name)),
       optional_kv("password", get(s, "password", "")),
       optional_kv("passwordAdmin", get(s, "admin_password", "")),
       kv_raw("maxPlayers", get(s, "max_players", 32)),
       motd(get(s, "motd", [])),
       kv_raw("persistent", bool(get(s, "persistent", true))),
       kv_raw("verifySignatures", get(s, "verify_signatures", 2)),
       kv_raw("BattlEye", bool(get(s, "battleye", false))),
       kv_raw("kickDuplicate", 1),
       kv_raw("allowedFilePatching", get(s, "allowed_file_patching", 1))
     ] ++ headless_client_lines(deploy))
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  # When a deploy runs headless clients, they must be whitelisted to connect locally
  # and be recognised as headless (so AI/scripting can be offloaded to them).
  defp headless_client_lines(%Deploy{headless_client_count: n}) when n > 0 do
    [
      "",
      ~s(// Headless clients),
      ~s(headlessClients[] = {"127.0.0.1"};),
      ~s(localClient[] = {"127.0.0.1"};)
    ]
  end

  defp headless_client_lines(_), do: []

  defp default_basic_cfg do
    """
    MaxMsgSend = 128;
    MaxSizeGuaranteed = 512;
    MaxSizeNonguaranteed = 256;
    MinBandwidth = 1310720;
    MaxBandwidth = 2147483647;
    MinErrorToSend = 0.001;
    MinErrorToSendNear = 0.01;
    MaxCustomFileSize = 0;
    class sockets { maxPacketSize = 1400; };
    """
  end

  defp kv(key, value), do: ~s(#{key} = "#{escape(value)}";)
  defp kv_raw(key, value), do: ~s(#{key} = #{value};)

  defp optional_kv(_key, value) when value in [nil, ""], do: nil
  defp optional_kv(key, value), do: kv(key, value)

  defp motd([]), do: nil
  defp motd(""), do: nil

  defp motd(text) when is_binary(text) do
    text |> String.split(~r/\r?\n/, trim: true) |> motd()
  end

  defp motd(lines) when is_list(lines) do
    case Enum.reject(lines, &(&1 in [nil, ""])) do
      [] -> nil
      clean -> ~s(motd[] = {#{Enum.map_join(clean, ", ", fn l -> ~s("#{escape(l)}") end)}};)
    end
  end

  defp motd(_), do: nil

  defp bool(true), do: 1
  defp bool(false), do: 0
  defp bool(v), do: v

  defp get(map, key, default) do
    case Map.get(map, key) do
      nil -> default
      "" when default != "" -> default
      v -> v
    end
  end

  defp escape(v), do: v |> to_string() |> String.replace("\"", "\"\"")
end
