defmodule ExironWeb.ConfigLive.Components.History do
  @moduledoc false
  use ExironWeb, :html

  alias ExironWeb.ConfigLive.Components.Diagnostics

  attr :streams, :any, required: true
  attr :count, :integer, required: true
  attr :error, :string, default: nil
  attr :previous_id, :string, default: nil
  attr :stale?, :boolean, default: false

  def history(assigns) do
    ~H"""
    <section id="exiron-config-history" class="ex-panel min-w-0 overflow-hidden">
      <div class="flex flex-col gap-3 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
        <div class="flex min-w-0 items-center gap-3">
          <span class="grid size-8 shrink-0 place-items-center rounded-lg bg-primary/10 text-primary">
            <.icon name="hero-clock-micro" class="size-4" />
          </span>
          <div class="min-w-0">
            <h2 class="text-sm font-bold">Configuration history</h2>
            <p class="text-xs text-base-content/55">
              {@count} of 20 revisions · restore a previous version if the latest one is wrong
            </p>
          </div>
        </div>
        <button
          :if={@previous_id}
          id="exiron-rollback-previous"
          type="button"
          phx-click="review_rollback"
          phx-value-id={@previous_id}
          disabled={@stale?}
          class="inline-flex w-fit shrink-0 items-center gap-2 rounded-lg border border-amber-500/30 bg-amber-500/5 px-3 py-2 text-xs font-bold transition hover:bg-amber-500/15 disabled:opacity-40"
        >
          <.icon name="hero-arrow-uturn-left-micro" class="size-4" /> Review rollback
        </button>
      </div>
      <p
        :if={@error}
        id="exiron-history-error"
        role="alert"
        class="border-t border-amber-500/20 px-4 py-3 text-xs text-amber-700 dark:text-amber-300"
      >
        {@error}
      </p>
      <details class="border-t border-base-300/70">
        <summary
          id="exiron-history-toggle"
          class="cursor-pointer px-4 py-2.5 text-xs font-semibold text-base-content/65 transition hover:bg-base-200/40"
        >
          Browse saved revisions
        </summary>
        <div id="exiron-config-revisions" phx-update="stream" class="divide-y divide-base-300/60">
          <p
            id="exiron-history-empty"
            class="hidden px-4 py-4 text-xs text-base-content/50 only:block"
          >
            No checkpoints available yet. A previous version must be recorded before it can be restored.
          </p>
          <article
            :for={{id, revision} <- @streams.config_revisions}
            id={id}
            data-current={revision.current?}
            class="flex min-w-0 flex-wrap items-center justify-between gap-3 px-4 py-3"
          >
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2 text-xs">
                <span class="font-mono font-bold">{String.slice(revision.id, 0, 8)}</span>
                <span
                  :if={revision.current?}
                  class="rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-bold text-primary"
                >Current file</span>
                <span
                  :if={!revision.valid?}
                  class="rounded-full bg-rose-500/10 px-2 py-0.5 text-[10px] text-rose-700 dark:text-rose-300"
                >Invalid backup</span>
                <span :if={revision.activated_at} class="text-[10px] text-base-content/50">Activated previously</span>
                <span
                  :if={!revision.activated_at && revision.valid?}
                  class="text-[10px] text-base-content/50"
                >Saved checkpoint</span>
              </div>
              <p class="mt-1 text-[11px] text-base-content/50">
                Saved <.timestamp iso={revision.saved_at} />
              </p>
            </div>
            <button
              :if={revision.valid? && !revision.current?}
              id={id <> "-restore"}
              type="button"
              phx-click="review_rollback"
              phx-value-id={revision.id}
              disabled={@stale?}
              class="rounded-md border border-base-300 px-3 py-1.5 text-xs font-semibold transition hover:border-primary/40 hover:bg-primary/5 disabled:opacity-40"
            >Review restore</button>
          </article>
        </div>
      </details>
    </section>
    """
  end

  attr :pending, :any, required: true
  attr :streams, :any, required: true
  attr :stale?, :boolean, default: false

  def review(assigns) do
    ~H"""
    <section
      :if={@pending}
      id="exiron-config-review"
      data-kind={@pending.kind}
      class="ex-panel min-w-0 overflow-hidden ring-1 ring-primary/20"
    >
      <div class="flex flex-col gap-3 border-b border-base-300/70 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
        <div class="min-w-0">
          <h2 class="text-sm font-bold">
            {if(@pending.kind == :rollback,
              do: "Review rollback",
              else: "Review configuration changes"
            )}
          </h2>
          <p class="mt-1 text-xs text-base-content/55">
            {if(@pending.kind == :rollback,
              do:
                "Restore this revision and activate it. The current file will be checkpointed first.",
              else: "Confirm to save and activate the reviewed configuration."
            )}
          </p>
        </div>
        <div class="flex shrink-0 flex-wrap gap-2">
          <button
            id="exiron-cancel-config-review"
            type="button"
            phx-click="cancel_config_review"
            class="rounded-lg border border-base-300 px-3 py-2 text-xs font-bold transition hover:bg-base-200"
          >Cancel</button>
          <button
            id="exiron-confirm-config"
            type="button"
            phx-click="confirm_config"
            disabled={@stale? || @pending.diff.truncated?}
            phx-disable-with="Saving and activating…"
            class="rounded-lg bg-primary px-3 py-2 text-xs font-bold text-primary-content transition hover:bg-primary/90 disabled:opacity-40"
          >
            {if(@pending.kind == :rollback, do: "Restore and activate", else: "Save and activate")}
          </button>
        </div>
      </div>
      <Diagnostics.diagnostics
        id="exiron-review-diagnostics"
        count={@pending.diagnostic_count}
        entries={@streams.review_diagnostics}
        proposed?={true}
      />
      <div class="space-y-1 border-b border-base-300/70 px-4 py-2 text-[11px] text-base-content/55">
        <p>Normalized configuration diff · credentials hidden · comments and formatting omitted</p>
        <p :if={@pending.diff.note}>{@pending.diff.note}</p>
        <p :if={!@pending.diff.semantic_changed?}>Only comments or formatting changed.</p>
        <p :if={@stale?} class="text-amber-700 dark:text-amber-300">
          The saved file changed. Reload it and review again.
        </p>
        <p :if={@pending.diff.truncated?} class="text-amber-700 dark:text-amber-300">
          This diff is too large to confirm here. Narrow the change and review again.
        </p>
      </div>
      <div
        id="exiron-config-diff"
        phx-update="stream"
        class="max-h-96 overflow-auto bg-base-200/30 py-2 font-mono text-[11px] leading-5"
      >
        <div
          :for={{id, line} <- @streams.config_diff}
          id={id}
          data-kind={line.kind}
          class={[
            "flex min-w-0 gap-2 whitespace-pre-wrap break-all px-4",
            line.kind == :ins && "bg-emerald-500/10 text-emerald-800 dark:text-emerald-200",
            line.kind == :del && "bg-rose-500/10 text-rose-800 dark:text-rose-200",
            line.kind == :eq && "text-base-content/55"
          ]}
        >
          <span aria-hidden="true" class="w-3 shrink-0 select-none">{marker(line.kind)}</span><span class="min-w-0">{line.text}</span>
        </div>
      </div>
    </section>
    """
  end

  defp marker(:ins), do: "+"
  defp marker(:del), do: "−"
  defp marker(_kind), do: " "

  attr :iso, :string, required: true

  defp timestamp(assigns) do
    {:ok, date, _} = DateTime.from_iso8601(assigns.iso)
    assigns = assign(assigns, :label, Calendar.strftime(date, "%Y-%m-%d %H:%M:%S UTC"))

    ~H"""
    <time datetime={@iso}>{@label}</time>
    """
  end
end
