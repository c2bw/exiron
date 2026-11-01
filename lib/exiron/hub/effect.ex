defmodule Exiron.Hub.Effect do
  @moduledoc false

  defstruct [:kind, :payload]

  @type t :: %__MODULE__{kind: atom(), payload: term()}

  @spec reply(GenServer.from(), term()) :: t()
  def reply(from, value), do: %__MODULE__{kind: :reply, payload: {from, value}}

  @spec broadcast_status() :: t()
  def broadcast_status, do: %__MODULE__{kind: :broadcast_status, payload: nil}

  @spec deliver_socket_queues() :: t()
  def deliver_socket_queues, do: %__MODULE__{kind: :deliver_socket_queues, payload: nil}

  @spec cancel_timer(term()) :: t()
  def cancel_timer(timer), do: %__MODULE__{kind: :cancel_timer, payload: timer}

  @spec start_send(GenServer.from() | nil, Exiron.Hub.SendCommand.t(), (-> term()), map(), term()) ::
          t()
  def start_send(from, command, task, failure_state, failure_reply \\ :auto) do
    %__MODULE__{
      kind: :start_send,
      payload: %{
        from: from,
        command: command,
        task: task,
        failure_state: failure_state,
        failure_reply: failure_reply
      }
    }
  end

  @spec terminate_task(pid()) :: t()
  def terminate_task(pid), do: %__MODULE__{kind: :terminate_task, payload: pid}

  @spec schedule(term(), pos_integer()) :: t()
  def schedule(message, delay_ms),
    do: %__MODULE__{kind: :schedule, payload: {message, max(delay_ms, 1)}}
end
