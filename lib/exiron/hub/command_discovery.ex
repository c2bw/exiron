defmodule Exiron.Hub.CommandDiscovery do
  @moduledoc false
  alias Exiron.Hub.{InteractionPolicy, Message, InlineKeyboard, Router, Transition}

  def response(router, message, :error) do
    if help?(message) do
      routes =
        Enum.filter(router.routes, fn route ->
          route.service_id == message.service_id and route.chat_id == message.chat_id and
            InteractionPolicy.enabled?(route, "help") and
            Exiron.Hub.AccessPolicy.allowed?(route, message.from)
        end)

      if routes != [] do
        entries =
          routes
          |> Enum.take(20)
          |> Enum.map(fn route ->
            policy = route.interaction

            commands =
              route.messages |> Enum.take(8) |> Enum.map_join(", ", &String.slice(&1, 0, 80))

            [commands, Map.get(policy, "description"), example(policy)]
            |> Enum.reject(&is_nil/1)
            |> Enum.join("\n")
          end)

        text =
          ["Commands available in this chat" | entries]
          |> Enum.join("\n\n")
          |> String.slice(0, 3500)

        Message.outgoing(message.service_id, message.chat_id, "text", text, message.bot_token,
          bot_name: message.bot_name,
          message_thread_id: message.message_thread_id,
          reply_to_message_id: message.message_id,
          parse_mode: "plain"
        )
        |> command_buttons(message, routes)
      end
    end
  end

  def response(_, _, _), do: nil

  defp command_buttons(card, %{from: %{id: user}}, routes) when is_integer(user) and user > 0 do
    choices =
      for route <- routes,
          command <- route.messages,
          Regex.match?(~r"^/[A-Za-z0-9_]{1,32}$", command),
          do: {command, route.to}

    choices = choices |> Enum.uniq_by(&elem(&1, 0)) |> Enum.take(20)

    if choices == [] do
      card
    else
      indexed =
        choices
        |> Enum.with_index()
        |> Enum.flat_map(fn {{command, hook}, index} ->
          Enum.map([{"run", "command"}, {"write", "command_input"}], fn {kind, action} ->
            {"#{kind}-#{index}",
             %{
               command: command,
               command_hook: hook,
               user_id: user,
               product_action: action,
               input_reply_to: card.reply_to_message_id
             }}
          end)
        end)
        |> Map.new()

      keyboard =
        choices
        |> Enum.with_index()
        |> Enum.map(fn {{command, _}, index} ->
          [
            %{text: "Run " <> command, callback_data: "run-#{index}"},
            %{text: "Write " <> command, callback_data: "write-#{index}"}
          ]
        end)

      card =
        %{
          card
          | data:
              card.data <>
                "\n\nRun sends a command without arguments. Write asks for your message in a reply prompt.",
            inline_keyboard: keyboard
        }
        |> InlineKeyboard.prepare(nil)

      buttons =
        Map.new(card.callback_buttons, fn {ref, binding} ->
          {ref, Map.merge(binding, Map.fetch!(indexed, binding.data))}
        end)

      %{card | callback_buttons: buttons}
    end
  end

  defp command_buttons(card, _, _), do: card

  def select(state, binding, token, query) do
    from = query.from

    message =
      Message.incoming(
        Exiron.Hub.Telegram.service_id(),
        elem(binding.target, 1),
        "text",
        binding.command,
        bot_token: token,
        bot_name: binding.bot_name,
        message_id: elem(binding.target, 2),
        message_thread_id: binding.message_thread_id,
        from: from,
        callback_query: %{id: query.id, origin_req_id: nil}
      )

    with %{id: user} <- from,
         true <- user == binding.user_id,
         {:ok, route} <- Router.match(state.router, message),
         true <- route.to == binding.command_hook,
         true <- InteractionPolicy.enabled?(route, "help"),
         true <- Exiron.Hub.AccessPolicy.allowed?(route, from) do
      if binding.product_action == "command_input" do
        Exiron.Hub.GuidedCommands.prompt(state, binding, message)
      else
        state
        |> Exiron.Hub.IncomingMessages.handle(message)
        |> Transition.reply({:ok, "Selected " <> binding.command <> "."})
      end
    else
      _ -> Transition.reply(state, {:error, :unavailable})
    end
  end

  defp example(%{"example" => example}), do: "Example: " <> example
  defp example(_), do: nil

  defp help?(%{datatype: "text", data: text, bot_name: name}) do
    case Regex.run(~r{^/help(?:@([A-Za-z0-9_]+))?\s*$}, text) do
      [_] ->
        true

      [_, ""] ->
        true

      [_, addressed] when is_binary(name) ->
        String.downcase(addressed) == String.downcase(String.trim_leading(name, "@"))

      _ ->
        false
    end
  end

  defp help?(_), do: false
end
