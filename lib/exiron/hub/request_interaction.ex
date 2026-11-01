defmodule Exiron.Hub.RequestInteraction do
  @moduledoc false
  alias Exiron.Hub.{
    InlineKeyboard,
    InteractionPolicy,
    Message,
    RequestCancellation,
    RequestControl,
    SendCommand,
    Transition
  }

  def controls(%{from: %{id: user}} = message, route, id) when is_integer(user) and user > 0 do
    if InteractionPolicy.enabled?(route, "request_controls") do
      card =
        Message.outgoing(
          message.service_id,
          message.chat_id,
          "text",
          "Request accepted by #{route.to}. Use Status for progress or Cancel to stop.",
          message.bot_token,
          bot_name: message.bot_name,
          message_thread_id: message.message_thread_id,
          reply_to_message_id: message.message_id,
          parse_mode: "plain",
          inline_keyboard: [
            [
              %{text: "Status", callback_data: "status"},
              %{text: "Cancel", callback_data: "cancel"}
            ]
          ]
        )
        |> InlineKeyboard.prepare(id)

      buttons =
        Map.new(card.callback_buttons, fn {ref, binding} ->
          {ref,
           Map.merge(binding, %{
             product_action: binding.data,
             user_id: user,
             prefixes: route.messages
           })}
        end)

      [SendCommand.background(:interaction, route.to, %{card | callback_buttons: buttons})]
    else
      []
    end
  end

  def controls(_, _, _), do: []

  def control?(state, token, query) do
    case InlineKeyboard.lookup(state, token, query) do
      {:ok, %{product_action: action}} when action in ["status", "cancel"] -> true
      _ -> false
    end
  end

  def handle(state, binding, from) do
    with %{id: user} <- from,
         true <-
           Enum.any?(state.router.routes, fn route ->
             route.to == binding.hook and route.chat_id == elem(binding.target, 1) and
               Enum.all?(binding.prefixes, &(&1 in route.messages)) and
               InteractionPolicy.enabled?(route, "request_controls") and
               (user == binding.user_id or Exiron.Hub.AccessPolicy.admin?(route, from))
           end) do
      case binding.product_action do
        "status" ->
          Transition.reply(state, {:ok, status(state, binding.origin_req_id, binding.hook)})

        "cancel" ->
          transition = RequestCancellation.cancel(state, binding.origin_req_id, binding.hook)

          case transition.reply do
            {:ok, _} ->
              Transition.reply(
                transition,
                {:ok, "Request cancelled. Earlier sends may already have completed."}
              )

            _ ->
              Transition.reply(transition, {:error, :unavailable})
          end

        _ ->
          Transition.reply(state, {:error, :unavailable})
      end
    else
      _ -> Transition.reply(state, {:error, :unavailable})
    end
  end

  defp status(state, id, hook) do
    case Map.get(state.delivery.pending, id) do
      %{lifecycle: :responding} ->
        "Sending a reply."

      %{response_message_id: message_id} when is_integer(message_id) ->
        "Reply in progress."

      %{claimed?: true} ->
        "Delivered to worker; waiting for its reply."

      %{} ->
        "Waiting for worker."

      nil ->
        case RequestControl.snapshot(state, hook, id) do
          {:ok, %{state: "completed"}} -> "Request completed."
          {:ok, %{state: "cancelled"}} -> "Request cancelled."
          {:ok, %{state: "expired"}} -> "Request expired."
          _ -> "Request is no longer active."
        end
    end
  end
end
