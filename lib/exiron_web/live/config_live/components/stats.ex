defmodule ExironWeb.ConfigLive.Components.Stats do
  @moduledoc false

  use ExironWeb, :html

  alias ExironWeb.ConfigLive.State

  attr :config, :map, required: true

  def stats_strip(assigns) do
    assigns = assign(assigns, :summary, State.summary(assigns.config))

    ~H"""
    <section class="grid grid-cols-5 border-t border-white/[0.08] bg-black/10">
      <.stat_tile
        id="exiron-telegram-bot-count"
        label="Bots"
        value={@summary.telegram_bots}
      />
      <.stat_tile
        id="exiron-route-chat-count"
        label="Chats"
        value={@summary.telegram_chats}
      /> <.stat_tile id="exiron-route-count" label="Resolved" value={@summary.routes} />
      <.stat_tile id="exiron-middleware-count" label="Middleware" value={@summary.middlewares} />
      <.stat_tile id="exiron-hook-count" label="Hooks" value={@summary.hooks} last? />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :last?, :boolean, default: false

  defp stat_tile(assigns) do
    ~H"""
    <div class={[
      "group flex min-w-0 items-center justify-center gap-2 px-2 py-2.5 transition hover:bg-white/[0.04] sm:px-4",
      !@last? && "border-r border-white/[0.08]"
    ]}>
      <p id={@id} class="text-lg font-black tracking-[-0.04em] text-white sm:text-xl">
        {@value}
      </p>
      <p class="hidden truncate text-[9px] font-bold uppercase tracking-[0.12em] text-white/35 sm:block">
        {@label}
      </p>
    </div>
    """
  end
end
