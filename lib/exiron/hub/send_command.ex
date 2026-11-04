defmodule Exiron.Hub.SendCommand do
  @moduledoc false

  @type kind :: :respond | :edit | :action | :push | :unavailable | :overloaded | :interaction

  @type t :: %__MODULE__{
          payload_bytes: non_neg_integer(),
          kind: kind(),
          from: GenServer.from() | nil,
          request_id: String.t() | nil,
          pending: term() | nil,
          hook: String.t() | nil,
          message: Exiron.Hub.Message.t() | nil
        }

  defstruct payload_bytes: 0,
            return_diagnostics?: false,
            return_receipts?: false,
            kind: nil,
            from: nil,
            request_id: nil,
            pending: nil,
            hook: nil,
            message: nil

  @spec respond(GenServer.from(), String.t(), term(), String.t(), Exiron.Hub.Message.t()) :: t()
  def respond(from, request_id, pending, hook, message) do
    %__MODULE__{
      kind: :respond,
      payload_bytes: Exiron.Hub.SendBudget.payload_bytes(message.data, []),
      from: from,
      request_id: request_id,
      pending: pending,
      hook: hook,
      message: message
    }
  end

  @spec push(GenServer.from() | nil, String.t()) :: t()
  def push(from, hook), do: %__MODULE__{kind: :push, from: from, hook: hook}

  @spec background(:unavailable | :overloaded | :interaction, String.t(), Exiron.Hub.Message.t()) ::
          t()
  def background(kind, hook, message) when kind in [:unavailable, :overloaded, :interaction] do
    %__MODULE__{
      kind: kind,
      hook: hook,
      message: message,
      payload_bytes: Exiron.Hub.SendBudget.payload_bytes(message.data, [])
    }
  end
end
