defmodule FueltruckWeb.DashboardComponents do
  @moduledoc "Shared function components + formatting helpers for the Fueltruck UI."
  use Phoenix.Component
  import FueltruckWeb.CoreComponents, only: [icon: 1]

  @doc "A titled panel/card with an optional icon and actions slot."
  attr :title, :string, default: nil
  attr :icon, :string, default: nil
  attr :class, :string, default: ""
  attr :body_class, :string, default: "p-4"
  slot :actions
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <section class={["overflow-hidden rounded-xl border border-base-300 bg-base-100", @class]}>
      <div
        :if={@title || @actions != []}
        class="flex items-center justify-between gap-3 border-b border-base-300 px-4 py-3"
      >
        <h2 :if={@title} class="flex items-center gap-2 text-sm font-semibold">
          <.icon :if={@icon} name={@icon} class="size-4 text-base-content/50" />
          {@title}
        </h2>
        <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
      </div>
      <div class={@body_class}>{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc "A button-styled tab bar. `tabs` is a list of `{key, label, icon}`."
  attr :tabs, :list, required: true
  attr :active, :string, required: true
  attr :event, :string, default: "switch_tab"

  def tab_bar(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-1 rounded-xl border border-base-300 bg-base-100 p-1">
      <button
        :for={{key, label, icon} <- @tabs}
        type="button"
        phx-click={@event}
        phx-value-tab={key}
        class={[
          "inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium transition-colors",
          @active == key && "bg-primary text-primary-content shadow-sm",
          @active != key && "text-base-content/70 hover:bg-base-200"
        ]}
      >
        <.icon name={icon} class="size-4" />
        {label}
      </button>
    </div>
    """
  end

  @doc """
  A drag-and-drop upload dropzone for a `Phoenix.LiveView.UploadConfig`. Wrap it in a
  `<form phx-submit=… phx-change="validate_upload">` and add a submit button.
  """
  attr :upload, Phoenix.LiveView.UploadConfig, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil

  def upload_area(assigns) do
    ~H"""
    <div>
      <label
        phx-drop-target={@upload.ref}
        class="flex cursor-pointer flex-col items-center justify-center gap-1 rounded-xl border-2 border-dashed border-base-300 bg-base-200/30 px-4 py-6 text-center transition-colors hover:border-primary/50 hover:bg-base-200/60"
      >
        <.icon name="hero-arrow-up-tray" class="size-6 text-base-content/40" />
        <span class="text-sm font-medium">{@label}</span>
        <span :if={@hint} class="text-xs text-base-content/50">{@hint}</span>
        <.live_file_input upload={@upload} class="sr-only" />
      </label>

      <div :for={entry <- @upload.entries} class="mt-2 rounded-lg border border-base-300 p-2">
        <div class="flex items-center justify-between text-xs">
          <span class="truncate font-medium">{entry.client_name}</span>
          <button
            type="button"
            phx-click="cancel_upload"
            phx-value-ref={entry.ref}
            phx-value-name={@upload.name}
            class="text-error/70 hover:text-error"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <div class="mt-1 h-1 overflow-hidden rounded-full bg-base-200">
          <div
            class="h-full rounded-full bg-primary transition-all"
            style={"width: #{entry.progress}%"}
          />
        </div>
        <p :for={err <- upload_errors(@upload, entry)} class="mt-1 text-xs text-error">
          {upload_error_to_string(err)}
        </p>
      </div>

      <p :for={err <- upload_errors(@upload)} class="mt-1 text-xs text-error">
        {upload_error_to_string(err)}
      </p>
    </div>
    """
  end

  @doc "Human string for an upload error atom."
  def upload_error_to_string(:too_large), do: "File is too large"
  def upload_error_to_string(:too_many_files), do: "Too many files"
  def upload_error_to_string(:not_accepted), do: "Unacceptable file type"
  def upload_error_to_string(other), do: to_string(other)

  @doc "Colored status pill for a process state."
  attr :state, :atom, required: true
  attr :ready, :boolean, default: false

  def status_badge(assigns) do
    {label, classes, dot} = badge_style(assigns.state, assigns.ready)
    assigns = assign(assigns, label: label, classes: classes, dot: dot)

    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-semibold",
      @classes
    ]}>
      <span class={["size-1.5 rounded-full", @dot]} />
      {@label}
    </span>
    """
  end

  defp badge_style(:running, true), do: {"Ready", "bg-success/15 text-success", "bg-success"}

  defp badge_style(:running, _),
    do: {"Starting", "bg-warning/15 text-warning", "bg-warning animate-pulse"}

  defp badge_style(:restarting, _),
    do: {"Restarting", "bg-warning/15 text-warning", "bg-warning animate-pulse"}

  defp badge_style(:failed, _), do: {"Failed", "bg-error/15 text-error", "bg-error"}

  defp badge_style(:stopped, _),
    do: {"Stopped", "bg-base-content/10 text-base-content/60", "bg-base-content/40"}

  defp badge_style(:idle, _),
    do: {"Idle", "bg-base-content/10 text-base-content/60", "bg-base-content/40"}

  defp badge_style(other, _),
    do: {to_string(other), "bg-base-content/10 text-base-content/60", "bg-base-content/40"}

  @doc "Inline SVG sparkline from a list of numbers (server-rendered, ~1s cadence)."
  attr :values, :list, default: []
  attr :max, :float, default: nil
  attr :class, :string, default: "h-8 w-full"
  attr :color, :string, default: "currentColor"

  def sparkline(assigns) do
    values = Enum.map(assigns.values, fn v -> v || 0 end)
    max = assigns.max || Enum.max([1.0 | Enum.map(values, &(&1 * 1.0))])
    assigns = assign(assigns, points: spark_points(values, max))

    ~H"""
    <svg viewBox="0 0 100 30" preserveAspectRatio="none" class={@class}>
      <%= if @points do %>
        <polyline
          points={@points}
          fill="none"
          stroke={@color}
          stroke-width="1.5"
          vector-effect="non-scaling-stroke"
          stroke-linejoin="round"
        />
      <% end %>
    </svg>
    """
  end

  defp spark_points([], _max), do: nil
  defp spark_points([_], _max), do: nil

  defp spark_points(values, max) do
    n = length(values)
    step = 100 / (n - 1)

    values
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {v, i} ->
      x = Float.round(i * step, 2)
      y = Float.round(30 - v / max * 28 - 1, 2)
      "#{x},#{y}"
    end)
  end

  @doc "A compact stat tile."
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, default: nil
  attr :icon, :string, default: nil
  slot :inner_block

  def stat_tile(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100 p-4">
      <div class="flex items-center gap-2 text-xs font-medium uppercase tracking-wide text-base-content/50">
        <.icon :if={@icon} name={@icon} class="size-3.5" />
        {@label}
      </div>
      <div class="mt-1 text-2xl font-bold tabular-nums tracking-tight">{@value}</div>
      <div :if={@sub} class="text-xs text-base-content/50">{@sub}</div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "A streaming log panel wired to the LogStream JS hook."
  attr :source, :string, required: true, doc: "source key, e.g. \"server\" or \"hc-0\""
  attr :label, :string, required: true
  attr :max, :integer, default: 4000
  attr :height, :string, default: "h-80"
  slot :actions

  def log_panel(assigns) do
    ~H"""
    <div class="overflow-hidden rounded-xl border border-base-300 bg-base-100">
      <div class="flex items-center justify-between border-b border-base-300 bg-base-200/50 px-3 py-2">
        <div class="flex items-center gap-2 text-sm font-semibold">
          <.icon name="hero-command-line" class="size-4 text-base-content/50" />
          {@label}
        </div>
        <div class="flex items-center gap-1">{render_slot(@actions)}</div>
      </div>
      <div
        id={"log-#{@source}"}
        phx-hook="LogStream"
        phx-update="ignore"
        data-source={@source}
        data-max={@max}
        class={["log-scroll overflow-y-auto bg-base-100 px-2 py-2 text-base-content/90", @height]}
      >
        <div data-log-list></div>
      </div>
    </div>
    """
  end

  @doc """
  Structured command-line view. Renders the executable + each argument on its own row,
  collapsing long `-mod=`/`-serverMod=` lists into an expandable, scrollable summary so
  a deploy with 100 mods doesn't blow out the layout. Includes a copy-full button.
  """
  attr :id, :string, required: true
  attr :argv, :any, required: true, doc: "{exe, args} tuple"

  def command_view(assigns) do
    {exe, args} = assigns.argv
    assigns = assign(assigns, exe: exe, args: args, full: command_string(exe, args))

    ~H"""
    <div class="overflow-hidden rounded-lg border border-base-300 bg-base-200/60">
      <div class="flex items-center justify-between gap-2 border-b border-base-300 px-2.5 py-1.5">
        <code class="truncate font-mono text-[11px] text-base-content/60" title={@exe}>
          {Path.basename(@exe)}
        </code>
        <button
          id={"#{@id}-copy"}
          type="button"
          phx-hook="Copy"
          data-clipboard={@full}
          class="ft-btn-xs shrink-0"
        >
          <.icon name="hero-clipboard-document" class="size-3.5" /> Copy
        </button>
      </div>
      <div class="max-h-72 space-y-1 overflow-y-auto p-2">
        <%= for {arg, i} <- Enum.with_index(@args) do %>
          <%= case mod_flag(arg) do %>
            <% {flag, paths} -> %>
              <details class="rounded border border-base-300 bg-base-100/60">
                <summary class="flex cursor-pointer items-center gap-2 px-2 py-1 text-[11px] font-medium">
                  <span class="font-mono text-primary">{flag}=</span>
                  <span class="text-base-content/50">{length(paths)} mod(s)</span>
                </summary>
                <div class="max-h-40 overflow-y-auto border-t border-base-300 px-2 py-1">
                  <div
                    :for={p <- paths}
                    class="truncate font-mono text-[11px] text-base-content/70"
                    title={p}
                  >
                    {Path.basename(p)}
                  </div>
                </div>
              </details>
            <% nil -> %>
              <div
                id={"#{@id}-arg-#{i}"}
                class="break-all font-mono text-[11px] text-base-content/70"
              >
                {arg}
              </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # Recognise `-mod=`/`-serverMod=` flags and split their `;`-joined path list.
  defp mod_flag("-mod=" <> value), do: {"-mod", split_paths(value)}
  defp mod_flag("-serverMod=" <> value), do: {"-serverMod", split_paths(value)}
  defp mod_flag(_), do: nil

  defp split_paths(value), do: String.split(value, ";", trim: true)

  defp command_string(exe, args), do: Enum.join([exe | args], " ")

  ## Formatting helpers

  @doc "Human-readable byte size."
  def humanize_bytes(nil), do: "—"
  def humanize_bytes(n) when n < 1024, do: "#{n} B"

  def humanize_bytes(n) do
    units = ["KB", "MB", "GB", "TB", "PB"]
    exp = min(trunc(:math.log(n) / :math.log(1024)), length(units))
    value = n / :math.pow(1024, exp)
    "#{:erlang.float_to_binary(value, decimals: 1)} #{Enum.at(units, exp - 1)}"
  end

  @doc "Format a CPU percentage."
  def fmt_pct(nil), do: "—"
  def fmt_pct(v) when is_number(v), do: "#{:erlang.float_to_binary(v / 1, decimals: 1)}%"

  @doc "Percentage of used over total, clamped 0..100."
  def pct_of(_used, nil), do: 0
  def pct_of(nil, _total), do: 0
  def pct_of(_used, 0), do: 0
  def pct_of(used, total), do: (used / total * 100) |> min(100) |> max(0) |> Float.round(1)
end
