defmodule Exiron.Hub.DeliveryState do
  @moduledoc false

  alias Exiron.Hub.{ClientSession, PendingRequest, QueueBuffer, SendTask}

  defstruct command_prompts: %{},
            command_prompt_order: [],
            send_byte_rejections: 0,
            buffer_rejections: %{requests: 0, listeners: 0},
            expirations: %{},
            expiration_order: [],
            diagnostics: %{},
            diagnostic_order: [],
            cancellations: %{},
            cancellation_order: [],
            callback_bindings: %{},
            callback_order: [],
            replies: %{},
            reply_order: [],
            queues: %{},
            clients: %{},
            client_presence: %{},
            pending: %{},
            sends: %{}

  @type t :: %__MODULE__{
          queues: %{optional(String.t()) => QueueBuffer.t()},
          clients: %{optional(String.t()) => ClientSession.t()},
          pending: %{optional(String.t()) => PendingRequest.t()},
          sends: %{optional(reference()) => SendTask.t()}
        }
end
