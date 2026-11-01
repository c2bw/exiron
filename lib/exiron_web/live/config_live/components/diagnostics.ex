defmodule ExironWeb.ConfigLive.Components.Diagnostics do
  @moduledoc false
  use ExironWeb, :html

  attr :id, :string, required: true
  attr :entries, :any, required: true
  attr :count, :integer, required: true
  attr :proposed?, :boolean, default: false

  def diagnostics(assigns) do
    ~H"""
    <section id={@id} class="ex-panel min-w-0 overflow-hidden">
      <div class="flex min-w-0 items-start gap-3 px-4 py-3">
        <span class={[
          "grid size-8 shrink-0 place-items-center rounded-lg",
          @count > 0 && "bg-amber-500/10 text-amber-700 dark:text-amber-300",
          @count == 0 && "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300"
        ]}>
          <.icon
            name={
              if(@count > 0, do: "hero-exclamation-triangle-micro", else: "hero-check-circle-micro")
            }
            class="size-4"
          />
        </span>
        <div class="min-w-0">
          <h2 class="text-sm font-bold">
            {if(@proposed?,
              do: "Proposed configuration diagnostics",
              else: "Saved configuration diagnostics"
            )}
          </h2>
          <p class="mt-1 text-xs text-base-content/60">
            {if(@count == 0,
              do: "No configuration warnings.",
              else: "#{@count} advisory warnings. Review these if the behavior is unexpected."
            )} Warnings do not prevent saving or activation.
          </p>
        </div>
      </div>
      <div
        id={@id <> "-entries"}
        phx-update="stream"
        class="max-h-80 divide-y divide-base-300/60 overflow-auto"
      >
        <article
          :for={{id, warning} <- @entries}
          id={id}
          data-kind={warning.kind}
          class="min-w-0 px-4 py-3"
        >
          <p class="break-words text-xs leading-5 text-base-content/80">{warning.message}</p>
          <div :if={!@proposed?} class="mt-1 flex flex-wrap gap-x-4 gap-y-1">
            <a
              :for={target <- warning.targets}
              href={target.href}
              class="break-all text-xs font-semibold text-primary underline-offset-2 transition hover:underline"
            >
              {target.label} <span aria-hidden="true">↓</span>
            </a>
          </div>
        </article>
      </div>
    </section>
    """
  end
end
