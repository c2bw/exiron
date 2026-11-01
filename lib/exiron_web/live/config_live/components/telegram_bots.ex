defmodule ExironWeb.ConfigLive.Components.TelegramBots do
  @moduledoc false

  use ExironWeb, :html

  import ExironWeb.ConfigLive.Components.DetailsSupport

  attr :bots, :list, required: true

  def telegram_bots(assigns) do
    ~H"""
    <.section_title title="Telegram Bots" meta="config.yml" />
    <div id="exiron-telegram-bots" class="ex-panel ex-config-card-grid">
      <div :if={@bots == []} class="flex ex-empty p-4 text-sm">No Telegram bots configured.</div>
      <div
        :for={bot <- @bots}
        id={"exiron-telegram-bot-#{bot.id}"}
        class="ex-config-item"
      >
        <div class="flex items-start justify-between gap-3">
          <div class="flex min-w-0 items-center gap-2.5">
            <span class="grid size-8 shrink-0 place-items-center rounded-lg bg-sky-500/10 text-sky-600 dark:text-sky-300">
              <.icon name="hero-paper-airplane-micro" class="size-4" />
            </span>
            <div class="min-w-0">
              <p class="truncate text-sm font-bold">{bot.bot_name || "Unnamed bot"}</p>
              <p class="truncate font-mono text-[11px] text-base-content/65">
                {bot.bot_tag || "no Telegram tag"}
              </p>
            </div>
          </div>
          <div class="shrink-0 text-right">
            <span class="ex-item-count">
              {bot.chat_count} {plural(bot.chat_count, "chat", "chats")}
            </span>
            <p class="mt-1 font-mono text-[10px] text-base-content/55">
              {bot.token_fingerprint}
            </p>
          </div>
        </div>

        <div class="mt-3 border-t border-base-300 pt-2.5">
          <p class="ex-item-label">Connected chats</p>
          <div class="mt-1.5 grid gap-1.5 sm:grid-cols-2">
            <div
              :for={chat <- bot.chats}
              class="rounded-md border border-base-300 bg-base-200 px-2 py-1.5"
            >
              <div class="flex min-w-0 items-center justify-between gap-2">
                <div class="flex min-w-0 flex-wrap gap-1">
                  <span
                    :for={alias <- chat.aliases}
                    class="rounded bg-base-100 px-1.5 py-0.5 font-mono text-[11px] font-medium"
                  >
                    {alias}
                  </span>
                  <span
                    :if={chat.aliases == []}
                    class="text-[11px] text-base-content/60"
                  >
                    no alias
                  </span>
                </div>
                <p class="truncate font-mono text-[10px] text-base-content/60">{chat.id}</p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
