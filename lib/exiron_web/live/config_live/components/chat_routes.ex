defmodule ExironWeb.ConfigLive.Components.ChatRoutes do
  @moduledoc false

  use ExironWeb, :html

  import ExironWeb.ConfigLive.Components.DetailsSupport

  attr :routes, :list, required: true

  def chat_routes(assigns) do
    ~H"""
    <.section_title title="Chats" meta="config.yml" />
    <div id="exiron-chat-routes" class="ex-panel ex-config-card-grid">
      <div :if={@routes == []} class="flex ex-empty p-4 text-sm">No chat routes configured.</div>
      <div
        :for={route <- @routes}
        id={"exiron-chat-route-#{route.alias}"}
        class="ex-config-item"
      >
        <div class="flex items-start justify-between gap-3">
          <div class="flex min-w-0 items-center gap-2.5">
            <span class="grid size-8 shrink-0 place-items-center rounded-lg bg-emerald-500/10 text-emerald-700 dark:text-emerald-300">
              <.icon name="hero-chat-bubble-left-right-micro" class="size-4" />
            </span>
            <div class="min-w-0">
              <p class="truncate text-sm font-bold">{route.alias}</p>
              <p class="font-mono text-[11px] text-base-content/65">{route.chat_id}</p>
            </div>
          </div>
          <div class="flex shrink-0 items-center gap-2">
            <.push_badge push={route.push} />
            <span class="ex-item-count">
              {route.hook_count} {plural(route.hook_count, "hook", "hooks")}
            </span>
          </div>
        </div>

        <div class="mt-3 grid gap-3 border-t border-base-300 pt-2.5 sm:grid-cols-2">
          <div class="min-w-0">
            <p class="ex-item-label">Middleware</p>
            <.tag_list items={route.middleware} empty="none" color="sky" />
          </div>
          <div class="min-w-0">
            <div class="flex items-center justify-between gap-2">
              <p class="ex-item-label">Destinations</p>
              <p class="text-[10px] font-medium text-base-content/55">
                {route.message_count} {plural(route.message_count, "prefix", "prefixes")}
              </p>
            </div>
            <.tag_list items={route.hooks} empty="no hooks" color="violet" />
          </div>
        </div>
      </div>
    </div>
    """
  end
end
