defmodule ExironWeb.ConfigLive.Components.DetailsSupport do
  @moduledoc false

  use ExironWeb, :html

  attr :title, :string, required: true
  attr :meta, :string, required: true

  def section_title(assigns) do
    ~H"""
    <div class="ex-section-head">
      <h2 class="ex-kicker shrink-0">{@title}</h2>
      <span class="order-last shrink-0 font-mono text-[10px] font-medium text-base-content/55">
        {@meta}
      </span>
    </div>
    """
  end

  attr :push, :boolean, required: true

  def push_badge(assigns) do
    ~H"""
    <span class={[
      "shrink-0 rounded-full px-2 py-0.5 text-xs font-medium",
      @push && "bg-emerald-500/10 text-emerald-700 dark:bg-emerald-400/15 dark:text-emerald-300",
      !@push && "bg-base-200 text-base-content/70"
    ]}>
      {if(@push, do: "push", else: "request")}
    </span>
    """
  end

  attr :items, :list, required: true
  attr :empty, :string, required: true
  attr :color, :string, default: "base"

  def tag_list(assigns) do
    ~H"""
    <div class="mt-1.5 flex flex-wrap items-center gap-1.5">
      <span :for={item <- @items} class={tag_class(@color)}>{item}</span>
      <span
        :if={@items == []}
        class="rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/65"
      >
        {@empty}
      </span>
    </div>
    """
  end

  def plural(1, singular, _plural), do: singular
  def plural(_count, _singular, plural), do: plural

  defp tag_class("sky"),
    do:
      "rounded bg-sky-500/10 px-1.5 py-0.5 font-mono text-xs text-sky-700 dark:bg-sky-400/15 dark:text-sky-300"

  defp tag_class("violet"),
    do:
      "rounded bg-violet-500/10 px-1.5 py-0.5 font-mono text-xs text-violet-700 dark:bg-violet-400/15 dark:text-violet-300"

  defp tag_class(_color), do: "rounded bg-base-200 px-1.5 py-0.5 font-mono text-xs"
end
