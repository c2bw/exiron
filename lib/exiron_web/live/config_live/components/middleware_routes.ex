defmodule ExironWeb.ConfigLive.Components.MiddlewareRoutes do
  @moduledoc false

  use ExironWeb, :html

  import ExironWeb.ConfigLive.Components.DetailsSupport

  attr :middlewares, :list, required: true

  def middleware_routes(assigns) do
    ~H"""
    <.section_title title="Middleware" meta="groups" />
    <div id="exiron-middlewares" class="ex-panel ex-config-card-grid">
      <div :if={@middlewares == []} class="flex ex-empty p-4 text-sm">
        No middleware groups configured.
      </div>
      <div
        :for={middleware <- @middlewares}
        id={"exiron-middleware-#{middleware.name}"}
        class="ex-config-item"
      >
        <div class="flex items-center justify-between gap-3">
          <div class="flex min-w-0 items-center gap-2.5">
            <span class="grid size-8 shrink-0 place-items-center rounded-lg bg-amber-500/10 text-amber-700 dark:text-amber-300">
              <.icon name="hero-square-3-stack-3d-micro" class="size-4" />
            </span>
            <p class="truncate text-sm font-bold">{middleware.name}</p>
          </div>
          <span class="ex-item-count">
            {length(middleware.routes)} {plural(length(middleware.routes), "route", "routes")}
          </span>
        </div>
        <div class="mt-3 grid gap-1.5 border-t border-base-300 pt-2.5">
          <div
            :for={route <- middleware.routes}
            class="grid gap-1.5 rounded-md border border-base-300 bg-base-200 px-2 py-1.5 sm:grid-cols-[minmax(7rem,auto)_minmax(0,1fr)] sm:items-center"
          >
            <div class="flex min-w-0 items-center gap-1.5">
              <p class="truncate text-xs font-bold">{route.hook}</p>
              <span
                :if={Map.get(route, :passthrough, false)}
                class="shrink-0 rounded-full bg-amber-500/10 px-1.5 py-0.5 text-[0.65rem] font-medium text-amber-700 dark:bg-amber-400/15 dark:text-amber-300"
              >
                passthrough
              </span>
            </div>
            <div class="flex flex-wrap gap-1.5">
              <span
                :for={message <- route.messages}
                class="rounded border border-base-300 bg-base-100 px-1.5 py-0.5 font-mono text-[11px]"
              >
                {message}
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
