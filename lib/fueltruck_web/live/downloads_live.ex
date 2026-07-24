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
     |> assign(:show_output, false)
     |> assign(:download, Downloads.get())
     |> assign(:mods, Catalog.list_mods())}
  end

  @impl true
  def handle_info({:downloads, snap}, socket), do: {:noreply, assign(socket, :download, snap)}

  def handle_info({:download_done, info}, socket) do
    {level, msg} = Downloads.done_message(info)
    {:noreply, put_flash(socket, level, msg)}
  end

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

  def handle_event("toggle_output", _p, socket) do
    {:noreply, update(socket, :show_output, &(!&1))}
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
            <button phx-click="update_server" class="ft-btn-ghost">
              <.icon name="hero-server" class="size-4" /> Update server
            </button>
            <button phx-click="update_all" class="ft-btn-primary-sm">
              <.icon name="hero-arrow-path" class="size-4" /> Update all mods
            </button>
            <button :if={@download.status == :running} phx-click="cancel" class="ft-btn-error">
              <.icon name="hero-x-circle" class="size-4" /> Cancel
            </button>
          </div>
        </div>

        <.card>
          <div class="flex flex-wrap items-center gap-3">
            <.status_badge state={dl_state(@download.status)} ready={@download.status == :running} />
            <span class="text-sm font-medium">
              {(@download.status == :running && (@download.label || "Working…")) || "Idle"}
            </span>
            <span :if={@download.queue != []} class="text-xs text-base-content/50">
              queued: {Enum.join(@download.queue, ", ")}
            </span>
            <span :if={@download.last_result} class="ml-auto text-xs text-base-content/50">
              last: {format_result(@download.last_result)}
            </span>
          </div>

          <div :if={@download.server || @download.items != []} class="mt-4">
            <.download_progress download={@download} />
          </div>

          <p
            :if={@download.status != :running and @download.server == nil and @download.items == []}
            class="mt-3 text-sm text-base-content/50"
          >
            No active download. Use the buttons above, or download mods from a deploy.
          </p>
        </.card>

        <div :if={@download.log != []} class="rounded-xl border border-base-300 bg-base-100">
          <button
            type="button"
            phx-click="toggle_output"
            class="flex w-full items-center justify-between px-4 py-2 text-sm font-semibold"
          >
            Raw steamree output
            <.icon
              name={if @show_output, do: "hero-chevron-up", else: "hero-chevron-down"}
              class="size-4 text-base-content/50"
            />
          </button>
          <pre
            :if={@show_output}
            id="download-output"
            phx-hook="ScrollBottom"
            class="log-scroll max-h-72 overflow-auto border-t border-base-300 p-3 text-[11px] leading-relaxed text-base-content/80"
          >{Enum.join(@download.log, "\n")}</pre>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp dl_state(:running), do: :running
  defp dl_state(_), do: :idle

  defp format_result(:ok), do: "ok"
  defp format_result({:summary, d}), do: "#{d["downloaded"]} downloaded, #{d["failed"]} failed"
  defp format_result(other), do: inspect(other)
end
