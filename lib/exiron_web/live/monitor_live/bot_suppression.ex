defmodule ExironWeb.MonitorLive.BotSuppression do
  @moduledoc false
  use ExironWeb, :html
  attr :summary, :map, default: nil
  attr :streams, :any, required: true

  def panel(assigns) do
    ~H"""
    <section id="telegram-suppression" class="ex-panel overflow-hidden">
      <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300/80 px-4 py-3">
        <div class="flex items-center gap-3">
          <.icon name="hero-shield-check-micro" class="size-5 text-primary" />
          <div>
            <h2 class="text-sm font-black">Telegram send protection</h2>
            <p class="text-[11px] text-base-content/55">
              Definitive rejections pause attempts for 60 seconds. Retry probes are serialized per bot.
            </p>
          </div>
        </div>
        <p :if={@summary} id="telegram-suppression-counters" class="text-xs text-base-content/65">
          {@summary.active} cooling down · {@summary.suppressed_attempts} attempts skipped · {@summary.probes} probes · {@summary.recoveries} confirmed recoveries
        </p>
      </div>
      <p
        :if={@summary && !@summary.available}
        id="telegram-suppression-unavailable"
        class="px-4 py-3 text-sm text-amber-700"
      >
        Protection status is unavailable.
      </p>
      <p
        :if={@summary && @summary.last_recovery}
        id="telegram-suppression-last-recovery"
        class="border-b border-base-300/70 px-4 py-2 text-xs text-base-content/60"
      >
        Last recovery: {@summary.last_recovery.bot_name || "Configured bot"} · {DateTime.to_iso8601(
          @summary.last_recovery.at
        )}
      </p>
      <div
        id="telegram-suppression-records"
        phx-update="stream"
        class="max-h-64 divide-y divide-base-300/70 overflow-y-auto"
      >
        <p
          id="telegram-suppression-empty"
          class="hidden px-4 py-5 text-sm text-base-content/55 only:block"
        >
          No retained rejection records.
        </p>
        <article
          :for={{id, record} <- @streams.suppressed_bots}
          id={id}
          class="flex min-w-0 flex-wrap items-center justify-between gap-2 px-4 py-3 text-xs"
        >
          <div class="min-w-0">
            <p class="break-all font-bold">{record.bot_name || "Configured bot"}</p>
            <p class="mt-1 text-base-content/55">
              HTTP {record.code} · {if(record.scope == "token",
                do: "All chats for this token",
                else: "Chat #{record.chat_id}"
              )}
            </p>
          </div>
          <div class="text-right text-base-content/60">
            <p>
              {if(record.phase == "cooldown", do: "Cooling down", else: "Ready for a retry probe")}
            </p>
            <p class="mt-1">Eligible at {DateTime.to_iso8601(record.retry_at)}</p>
          </div>
        </article>
      </div>
      <p class="border-t border-base-300/70 px-4 py-2 text-[11px] text-base-content/50">
        Shows up to 50 recent records. Timeouts and uncertain delivery results do not trigger suppression or bot fallback.
      </p>
    </section>
    """
  end
end
