defmodule ExironWeb.ConfigLive.Components.PageHeader do
  @moduledoc false

  use ExironWeb, :html

  alias ExironWeb.ConfigLive.State
  alias ExironWeb.ConfigLive.Components.Stats

  attr :route_configuration, :any, required: true

  def page_header(assigns) do
    ~H"""
    <section class="ex-config-hero">
      <div class="flex min-w-0 items-center justify-between gap-4 px-4 py-3.5 sm:px-5">
        <div class="flex min-w-0 items-center gap-3">
          <span class="grid size-9 shrink-0 place-items-center rounded-lg border border-white/10 bg-white/[0.07] text-emerald-300 shadow-inner">
            <.icon name="hero-adjustments-horizontal" class="size-4.5" />
          </span>
          <div class="min-w-0">
            <div class="flex items-baseline gap-2">
              <h1 class="text-xl font-black tracking-[-0.035em] text-white sm:text-2xl">
                Configuration
              </h1>
              <span class="hidden font-mono text-[8px] font-bold uppercase tracking-[0.18em] text-emerald-300/80 sm:inline">
                live workspace
              </span>
            </div>
            <p
              id="exiron-config-path"
              class="mt-0.5 truncate font-mono text-[10px] text-white/40 sm:text-xs"
            >
              {State.route_path(@route_configuration)}
            </p>
          </div>
        </div>

        <.link
          navigate={~p"/"}
          class="inline-flex h-8 shrink-0 items-center gap-1.5 rounded-lg border border-white/10 bg-white/[0.06] px-2.5 text-[11px] font-bold text-white/65 transition hover:border-emerald-300/30 hover:bg-emerald-300/10 hover:text-emerald-200"
        >
          <.icon name="hero-arrow-left-micro" class="size-3.5" />
          <span class="hidden sm:inline">Dashboard</span>
        </.link>
      </div>

      <%= case @route_configuration do %>
        <% {:ok, config} -> %>
          <Stats.stats_strip config={config} />
        <% _error -> %>
          <div class="border-t border-white/[0.08] px-4 py-2 font-mono text-[10px] uppercase tracking-[0.14em] text-rose-300/80 sm:px-5">
            Configuration unavailable
          </div>
      <% end %>
    </section>
    """
  end
end
