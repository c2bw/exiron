defmodule ExironWeb.ConfigLive.Components.Configurator do
  @moduledoc false

  use ExironWeb, :html

  alias ExironWeb.ConfigLive.State
  alias ExironWeb.ConfigLive.Components.QuickAdd

  attr :activation, :map, required: true

  def activation_status(assigns) do
    {title, detail} =
      case assigns.activation.status do
        :invalid ->
          {"Saved configuration could not be loaded",
           "Restore a revision from history below, or repair the YAML. The running Hub may still use its previous configuration."}

        :active ->
          {"Saved configuration is active", "The Hub loaded this exact saved file successfully."}

        :pending ->
          {"Saved configuration is not active",
           "The Hub is using a different configuration. Activate the saved file to apply it."}

        :failed ->
          {"Configuration activation failed",
           "The saved file is not confirmed active. Resolve the reload problem, then retry activation."}

        :disabled ->
          {"Saved configuration is not active — Hub disabled",
           "The file is saved. Enable the Hub before applying this configuration."}

        :changed ->
          {"Saved file changed",
           "The file changed since this page was loaded. Reload it before saving or activating."}

        :unavailable ->
          {"Activation status unavailable",
           "Could not reach the Hub. Check status before retrying activation."}

        :unverified ->
          {"Configuration activation not verified",
           "The Hub was configured directly or reloaded only in part. Activate the saved file to verify it."}
      end

    assigns = assigns |> assign(:title, title) |> assign(:detail, detail)

    ~H"""
    <section
      id="exiron-config-activation"
      data-state={@activation.status}
      aria-live="polite"
      class={[
        "ex-panel flex min-w-0 flex-col gap-3 border-l-4 p-4 sm:flex-row sm:items-center sm:justify-between",
        @activation.status == :active && "border-l-emerald-500",
        @activation.status != :active && "border-l-amber-500"
      ]}
    >
      <div class="min-w-0">
        <h2 class="flex items-center gap-2 text-sm font-bold">
          <.icon
            name={
              if(@activation.status == :active,
                do: "hero-check-circle-micro",
                else: "hero-exclamation-triangle-micro"
              )
            }
            class="size-4 shrink-0"
          />
          {@title}
        </h2>
        <p class="mt-1 text-xs text-base-content/65">{@detail}</p>
        <p class="mt-1 text-xs text-base-content/50">
          Tables and route tests below describe the saved file.
        </p>
        <p :if={@activation.activated_at} class="mt-1 text-xs text-base-content/50">
          Last full activation:
          <time datetime={DateTime.to_iso8601(@activation.activated_at)}>
            {Calendar.strftime(@activation.activated_at, "%Y-%m-%d %H:%M:%S UTC")}
          </time>
        </p>
      </div>
      <div class="flex shrink-0 flex-wrap gap-2">
        <.link
          :if={@activation.status in [:changed, :invalid]}
          id="exiron-refresh-config"
          href={~p"/config"}
          class="rounded-md border border-base-300 px-3 py-2 text-xs font-bold transition hover:bg-base-200"
        >
          Reload saved file
        </.link>
        <button
          :if={@activation.status in [:pending, :failed, :unverified]}
          id="exiron-activate-config"
          type="button"
          phx-click="activate_saved"
          phx-disable-with="Activating…"
          class="rounded-md bg-primary px-3 py-2 text-xs font-bold text-primary-content transition hover:bg-primary/90 disabled:opacity-60"
        >
          Activate saved configuration
        </button>
        <button
          id="exiron-check-activation"
          type="button"
          phx-click="check_activation"
          phx-disable-with="Checking…"
          class="rounded-md border border-base-300 px-3 py-2 text-xs font-bold transition hover:bg-base-200 disabled:opacity-60"
        >
          Check status
        </button>
      </div>
    </section>
    """
  end

  attr :status, :any, required: true

  def editor_status_badge(assigns) do
    ~H"""
    <span class={State.editor_status_class(@status)}>
      {State.editor_status_text(@status)}
    </span>
    """
  end

  attr :path, :string, required: true
  attr :reason, :any, required: true

  def config_error(assigns) do
    ~H"""
    <section
      id="exiron-config-error"
      class="rounded-md border border-rose-500/30 bg-rose-500/10 p-4"
    >
      <p class="font-semibold text-rose-700 dark:text-rose-300">
        Could not load config.yml
      </p>

      <p class="mt-2 font-mono text-sm text-rose-700/80 dark:text-rose-200/90">{@path}</p>

      <p class="mt-4 text-sm text-rose-700/80 dark:text-rose-200/90">
        {State.error_message(@reason)}
      </p>
    </section>
    """
  end

  attr :editor, :map, required: true

  def configurator(assigns) do
    ~H"""
    <section class="ex-panel overflow-hidden">
      <div class="flex items-center justify-between gap-3 px-3 py-2.5 sm:px-4">
        <div class="flex items-center gap-3">
          <span class="grid size-7 place-items-center rounded-md border border-primary/15 bg-primary/[0.07] text-primary">
            <.icon name="hero-code-bracket-micro" class="size-3.5" />
          </span>
          <div>
            <div class="flex items-center gap-2">
              <h2 class="text-xs font-bold tracking-tight">Source editor</h2>
              <span class="rounded bg-base-200 px-1.5 py-0.5 font-mono text-[8px] font-bold uppercase tracking-wider text-base-content/40">
                YAML
              </span>
            </div>

            <p class="mt-0.5 hidden text-xs text-base-content/50 sm:block">
              Review changes before saving and activating.
            </p>
          </div>
        </div>

        <button
          id="exiron-toggle-config-editor"
          type="button"
          phx-click="toggle_editor"
          class="inline-flex items-center gap-1.5 rounded-md bg-base-content px-3 py-1.5 text-xs font-bold text-base-100 shadow-sm transition hover:-translate-y-px hover:bg-primary hover:text-primary-content phx-click-loading:opacity-60"
        >
          <.icon
            name={if(@editor.open?, do: "hero-eye-slash-micro", else: "hero-pencil-square-micro")}
            class="size-4"
          /> {if(@editor.open?, do: "Hide", else: "Edit")}
        </button>
      </div>

      <div
        :if={@editor.open?}
        class="grid gap-3 border-t border-base-300 p-3 sm:p-4 xl:grid-cols-[minmax(0,1fr)_19rem]"
      >
        <.form for={@editor.form} id="exiron-config-form" phx-change="validate" phx-submit="save">
          <div class="flex items-center justify-between gap-2">
            <label
              for={@editor.form[:source].id}
              class="text-xs font-semibold uppercase text-base-content/55"
            >
              config.yml
            </label>
            <.editor_status_badge status={@editor.status} />
          </div>
          <.input
            field={@editor.form[:source]}
            type="textarea"
            rows="20"
            class="ex-readout mt-2 min-h-[24rem] w-full px-3 py-2 font-mono text-xs leading-relaxed text-base-content transition focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/20"
          />
          <div class="mt-2 flex flex-wrap items-center gap-2">
            <button
              id="exiron-save-config"
              type="submit"
              phx-disable-with="Preparing review…"
              class="inline-flex items-center gap-2 rounded-md bg-primary px-3 py-1.5 text-sm font-semibold text-primary-content transition hover:bg-primary/90"
            >
              <.icon name="hero-eye-micro" class="size-4" /> Review changes
            </button>
          </div>
        </.form>

        <div class="space-y-2">
          <.editor_summary status={@editor.status} />
          <QuickAdd.quick_add forms={@editor.quick_forms} />
        </div>
      </div>
    </section>
    """
  end

  attr :status, :any, required: true

  defp editor_summary(assigns) do
    ~H"""
    <div
      id="exiron-config-editor-summary"
      class="rounded-md border border-base-300 bg-base-200/50 px-3 py-2 text-sm"
    >
      <%= case @status do %>
        <% {:valid, summary} -> %>
          <div class="flex items-center justify-between gap-2">
            <p class="font-semibold text-emerald-700 dark:text-emerald-300">Valid</p>

            <p class="text-xs text-base-content/45">live check</p>
          </div>

          <dl class="mt-2 grid grid-cols-5 gap-1 text-center text-xs">
            <dt class="text-base-content/50">Bots</dt>

            <dt class="text-base-content/50">Chats</dt>

            <dt class="text-base-content/50">Resolved</dt>

            <dt class="text-base-content/50">Mid</dt>

            <dt class="text-base-content/50">Hooks</dt>

            <dd class="font-medium">{summary.telegram_bots}</dd>

            <dd class="font-medium">{summary.telegram_chats}</dd>

            <dd class="font-medium">{summary.routes}</dd>

            <dd class="font-medium">{summary.middlewares}</dd>

            <dd class="font-medium">{summary.hooks}</dd>
          </dl>
        <% {:invalid, reason} -> %>
          <p class="font-semibold text-rose-700 dark:text-rose-300">
            Invalid configuration
          </p>

          <p class="mt-2 text-xs text-rose-700/80 dark:text-rose-200/90">{reason}</p>
      <% end %>
    </div>
    """
  end
end
