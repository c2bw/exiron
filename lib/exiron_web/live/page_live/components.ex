defmodule ExironWeb.PageLive.Components do
  @moduledoc false

  use ExironWeb, :html

  attr :exiron, :map, required: true
  attr :counts, :map, required: true

  def overview(assigns) do
    ~H"""
    <section id="control-plane-overview" class="ex-control-overview" aria-labelledby="overview-title">
      <header class="ex-control-header">
        <div class="flex items-center gap-3">
          <span class="grid size-8 place-items-center rounded-lg border border-white/10 bg-white/6 text-emerald-300">
            <.icon name="hero-cpu-chip-micro" class="size-4" />
          </span>
          <div>
            <p class="font-mono text-[9px] font-bold uppercase tracking-[0.18em] text-white/35">
              Control plane
            </p>
            <h1 id="overview-title" class="mt-0.5 text-base font-black tracking-[-0.03em] text-white">
              Overview
            </h1>
          </div>
        </div>
      </header>

      <div class="ex-control-grid">
        <div class="ex-control-telegram">
          <div class="flex items-start justify-between gap-3">
            <div>
              <p class="ex-control-label">Telegram</p>
              <p
                id="exiron-telegram-polling-status"
                class={[
                  "mt-2 text-lg font-black tracking-[-0.04em]",
                  @exiron.telegram_polling && "text-emerald-300",
                  !@exiron.telegram_polling && "text-white/45"
                ]}
              >
                {if(@exiron.telegram_polling, do: "polling", else: "not polling")}
              </p>
            </div>

            <span class={[
              "grid size-7 place-items-center rounded-lg border",
              @exiron.telegram_polling && "border-emerald-300/15 bg-emerald-300/8 text-emerald-300",
              !@exiron.telegram_polling && "border-white/8 bg-white/5 text-white/35"
            ]}>
              <.icon name="hero-paper-airplane-micro" class="size-3.5" />
            </span>
          </div>

          <p
            id="exiron-telegram-last-polled"
            class="mt-3 font-mono text-[9px] uppercase tracking-[0.08em] text-white/30"
          >
            Last poll: {last_polled_text(@exiron.telegram_last_polled_at)}
          </p>
        </div>

        <.overview_stat
          label="Routes"
          value={@counts.routes}
          hint="Configured paths"
          icon="hero-map-micro"
        />
        <.overview_ratio
          id="exiron-connected-count"
          label="Hooks"
          active={@counts.connected}
          total={@counts.hooks}
          hint="Active / total"
          icon="hero-command-line-micro"
        />
        <.overview_stat
          id="exiron-queued-count"
          label="Queued"
          value={@counts.queued}
          hint="Waiting messages"
          icon="hero-inbox-stack-micro"
        />
        <.overview_stat
          id="exiron-requested-count"
          label="Requested"
          value={@exiron.requested}
          hint="Routed requests"
          icon="hero-arrow-path-rounded-square-micro"
        />
      </div>
    </section>
    """
  end

  attr :streams, :map, required: true
  attr :counts, :map, required: true

  def activity(assigns) do
    ~H"""
    <section class="grid items-start gap-6 xl:grid-cols-[minmax(21rem,0.78fr)_minmax(34rem,1.22fr)]">
      <div class="space-y-6">
        <div>
          <.area_heading
            eyebrow="Infrastructure"
            title="Connections & routes"
            description="The active paths carrying messages into and across Exiron."
          />
          <div class="mt-3 space-y-4">
            <.hooks hooks={@streams.hooks} count={@counts.hooks} />
            <.routes routes={@streams.routes} count={@counts.routes} />
          </div>
        </div>

        <div class="grid gap-4 lg:grid-cols-2 xl:grid-cols-1">
          <.client_events events={@streams.client_events} count={@counts.client_events} />
          <.overload_events events={@streams.overload_events} count={@counts.overload_events} />
        </div>
      </div>

      <div class="xl:sticky xl:top-[5.75rem]">
        <.area_heading
          eyebrow="Traffic"
          title="Live message stream"
          description="The latest inbound, forwarded, and outbound payloads."
        />
        <div class="mt-3">
          <.message_events events={@streams.events} count={@counts.events} />
        </div>
      </div>
    </section>
    """
  end

  attr :hooks, :any, required: true
  attr :count, :integer, required: true

  defp hooks(assigns) do
    ~H"""
    <div id="exiron-hooks" class="ex-panel overflow-hidden">
      <.panel_header
        title="HTTP hooks"
        meta={"#{@count} clients"}
        icon="hero-command-line-micro"
      />
      <div phx-update="stream" id="exiron-hook-stream">
        <div id="exiron-hook-empty" class="hidden only:flex ex-empty p-5 text-sm">
          <.empty_state
            icon="hero-command-line-micro"
            title="No hooks configured"
            description="Add a hook to begin receiving client traffic."
          />
        </div>

        <div
          :for={{id, hook} <- @hooks}
          id={id}
          class="ex-panel-row border-t border-base-300 px-3 py-2.5 first:border-t-0"
        >
          <div class="flex items-center justify-between gap-3">
            <div class="flex min-w-0 items-center gap-2.5">
              <span class={[
                "size-1.5 shrink-0 rounded-full ring-[3px]",
                hook.connected && "bg-emerald-500 ring-emerald-500/10",
                !hook.connected && "bg-base-content/25 ring-base-content/5"
              ]} />
              <div class="flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-0.5">
                <.link
                  navigate={~p"/hooks/#{hook.name}"}
                  class="truncate font-mono text-[11px] font-bold transition-colors hover:text-primary"
                >{hook.name}</.link>
                <p class="text-[9px] text-base-content/40">{hook.queued} queued</p>
                <p
                  :if={hook.connected or Map.get(hook.client, :client_version)}
                  id={id <> "-version"}
                  class="break-all font-mono text-[9px] text-base-content/50"
                >
                  {ExironWeb.MonitorLive.ClientConnection.version_label(hook.client)}
                </p>
              </div>
            </div>

            <div class="flex shrink-0 flex-wrap justify-end gap-1">
              <span class={[
                "ex-status ex-status-compact",
                hook.connected &&
                  "bg-emerald-500/10 text-emerald-700 dark:bg-emerald-400/15 dark:text-emerald-300",
                !hook.connected && "bg-base-200 text-base-content/55"
              ]}>
                {if(hook.connected, do: "connected", else: "idle")}
              </span>

              <span
                :if={hook.listening}
                class="ex-status ex-status-compact bg-sky-500/10 text-sky-700 dark:bg-sky-400/15 dark:text-sky-300"
              >
                listening
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :routes, :any, required: true
  attr :count, :integer, required: true

  defp routes(assigns) do
    ~H"""
    <div id="exiron-routes" class="ex-panel overflow-hidden">
      <.panel_header title="Routing map" meta={"#{@count} configured"} icon="hero-map-micro" />
      <div id="exiron-route-stream" phx-update="stream">
        <div id="exiron-route-empty" class="hidden only:flex ex-empty p-5 text-sm">
          <.empty_state
            icon="hero-map-micro"
            title="No routes configured"
            description="Connect a chat to a client to establish your first path."
          />
        </div>

        <div
          :for={{id, route} <- @routes}
          id={id}
          class="ex-panel-row border-t border-base-300 px-3 py-2.5 first:border-t-0"
        >
          <div class="grid gap-2 sm:grid-cols-[minmax(7rem,0.8fr)_auto_minmax(7rem,0.8fr)_minmax(9rem,1.2fr)] sm:items-center">
            <div class="min-w-0">
              <p class="truncate text-xs font-bold tracking-[-0.01em]">{route.chat_alias}</p>
              <p class="mt-0.5 font-mono text-[9px] text-base-content/40">{route.chat_id}</p>
            </div>
            <span class="hidden size-6 place-items-center rounded-full border border-base-300 bg-base-200 text-base-content/35 sm:grid">
              <.icon name="hero-arrow-right-micro" class="size-3.5" />
            </span>
            <p class="truncate font-mono text-[11px] font-semibold text-primary">{route.to}</p>
            <div class="flex flex-wrap gap-1 sm:justify-end">
              <span
                :for={message <- route.messages}
                class="rounded border border-base-300 bg-base-200/70 px-1.5 py-0.5 font-mono text-[9px] leading-4 text-base-content/60"
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

  attr :events, :any, required: true
  attr :count, :integer, required: true

  defp client_events(assigns) do
    ~H"""
    <div id="exiron-client-events" class="ex-panel overflow-hidden">
      <.panel_header title="Client events" meta={"Latest #{@count}"} icon="hero-bolt-micro" />
      <div id="exiron-client-event-stream" phx-update="stream">
        <div id="exiron-client-event-empty" class="hidden only:flex ex-empty p-5 text-sm">
          <.empty_state
            icon="hero-bolt-micro"
            title="No client events"
            description="Connection changes will appear here."
          />
        </div>

        <div
          :for={{id, event} <- @events}
          id={id}
          class="ex-panel-row grid gap-3 border-t border-base-300 p-4 first:border-t-0 sm:grid-cols-[6.5rem_minmax(0,1fr)]"
        >
          <div>
            <span class={[
              "ex-status",
              event.action == "connected" &&
                "bg-emerald-500/10 text-emerald-700 dark:bg-emerald-400/15 dark:text-emerald-300",
              event.action == "disconnected" &&
                "bg-rose-500/10 text-rose-700 dark:bg-rose-400/15 dark:text-rose-300"
            ]}>
              {event.action}
            </span>
            <p class="mt-2 font-mono text-[10px] text-base-content/40">
              {Calendar.strftime(event.at, "%H:%M:%S UTC")}
            </p>
          </div>

          <div class="min-w-0 text-sm">
            <p class="truncate font-mono text-xs font-bold">{event.hook}</p>
            <div class="mt-1.5 flex flex-wrap gap-x-3 gap-y-1 text-[11px] text-base-content/50">
              <span>client: {event.client_id}</span>
              <span>{if(event.listening, do: "listening", else: "polling")}</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :events, :any, required: true
  attr :count, :integer, required: true

  defp overload_events(assigns) do
    ~H"""
    <div id="exiron-overload-events" class="ex-panel overflow-hidden">
      <.panel_header
        title="Capacity alerts"
        meta={"Latest #{@count}"}
        icon="hero-shield-exclamation-micro"
      />
      <div id="exiron-overload-event-stream" phx-update="stream">
        <div id="exiron-overload-event-empty" class="hidden only:flex ex-empty p-5 text-sm">
          <.empty_state
            icon="hero-shield-check-micro"
            title="Capacity looks healthy"
            description="No overload events have been recorded."
          />
        </div>

        <div
          :for={{id, event} <- @events}
          id={id}
          class="ex-panel-row grid gap-3 border-t border-base-300 p-4 first:border-t-0 sm:grid-cols-[6.5rem_minmax(0,1fr)]"
        >
          <div>
            <span class="ex-status bg-rose-500/10 text-rose-700 dark:bg-rose-400/15 dark:text-rose-300">
              rejected
            </span>
            <p class="mt-2 font-mono text-[10px] text-base-content/40">
              {Calendar.strftime(event.at, "%H:%M:%S UTC")}
            </p>
          </div>

          <div class="min-w-0 text-sm">
            <p class="truncate font-mono text-xs font-bold">{event.hook}</p>
            <div class="mt-1.5 flex flex-wrap gap-x-3 gap-y-1 text-[11px] text-base-content/50">
              <span>{event.reason}</span>
              <span>chat: {event.chat_id}</span>
              <span>{event.payload_bytes} bytes</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :events, :any, required: true
  attr :count, :integer, required: true

  defp message_events(assigns) do
    ~H"""
    <div id="exiron-messages" class="ex-panel overflow-hidden">
      <div class="flex items-center justify-between border-b border-base-300 bg-base-100/75 px-5 py-4">
        <div class="flex items-center gap-3">
          <span class="relative flex size-2.5">
            <span class="absolute inline-flex size-full animate-ping rounded-full bg-primary opacity-40" />
            <span class="relative inline-flex size-2.5 rounded-full bg-primary" />
          </span>
          <p class="text-xs font-extrabold tracking-[-0.01em]">Traffic log</p>
        </div>
        <span class="rounded-full bg-base-200 px-2.5 py-1 font-mono text-[9px] font-bold uppercase tracking-wider text-base-content/45">
          Latest {@count}
        </span>
      </div>

      <div id="exiron-message-stream" phx-update="stream">
        <div id="exiron-message-empty" class="hidden only:flex ex-empty min-h-64 p-6 text-sm">
          <.empty_state
            icon="hero-chat-bubble-left-right-micro"
            title="Waiting for traffic"
            description="Messages will appear here the moment they move through Exiron."
          />
        </div>

        <article
          :for={{id, event} <- @events}
          id={id}
          class="ex-panel-row grid gap-4 border-t border-base-300 p-4 first:border-t-0 sm:grid-cols-[6.75rem_minmax(0,1fr)] sm:p-5"
        >
          <div>
            <span class={message_direction_class(event)}>
              <span class="size-1.5 rounded-full bg-current opacity-70" />
              {display_direction(event)}
            </span>
            <p class="mt-2.5 font-mono text-[10px] text-base-content/40">
              {Calendar.strftime(event.at, "%H:%M:%S UTC")}
            </p>
          </div>

          <div class="min-w-0">
            <.message_meta event={event} />
            <div
              :if={event.image_src}
              class="mt-3 overflow-hidden rounded-xl border border-base-300 bg-base-200"
            >
              <img
                id={"exiron-event-image-#{event.id}"}
                src={event.image_src}
                alt="Message image preview"
                class="max-h-80 w-full object-contain"
              />
            </div>

            <div
              :if={Map.get(event, :caption) not in [nil, ""]}
              id={"exiron-event-caption-#{event.id}"}
              class="ex-readout mt-3 px-3.5 py-3"
            >
              <p class="text-[10px] font-bold uppercase tracking-wider text-base-content/45">
                Caption
              </p>
              <p class="mt-1.5 max-h-48 overflow-y-auto whitespace-pre-wrap text-sm leading-6 text-base-content/80 [overflow-wrap:anywhere]">
                {event.caption}
              </p>
            </div>

            <p class="ex-readout mt-3 truncate px-3.5 py-3 font-mono text-xs text-base-content/70">
              {event.preview}
            </p>
          </div>
        </article>
      </div>
    </div>
    """
  end

  attr :event, :map, required: true

  defp message_meta(assigns) do
    ~H"""
    <div>
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-sm font-extrabold tracking-[-0.01em]">{@event.kind}</span>
        <span class="rounded-md bg-primary/8 px-2 py-0.5 font-mono text-[10px] font-semibold text-primary">
          {@event.datatype}
        </span>
      </div>

      <div class="mt-2 flex flex-wrap gap-x-3 gap-y-1 font-mono text-[10px] text-base-content/45">
        <span>target: {@event.target}</span>
        <span :if={@event.hook}>hook: {@event.hook}</span>
        <span :if={@event.bot_name}>bot: {@event.bot_name}</span>
        <span>chat: {@event.chat_id}</span>
        <span :if={@event.message_id}>msg: {@event.message_id}</span>
        <span :if={@event.reply_to_message_id}>reply: {@event.reply_to_message_id}</span>
        <span :if={Map.get(@event, :sticker_id)}>sticker: {@event.sticker_id}</span>
        <span :if={@event.sticker_emoji}>emoji: {@event.sticker_emoji}</span>
        <span :if={Map.get(@event, :emoji_list, []) != []}>
          emoji list: {Enum.join(@event.emoji_list, " ")}
        </span>
      </div>
    </div>
    """
  end

  attr :eyebrow, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true

  defp area_heading(assigns) do
    ~H"""
    <div class="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
      <div>
        <p class="ex-kicker">{@eyebrow}</p>
        <h2 class="mt-2 text-xl font-black tracking-[-0.035em] sm:text-2xl">{@title}</h2>
      </div>
      <p class="max-w-sm text-xs leading-5 text-base-content/45 sm:text-right">
        {@description}
      </p>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :meta, :string, required: true
  attr :icon, :string, required: true

  defp panel_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between border-b border-base-300 bg-base-200/35 px-4 py-3.5">
      <div class="flex items-center gap-2.5">
        <span class="grid size-7 place-items-center rounded-lg bg-primary/10 text-primary">
          <.icon name={@icon} class="size-4" />
        </span>
        <h3 class="text-xs font-extrabold tracking-[-0.01em]">{@title}</h3>
      </div>
      <span class="font-mono text-[9px] font-semibold uppercase tracking-wider text-base-content/40">
        {@meta}
      </span>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true

  defp empty_state(assigns) do
    ~H"""
    <div class="flex max-w-xs flex-col items-center text-center">
      <span class="grid size-10 place-items-center rounded-xl border border-base-300 bg-base-100 text-base-content/35 shadow-sm">
        <.icon name={@icon} class="size-5" />
      </span>
      <p class="mt-3 text-xs font-bold text-base-content/70">{@title}</p>
      <p class="mt-1 text-[11px] leading-4 text-base-content/40">{@description}</p>
    </div>
    """
  end

  attr :id, :string, default: nil
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :hint, :string, required: true
  attr :icon, :string, required: true

  defp overview_stat(assigns) do
    ~H"""
    <div class="ex-control-stat">
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="ex-control-label">{@label}</p>
          <p id={@id} class="mt-2 text-2xl font-black tracking-[-0.055em] text-white">
            {@value}
          </p>
        </div>
        <span class="grid size-7 place-items-center rounded-lg border border-white/8 bg-white/5 text-white/30">
          <.icon name={@icon} class="size-3.5" />
        </span>
      </div>
      <p class="mt-2 text-[9px] font-medium text-white/30">{@hint}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :active, :integer, required: true
  attr :total, :integer, required: true
  attr :hint, :string, required: true
  attr :icon, :string, required: true

  defp overview_ratio(assigns) do
    ~H"""
    <div class="ex-control-stat">
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="ex-control-label">{@label}</p>
          <p
            id={@id}
            class="mt-2 text-2xl font-black tracking-[-0.055em] text-white"
            aria-label={"#{@active} active of #{@total} total hooks"}
          >
            <span class="text-emerald-300">{@active}</span>
            <span class="mx-0.5 text-sm font-medium text-white/25">/</span>
            <span>{@total}</span>
          </p>
        </div>
        <span class="grid size-7 place-items-center rounded-lg border border-white/8 bg-white/5 text-white/30">
          <.icon name={@icon} class="size-3.5" />
        </span>
      </div>
      <p class="mt-2 text-[9px] font-medium text-white/30">{@hint}</p>
    </div>
    """
  end

  defp message_direction_class(event) do
    [
      "ex-status uppercase tracking-[0.08em]",
      event.direction == "incoming" &&
        "bg-amber-500/10 text-amber-700 dark:bg-amber-400/15 dark:text-amber-300",
      display_direction(event) == "forward" &&
        "bg-indigo-500/10 text-indigo-700 dark:bg-indigo-400/15 dark:text-indigo-300",
      display_direction(event) == "outgoing" &&
        "bg-rose-500/10 text-rose-700 dark:bg-rose-400/15 dark:text-rose-300"
    ]
  end

  defp display_direction(%{direction: "outgoing", target: "client"}), do: "forward"
  defp display_direction(%{direction: direction}), do: direction

  defp last_polled_text(nil), do: "never"

  defp last_polled_text(%DateTime{} = at) do
    Calendar.strftime(at, "%H:%M:%S UTC")
  end
end
