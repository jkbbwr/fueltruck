defmodule FueltruckWeb.DeploysLive do
  @moduledoc "List and create deploys."
  use FueltruckWeb, :live_view

  alias Fueltruck.{Arma, Deploys}
  alias Fueltruck.Deploys.Deploy

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Arma.subscribe_procs()

    {:ok,
     socket
     |> assign(:active, :deploys)
     |> load_deploys()}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    socket =
      case socket.assigns.live_action do
        :new -> assign(socket, :form, to_form(Deploys.change_deploy(%Deploy{})))
        _ -> assign(socket, :form, nil)
      end

    {:noreply, assign(socket, :page_title, page_title(socket.assigns.live_action))}
  end

  @impl true
  def handle_info({:proc_status, _s, _st}, socket), do: {:noreply, load_deploys(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate", %{"deploy" => params}, socket) do
    changeset = %Deploy{} |> Deploys.change_deploy(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"deploy" => params}, socket) do
    case Deploys.create_deploy(params) do
      {:ok, deploy} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deploy created")
         |> push_navigate(to: ~p"/deploys/#{deploy.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("start", %{"id" => id}, socket) do
    deploy = Deploys.get_deploy!(id)

    socket =
      case Arma.start_deploy(deploy) do
        :ok -> socket |> put_flash(:info, "Starting #{deploy.name}…") |> push_navigate(to: ~p"/")
        {:error, reason} -> put_flash(socket, :error, "Start failed: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    deploy = Deploys.get_deploy!(id)

    if deploy.is_active do
      {:noreply, put_flash(socket, :error, "Stop the deploy before deleting it")}
    else
      {:ok, _} = Deploys.delete_deploy(deploy)
      {:noreply, socket |> put_flash(:info, "Deploy deleted") |> load_deploys()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={@active}>
      <div class="space-y-5">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-xl font-bold">Deploys</h1>
            <p class="text-sm text-base-content/60">
              Named configurations of settings, mods and presets.
            </p>
          </div>
          <.link
            navigate={~p"/deploys/new"}
            class="inline-flex items-center gap-1.5 rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-content hover:brightness-110"
          >
            <.icon name="hero-plus" class="size-4" /> New deploy
          </.link>
        </div>

        <div
          :if={@deploys == []}
          class="rounded-xl border border-dashed border-base-300 p-10 text-center text-sm text-base-content/60"
        >
          No deploys yet. Create one to get started.
        </div>

        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          <div
            :for={d <- @deploys}
            class="flex flex-col rounded-xl border border-base-300 bg-base-100 p-4"
          >
            <div class="flex items-start justify-between">
              <.link navigate={~p"/deploys/#{d.id}"} class="font-semibold hover:underline">
                {d.name}
              </.link>
              <span
                :if={d.is_active}
                class="rounded-full bg-success/15 px-2 py-0.5 text-[10px] font-semibold text-success"
              >
                ACTIVE
              </span>
            </div>
            <p :if={d.description} class="mt-1 line-clamp-2 text-xs text-base-content/50">
              {d.description}
            </p>
            <div class="mt-3 flex flex-wrap gap-3 text-xs text-base-content/60">
              <span class="inline-flex items-center gap-1">
                <.icon name="hero-puzzle-piece" class="size-3.5" /> {d.mod_count} mods
              </span>
              <span class="inline-flex items-center gap-1">
                <.icon name="hero-cpu-chip" class="size-3.5" /> {d.headless_client_count} HC
              </span>
              <span class="inline-flex items-center gap-1">
                <.icon name="hero-signal" class="size-3.5" /> :{d.port}
              </span>
            </div>

            <div class="mt-4 flex items-center gap-2">
              <.link
                navigate={~p"/deploys/#{d.id}"}
                class="flex-1 rounded-lg border border-base-300 px-3 py-1.5 text-center text-xs font-medium hover:bg-base-200"
              >
                Manage
              </.link>
              <button
                phx-click="start"
                phx-value-id={d.id}
                class="inline-flex items-center gap-1 rounded-lg bg-success px-3 py-1.5 text-xs font-semibold text-success-content hover:brightness-110"
              >
                <.icon name="hero-play" class="size-3.5" /> Start
              </button>
              <button
                phx-click="delete"
                phx-value-id={d.id}
                data-confirm={"Delete #{d.name}?"}
                class="rounded-lg border border-base-300 px-2 py-1.5 text-error hover:bg-error/10"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </div>
        </div>
      </div>

      <.modal :if={@live_action == :new} form={@form} />
    </Layouts.app>
    """
  end

  attr :form, :any, required: true

  defp modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-40 flex items-center justify-center bg-black/40 p-4">
      <div class="w-full max-w-lg rounded-2xl border border-base-300 bg-base-100 p-6 shadow-xl">
        <div class="mb-4 flex items-center justify-between">
          <h2 class="text-lg font-bold">New deploy</h2>
          <.link navigate={~p"/deploys"} class="text-base-content/50 hover:text-base-content">
            <.icon name="hero-x-mark" class="size-5" />
          </.link>
        </div>

        <.form for={@form} id="deploy-form" phx-change="validate" phx-submit="save" class="space-y-4">
          <.input field={@form[:name]} label="Name" placeholder="e.g. Antistasi Altis" required />
          <.input field={@form[:description]} type="textarea" label="Description" />
          <div class="grid grid-cols-2 gap-3">
            <.input field={@form[:port]} type="number" label="Game port" />
            <.input
              field={@form[:headless_client_count]}
              type="number"
              label="Headless clients"
            />
          </div>
          <div class="flex justify-end gap-2 pt-2">
            <.link navigate={~p"/deploys"} class="rounded-lg border border-base-300 px-4 py-2 text-sm">
              Cancel
            </.link>
            <button class="rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-content hover:brightness-110">
              Create
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp load_deploys(socket), do: assign(socket, :deploys, Deploys.list_deploys_with_counts())

  defp page_title(:new), do: "New deploy"
  defp page_title(_), do: "Deploys"
end
