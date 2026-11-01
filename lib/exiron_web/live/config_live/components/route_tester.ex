defmodule ExironWeb.ConfigLive.Components.RouteTester do
  @moduledoc false

  use ExironWeb, :html

  alias ExironWeb.ConfigLive.State
  alias ExironWeb.ConfigLive.RouteTesting

  attr :config, :map, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :result, :any, required: true

  def route_tester(assigns) do
    assigns = assign(assigns, :mode, RouteTesting.route_tester_mode(assigns.form))

    ~H"""
    <section class="ex-panel mb-3 overflow-hidden">
      <div class="border-b border-base-300 bg-base-200/35 px-4 py-3">
        <div class="flex items-center justify-between gap-3">
          <div class="flex min-w-0 items-center gap-2.5">
            <span class="grid size-7 place-items-center rounded-md bg-primary/10 text-primary">
              <.icon name="hero-beaker-micro" class="size-4" />
            </span>

            <h2 class="text-xs font-bold tracking-tight">Route tester</h2>
          </div>
          <.route_tester_status_badge result={@result} />
        </div>
      </div>

      <.form
        for={@form}
        id="exiron-route-tester-form"
        phx-change="test_route"
        class="grid gap-x-3 gap-y-1 p-4 sm:grid-cols-2"
      >
        <.input
          field={@form[:mode]}
          type="select"
          label="Mode"
          options={RouteTesting.route_tester_mode_options()}
          class={State.compact_input_class()}
        />
        <.input
          :if={@mode != "push"}
          field={@form[:chat_alias]}
          type="select"
          label="Chat"
          options={RouteTesting.route_tester_options(@config)}
          class={State.compact_input_class()}
        />
        <.input
          :if={@mode == "push"}
          field={@form[:hook]}
          type="select"
          label="Hook"
          options={RouteTesting.route_tester_hook_options(@config)}
          class={State.compact_input_class()}
        />
        <div :if={@mode != "push"} class="sm:col-span-2">
          <.input
            field={@form[:message]}
            type="text"
            label="Fake message"
            placeholder="/ai hello"
            class={State.compact_input_class()}
          />
        </div>
        <.input :if={@mode == "push"} field={@form[:chat_alias]} type="hidden" />
        <.input :if={@mode == "push"} field={@form[:message]} type="hidden" />
        <.input :if={@mode != "push"} field={@form[:hook]} type="hidden" />
      </.form>

      <div class="px-4 pb-4"><.route_tester_targets result={@result} /></div>
    </section>
    """
  end

  attr :result, :any, required: true

  defp route_tester_targets(assigns) do
    ~H"""
    <div
      :if={@result.status in [:push_match, :push_miss]}
      id="exiron-route-tester-targets"
      class="mt-3 rounded-md border border-base-300 bg-base-200/50 p-2"
    >
      <div
        :if={Map.get(@result, :targets, []) == []}
        class="px-1 py-0.5 text-sm text-base-content/55"
      >
        No push-enabled groups for this hook.
      </div>

      <div :if={Map.get(@result, :targets, []) != []} class="flex flex-wrap gap-1.5">
        <span
          :for={target <- @result.targets}
          class="rounded bg-emerald-500/10 px-1.5 py-0.5 font-mono text-xs text-emerald-700 dark:bg-emerald-400/15 dark:text-emerald-300"
        >
          {target.chat_alias} ({target.chat_id})
        </span>
      </div>
    </div>
    """
  end

  attr :result, :any, required: true

  def route_tester_status_badge(assigns) do
    ~H"""
    <span id="exiron-route-tester-status" class={RouteTesting.route_tester_status_class(@result)}>
      {RouteTesting.route_tester_status_text(@result)}
    </span>
    """
  end
end
