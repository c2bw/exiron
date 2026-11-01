defmodule Exiron.Hub.PendingRequest do
  @moduledoc false

  alias Exiron.Hub.Message

  @type lifecycle :: :queued | :claimed | :responding

  @type t :: %__MODULE__{
          service_id: term(),
          chat_id: term(),
          instance: term(),
          bot_token: term(),
          bot_name: term(),
          hook: String.t(),
          timer: reference(),
          accepted_at: integer() | nil,
          claimed?: boolean(),
          lifecycle: lifecycle()
        }

  defstruct interaction_context: nil,
            service_id: nil,
            chat_id: nil,
            instance: nil,
            bot_token: nil,
            bot_name: nil,
            hook: nil,
            message_thread_id: nil,
            original_message_id: nil,
            response_reply_to_message_id: nil,
            inline_keyboard: nil,
            callback_buttons: nil,
            origin_keyboard: nil,
            origin_buttons: nil,
            callback_message_id: nil,
            response_message_id: nil,
            delivery_message_ids: [],
            delivered?: false,
            delivery_unknown?: false,
            text_message_ids: [],
            origin_text_ids: [],
            response_bot_token: nil,
            response_bot_name: nil,
            timer: nil,
            accepted_at: nil,
            assigned_client_id: nil,
            assigned_client_transport: nil,
            claimed?: false,
            lifecycle: :queued

  @spec new(Message.t(), String.t(), reference()) :: t()
  def new(%Message{} = message, hook, timer) do
    %__MODULE__{
      service_id: message.service_id,
      chat_id: message.chat_id,
      instance: message.instance,
      bot_token: message.bot_token,
      bot_name: message.bot_name,
      hook: hook,
      message_thread_id: message.message_thread_id,
      original_message_id: message.message_id,
      callback_message_id: if(message.callback_query, do: message.message_id),
      origin_keyboard: message.inline_keyboard,
      origin_buttons: message.callback_buttons,
      origin_text_ids: message.text_message_ids,
      timer: timer,
      accepted_at: System.monotonic_time()
    }
  end

  def claim(%__MODULE__{} = request), do: %{request | claimed?: true, lifecycle: :claimed}
  def unclaim(%__MODULE__{} = request), do: %{request | claimed?: false, lifecycle: :queued}
  def start_response(%__MODULE__{} = request), do: %{request | lifecycle: :responding}
  def clear_response(%__MODULE__{} = request), do: %{request | lifecycle: lifecycle(request)}

  def responding?(%__MODULE__{lifecycle: :responding}), do: true
  def responding?(_request), do: false

  def assigned_to?(%__MODULE__{hook: request_hook}, request_hook), do: true
  def assigned_to?(_request, _hook), do: false

  defp lifecycle(%__MODULE__{claimed?: true}), do: :claimed
  defp lifecycle(_request), do: :queued
end
