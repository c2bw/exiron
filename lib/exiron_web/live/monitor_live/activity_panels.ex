defmodule ExironWeb.MonitorLive.ActivityPanels do
  @moduledoc false

  use ExironWeb, :html

  attr :streams, :any, required: true
  attr :counts, :map, required: true

  def activity_panels(assigns) do
    ~H"""
    <div class="grid gap-5 xl:grid-cols-2">
      <section id="exiron-monitor-membership-events" class="ex-panel overflow-hidden">
        <div class="flex items-center justify-between border-b border-base-300/80 px-4 py-4 sm:px-5">
          <div class="flex items-center gap-3">
            <span class="grid size-9 place-items-center rounded-xl bg-violet-500/10 text-violet-600 dark:text-violet-300">
              <.icon name="hero-user-group-micro" class="size-4" />
            </span>
            <div>
              <h2 class="text-sm font-black tracking-[-0.02em]">Group activity</h2>
              <p class="mt-0.5 text-xs text-base-content/45">Bot membership changes</p>
            </div>
          </div>
          <span class="font-mono text-[9px] font-bold uppercase tracking-[0.12em] text-base-content/35">
            {@counts.membership_events} events
          </span>
        </div>

        <div id="exiron-monitor-membership-event-stream" phx-update="stream">
          <div
            id="exiron-monitor-membership-event-empty"
            class="hidden min-h-56 flex-col items-center justify-center p-5 text-center only:flex"
          >
            <span class="grid size-11 place-items-center rounded-2xl bg-emerald-500/10 text-emerald-600 dark:text-emerald-300">
              <.icon name="hero-check-circle-micro" class="size-5" />
            </span>
            <p class="mt-3 text-sm font-bold">No membership changes</p>
            <p class="mt-1 text-xs text-base-content/45">Bot presence has been stable.</p>
          </div>

          <article
            :for={{id, event} <- @streams.membership_events}
            id={id}
            class="ex-monitor-event-row"
          >
            <div class={[
              "ex-monitor-event-icon",
              event.action == "added" &&
                "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300",
              event.action == "removed" && "bg-rose-500/10 text-rose-700 dark:text-rose-300"
            ]}>
              <.icon
                name={
                  if(event.action == "added",
                    do: "hero-user-plus-micro",
                    else: "hero-user-minus-micro"
                  )
                }
                class="size-4"
              />
            </div>

            <div class="min-w-0 flex-1">
              <div class="flex items-start justify-between gap-3">
                <p class="truncate text-sm font-bold">{event.bot_name || "Unknown bot"}</p>
                <time class="flex-none font-mono text-[9px] text-base-content/35">
                  {Calendar.strftime(event.at, "%H:%M:%S")}
                </time>
              </div>
              <p class="mt-1 text-xs leading-5 text-base-content/50">
                <span class={[
                  "font-bold",
                  event.action == "added" && "text-emerald-700 dark:text-emerald-300",
                  event.action == "removed" && "text-rose-700 dark:text-rose-300"
                ]}>
                  {event.action}
                </span>
                in chat: {event.chat_id}
                <span :if={event.chat_title}> · group: {event.chat_title}</span>
              </p>
              <p class="mt-1 font-mono text-[10px] text-base-content/40">
                {event.old_status || "unknown"} -> {event.new_status || "unknown"}
              </p>
            </div>
          </article>
        </div>
      </section>

      <section id="exiron-monitor-send-failures" class="ex-panel overflow-hidden">
        <div class="flex items-center justify-between border-b border-base-300/80 px-4 py-4 sm:px-5">
          <div class="flex items-center gap-3">
            <span class={[
              "grid size-9 place-items-center rounded-xl",
              @counts.send_failures == 0 &&
                "bg-emerald-500/10 text-emerald-600 dark:text-emerald-300",
              @counts.send_failures > 0 && "bg-rose-500/10 text-rose-600 dark:text-rose-300"
            ]}>
              <.icon
                name={
                  if(@counts.send_failures == 0,
                    do: "hero-check-circle-micro",
                    else: "hero-exclamation-triangle-micro"
                  )
                }
                class="size-4"
              />
            </span>
            <div>
              <h2 class="text-sm font-black tracking-[-0.02em]">Recent send issues</h2>
              <p class="mt-0.5 text-xs text-base-content/45">Failed Telegram sends</p>
            </div>
          </div>
          <span class={[
            "rounded-full px-2 py-1 font-mono text-[9px] font-bold uppercase tracking-[0.12em]",
            @counts.send_failures == 0 &&
              "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300",
            @counts.send_failures > 0 && "bg-rose-500/10 text-rose-700 dark:text-rose-300"
          ]}>
            {if(@counts.send_failures == 0, do: "clear", else: "#{@counts.send_failures} issues")}
          </span>
        </div>

        <div id="exiron-monitor-send-failure-stream" phx-update="stream">
          <div
            id="exiron-monitor-send-failure-empty"
            class="hidden min-h-56 flex-col items-center justify-center p-5 text-center only:flex"
          >
            <span class="grid size-11 place-items-center rounded-2xl bg-emerald-500/10 text-emerald-600 dark:text-emerald-300">
              <.icon name="hero-paper-airplane-micro" class="size-5" />
            </span>
            <p class="mt-3 text-sm font-bold">No recent send issues</p>
            <p class="mt-1 text-xs text-base-content/45">
              No failed Telegram sends in recent history.
            </p>
          </div>

          <article
            :for={{id, failure} <- @streams.send_failures}
            id={id}
            class="ex-monitor-event-row"
          >
            <div class="ex-monitor-event-icon bg-rose-500/10 text-rose-700 dark:text-rose-300">
              <.icon name="hero-x-mark-micro" class="size-4" />
            </div>

            <div class="min-w-0 flex-1">
              <div class="flex items-start justify-between gap-3">
                <p class="truncate text-sm font-bold">{failure.reason}</p>
                <button
                  :if={Map.get(failure, :delivery)}
                  id={id <> "-delivery"}
                  type="button"
                  phx-click="inspect_delivery"
                  phx-value-id={failure.delivery.id}
                  class="mt-2 text-xs font-bold text-primary underline-offset-2 transition hover:underline"
                >Inspect delivery · {failure.delivery.delivery_status}</button>
                <time class="flex-none font-mono text-[9px] text-base-content/35">
                  {Calendar.strftime(failure.at, "%H:%M:%S")}
                </time>
              </div>
              <div class="mt-1 flex flex-wrap gap-x-2 text-[11px] leading-5 text-base-content/50">
                <span class="font-bold text-rose-700 dark:text-rose-300">{failure.operation}</span>
                <span :if={failure.hook}>hook: {failure.hook}</span>
                <span :if={failure.bot_name}>bot: {failure.bot_name}</span>
                <span>chat: {failure.chat_id}</span>
                <span>{failure.datatype}</span>
              </div>
              <p class="mt-2 truncate rounded-lg border border-base-300/70 bg-base-200/55 px-2.5 py-2 font-mono text-[10px] text-base-content/60">
                {failure.preview}
              </p>
            </div>
          </article>
        </div>
      </section>
    </div>
    """
  end
end
