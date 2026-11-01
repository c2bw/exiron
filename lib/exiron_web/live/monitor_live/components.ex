defmodule ExironWeb.MonitorLive.Components do
  @moduledoc false

  use ExironWeb, :html

  attr :id, :string, default: nil
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :detail, :string, required: true
  attr :icon, :string, required: true
  attr :alert, :boolean, default: false
  attr :live, :boolean, default: false

  def monitor_stat(assigns) do
    ~H"""
    <div id={@id} class="ex-monitor-stat">
      <span class={[
        "relative grid size-8 place-items-center rounded-lg",
        @alert && "bg-rose-400/12 text-rose-300",
        !@alert && "bg-white/6 text-emerald-300/75"
      ]}>
        <span
          :if={@live}
          class="absolute right-0.5 top-0.5 size-1.5 rounded-full bg-emerald-300 ring-2 ring-[#172721]"
        />
        <.icon name={@icon} class="size-4" />
      </span>
      <div class="min-w-0">
        <p class="font-mono text-[8px] font-bold uppercase tracking-[0.14em] text-white/35">
          {@label}
        </p>
        <p class="mt-0.5 flex items-baseline gap-1.5">
          <span class="text-xl font-black tracking-[-0.04em] text-white">{@value}</span>
          <span class={[
            "hidden truncate text-[10px] sm:inline",
            @alert && "text-rose-300/70",
            !@alert && "text-white/35"
          ]}>
            {@detail}
          </span>
        </p>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, default: nil
  attr :current, :boolean, default: false

  def bot_name(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "mt-1 block truncate text-[11px] font-bold",
        @current && "text-primary",
        !@current && "text-base-content/70"
      ]}
    >
      {if(@name in [nil, ""], do: "unknown", else: @name)}
    </span>
    """
  end
end
