defmodule Exiron.Hub.GuidedCommands do
  @moduledoc false
  alias Exiron.Hub.{
    Message,
    Router,
    InteractionPolicy,
    AccessPolicy,
    IncomingDeduplicator,
    SendCommand,
    SendTasks,
    Transition
  }

  @limit 500
  @ttl :timer.minutes(5)

  def prompt(state, binding, message) do
    case IncomingDeduplicator.remember(state, message) do
      {:duplicate, state} ->
        Transition.reply(state, {:ok, "Reply to the input prompt."})

      {:new, state} ->
        prompt =
          Message.outgoing(
            message.service_id,
            message.chat_id,
            "text",
            "Reply to this message with the text for #{binding.command}. This prompt is for you and expires in five minutes.",
            message.bot_token,
            bot_name: message.bot_name,
            message_thread_id: message.message_thread_id,
            reply_to_message_id: Map.get(binding, :input_reply_to),
            parse_mode: "plain"
          )

        prompt = %{
          prompt
          | force_reply?: true,
            command_prompt: %{
              command: binding.command,
              hook: binding.command_hook,
              user_id: binding.user_id
            }
        }

        state
        |> SendTasks.start_background_sends([
          SendCommand.background(:interaction, binding.command_hook, prompt)
        ])
        |> Transition.reply({:ok, "Reply to the input prompt."})
    end
  end

  def remember(state, %{command_prompt: %{} = prompt, message_id: id, bot_token: token} = message)
      when is_integer(id) and id > 0 and is_binary(token) do
    key = key(message, id)
    order = [key | List.delete(state.delivery.command_prompt_order, key)] |> Enum.take(@limit)

    record =
      Map.merge(prompt, %{
        thread: message.message_thread_id,
        expires: now() + @ttl,
        consumed?: false
      })

    delivery = %{
      state.delivery
      | command_prompts:
          state.delivery.command_prompts |> Map.put(key, record) |> Map.take(order),
        command_prompt_order: order
    }

    %{state | delivery: delivery}
  end

  def remember(state, _), do: state

  def resolve(state, message) do
    # Typed commands always keep their existing routing, including unknown ones.
    if String.starts_with?(String.trim_leading(Message.text(message)), "/") do
      :skip
    else
      resolve_reply(state, message)
    end
  end

  defp resolve_reply(state, %{reply_to_message_id: id, bot_token: token} = message)
       when is_integer(id) and is_binary(token) do
    key = key(message, id)

    case Map.get(state.delivery.command_prompts, key) do
      nil ->
        :skip

      prompt ->
        with %{id: user} <- message.from,
             true <- user == prompt.user_id and message.message_thread_id == prompt.thread,
             true <- not prompt.consumed? and now() < prompt.expires,
             true <- message.datatype == "text" and String.trim(message.data) != "",
             {:ok, route} <- Router.match(state.router, %{message | data: prompt.command}),
             true <- route.to == prompt.hook and InteractionPolicy.enabled?(route, "help"),
             true <- AccessPolicy.allowed?(route, message.from) do
          {:ok, route,
           %{
             message
             | data: prompt.command <> " " <> message.data,
               entities: nil,
               guided_prompt_key: key
           }}
        else
          _ -> :blocked
        end
    end
  end

  defp resolve_reply(_, _), do: :skip

  def consume(state, %{guided_prompt_key: nil}), do: state

  def consume(state, %{guided_prompt_key: key}) do
    update_in(state.delivery.command_prompts[key], &Map.put(&1, :consumed?, true))
  end

  defp key(message, id),
    do: {:crypto.hash(:sha256, message.bot_token), message.service_id, message.chat_id, id}

  defp now, do: System.monotonic_time(:millisecond)
end
