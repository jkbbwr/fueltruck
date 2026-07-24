defmodule FueltruckWeb.DashboardLive do
  @moduledoc "Control room: lifecycle control, live logs, and resource metrics."
  use FueltruckWeb, :live_view

  alias Fueltruck.{Arma, Deploys, Logs}
  alias Fueltruck.Downloads.Queue, as: Downloads
  alias Fueltruck.Logs.History
  alias Fueltruck.Metrics.Sampler, as: Metrics

  @history_len 60

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Arma.subscribe_procs()
      Metrics.subscribe()
      Downloads.subscribe()
    end

    socket =
      socket
      |> assign(:active, :dashboard)
      |> assign(:page_title, "Dashboard")
      |> assign(:start_error, nil)
      |> assign(:active_deploy, nil)
      |> assign(:active_hcs, [])
      |> assign(:status, Arma.status())
      |> remember()
      |> assign(:deploys, Deploys.list_deploys())
      |> assign(:metrics, %{procs: %{}, system: %{}})
      |> assign(:history, %{})
      |> assign(:download, Downloads.get())
      |> assign(:subscribed, MapSet.new())
      |> sync_log_subs()

    {:ok, socket}
  end

  ## PubSub

  @impl true
  def handle_info({:proc_status, _source, _status}, socket) do
    {:noreply, socket |> assign(:status, Arma.status()) |> remember() |> sync_log_subs()}
  end

  def handle_info({:metrics, payload}, socket) do
    procs = Map.new(payload.procs, fn p -> {p.source, p} end)
    history = put_history(socket.assigns.history, payload.procs)
    {:noreply, assign(socket, metrics: %{procs: procs, system: payload.system}, history: history)}
  end

  def handle_info({:logs, source, batch}, socket) do
    {:noreply,
     push_event(socket, "log_batch", %{source: Logs.source_key(source), lines: to_pairs(batch)})}
  end

  def handle_info({:downloads, snap}, socket) do
    {:noreply, assign(socket, :download, snap)}
  end

  def handle_info({:download_done, info}, socket) do
    {level, msg} = Downloads.done_message(info)
    {:noreply, put_flash(socket, level, msg)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Events

  @impl true
  def handle_event("start", %{"id" => id}, socket) do
    deploy = Deploys.get_deploy!(id)

    case safe_start_deploy(deploy) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Starting #{deploy.name}…") |> refresh()}

      {:error, reason} ->
        {:noreply, assign(socket, :start_error, Arma.format_error(reason))}
    end
  end

  def handle_event("dismiss_error", _p, socket), do: {:noreply, assign(socket, :start_error, nil)}

  def handle_event("clear_active", _p, socket) do
    {:noreply, socket |> assign(:active_deploy, nil) |> assign(:active_hcs, [])}
  end

  def handle_event("stop", _params, socket) do
    Arma.stop_deploy()
    # Stay on the current page — just update it in place.
    {:noreply, socket |> put_flash(:info, "Stopping deploy…") |> refresh()}
  end

  def handle_event("restart_deploy", _params, socket) do
    Arma.restart_deploy()
    {:noreply, socket |> put_flash(:info, "Restarting deploy…") |> refresh()}
  end

  def handle_event("restart_server", _params, socket) do
    Arma.restart_server()
    {:noreply, socket |> put_flash(:info, "Restarting server…") |> refresh()}
  end

  def handle_event("restart_hc", %{"index" => index}, socket) do
    Arma.restart_hc(String.to_integer(index))
    {:noreply, refresh(socket)}
  end

  def handle_event("log_snapshot", %{"source" => key}, socket) do
    lines = key |> Logs.source_from_key() |> Logs.recent(2_000) |> to_pairs()
    {:reply, %{lines: lines}, socket}
  end

  def handle_event("log_history", %{"source" => key, "before_seq" => before}, socket) do
    source = Logs.source_from_key(key)

    lines =
      case run_dir(socket.assigns.status) do
        nil -> []
        dir -> History.page_before(History.source_dir(dir, source), before, 500) |> to_pairs()
      end

    {:reply, %{lines: lines}, socket}
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={@active}>
      <.error_modal :if={@start_error} title="Couldn't start deploy" message={@start_error} />
      <div class="space-y-6">
        <.control_bar status={@status} deploys={@deploys} active_deploy={@active_deploy} />
        <.download_banner :if={@download.status == :running} download={@download} />
        <.system_strip system={@metrics.system} />

        <%= cond do %>
          <% @status.phase != :idle -> %>
            <.process_grid status={@status} metrics={@metrics} history={@history} />
          <% @active_deploy != nil -> %>
            <.stopped_banner deploy={@active_deploy} />
          <% true -> %>
            <.idle_panel deploys={@deploys} />
        <% end %>

        <%!-- Rendered OUTSIDE the cond, at a fixed DOM slot, so the log panels keep
              the same ancestry across the running→stopped flip. Their captured lines
              (phx-update="ignore") stay on screen — that's the whole point of Stop. --%>
        <.logs_section :if={@active_deploy != nil} hcs={@active_hcs} />
      </div>
    </Layouts.app>
    """
  end

  ## Components

  attr :status, :map, required: true
  attr :deploys, :list, required: true
  attr :active_deploy, :map, default: nil

  defp control_bar(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-base-300 bg-base-100 p-4">
      <div class="flex items-center gap-3">
        <div>
          <div class="text-xs uppercase tracking-wide text-base-content/50">Active deploy</div>
          <div class="text-lg font-bold">
            {(@active_deploy && @active_deploy.name) || "None running"}
          </div>
        </div>
        <.status_badge state={phase_state(@status.phase)} ready={@status.phase == :running} />
      </div>

      <div class="flex items-center gap-2">
        <%= cond do %>
          <% @status.phase != :idle -> %>
            <button phx-click="restart_deploy" class="ft-btn-ghost">
              <.icon name="hero-arrow-path" class="size-4" /> Restart all
            </button>
            <button phx-click="stop" data-confirm="Stop the active deploy?" class="ft-btn-error">
              <.icon name="hero-stop" class="size-4" /> Stop
            </button>
          <% @active_deploy != nil -> %>
            <button phx-click="start" phx-value-id={@active_deploy.id} class="ft-btn-success">
              <.icon name="hero-play" class="size-4" /> Start
            </button>
            <button phx-click="clear_active" class="ft-btn-ghost">Pick another</button>
          <% true -> %>
            <form phx-submit="start" id="dashboard-start-form" class="flex items-center gap-2">
              <select
                name="id"
                class="rounded-lg border border-base-300 bg-base-100 px-3 py-1.5 text-sm"
                required
              >
                <option value="" disabled selected>Select a deploy…</option>
                <option :for={d <- @deploys} value={d.id}>{d.name}</option>
              </select>
              <button class="ft-btn-success">
                <.icon name="hero-play" class="size-4" /> Start
              </button>
            </form>
        <% end %>
      </div>
    </div>
    """
  end

  attr :deploy, :map, required: true

  defp stopped_banner(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-3 rounded-xl border border-base-300 bg-base-200/40 px-4 py-2.5 text-sm">
      <.icon name="hero-stop-circle" class="size-5 text-base-content/50" />
      <span class="font-medium">{@deploy.name} is stopped</span>
      <span class="text-base-content/50">— logs below are from the last run</span>
      <div class="ml-auto flex items-center gap-2">
        <button phx-click="start" phx-value-id={@deploy.id} class="ft-btn-success">
          <.icon name="hero-play" class="size-4" /> Start again
        </button>
        <button phx-click="clear_active" class="ft-btn-ghost">Pick another</button>
      </div>
    </div>
    """
  end

  attr :download, :map, required: true

  defp download_banner(assigns) do
    ~H"""
    <div class="flex items-center gap-3 rounded-xl border border-info/30 bg-info/10 px-4 py-2.5 text-sm">
      <.icon name="hero-cloud-arrow-down" class="size-5 text-info motion-safe:animate-bounce" />
      <span class="font-medium">Download in progress</span>
      <span class="text-base-content/60">{@download.label}</span>
      <span :if={@download.pct} class="text-base-content/60">· {@download.done}/{@download.total} ({@download.pct}%)</span>
      <.link navigate={~p"/downloads"} class="ml-auto text-info hover:underline">View →</.link>
    </div>
    """
  end

  attr :system, :map, required: true

  defp system_strip(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
      <.stat_tile label="System CPU" icon="hero-cpu-chip" value={fmt_pct(@system[:cpu_pct])} />
      <.stat_tile
        label="System RAM"
        icon="hero-server"
        value={humanize_bytes(@system[:mem_used])}
        sub={"of #{humanize_bytes(@system[:mem_total])}"}
      />
      <.stat_tile
        label="Disk used"
        icon="hero-circle-stack"
        value={humanize_bytes(@system[:disk_used])}
        sub={"of #{humanize_bytes(@system[:disk_total])}"}
      />
      <.stat_tile
        label="Disk free"
        icon="hero-inbox-stack"
        value={humanize_bytes(@system[:disk_free])}
      />
    </div>
    """
  end

  attr :deploys, :list, required: true

  defp idle_panel(assigns) do
    ~H"""
    <div class="rounded-xl border border-dashed border-base-300 bg-base-100 p-10 text-center">
      <div class="mx-auto grid size-14 place-items-center rounded-2xl bg-base-200">
        <.icon name="hero-rocket-launch" class="size-7 text-base-content/40" />
      </div>
      <h2 class="mt-4 text-lg font-bold">No deploy is running</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Pick a deploy above to launch the server and its headless clients.
      </p>

      <div :if={@deploys != []} class="mx-auto mt-6 grid max-w-2xl gap-2">
        <div
          :for={d <- @deploys}
          class="flex items-center justify-between rounded-lg border border-base-300 bg-base-200/40 px-4 py-2.5"
        >
          <div class="text-left">
            <div class="text-sm font-semibold">{d.name}</div>
            <div class="text-xs text-base-content/50">
              {d.headless_client_count} HC · port {d.port}
            </div>
          </div>
          <div class="flex items-center gap-2">
            <.link navigate={~p"/deploys/#{d.id}"} class="ft-btn-xs">Manage</.link>
            <button phx-click="start" phx-value-id={d.id} class="ft-btn-primary-sm">
              <.icon name="hero-play" class="size-3.5" /> Start
            </button>
          </div>
        </div>
      </div>

      <.link navigate={~p"/deploys/new"} class="ft-btn-primary mt-6">
        <.icon name="hero-plus" class="size-4" /> New deploy
      </.link>
    </div>
    """
  end

  attr :status, :map, required: true
  attr :metrics, :map, required: true
  attr :history, :map, required: true

  defp process_grid(assigns) do
    ~H"""
    <div class="grid gap-3 lg:grid-cols-2 xl:grid-cols-3">
      <.process_card
        proc={@status.server}
        metric={@metrics.procs[:server]}
        history={@history[:server]}
        kind={:server}
      />
      <.process_card
        :for={hc <- @status.hcs}
        proc={hc}
        metric={@metrics.procs[hc.source]}
        history={@history[hc.source]}
        kind={:hc}
      />
    </div>
    """
  end

  attr :proc, :map, required: true
  attr :metric, :map, default: nil
  attr :history, :map, default: nil
  attr :kind, :atom, required: true

  defp process_card(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100 p-4">
      <div class="flex items-start justify-between">
        <div>
          <div class="flex items-center gap-2">
            <.icon
              name={if @kind == :server, do: "hero-server-stack", else: "hero-cpu-chip"}
              class="size-4 text-base-content/50"
            />
            <span class="font-semibold">{@proc.label}</span>
          </div>
          <div class="mt-0.5 text-xs text-base-content/50">
            {if @proc[:os_pid], do: "pid #{@proc.os_pid}", else: "—"}
            <span :if={@proc[:attempts] && @proc.attempts > 0} class="text-warning">
              · restart #{@proc.attempts}
            </span>
          </div>
        </div>
        <.status_badge state={@proc.state} ready={@proc[:ready] || false} />
      </div>

      <div class="mt-3 grid grid-cols-2 gap-3">
        <div>
          <div class="text-[10px] uppercase tracking-wide text-base-content/40">CPU</div>
          <div class="text-sm font-bold tabular-nums">{fmt_pct(@metric && @metric.cpu_pct)}</div>
          <.sparkline
            :if={@history}
            values={@history.cpu}
            class="mt-1 h-6 w-full text-primary"
          />
        </div>
        <div>
          <div class="text-[10px] uppercase tracking-wide text-base-content/40">Memory</div>
          <div class="text-sm font-bold tabular-nums">
            {humanize_bytes(@metric && @metric.mem_bytes)}
          </div>
          <.sparkline
            :if={@history}
            values={@history.mem}
            class="mt-1 h-6 w-full text-accent"
          />
        </div>
      </div>

      <div class="mt-3 flex items-center gap-2">
        <%= if @kind == :server do %>
          <button phx-click="restart_server" class="ft-btn-xs">
            <.icon name="hero-arrow-path" class="size-3.5" /> Restart
          </button>
        <% else %>
          <button phx-click="restart_hc" phx-value-index={hc_index(@proc.source)} class="ft-btn-xs">
            <.icon name="hero-arrow-path" class="size-3.5" /> Restart
          </button>
        <% end %>
      </div>

      <details :if={@proc[:argv]} class="group mt-3">
        <summary class="cursor-pointer text-xs font-medium text-base-content/50 hover:text-base-content">
          Command line
        </summary>
        <div class="mt-2">
          <.command_view id={"cmd-#{Logs.source_key(@proc.source)}"} argv={@proc.argv} />
        </div>
      </details>
    </div>
    """
  end

  attr :hcs, :list, default: [], doc: "list of {:hc, n} sources"

  defp logs_section(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex items-center justify-between">
        <h2 class="flex items-center gap-2 text-sm font-bold uppercase tracking-wide text-base-content/60">
          <.icon name="hero-command-line" class="size-4" /> Live logs
        </h2>
        <span class="text-xs text-base-content/40">
          Auto-scrolls at the bottom · scroll up to load history
        </span>
      </div>

      <.log_panel source="server" label="Server" height="h-96" />

      <div :if={@hcs != []} class="grid gap-3 lg:grid-cols-2">
        <.log_panel
          :for={source <- @hcs}
          source={Logs.source_key(source)}
          label={Logs.source_label(source)}
          height="h-72"
        />
      </div>
    </div>
    """
  end

  ## Helpers

  defp refresh(socket) do
    socket
    |> assign(:status, Arma.status())
    |> remember()
    |> assign(:deploys, Deploys.list_deploys())
    |> sync_log_subs()
  end

  # Remember the deploy (and its live HC sources) so a Stop keeps them in view
  # (stopped) instead of dumping to the picker. The status.deploy map is lean
  # (id/name/slug) so we capture the HC source list straight from the running
  # status rather than reconstructing it from the deploy schema.
  defp remember(socket) do
    case socket.assigns.status.deploy do
      nil ->
        socket

      deploy ->
        socket
        |> assign(:active_deploy, deploy)
        |> assign(:active_hcs, Enum.map(socket.assigns.status.hcs, & &1.source))
    end
  end

  defp safe_start_deploy(deploy) do
    Arma.start_deploy(deploy)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Subscribe/unsubscribe to log topics so we only forward for active sources.
  defp sync_log_subs(socket) do
    wanted = MapSet.new(active_sources(socket.assigns.status))
    current = socket.assigns.subscribed

    for source <- MapSet.difference(wanted, current), do: Logs.subscribe(source)
    for source <- MapSet.difference(current, wanted), do: Logs.unsubscribe(source)

    assign(socket, :subscribed, wanted)
  end

  defp active_sources(%{phase: :idle}), do: []

  defp active_sources(status) do
    [:server | Enum.map(status.hcs, & &1.source)]
  end

  defp run_dir(%{run_dir: dir}), do: dir
  defp run_dir(_), do: nil

  defp phase_state(:idle), do: :idle
  defp phase_state(:stopping), do: :restarting
  defp phase_state(_), do: :running

  defp hc_index({:hc, n}), do: n

  defp to_pairs(batch), do: Enum.map(batch, fn {seq, line} -> [seq, line] end)

  defp put_history(history, procs) do
    Enum.reduce(procs, history, fn p, acc ->
      cur = Map.get(acc, p.source, %{cpu: [], mem: []})

      Map.put(acc, p.source, %{
        cpu: append_capped(cur.cpu, p.cpu_pct || 0),
        mem: append_capped(cur.mem, p.mem_bytes || 0)
      })
    end)
  end

  defp append_capped(list, value) do
    (list ++ [value]) |> Enum.take(-@history_len)
  end
end
