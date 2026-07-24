defmodule FueltruckWeb.DeployLive do
  @moduledoc "Manage a single deploy: settings, config, mods, presets, and profiles."
  use FueltruckWeb, :live_view

  alias Fueltruck.{Arma, Backups, Catalog, Deploys, Presets, Profiles}
  alias Fueltruck.Arma.{CDLC, ServerConfig}
  alias Fueltruck.Downloads.Queue, as: Downloads

  @tabs [
    {"settings", "Settings", "hero-cog-6-tooth"},
    {"config", "server.cfg / basic.cfg", "hero-document-text"},
    {"mods", "Mods & Presets", "hero-puzzle-piece"},
    {"profiles", "Profiles & Backups", "hero-identification"}
  ]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Arma.subscribe_procs()
      Downloads.subscribe()
    end

    {:ok,
     socket
     |> assign(:active, :deploys)
     |> assign(:tab, "settings")
     |> assign(:tabs, @tabs)
     |> allow_upload(:preset, accept: ~w(.html .htm), max_entries: 1, max_file_size: 5_000_000)
     |> allow_upload(:profiles, accept: :any, max_entries: 2, max_file_size: 20_000_000)
     |> allow_upload(:server_cfg, accept: :any, max_entries: 1, max_file_size: 2_000_000)
     |> allow_upload(:basic_cfg, accept: :any, max_entries: 1, max_file_size: 2_000_000)
     |> assign(:download, Downloads.get())
     |> load(id)}
  end

  @impl true
  def handle_info({:proc_status, _s, _st}, socket), do: {:noreply, reload(socket)}
  def handle_info({:downloads, snap}, socket), do: {:noreply, assign(socket, :download, snap)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Tabs + validation

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket),
    do: {:noreply, assign(socket, :tab, tab)}

  def handle_event("validate", %{"deploy" => params}, socket) do
    changeset =
      socket.assigns.deploy |> Deploys.change_deploy(params) |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref, "name" => name}, socket) do
    {:noreply, cancel_upload(socket, String.to_existing_atom(name), ref)}
  end

  ## Settings + config

  def handle_event("save_settings", params, socket) do
    attrs =
      params
      |> Map.get("deploy", %{})
      |> Map.put("settings", Map.get(params, "settings", %{}))

    save_deploy(socket, attrs, "Settings saved")
  end

  def handle_event("save_config", %{"deploy" => params}, socket) do
    attrs =
      params
      |> Map.take(["server_cfg", "basic_cfg"])
      |> sync_settings_from_cfg(socket.assigns.deploy)

    save_deploy(socket, attrs, "Config saved")
  end

  def handle_event("upload_server_cfg", _params, socket) do
    case consume_uploaded_entries(socket, :server_cfg, fn %{path: p}, _ ->
           {:ok, File.read!(p)}
         end) do
      [body] ->
        attrs = sync_settings_from_cfg(%{"server_cfg" => body}, socket.assigns.deploy)
        save_deploy(socket, attrs, "server.cfg uploaded — settings read from it")

      _ ->
        {:noreply, put_flash(socket, :error, "No file uploaded")}
    end
  end

  def handle_event("upload_basic_cfg", _params, socket) do
    case consume_uploaded_entries(socket, :basic_cfg, fn %{path: p}, _ -> {:ok, File.read!(p)} end) do
      [body] -> save_deploy(socket, %{"basic_cfg" => body}, "basic.cfg uploaded")
      _ -> {:noreply, put_flash(socket, :error, "No file uploaded")}
    end
  end

  def handle_event("generate_config", %{"which" => "server"}, socket) do
    save_deploy(
      socket,
      %{"server_cfg" => ServerConfig.generate_server_cfg(socket.assigns.deploy)},
      "Generated server.cfg"
    )
  end

  def handle_event("generate_config", %{"which" => "basic"}, socket) do
    save_deploy(
      socket,
      %{"basic_cfg" => ServerConfig.basic_cfg(%{socket.assigns.deploy | basic_cfg: nil})},
      "Generated basic.cfg"
    )
  end

  def handle_event("reset_config", %{"which" => "server"}, socket),
    do: save_deploy(socket, %{"server_cfg" => ""}, "Reset to auto-generated")

  def handle_event("reset_config", %{"which" => "basic"}, socket),
    do: save_deploy(socket, %{"basic_cfg" => ""}, "Reset to auto-generated")

  ## Mods

  def handle_event("add_mod", %{"workshop_id" => raw}, socket) do
    case extract_id(raw) do
      nil ->
        {:noreply, put_flash(socket, :error, "Enter a workshop id or URL")}

      id ->
        {:ok, mod} = Catalog.upsert_mod(%{workshop_id: id, name: "mod-#{id}"})
        Deploys.add_mod(socket.assigns.deploy, mod)
        {:noreply, socket |> put_flash(:info, "Added mod #{id}") |> reload()}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    dm = find_dm(socket, id)
    Deploys.update_deploy_mod(dm, %{enabled: !dm.enabled})
    {:noreply, reload(socket)}
  end

  def handle_event("toggle_server_only", %{"id" => id}, socket) do
    dm = find_dm(socket, id)
    Deploys.update_deploy_mod(dm, %{server_only: !dm.server_only})
    {:noreply, reload(socket)}
  end

  def handle_event("remove_mod", %{"id" => id}, socket) do
    Deploys.remove_mod(find_dm(socket, id))
    {:noreply, socket |> put_flash(:info, "Mod removed") |> reload()}
  end

  def handle_event("update_mod", %{"id" => id}, socket) do
    dm = find_dm(socket, id)
    mod = dm.mod
    Downloads.update_mods([mod.workshop_id], names: %{mod.workshop_id => mod.name})
    {:noreply, put_flash(socket, :info, "Queued update for #{mod.name}")}
  end

  def handle_event("toggle_cdlc", %{"key" => key}, socket) do
    current = socket.assigns.deploy.cdlc || []
    next = if key in current, do: List.delete(current, key), else: current ++ [key]
    {:ok, _} = Deploys.update_deploy(socket.assigns.deploy, %{cdlc: next})
    {:noreply, reload(socket)}
  end

  def handle_event("move", %{"id" => id, "dir" => dir}, socket) do
    ids = Enum.map(socket.assigns.deploy_mods, & &1.id)
    idx = Enum.find_index(ids, &(&1 == id))
    swap = if dir == "up", do: idx - 1, else: idx + 1

    if idx && swap in 0..(length(ids) - 1) do
      Deploys.reorder_mods(socket.assigns.deploy, swap_at(ids, idx, swap))
    end

    {:noreply, reload(socket)}
  end

  ## Presets

  def handle_event("import_preset", _params, socket) do
    results =
      consume_uploaded_entries(socket, :preset, fn %{path: path}, _entry ->
        {:ok, Presets.import_to_deploy(socket.assigns.deploy, File.read!(path))}
      end)

    socket =
      case results do
        [%{added: n}] -> put_flash(socket, :info, "Imported #{n} mods from preset")
        _ -> put_flash(socket, :error, "No preset file uploaded")
      end

    {:noreply, reload(socket)}
  end

  def handle_event("import_preset_text", %{"html" => html}, socket) when byte_size(html) > 0 do
    {:ok, %{added: n}} = Presets.import_to_deploy(socket.assigns.deploy, html)
    {:noreply, socket |> put_flash(:info, "Imported #{n} mods from preset") |> reload()}
  end

  def handle_event("import_preset_text", _params, socket), do: {:noreply, socket}

  ## Profiles + backups

  def handle_event("upload_profiles", _params, socket) do
    deploy = socket.assigns.deploy

    kinds =
      consume_uploaded_entries(socket, :profiles, fn %{path: path}, entry ->
        {:ok, Profiles.put_upload(deploy, entry.client_name, path)}
      end)

    socket =
      case kinds do
        [] -> put_flash(socket, :error, "No profile file uploaded")
        list -> put_flash(socket, :info, "Uploaded #{Enum.join(list, ", ")} profile")
      end

    {:noreply, reload(socket)}
  end

  def handle_event("backup_now", _params, socket) do
    socket =
      case Backups.create(socket.assigns.deploy, "manual") do
        {:ok, :nothing_to_backup} -> put_flash(socket, :error, "No profile data to back up yet")
        {:ok, _} -> put_flash(socket, :info, "Backup created")
        {:error, _} -> put_flash(socket, :error, "Backup failed")
      end

    {:noreply, reload(socket)}
  end

  def handle_event("delete_backup", %{"id" => id}, socket) do
    backup = Enum.find(socket.assigns.backups, &(&1.id == id))

    if backup do
      _ = File.rm(backup.path)
      Fueltruck.Repo.delete(backup)
    end

    {:noreply, reload(socket)}
  end

  ## Downloads + lifecycle

  def handle_event("download_mods", _params, socket) do
    mods = socket.assigns.deploy_mods
    ids = Enum.map(mods, & &1.mod.workshop_id)
    names = Map.new(mods, fn dm -> {dm.mod.workshop_id, dm.mod.name} end)

    if ids == [] do
      {:noreply, put_flash(socket, :error, "No mods to download")}
    else
      Downloads.update_mods(ids, names: names)
      {:noreply, put_flash(socket, :info, "Queued download of #{length(ids)} mods")}
    end
  end

  def handle_event("download_server", _params, socket) do
    Downloads.update_server()
    {:noreply, put_flash(socket, :info, "Queued server download/update")}
  end

  def handle_event("start", _params, socket) do
    case Arma.start_deploy(socket.assigns.deploy) do
      :ok -> {:noreply, socket |> put_flash(:info, "Starting…") |> push_navigate(to: ~p"/")}
      {:error, r} -> {:noreply, put_flash(socket, :error, "Start failed: #{inspect(r)}")}
    end
  end

  def handle_event("delete", _params, socket) do
    deploy = socket.assigns.deploy

    if deploy.is_active do
      {:noreply, put_flash(socket, :error, "Stop the deploy before deleting it")}
    else
      {:ok, _} = Deploys.delete_deploy(deploy)

      {:noreply,
       socket
       |> put_flash(:info, "Deleted #{deploy.name}")
       |> push_navigate(to: ~p"/deploys")}
    end
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={@active}>
      <div class="space-y-5">
        <.deploy_header deploy={@deploy} count={length(@deploy_mods)} />
        <.tab_bar tabs={@tabs} active={@tab} />

        <div class="grid gap-5 lg:grid-cols-3">
          <div class="lg:col-span-2">
            <%= case @tab do %>
              <% "settings" -> %>
                <.settings_tab form={@form} deploy={@deploy} />
              <% "config" -> %>
                <.config_tab form={@form} deploy={@deploy} uploads={@uploads} />
              <% "mods" -> %>
                <.mods_tab deploy_mods={@deploy_mods} uploads={@uploads} />
              <% "profiles" -> %>
                <.profiles_tab deploy={@deploy} backups={@backups} uploads={@uploads} />
            <% end %>
          </div>

          <div class="space-y-4">
            <.command_sidebar preview={@preview} />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  ## Header

  attr :deploy, :map, required: true
  attr :count, :integer, required: true

  defp deploy_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-3">
      <div class="flex items-center gap-3">
        <.link navigate={~p"/deploys"} class="text-base-content/50 hover:text-base-content">
          <.icon name="hero-arrow-left" class="size-5" />
        </.link>
        <div>
          <h1 class="text-xl font-bold">{@deploy.name}</h1>
          <p class="text-xs text-base-content/50">
            {@deploy.headless_client_count} HC · port {@deploy.port} · {@count} mods
          </p>
        </div>
        <span
          :if={@deploy.is_active}
          class="rounded-full bg-success/15 px-2 py-0.5 text-[10px] font-semibold text-success"
        >
          ACTIVE
        </span>
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <button phx-click="download_server" class="ft-btn-ghost">
          <.icon name="hero-server" class="size-4" /> Update server
        </button>
        <button phx-click="download_mods" class="ft-btn-ghost">
          <.icon name="hero-cloud-arrow-down" class="size-4" /> Download mods
        </button>
        <button
          phx-click="delete"
          data-confirm={"Delete #{@deploy.name}? This cannot be undone."}
          class="ft-btn-ghost"
          title="Delete deploy"
        >
          <.icon name="hero-trash" class="size-4 text-error" />
        </button>
        <button phx-click="start" class="ft-btn-success">
          <.icon name="hero-play" class="size-4" /> Start
        </button>
      </div>
    </div>
    """
  end

  ## Settings tab

  attr :form, :any, required: true
  attr :deploy, :map, required: true

  defp settings_tab(assigns) do
    ~H"""
    <.card title="Deploy settings" icon="hero-cog-6-tooth">
      <.form
        for={@form}
        id="settings-form"
        phx-change="validate"
        phx-submit="save_settings"
        class="space-y-4"
      >
        <.input field={@form[:name]} label="Name" />
        <.input field={@form[:description]} type="textarea" label="Description" />
        <div class="grid grid-cols-2 gap-3">
          <.input field={@form[:port]} type="number" label="Game port" />
          <.input field={@form[:headless_client_count]} type="number" label="Headless clients" />
        </div>
        <.input field={@form[:profile_name]} label="Profile name (-name)" />

        <div class="border-t border-base-200 pt-4">
          <h3 class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content/50">
            server.cfg values
          </h3>
          <div class="grid gap-3 sm:grid-cols-2">
            <.setting_input deploy={@deploy} key="hostname" label="Hostname" />
            <.setting_input deploy={@deploy} key="max_players" label="Max players" type="number" />
            <.setting_input deploy={@deploy} key="password" label="Game password" />
            <.setting_input deploy={@deploy} key="admin_password" label="Admin password" />
            <.setting_input
              deploy={@deploy}
              key="connect_host"
              label="HC connect host"
              placeholder="127.0.0.1"
            />
          </div>
          <p class="mt-2 text-xs text-base-content/50">
            These feed the auto-generated <code>server.cfg</code>. Override the full file on the config tab.
          </p>
        </div>

        <div class="border-t border-base-200 pt-4">
          <.input
            field={@form[:extra_server_args]}
            label="Extra server args"
            placeholder="-autoInit -filePatching"
          />
          <div class="mt-3">
            <.input field={@form[:extra_hc_args]} label="Extra headless client args" />
          </div>
        </div>

        <div class="flex justify-end">
          <button class="ft-btn-primary">Save settings</button>
        </div>
      </.form>
    </.card>

    <.card title="Creator DLC" icon="hero-sparkles" class="mt-5">
      <p class="mb-3 text-xs text-base-content/50">
        Enabled Creator DLC are added to <code>-mod</code> by their folder key. Toggles save
        immediately.
      </p>
      <div class="grid gap-2 sm:grid-cols-2">
        <button
          :for={c <- cdlc_all()}
          type="button"
          phx-click="toggle_cdlc"
          phx-value-key={c.key}
          class={[
            "flex items-center gap-2 rounded-lg border px-3 py-2 text-left text-sm transition-colors",
            c.key in (@deploy.cdlc || []) && "border-primary bg-primary/10",
            c.key not in (@deploy.cdlc || []) && "border-base-300 hover:bg-base-200"
          ]}
        >
          <.icon
            name={
              if(c.key in (@deploy.cdlc || []),
                do: "hero-check-circle-solid",
                else: "hero-plus-circle"
              )
            }
            class={["size-4", c.key in (@deploy.cdlc || []) && "text-primary"]}
          />
          <span class="flex-1">{c.name}</span>
          <code class="text-xs text-base-content/40">{c.key}</code>
        </button>
      </div>
    </.card>
    """
  end

  attr :deploy, :map, required: true
  attr :key, :string, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :placeholder, :string, default: nil

  defp setting_input(assigns) do
    ~H"""
    <label class="block">
      <span class="mb-1 block text-xs font-medium text-base-content/70">{@label}</span>
      <input
        type={@type}
        name={"settings[#{@key}]"}
        value={Map.get(@deploy.settings || %{}, @key)}
        placeholder={@placeholder}
        class="w-full rounded-lg border border-base-300 bg-base-100 px-2.5 py-1.5 text-sm"
      />
    </label>
    """
  end

  ## Config tab

  attr :form, :any, required: true
  attr :deploy, :map, required: true
  attr :uploads, :map, required: true

  defp config_tab(assigns) do
    ~H"""
    <div class="space-y-5">
      <.form
        for={@form}
        id="config-form"
        phx-change="validate"
        phx-submit="save_config"
        class="space-y-5"
      >
        <.card title="server.cfg" icon="hero-document-text">
          <:actions>
            <button
              type="button"
              phx-click="generate_config"
              phx-value-which="server"
              class="ft-btn-xs"
            >
              Generate from settings
            </button>
            <button type="button" phx-click="reset_config" phx-value-which="server" class="ft-btn-xs">
              Reset to auto
            </button>
          </:actions>
          <p class="mb-2 text-xs text-base-content/50">
            {if blank?(@deploy.server_cfg),
              do: "Empty → auto-generated from settings at launch. Edit below to override.",
              else: "Custom override in use. Its values are read into the settings tab."}
          </p>
          <textarea
            name="deploy[server_cfg]"
            rows="12"
            spellcheck="false"
            placeholder={ServerConfig.generate_server_cfg(@deploy)}
            class="ft-code w-full"
          >{@deploy.server_cfg}</textarea>
        </.card>

        <.card title="basic.cfg" icon="hero-document-text">
          <:actions>
            <button
              type="button"
              phx-click="generate_config"
              phx-value-which="basic"
              class="ft-btn-xs"
            >
              Generate default
            </button>
            <button type="button" phx-click="reset_config" phx-value-which="basic" class="ft-btn-xs">
              Reset to auto
            </button>
          </:actions>
          <textarea
            name="deploy[basic_cfg]"
            rows="10"
            spellcheck="false"
            placeholder={ServerConfig.basic_cfg(%{@deploy | basic_cfg: nil})}
            class="ft-code w-full"
          >{@deploy.basic_cfg}</textarea>
        </.card>

        <div class="flex justify-end">
          <button class="ft-btn-primary">Save config</button>
        </div>
      </.form>

      <.card title="Upload config files" icon="hero-arrow-up-tray">
        <p class="mb-3 text-xs text-base-content/50">
          Upload an existing <code>server.cfg</code>; its hostname, passwords, max players and
          other known values are read into the settings tab.
        </p>
        <div class="grid gap-4 md:grid-cols-2">
          <form
            phx-submit="upload_server_cfg"
            phx-change="validate_upload"
            id="upload-server-cfg-form"
            class="space-y-2"
          >
            <.upload_area
              upload={@uploads.server_cfg}
              label="Upload server.cfg"
              hint="Values read into settings"
            />
            <button class="ft-btn-ghost w-full justify-center">Upload server.cfg</button>
          </form>
          <form
            phx-submit="upload_basic_cfg"
            phx-change="validate_upload"
            id="upload-basic-cfg-form"
            class="space-y-2"
          >
            <.upload_area upload={@uploads.basic_cfg} label="Upload basic.cfg" />
            <button class="ft-btn-ghost w-full justify-center">Upload basic.cfg</button>
          </form>
        </div>
      </.card>
    </div>
    """
  end

  ## Mods tab

  attr :deploy_mods, :list, required: true
  attr :uploads, :map, required: true

  defp mods_tab(assigns) do
    ~H"""
    <div class="space-y-5">
      <.card title="Mods" icon="hero-puzzle-piece">
        <:actions>
          <form phx-submit="add_mod" id="add-mod-form" class="flex items-center gap-2">
            <input
              name="workshop_id"
              placeholder="Workshop id or URL"
              class="w-52 rounded-lg border border-base-300 bg-base-100 px-2.5 py-1 text-sm"
            />
            <button class="ft-btn-primary-sm">Add</button>
          </form>
        </:actions>

        <div :if={@deploy_mods == []} class="py-6 text-center text-sm text-base-content/50">
          No mods yet. Add by workshop id or import a launcher preset below.
        </div>

        <ul class="divide-y divide-base-200">
          <li
            :for={{dm, idx} <- Enum.with_index(@deploy_mods)}
            class={["flex items-center gap-3 py-2.5", !dm.enabled && "opacity-50"]}
          >
            <div class="flex flex-col">
              <button
                phx-click="move"
                phx-value-id={dm.id}
                phx-value-dir="up"
                disabled={idx == 0}
                class="ft-chevron"
              >
                <.icon name="hero-chevron-up" class="size-3.5" />
              </button>
              <button
                phx-click="move"
                phx-value-id={dm.id}
                phx-value-dir="down"
                disabled={idx == length(@deploy_mods) - 1}
                class="ft-chevron"
              >
                <.icon name="hero-chevron-down" class="size-3.5" />
              </button>
            </div>

            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2">
                <span class="truncate text-sm font-medium">{dm.mod.name}</span>
                <span :if={dm.mod.update_available} class="ft-tag ft-tag-warning">UPDATE</span>
                <span :if={mod_installed?(dm.mod)} class="ft-tag ft-tag-success">INSTALLED</span>
              </div>
              <div class="text-xs text-base-content/40">
                id {dm.mod.workshop_id} · {humanize_bytes(dm.mod.size_bytes)}
              </div>
            </div>

            <button
              phx-click="update_mod"
              phx-value-id={dm.id}
              class={["ft-toggle", dm.mod.update_available && "ft-toggle-warning"]}
              title="Download / update just this mod via steamree"
            >
              <.icon name="hero-arrow-down-tray" class="size-3.5" />
            </button>
            <button
              phx-click="toggle_server_only"
              phx-value-id={dm.id}
              class={["ft-toggle", dm.server_only && "ft-toggle-info"]}
              title="Load only on the server (-serverMod)"
            >
              Server-only
            </button>
            <button
              phx-click="toggle_enabled"
              phx-value-id={dm.id}
              class={["ft-toggle", dm.enabled && "ft-toggle-success"]}
            >
              {if dm.enabled, do: "Enabled", else: "Disabled"}
            </button>
            <button
              phx-click="remove_mod"
              phx-value-id={dm.id}
              data-confirm="Remove this mod from the deploy?"
              class="text-error/70 hover:text-error"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </li>
        </ul>
      </.card>

      <.card title="Launcher preset" icon="hero-arrow-down-on-square">
        <div class="grid gap-4 md:grid-cols-2">
          <form
            phx-submit="import_preset"
            phx-change="validate_upload"
            id="import-preset-form"
            class="space-y-2"
          >
            <.upload_area
              upload={@uploads.preset}
              label="Import preset (.html)"
              hint="Arma Launcher export"
            />
            <button class="ft-btn-ghost w-full justify-center">Import file</button>
          </form>
          <form phx-submit="import_preset_text" id="import-preset-text-form" class="flex flex-col">
            <label class="mb-1 text-xs font-medium text-base-content/70">…or paste preset HTML</label>
            <textarea name="html" rows="5" class="ft-code w-full flex-1" placeholder="<html>…"></textarea>
            <button class="ft-btn-ghost mt-2 w-full justify-center">Import pasted</button>
          </form>
        </div>
      </.card>
    </div>
    """
  end

  ## Profiles tab

  attr :deploy, :map, required: true
  attr :backups, :list, required: true
  attr :uploads, :map, required: true

  defp profiles_tab(assigns) do
    ~H"""
    <div class="space-y-5">
      <.card title="Profile files (var.profiles)" icon="hero-identification">
        <p class="mb-3 text-xs text-base-content/50">
          Arma writes profile <code>{@deploy.profile_name}</code>
          to a <code>{@deploy.profile_name}/</code>
          folder under the server install (keyed by <code>-name</code>). Persistent mission state is the <code>.vars.armaprofile</code>. Files are located wherever Arma puts them.
        </p>

        <div class="grid gap-3 sm:grid-cols-2">
          <.profile_row deploy={@deploy} kind={:main} label=".Arma3Profile" />
          <.profile_row deploy={@deploy} kind={:vars} label=".vars.Arma3Profile" />
        </div>

        <form
          phx-submit="upload_profiles"
          phx-change="validate_upload"
          id="upload-profiles-form"
          class="mt-4 space-y-2"
        >
          <.upload_area
            upload={@uploads.profiles}
            label="Upload existing profile files"
            hint=".Arma3Profile and/or .vars.Arma3Profile"
          />
          <button class="ft-btn-ghost w-full justify-center">Upload</button>
        </form>
      </.card>

      <.card title="Backups" icon="hero-archive-box">
        <:actions>
          <button phx-click="backup_now" class="ft-btn-primary-sm">
            <.icon name="hero-camera" class="size-4" /> Back up now
          </button>
        </:actions>

        <div :if={@backups == []} class="py-4 text-center text-sm text-base-content/50">
          No backups yet. Backups are also taken automatically on stop.
        </div>

        <ul class="divide-y divide-base-200">
          <li :for={b <- @backups} class="flex items-center justify-between py-2.5 text-sm">
            <div>
              <div class="font-medium">{Path.basename(b.path)}</div>
              <div class="text-xs text-base-content/40">
                {humanize_bytes(b.size_bytes)} · {b.reason} · {Calendar.strftime(
                  b.inserted_at,
                  "%Y-%m-%d %H:%M UTC"
                )}
              </div>
            </div>
            <div class="flex items-center gap-2">
              <a href={~p"/deploys/#{@deploy.id}/backups/#{b.id}"} class="ft-btn-xs">Download</a>
              <button
                phx-click="delete_backup"
                phx-value-id={b.id}
                data-confirm="Delete this backup?"
                class="text-error/70 hover:text-error"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </li>
        </ul>
      </.card>
    </div>
    """
  end

  attr :deploy, :map, required: true
  attr :kind, :atom, required: true
  attr :label, :string, required: true

  defp profile_row(assigns) do
    info = Profiles.info(assigns.deploy, assigns.kind)
    assigns = assign(assigns, :info, info)

    ~H"""
    <div class="rounded-lg border border-base-300 p-3">
      <div class="flex items-center justify-between">
        <span class="text-sm font-medium">{@label}</span>
        <span :if={@info} class="ft-tag ft-tag-success">present</span>
        <span :if={!@info} class="ft-tag">missing</span>
      </div>
      <div :if={@info} class="mt-1 text-xs text-base-content/40">
        {humanize_bytes(@info.size)} · {Calendar.strftime(@info.mtime, "%Y-%m-%d %H:%M UTC")}
      </div>
      <a
        :if={@info}
        href={~p"/deploys/#{@deploy.id}/profile/#{Atom.to_string(@kind)}"}
        class="ft-btn-xs mt-2 inline-flex"
      >
        <.icon name="hero-arrow-down-tray" class="size-3.5" /> Download
      </a>
    </div>
    """
  end

  ## Command sidebar

  attr :preview, :map, required: true

  defp command_sidebar(assigns) do
    ~H"""
    <.card title="Command line" icon="hero-command-line" body_class="p-3 space-y-3">
      <div>
        <div class="mb-1 text-xs font-medium uppercase tracking-wide text-base-content/50">
          Server
        </div>
        <.command_view id="preview-server" argv={@preview.server} />
      </div>
      <div :for={{argv, i} <- Enum.with_index(@preview.hcs)}>
        <div class="mb-1 text-xs font-medium uppercase tracking-wide text-base-content/50">
          Headless client {i}
        </div>
        <.command_view id={"preview-hc-#{i}"} argv={argv} />
      </div>
      <p :if={@preview.hcs == []} class="text-xs text-base-content/40">
        No headless clients configured.
      </p>
    </.card>
    """
  end

  ## Helpers

  # When a full server.cfg is provided, read the known values out of it and merge them
  # into settings so the Settings tab reflects the uploaded/edited cfg.
  defp sync_settings_from_cfg(attrs, deploy) do
    case Map.get(attrs, "server_cfg") do
      cfg when is_binary(cfg) and cfg != "" ->
        merged = Map.merge(deploy.settings || %{}, ServerConfig.parse(cfg))
        Map.put(attrs, "settings", merged)

      _ ->
        attrs
    end
  end

  defp save_deploy(socket, attrs, message) do
    case Deploys.update_deploy(socket.assigns.deploy, attrs) do
      {:ok, _deploy} -> {:noreply, socket |> put_flash(:info, message) |> reload()}
      {:error, changeset} -> {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp load(socket, id), do: put_deploy(socket, Deploys.get_deploy!(id))

  defp reload(socket), do: put_deploy(socket, Deploys.get_deploy!(socket.assigns.deploy.id))

  defp put_deploy(socket, deploy) do
    socket
    |> assign(:deploy, deploy)
    |> assign(:deploy_mods, Deploys.deploy_mods(deploy))
    |> assign(:backups, Backups.list_backups(deploy))
    |> assign(:preview, Deploys.command_preview(deploy))
    |> assign(:form, to_form(Deploys.change_deploy(deploy)))
    |> assign(:page_title, deploy.name)
  end

  defp cdlc_all, do: CDLC.all()

  defp find_dm(socket, id), do: Enum.find(socket.assigns.deploy_mods, &(&1.id == id))

  defp mod_installed?(mod), do: mod.store_path && File.dir?(mod.store_path)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp swap_at(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)
    list |> List.replace_at(i, b) |> List.replace_at(j, a)
  end

  defp extract_id(raw) do
    raw = String.trim(raw)

    cond do
      raw == "" -> nil
      Regex.match?(~r/^\d+$/, raw) -> raw
      match = Regex.run(~r/[?&]id=(\d+)/, raw) -> Enum.at(match, 1)
      true -> nil
    end
  end
end
