defmodule ExironWeb.ConfigLive.Components.Hooks do
  @moduledoc false

  use ExironWeb, :html

  import ExironWeb.ConfigLive.Components.DetailsSupport

  attr :hooks, :list, required: true

  def hooks(assigns) do
    ~H"""
    <.section_title title="Hooks" meta="tokens and reach" />
    <div id="exiron-hooks" class="ex-panel ex-config-card-grid">
      <div :if={@hooks == []} class="flex ex-empty p-4 text-sm">No hooks configured.</div>
      <div
        :for={hook <- @hooks}
        id={"exiron-hook-#{hook.name}"}
        class="ex-config-item"
      >
        <div class="flex items-start justify-between gap-3">
          <div class="flex min-w-0 items-center gap-2.5">
            <span class="grid size-8 shrink-0 place-items-center rounded-lg bg-violet-500/10 text-violet-700 dark:text-violet-300">
              <.icon name="hero-link-micro" class="size-4" />
            </span>
            <div class="min-w-0">
              <p class="truncate text-sm font-bold">{hook.name}</p>
              <p class="font-mono text-[11px] text-base-content/65">{hook.token_fingerprint}</p>
            </div>
          </div>
          <div class="flex shrink-0 gap-1.5">
            <span class="ex-item-count">
              {hook.chat_count} {plural(hook.chat_count, "chat", "chats")}
            </span>
            <span class="ex-item-count">
              {hook.route_count} {plural(hook.route_count, "route", "routes")}
            </span>
          </div>
        </div>

        <div class="mt-3 grid gap-3 border-t border-base-300 pt-2.5 sm:grid-cols-2">
          <div class="min-w-0">
            <p class="ex-item-label">Chats</p>
            <.tag_list items={hook.chat_aliases} empty="unused" />
          </div>
          <div class="min-w-0">
            <div class="flex items-center justify-between gap-2">
              <p class="ex-item-label">Middleware</p>
              <p class="text-[10px] font-medium text-base-content/55">
                {hook.push_count} push · {hook.message_count} prefixes
              </p>
            </div>
            <.tag_list items={hook.middlewares} empty="none" color="sky" />
          </div>
        </div>
      </div>
    </div>
    """
  end
end
