defmodule Exiron.Hub.IncomingMessages do
  @moduledoc false

  alias Exiron.Hub.{
    Dispatch,
    Effect,
    IncomingDeduplicator,
    Message,
    Runtime,
    SendTasks,
    State,
    Transition
  }

  @spec handle(State.t(), Message.t()) :: Transition.t()
  def handle(state, %Message{} = message) do
    case IncomingDeduplicator.remember(state, message) do
      {:duplicate, state} ->
        Transition.reply(state, :ok)

      {:new, state} ->
        {state, events, sends} =
          Dispatch.incoming_service_message(state, message,
            pending_timeout: state.settings.pending_timeout
          )

        state
        |> Runtime.record_events(events)
        |> SendTasks.start_background_sends(sends)
        |> Transition.reply(:ok)
        |> Transition.effect(Effect.deliver_socket_queues())
        |> Transition.effect(Effect.broadcast_status())
    end
  end
end
