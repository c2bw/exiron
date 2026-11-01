defmodule Exiron.Hub.ConversationRouting do
  @moduledoc false
  alias Exiron.Hub.{InteractionPolicy, Message, Router}
  @lifetime_ms :timer.hours(24)

  def context(_message, nil), do: nil

  def context(message, route) do
    %{
      followups?: InteractionPolicy.enabled?(route, "followups"),
      prefixes: route.messages,
      owner:
        case message.from do
          %{id: id} -> id
          _ -> nil
        end,
      accepted_at: System.monotonic_time(:millisecond)
    }
  end

  def resolve(state, message) do
    message = %{message | followup_req_id: nil}

    case Router.match(state.router, message) do
      :error ->
        case followup(state, message) do
          {:ok, route, id} -> {{:ok, route}, %{message | followup_req_id: id}}
          :error -> {:error, message}
        end

      matched ->
        {matched, message}
    end
  end

  defp followup(state, message) do
    # Explicit commands, including unknown commands, never inherit a destination.
    if String.starts_with?(String.trim_leading(Message.text(message)), "/") do
      :error
    else
      Enum.find_value(state.delivery.replies, :error, fn {id, receipt} ->
        with %{followups?: true, prefixes: prefixes, accepted_at: accepted} <-
               Map.get(receipt, :interaction_context),
             true <- System.monotonic_time(:millisecond) - accepted < @lifetime_ms,
             true <-
               receipt.service_id == message.service_id and receipt.chat_id == message.chat_id,
             true <- receipt.bot_token == message.bot_token and is_binary(message.bot_token),
             true <- receipt.message_thread_id == message.message_thread_id,
             reply when is_integer(reply) <- message.reply_to_message_id,
             true <-
               reply in [
                 receipt.message_id
                 | receipt.text_message_ids ++ Map.get(receipt, :media_message_ids, [])
               ],
             :ok <- Exiron.Hub.RequestCancellation.check(state, id, receipt.hook),
             route when not is_nil(route) <-
               Enum.find(state.router.routes, fn route ->
                 route.to == receipt.hook and route.service_id == message.service_id and
                   route.chat_id == message.chat_id and
                   Enum.all?(prefixes, &(&1 in route.messages)) and
                   InteractionPolicy.enabled?(route, "followups")
               end) do
          {:ok, route, id}
        else
          _ -> false
        end
      end)
    end
  end
end
