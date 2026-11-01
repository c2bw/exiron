defmodule ExironWeb.MonitorLive.ChatNetwork do
  @moduledoc false

  use ExironWeb, :html

  alias ExironWeb.MonitorLive.Components

  attr :streams, :any, required: true
  attr :count, :integer, required: true

  def chat_network(assigns) do
    ~H"""
    <div id="exiron-monitor-chats" class="ex-panel overflow-hidden">
      <div class="flex flex-col gap-2.5 border-b border-base-300/80 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
        <div class="flex items-center gap-3">
          <span class="grid size-8 place-items-center rounded-lg border border-primary/15 bg-primary/10 text-primary">
            <.icon name="hero-signal-micro" class="size-4" />
          </span>
          <div>
            <h2 class="text-sm font-black tracking-[-0.02em] text-base-content">Chat network</h2>
            <p class="text-[11px] text-base-content/45">
              Active bot routing and membership by destination
            </p>
          </div>
        </div>

        <span class="inline-flex w-fit items-center rounded-full border border-base-300 bg-base-200/65 px-2.5 py-1 font-mono text-[9px] font-bold uppercase tracking-[0.12em] text-base-content/45">
          {@count} destinations
        </span>
      </div>

      <div
        id="exiron-monitor-chats-stream"
        phx-update="stream"
        class="grid gap-px bg-base-300/70 md:grid-cols-2 xl:grid-cols-3"
      >
        <div
          id="exiron-monitor-chat-empty"
          class="hidden min-h-40 flex-col items-center justify-center bg-base-100 px-5 text-center only:flex md:col-span-2 xl:col-span-3"
        >
          <span class="grid size-11 place-items-center rounded-2xl bg-base-200 text-base-content/35">
            <.icon name="hero-inbox-micro" class="size-5" />
          </span>
          <p class="mt-3 text-sm font-bold">No chats configured</p>
          <p class="mt-1 text-xs text-base-content/45">
            Configured Telegram destinations will appear here.
          </p>
        </div>

        <article
          :for={{id, chat} <- @streams.chats}
          id={id}
          class="ex-monitor-chat-card group"
        >
          <div class="flex items-center justify-between gap-3">
            <div class="flex min-w-0 flex-wrap items-center gap-1.5">
              <span class="grid size-7 flex-none place-items-center rounded-md bg-primary/10 text-primary ring-1 ring-primary/10">
                <.icon name="hero-hashtag-micro" class="size-3.5" />
              </span>
              <span class="mr-1 font-mono text-xs font-black text-base-content">{chat.id}</span>
              <span :if={chat.aliases == []} class="text-[10px] italic text-base-content/35">
                no aliases
              </span>
              <span
                :for={alias <- chat.aliases}
                class="rounded bg-primary/8 px-1.5 py-0.5 font-mono text-[9px] font-bold text-primary ring-1 ring-primary/10"
              >
                {alias}
              </span>
            </div>

            <span
              id={"exiron-monitor-chat-#{chat.id}-polling"}
              class={[
                "ex-status ex-status-compact flex-none",
                chat.polling &&
                  "bg-emerald-500/10 text-emerald-700 ring-1 ring-emerald-500/15 dark:bg-emerald-400/15 dark:text-emerald-300",
                !chat.polling && "bg-base-200 text-base-content/50 ring-1 ring-base-300"
              ]}
            >
              <span class={[
                "size-1.5 rounded-full",
                chat.polling && "bg-emerald-500",
                !chat.polling && "bg-base-content/30"
              ]} />
              {if(chat.polling, do: "polling", else: "not polling")}
            </span>
          </div>

          <div class="mt-2.5 grid grid-cols-2 gap-px overflow-hidden rounded-lg border border-base-300/80 bg-base-300/70 sm:grid-cols-[minmax(0,0.8fr)_minmax(0,0.8fr)_minmax(0,1.4fr)]">
            <div class="min-w-0 bg-base-200/80 px-2.5 py-2">
              <p class="font-mono text-[8px] font-bold uppercase tracking-[0.12em] text-base-content/35">
                Default
              </p>
              <Components.bot_name
                id={"exiron-monitor-chat-#{chat.id}-default-bot"}
                name={chat.default_bot}
              />
            </div>

            <div class="min-w-0 bg-primary/6 px-2.5 py-2">
              <p class="font-mono text-[8px] font-bold uppercase tracking-[0.12em] text-primary/60">
                Current
              </p>
              <Components.bot_name
                id={"exiron-monitor-chat-#{chat.id}-current-bot"}
                name={chat.current_bot}
                current
              />
            </div>

            <div class="col-span-2 min-w-0 bg-base-100 px-2.5 py-2 sm:col-span-1">
              <p class="font-mono text-[8px] font-bold uppercase tracking-[0.12em] text-base-content/35">
                Presence
              </p>
              <div
                id={"exiron-monitor-chat-#{chat.id}-bot-memberships"}
                class="mt-1 flex min-h-4 flex-wrap gap-1"
              >
                <span
                  :if={chat.bot_memberships == []}
                  id={"exiron-monitor-chat-#{chat.id}-membership-empty"}
                  class="text-[10px] text-base-content/40"
                >
                  unknown
                </span>
                <span
                  :for={membership <- chat.bot_memberships}
                  id={membership_dom_id(chat.id, membership)}
                  class={[
                    "ex-status ex-status-compact max-w-full",
                    membership.present &&
                      "bg-emerald-500/10 text-emerald-700 dark:bg-emerald-400/15 dark:text-emerald-300",
                    !membership.present && "bg-base-200 text-base-content/55"
                  ]}
                >
                  <span class={[
                    "size-1.5 flex-none rounded-full",
                    membership.present && "bg-emerald-500",
                    !membership.present && "bg-base-content/25"
                  ]} />
                  <span class="truncate">
                    {membership.bot_name || membership.bot_user_id || "unknown"}: {membership.status}
                  </span>
                </span>
              </div>
            </div>
          </div>
        </article>
      </div>
    </div>
    """
  end

  defp membership_dom_id(chat_id, membership) do
    bot = membership.bot_user_id || membership.bot_name || membership.status || "unknown"
    "exiron-monitor-membership-#{chat_id}-#{bot}"
  end
end
