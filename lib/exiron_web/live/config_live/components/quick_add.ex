defmodule ExironWeb.ConfigLive.Components.QuickAdd do
  @moduledoc false

  use ExironWeb, :html

  alias ExironWeb.ConfigLive.Components.QuickForm
  alias ExironWeb.ConfigLive.State

  attr :forms, :map, required: true

  def quick_add(assigns) do
    ~H"""
    <div class="ex-panel overflow-hidden shadow-none">
      <div class="border-b border-base-300 px-3 py-2">
        <h3 class="text-xs font-semibold uppercase text-base-content/60">Quick Add</h3>
      </div>

      <.telegram_bot form={@forms.telegram_bot} />
      <.chat_route form={@forms.chat_route} />
      <.middleware_route form={@forms.middleware_route} />
      <.hook form={@forms.hook} />
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  def telegram_bot(assigns) do
    ~H"""
    <QuickForm.quick_form
      form={@form}
      id="exiron-telegram-bot-form"
      event="put_telegram_bot"
      title="Telegram Bot"
      button_id="exiron-apply-telegram-bot"
      icon="hero-plus-micro"
      class="border-b border-base-300 p-3"
    >
      <div class="grid gap-2 sm:grid-cols-2">
        <.input
          field={@form[:bot_token]}
          type="password"
          label="Bot token"
          class={State.compact_input_class()}
        />
        <.input
          field={@form[:bot_name]}
          type="text"
          label="Bot name"
          placeholder="assistant-bot"
          class={State.compact_input_class()}
        />
      </div>

      <div class="grid gap-2 sm:grid-cols-2">
        <.input
          field={@form[:alias]}
          type="text"
          label="Chat alias"
          class={State.compact_input_class()}
        />
        <.input
          field={@form[:chat_id]}
          type="number"
          label="Chat ID"
          class={State.compact_input_class()}
        />
      </div>
    </QuickForm.quick_form>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  def chat_route(assigns) do
    ~H"""
    <QuickForm.quick_form
      form={@form}
      id="exiron-chat-route-form"
      event="put_chat_route"
      title="Chat"
      button_id="exiron-apply-chat-route"
      icon="hero-plus-micro"
      class="border-b border-base-300 p-3"
    >
      <div class="grid gap-2 sm:grid-cols-2">
        <.input field={@form[:alias]} type="text" label="Alias" class={State.compact_input_class()} />
        <.input
          field={@form[:chat_id]}
          type="number"
          label="Chat ID"
          class={State.compact_input_class()}
        />
      </div>

      <.input
        field={@form[:bot_token]}
        type="password"
        label="Bot token"
        class={State.compact_input_class()}
      />
      <.input
        field={@form[:middleware]}
        type="text"
        label="Middleware"
        placeholder="shared, alerts"
        class={State.compact_input_class()}
      />
      <.input field={@form[:push]} type="checkbox" label="Push" />
    </QuickForm.quick_form>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  def middleware_route(assigns) do
    ~H"""
    <QuickForm.quick_form
      form={@form}
      id="exiron-middleware-route-form"
      event="put_middleware_route"
      title="Middleware Route"
      button_id="exiron-apply-middleware-route"
      icon="hero-plus-micro"
      class="border-b border-base-300 p-3"
    >
      <div class="grid gap-2 sm:grid-cols-2">
        <.input
          field={@form[:middleware]}
          type="text"
          label="Middleware"
          class={State.compact_input_class()}
        />
        <.input field={@form[:hook]} type="text" label="Hook" class={State.compact_input_class()} />
      </div>

      <.input
        field={@form[:messages]}
        type="text"
        label="Messages"
        placeholder="/ask, /status"
        class={State.compact_input_class()}
      />
      <.input field={@form[:passthrough]} type="checkbox" label="Passthrough" />
    </QuickForm.quick_form>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  def hook(assigns) do
    ~H"""
    <QuickForm.quick_form
      form={@form}
      id="exiron-hook-form"
      event="put_hook"
      title="Hook"
      button_id="exiron-apply-hook"
      icon="hero-key-micro"
      class="p-3"
    >
      <div class="grid gap-2 sm:grid-cols-2">
        <.input field={@form[:hook]} type="text" label="Name" class={State.compact_input_class()} />
        <.input
          field={@form[:token]}
          type="password"
          label="Token"
          class={State.compact_input_class()}
        />
      </div>
    </QuickForm.quick_form>
    """
  end
end
