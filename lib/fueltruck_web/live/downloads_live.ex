defmodule FueltruckWeb.DownloadsLive do
  @moduledoc "Steamree download monitor: progress, queue, and controls."
  use FueltruckWeb, :live_view

  alias Fueltruck.Catalog
  alias Fueltruck.Downloads.Queue, as: Downloads

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Downloads.subscribe()

    {:ok,
     socket
     |> assign(:active, :downloads)
     |> assign(:page_title, "Downloads")
     |> assign(:download, Downloads.get())
     |> assign(:mods, Catalog.list_mods())}
  end

  @impl true
  def handle_info({:downloads, snap}, socket), do: {:noreply, assign(socket, :download, snap)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("update_server", _p, socket) do
    Downloads.update_server()
    {:noreply, put_flash(socket, :info, "Queued server update")}
  end

  def handle_event("update_all", _p, socket) do
    ids = Enum.map(socket.assigns.mods, & &1.workshop_id)
    names = Map.new(socket.assigns.mods, fn m -> {m.workshop_id, m.name} end)

    if ids == [] do
      {:noreply, put_flash(socket, :error, "No mods in the catalog yet")}
    else
      Downloads.update_mods(ids, names: names)
      {:noreply, put_flash(socket, :info, "Queued update of #{length(ids)} mods")}
    end
  end

  def handle_event("cancel", _p, socket) do
    Downloads.cancel()
    {:noreply, put_flash(socket, :info, "Cancelling…")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={@active}>
      <div class="space-y-5">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 class="text-xl font-bold">Downloads</h1>
            <p class="text-sm text-base-content/60">steamree server &amp; workshop mod downloads.</p>
          </div>
          <div class="flex items-center gap-2">
            <button
              phx-click="update_server"
              class="inline-flex items-center gap-1.5 rounded-lg border border-base-300 px-3 py-1.5 text-sm hover:bg-base-200"
            >
              <.icon name="hero-server" class="size-4" /> Update server
            </button>
            <button
              phx-click="update_all"
              class="inline-flex items-center gap-1.5 rounded-lg bg-primary px-3 py-1.5 text-sm font-semibold text-primary-content hover:brightness-110"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Update all mods
            </button>
            <button
              :if={@download.status == :running}
              phx-click="cancel"
              class="inline-flex items-center gap-1.5 rounded-lg bg-error px-3 py-1.5 text-sm font-semibold text-error-content hover:brightness-110"
            >
              <.icon name="hero-x-circle" class="size-4" /> Cancel
            </button>
          </div>
        </div>

        <div class="rounded-xl border border-base-300 bg-base-100 p-4">
          <div class="flex items-center gap-3">
            <.status_badge state={dl_state(@download.status)} ready={@download.status == :running} />
            <span class="text-sm font-medium">
              {(@download.job && @download.job.label) || "Idle"}
            </span>
            <span :if={@download.queue != []} class="text-xs text-base-content/50">
              queued: {Enum.join(@download.queue, ", ")}
            </span>
            <span
              :if={@download.last_result}
              class="ml-auto text-xs text-base-content/50"
            >
              last: {inspect(@download.last_result)}
            </span>
          </div>

          <div :if={@download.items != []} class="mt-4 space-y-2">
            <div :for={item <- @download.items} class="text-sm">
              <div class="flex items-center justify-between">
                <span class="truncate font-medium">{item.name}</span>
                <span class="text-xs tabular-nums text-base-content/50">
                  {item.status} {item.progress && "· #{item.progress}%"}
                </span>
              </div>
              <div class="mt-1 h-1.5 overflow-hidden rounded-full bg-base-200">
                <div
                  class="h-full rounded-full bg-primary transition-all"
                  style={"width: #{item.progress || 0}%"}
                >
                </div>
              </div>
            </div>
          </div>
        </div>

        <div :if={@download.log != []} class="rounded-xl border border-base-300 bg-base-100">
          <div class="border-b border-base-300 px-4 py-2 text-sm font-semibold">Output</div>
          <pre class="log-scroll max-h-72 overflow-auto p-3 text-[11px] leading-relaxed text-base-content/80">{Enum.join(@download.log, "\n")}</pre>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp dl_state(:running), do: :running
  defp dl_state(_), do: :idle
end
