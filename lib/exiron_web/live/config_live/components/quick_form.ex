defmodule ExironWeb.ConfigLive.Components.QuickForm do
  @moduledoc false

  use ExironWeb, :html

  attr :form, Phoenix.HTML.Form, required: true
  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :title, :string, required: true
  attr :button_id, :string, required: true
  attr :icon, :string, required: true
  attr :class, :string, required: true
  slot :inner_block, required: true

  def quick_form(assigns) do
    ~H"""
    <.form for={@form} id={@id} phx-submit={@event} class={@class}>
      <div class="mb-2 flex items-center justify-between gap-2">
        <h4 class="text-xs font-medium text-base-content/70">{@title}</h4>

        <button
          id={@button_id}
          type="submit"
          class="inline-flex items-center gap-1 rounded-md border border-base-300 px-2 py-1 text-xs font-medium transition hover:border-primary/60 hover:bg-base-200 hover:text-primary"
        >
          <.icon name={@icon} class="size-4" /> Apply
        </button>
      </div>
      {render_slot(@inner_block)}
    </.form>
    """
  end
end
