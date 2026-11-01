defmodule ExironWeb.ConfigLive.Components.ConfigurationDetails do
  @moduledoc false

  use ExironWeb, :html

  alias ExironWeb.ConfigLive.Components.{ChatRoutes, Hooks, MiddlewareRoutes, TelegramBots}
  alias ExironWeb.ConfigLive.Components.RouteTester
  alias ExironWeb.ConfigLive.RouteTesting

  attr :config, :map, required: true
  attr :route_tester_form, Phoenix.HTML.Form, required: true
  attr :route_tester_result, :any, required: true

  def configuration_details(assigns) do
    ~H"""
    <section>
      <nav aria-label="Configuration sections" class="ex-config-index">
        <a href="#exiron-telegram-bots">
          <.icon name="hero-paper-airplane-micro" class="size-3.5" /> <span>Bots</span>
        </a>
        <a href="#exiron-chat-routes">
          <.icon name="hero-chat-bubble-left-right-micro" class="size-3.5" /> <span>Chats</span>
        </a>
        <a href="#exiron-middlewares">
          <.icon name="hero-square-3-stack-3d-micro" class="size-3.5" />
          <span class="hidden sm:inline">Middleware</span><span class="sm:hidden">Mid</span>
        </a>
        <a href="#exiron-hooks">
          <.icon name="hero-link-micro" class="size-3.5" /> <span>Hooks</span>
        </a>
        <a href="#exiron-resolved-routes">
          <.icon name="hero-map-micro" class="size-3.5" />
          <span class="hidden sm:inline">Resolved</span><span class="sm:hidden">Map</span>
        </a>
      </nav>

      <div class="mt-3 grid items-start gap-3 xl:grid-cols-[minmax(34rem,1.2fr)_minmax(26rem,0.8fr)]">
        <div class="space-y-3">
          <TelegramBots.telegram_bots bots={@config.bots} />
          <ChatRoutes.chat_routes routes={@config.routes} />
          <MiddlewareRoutes.middleware_routes middlewares={@config.middlewares} />
          <Hooks.hooks hooks={@config.hooks} />
        </div>

        <div class="xl:sticky xl:top-[5.75rem]">
          <RouteTester.route_tester
            config={@config}
            form={@route_tester_form}
            result={@route_tester_result}
          />
          <.resolved_routes config={@config} route_tester_result={@route_tester_result} />
        </div>
      </div>
    </section>
    """
  end

  attr :config, :map, required: true
  attr :route_tester_result, :any, required: true

  def resolved_routes(assigns) do
    ~H"""
    <div id="exiron-resolved-routes">
      <div class="ex-section-head">
        <h2 class="ex-kicker">Resolved Routes</h2>
        <span class="order-last font-mono text-[10px] font-medium text-base-content/55">
          effective map
        </span>
      </div>

      <div class="ex-panel ex-config-card-grid mt-2">
        <div :if={@config.resolved_routes == []} class="flex ex-empty p-4 text-sm">
          No resolved routes.
        </div>

        <div
          :for={route <- @config.resolved_routes}
          id={"exiron-resolved-route-#{route.id}"}
          class={[
            "ex-config-item grid gap-2.5 md:grid-cols-[minmax(7rem,0.55fr)_minmax(8rem,0.7fr)_minmax(0,1fr)] md:items-center",
            RouteTesting.route_tester_match?(@route_tester_result, route.id) &&
              "border-l-4 border-l-emerald-500 bg-emerald-50 dark:bg-emerald-500/10",
            !RouteTesting.route_tester_match?(@route_tester_result, route.id) &&
              "bg-base-100"
          ]}
        >
          <div class="min-w-0">
            <p class="ex-item-label">Chat</p>
            <p class="truncate text-sm font-bold">{route.chat_alias}</p>
            <p class="font-mono text-xs text-base-content/70">{route.chat_id}</p>
          </div>

          <div class="min-w-0">
            <p class="ex-item-label">Destination</p>
            <div class="mt-0.5 flex min-w-0 items-center gap-2">
              <p class="truncate text-sm font-bold">{route.to}</p>
              <span class={[
                "shrink-0 rounded-full px-1.5 py-0.5 text-[0.65rem] font-medium",
                route.push &&
                  "bg-emerald-500/10 text-emerald-700 dark:bg-emerald-400/15 dark:text-emerald-300",
                !route.push && "bg-base-200 text-base-content/70"
              ]}>
                {if(route.push, do: "push", else: "request")}
              </span>
              <span
                :if={Map.get(route, :passthrough, false)}
                class="shrink-0 rounded-full bg-amber-500/10 px-1.5 py-0.5 text-[0.65rem] font-medium text-amber-700 dark:bg-amber-400/15 dark:text-amber-300"
              >
                passthrough
              </span>
            </div>
          </div>

          <div class="min-w-0">
            <p class="ex-item-label">Prefixes</p>
            <div class="mt-1 flex flex-wrap gap-1">
              <span
                :for={message <- route.messages}
                class="rounded border border-base-300 bg-base-200 px-1.5 py-0.5 font-mono text-[11px]"
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
