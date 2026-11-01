defmodule ExironWeb.HookLive do
  use ExironWeb, :live_view
  alias Exiron.Hub
  alias ExironWeb.MonitorLive.ClientConnection

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    if connected?(socket) do
      Hub.subscribe_status()
      Hub.subscribe_traces()
      Process.send_after(self(), :refresh_hook, 5_000)
    end

    {:ok, socket |> assign(:name, name) |> assign(:page_title, "Hook workspace") |> refresh()}
  end

  @impl true
  def handle_info(:refresh_hook, socket) do
    Process.send_after(self(), :refresh_hook, 5_000)
    {:noreply, refresh(socket)}
  end

  def handle_info(:request_traces_changed, socket), do: {:noreply, refresh(socket)}

  def handle_info({kind, _}, socket) when kind in [:hub_status, :hub_status_delta],
    do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    name = socket.assigns.name
    status = Hub.status()
    hook = Enum.find(status.hooks, &(&1.name == name))

    traces =
      if hook,
        do: Hub.request_traces() |> Enum.filter(&(&1.hook == name)) |> Enum.take(50),
        else: []

    routes = Enum.filter(status.routes, &(&1.to == name))

    failures =
      status.send_failures
      |> Enum.filter(&(&1.hook == name))
      |> Enum.take(20)
      |> Enum.map(&Map.put(&1, :summary, ExironWeb.HookLiveFailure.summary(&1)))

    socket
    |> assign(:hook, hook)
    |> stream(:requests, traces, reset: true, dom_id: &"hook-request-#{&1.id}")
    |> stream(:routes, routes, reset: true, dom_id: &"hook-route-#{&1.id}")
    |> stream(:failures, failures, reset: true, dom_id: &"hook-failure-#{&1.id}")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:overview}>
      <section id="hook-workspace" class="space-y-5">
        <div class="ex-panel flex flex-wrap items-center justify-between gap-4 p-5 sm:p-6">
          <div class="min-w-0">
            <p class="text-[10px] font-bold uppercase tracking-[0.18em] text-primary">
              Hook workspace
            </p>
            <h1 id="hook-title" class="mt-2 break-all font-mono text-2xl font-black">{@name}</h1>
            <p
              :if={@hook}
              id="hook-availability"
              data-connected={to_string(@hook.connected)}
              class="mt-2 text-sm text-base-content/60"
            >
              {if @hook.connected, do: "Available for routed work", else: "Client unavailable"}
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <.link id="hook-monitor" navigate={~p"/monitor?#{[hook: @name]}"} class="ex-action-button"><.icon
              name="hero-signal-micro"
              class="size-4"
            /> Open monitor</.link>
            <.link id="hook-compose" navigate={~p"/compose?#{[hook: @name]}"} class="ex-action-button">Compose message</.link>
            <.link id="hook-configure" navigate={~p"/config"} class="ex-action-button">Configure routes</.link>
          </div>
        </div>
        <div :if={!@hook} id="hook-not-found" class="ex-panel p-6 text-sm text-base-content/60">
          This hook is no longer configured.
          <.link navigate={~p"/"} class="font-bold text-primary">Return to overview</.link>
        </div>
        <%= if @hook do %>
          <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
            <.stat
              id="hook-queued"
              label="Queued"
              value={@hook.health.queued}
              detail="Waiting for delivery to a worker"
            />
            <.stat
              id="hook-pending"
              label="Pending"
              value={@hook.health.pending}
              detail="Accepted requests awaiting completion"
            />
            <.stat
              id="hook-sends"
              label="Sending"
              value={@hook.health.in_flight_sends}
              detail={"Limit #{@hook.health.in_flight_send_limit} operations"}
            />
            <.stat
              id="hook-completed"
              label="Completed"
              value={@hook.health.completed_responses}
              detail="Successful responses since Hub start"
            />
          </div>
          <div class="grid min-w-0 gap-5 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
            <section class="ex-panel min-w-0 p-5">
              <h2 class="text-sm font-black">Worker connection</h2>
              <ClientConnection.summary id="hook-client" client={@hook.client} />
              <p class="mt-4 text-xs text-base-content/50">
                Client contact and queue delivery do not prove handler execution.
              </p>
            </section>
            <section class="ex-panel min-w-0 p-5">
              <h2 class="text-sm font-black">Admission and delivery</h2>
              <dl id="hook-rejections" class="mt-4 grid grid-cols-2 gap-4 text-xs">
                <div>
                  <dt class="text-base-content/50">Offline rejections</dt><dd class="mt-1 font-mono font-bold">
                    {@hook.health.unavailable_rejections}
                  </dd>
                </div>
                <div>
                  <dt class="text-base-content/50">Queue rejections</dt><dd class="mt-1 font-mono font-bold">
                    {@hook.health.overload_rejections}
                  </dd>
                </div>
                <div>
                  <dt class="text-base-content/50">Send capacity rejections</dt><dd class="mt-1 font-mono font-bold">
                    {@hook.health.send_capacity_rejections}
                  </dd>
                </div>
                <div>
                  <dt class="text-base-content/50">Failed sends</dt><dd class="mt-1 font-mono font-bold">
                    {@hook.health.send_failures}
                  </dd>
                </div>
              </dl>
            </section>
          </div>
          <section class="ex-panel overflow-hidden">
            <div class="border-b border-base-300 p-5">
              <h2 class="text-sm font-black">Recent requests</h2><p class="mt-1 text-xs text-base-content/50">
                Latest 50 retained requests. Inspect a request to view its timeline or cancel remaining work.
              </p>
            </div>
            <div
              id="hook-requests"
              phx-update="stream"
              class="max-h-[28rem] overflow-y-auto divide-y divide-base-300"
            >
              <p id="hook-requests-empty" class="hidden p-5 text-sm text-base-content/50 only:block">
                No retained requests for this hook.
              </p>
              <article
                :for={{id, request} <- @streams.requests}
                id={id}
                class="flex min-w-0 flex-wrap items-center justify-between gap-3 px-5 py-3 transition-colors hover:bg-base-200/50"
              >
                <div class="min-w-0">
                  <p class="break-all font-mono text-xs font-semibold">{request.id}</p><p class="mt-1 text-xs text-base-content/50">
                    Chat {request.chat_id} · {request.status} · {request.elapsed_ms} ms
                  </p>
                </div>
                <.link
                  id={id <> "-inspect"}
                  navigate={~p"/monitor?#{[hook: @name, request: request.id, inspect: request.id]}"}
                  class="ex-action-button"
                >Inspect <.icon name="hero-arrow-up-right-micro" class="size-3" /></.link>
              </article>
            </div>
          </section>
          <div class="grid min-w-0 gap-5 lg:grid-cols-2">
            <section class="ex-panel min-w-0 overflow-hidden">
              <h2 class="border-b border-base-300 p-5 text-sm font-black">Configured routes</h2>
              <div
                id="hook-routes"
                phx-update="stream"
                class="max-h-72 overflow-y-auto divide-y divide-base-300"
              >
                <p id="hook-routes-empty" class="hidden p-5 text-sm text-base-content/50 only:block">
                  No routes.
                </p>
                <div :for={{id, route} <- @streams.routes} id={id} class="min-w-0 p-4 text-xs">
                  <p class="break-all font-semibold">{route.chat_alias} · {route.chat_id}</p><p class="mt-1 break-all font-mono text-base-content/60">
                    {Enum.join(route.messages, ", ")}
                  </p>
                </div>
              </div>
            </section>
            <section class="ex-panel min-w-0 overflow-hidden">
              <h2 class="border-b border-base-300 p-5 text-sm font-black">Recent failed sends</h2>
              <div
                id="hook-failures"
                phx-update="stream"
                class="max-h-72 overflow-y-auto divide-y divide-base-300"
              >
                <p id="hook-failures-empty" class="hidden p-5 text-sm text-base-content/50 only:block">
                  No retained send failures.
                </p>
                <div :for={{id, failure} <- @streams.failures} id={id} class="p-4 text-xs">
                  <p class="font-semibold">
                    {failure.operation} · {failure.datatype} · chat {failure.chat_id}
                  </p>
                  <p
                    id={id <> "-summary"}
                    class="mt-2 font-semibold text-amber-700 dark:text-amber-300"
                  >
                    {failure.summary.title}
                  </p>
                  <p id={id <> "-certainty"} class="mt-1 text-base-content/65">
                    {failure.summary.certainty}
                  </p>
                  <p class="mt-1 text-base-content/65">{failure.summary.action}</p>
                  <.link
                    :if={Map.get(failure, :delivery)}
                    id={id <> "-delivery"}
                    navigate={~p"/monitor?#{[hook: @name, delivery: failure.delivery.id]}"}
                    class="ex-action-button mt-3"
                  >Inspect this delivery <.icon name="hero-arrow-up-right-micro" class="size-3" /></.link>
                  <.link
                    :if={!Map.get(failure, :delivery)}
                    id={id <> "-monitor"}
                    navigate={~p"/monitor?#{[hook: @name]}"}
                    class="ex-action-button mt-3"
                  >Open monitor</.link>
                  <time
                    class="mt-3 block text-base-content/50"
                    datetime={DateTime.to_iso8601(failure.at)}
                  >{Calendar.strftime(failure.at, "%Y-%m-%d %H:%M:%S UTC")}</time>
                </div>
              </div>
            </section>
          </div>
        <% end %>
      </section>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :detail, :string, required: true

  defp stat(assigns) do
    ~H"""
    <div id={@id} class="ex-panel min-w-0 p-5" data-value={@value}>
      <p class="text-[10px] font-bold uppercase tracking-wider text-base-content/50">{@label}</p>
      <p class="mt-2 font-mono text-3xl font-black text-primary">{@value}</p>
      <p class="mt-2 text-xs text-base-content/50">{@detail}</p>
    </div>
    """
  end
end
