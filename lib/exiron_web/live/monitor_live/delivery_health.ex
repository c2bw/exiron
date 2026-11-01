defmodule ExironWeb.MonitorLive.DeliveryHealth do
  @moduledoc false
  use ExironWeb, :html
  alias ExironWeb.MonitorLive.ClientConnection

  attr :health, :map, required: true
  attr :capacity, :map, default: nil
  attr :send_capacity, :map, default: nil
  attr :streams, :any, required: true

  def delivery_health(assigns) do
    ~H"""
    <section id="exiron-delivery-health" class="ex-panel overflow-hidden">
      <div class="border-b border-base-300/80 px-4 py-3">
        <div class="flex items-center gap-3">
          <span class="grid size-8 place-items-center rounded-lg border border-primary/15 bg-primary/10 text-primary">
            <.icon name="hero-heart-micro" class="size-4" />
          </span>
          <div>
            <h2 class="text-sm font-black tracking-[-0.02em]">Delivery health</h2>
            <p class="text-[11px] text-base-content/50">
              Counters since Hub start or reset. New messages to unavailable clients are rejected.
            </p>
          </div>
        </div>
      </div>
      <div :if={@capacity} id="delivery-buffer-capacity" class="border-b border-base-300/80 px-4 py-3">
        <div class="flex flex-wrap items-center justify-between gap-2 text-xs">
          <span class="font-bold">Shared payload capacity</span>
          <span id="delivery-buffer-usage" class="font-mono">{bytes(@capacity.bytes)} / {bytes(
            @capacity.limit
          )}</span>
        </div>
        <progress
          id="delivery-buffer-progress"
          class="mt-2 h-2 w-full overflow-hidden rounded-full accent-primary"
          value={@capacity.bytes}
          max={@capacity.limit}
          aria-label="Shared buffered payload usage"
        />
        <p id="delivery-buffer-rejections" class="mt-2 text-[11px] text-base-content/55">
          {bytes(@capacity.awaiting_ack_bytes)} awaiting acknowledgement · {@capacity.request_rejections} requests rejected · {@capacity.listener_rejections} listener copies rejected
        </p>
      </div>
      <div
        :if={@send_capacity}
        id="delivery-send-byte-capacity"
        class="border-b border-base-300/80 px-4 py-3"
      >
        <div class="flex flex-wrap items-center justify-between gap-2 text-xs">
          <span class="font-bold">Outgoing send payload</span>
          <span id="delivery-send-byte-usage" class="font-mono">{bytes(@send_capacity.bytes)} / {bytes(
            @send_capacity.limit
          )}</span>
        </div>
        <progress
          id="delivery-send-byte-progress"
          class="mt-2 h-2 w-full overflow-hidden rounded-full accent-primary"
          value={@send_capacity.bytes}
          max={@send_capacity.limit}
          aria-label="Active send payload usage"
        />
        <p id="delivery-send-byte-rejections" class="mt-2 text-[11px] text-base-content/55">
          Includes coordinator waits · {@send_capacity.rejections} admissions rejected with byte capacity exhausted
        </p>
      </div>
      <div class="grid grid-cols-2 gap-3 p-4 lg:grid-cols-4">
        <.health_stat
          id="delivery-backlog"
          label="Queued"
          value={@health.queued}
          detail={"#{bytes(@health.queued_bytes)} payload"}
        />
        <.health_stat
          id="delivery-pending"
          label="Pending requests"
          value={@health.pending}
          detail={"#{@health.in_flight_sends} sends in flight"}
        />
        <.health_stat
          id="delivery-rejections"
          label="Offline rejections"
          value={@health.unavailable_rejections}
          detail={"#{@health.overload_rejections} admission · #{@health.send_capacity_rejections} send capacity"}
          alert={
            @health.unavailable_rejections + @health.overload_rejections +
              @health.send_capacity_rejections > 0
          }
        />
        <.health_stat
          id="delivery-send-failures"
          label="Failed send operations"
          value={@health.send_failures}
          detail={"#{latency(@health.average_response_ms)} average successful response"}
          alert={@health.send_failures > 0}
        />
      </div>
      <div class="border-t border-base-300/80 px-4 py-2 text-[11px] text-base-content/50">
        Response time includes queueing, client processing and Telegram send. Queue bytes exclude deliveries awaiting acknowledgement.
      </div>
      <div id="delivery-hooks" phx-update="stream" class="divide-y divide-base-300/70">
        <p
          id="delivery-hooks-empty"
          class="hidden px-4 py-6 text-center text-sm text-base-content/50 only:block"
        >
          No hooks configured.
        </p>
        <article
          :for={{id, hook} <- @streams.hooks}
          id={id}
          class="grid min-w-0 gap-3 px-4 py-4 transition-colors hover:bg-base-200/40 lg:grid-cols-[minmax(0,1.2fr)_minmax(0,2fr)]"
        >
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <.link
                navigate={~p"/hooks/#{hook.name}"}
                class="break-all font-mono text-xs font-bold transition-colors hover:text-primary"
              >{hook.name}</.link>
              <span
                id={id <> "-availability"}
                class={[
                  "rounded-full px-2 py-0.5 text-[10px] font-bold",
                  hook.connected && "bg-primary/10 text-primary",
                  !hook.connected && "bg-amber-500/10 text-amber-700 dark:text-amber-300"
                ]}
              >{if(hook.connected, do: "Available", else: "Unavailable")}</span>
            </div>
            <p id={id <> "-connected"} class="mt-2 text-[11px] text-base-content/55">
              Last connected: <.timestamp at={hook.health.last_connected_at} />
            </p>
            <p id={id <> "-disconnected"} class="mt-1 text-[11px] text-base-content/55">
              Last disconnected: <.timestamp at={hook.health.last_disconnected_at} />
            </p>
            <ClientConnection.summary id={id <> "-client"} client={hook.client} />
          </div>
          <dl class="grid min-w-0 grid-cols-2 gap-3 text-xs sm:grid-cols-4">
            <div>
              <dt class="text-base-content/50">Backlog</dt>
              <dd class="mt-1 font-semibold">
                {hook.health.queued} · {bytes(hook.health.queued_bytes)}
              </dd>
              <dd class="mt-1 text-[11px] text-base-content/50">{hook.health.pending} pending</dd>
            </div>
            <div id={id <> "-rejections"}>
              <dt class="text-base-content/50">Rejected</dt>
              <dd class="mt-1 font-semibold">{hook.health.unavailable_rejections} offline</dd>
              <dd class="mt-1 text-[11px] text-base-content/50">
                {hook.health.overload_rejections} admission
              </dd>
              <dd id={id <> "-send-capacity-rejections"} class="mt-1 text-[11px] text-base-content/50">
                {hook.health.send_capacity_rejections} send capacity
              </dd>
            </div>
            <div id={id <> "-sends"}>
              <dt class="text-base-content/50">Sends</dt>
              <dd id={id <> "-send-capacity"} class="mt-1 font-semibold">
                {hook.health.in_flight_sends} / {hook.health.in_flight_send_limit} in flight
              </dd>
              <dd id={id <> "-send-bytes"} class="mt-1 text-[11px] text-base-content/50">
                {bytes(hook.health.in_flight_send_bytes)} / {bytes(
                  hook.health.in_flight_send_bytes_limit
                )} payload
              </dd>
              <dd id={id <> "-send-byte-rejections"} class="mt-1 text-[11px] text-base-content/50">
                {hook.health.send_byte_capacity_rejections} byte capacity · {hook.health.send_failures} failed
              </dd>
            </div>
            <div id={id <> "-latency"}>
              <dt class="text-base-content/50">Last response</dt>
              <dd class="mt-1 font-semibold">{latency(hook.health.last_response_ms)}</dd>
              <dd class="mt-1 text-[11px] text-base-content/50">
                {hook.health.completed_responses} completed
              </dd>
            </div>
          </dl>
        </article>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :detail, :string, required: true
  attr :alert, :boolean, default: false

  defp health_stat(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "min-w-0 rounded-xl border p-3",
        @alert && "border-amber-500/25 bg-amber-500/5",
        !@alert && "border-base-300/70 bg-base-200/30"
      ]}
    >
      <p class="text-[11px] text-base-content/60">{@label}</p>
      <p class="mt-1 text-2xl font-black tracking-tight">{@value}</p>
      <p class="mt-1 text-[11px] text-base-content/50">{@detail}</p>
    </div>
    """
  end

  attr :at, :any, required: true

  defp timestamp(assigns) do
    ~H"""
    <%= if @at do %>
      <time datetime={DateTime.to_iso8601(@at)}>{Calendar.strftime(@at, "%Y-%m-%d %H:%M:%S UTC")}</time>
    <% else %>
      Never
    <% end %>
    """
  end

  defp latency(nil), do: "—"
  defp latency(value), do: "#{Float.round(value * 1.0, 1)} ms"
  defp bytes(value) when value >= 1_048_576, do: "#{Float.round(value / 1_048_576, 1)} MiB"
  defp bytes(value) when value >= 1024, do: "#{Float.round(value / 1024, 1)} KiB"
  defp bytes(value), do: "#{value} B"
end
