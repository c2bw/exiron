defmodule Exiron.Hub.ManualMessages do
  @moduledoc false
  alias Exiron.Hub.{
    Drain,
    Effect,
    Idempotency,
    Identifier,
    Message,
    SendCommand,
    SendTasks,
    Telegram,
    Transition
  }

  @preview_lifetime :timer.minutes(10)

  def targets(%{enabled?: true, router: router, telegram: %Telegram{} = telegram}) do
    for route <- router.routes,
        route.push,
        bot <- Telegram.configs(telegram),
        bot.chat_id == route.chat_id do
      identity =
        {route.to, route.service_id, route.chat_id, bot.bot_token, Map.get(bot, :bot_name)}

      id = :crypto.hash(:sha256, :erlang.term_to_binary(identity)) |> Base.encode16(case: :lower)

      %{
        id: id,
        hook: route.to,
        service_id: route.service_id,
        chat_id: route.chat_id,
        chat_alias: route.chat_alias,
        bot_name: Map.get(bot, :bot_name),
        label:
          "#{route.to} · #{route.chat_alias} (#{route.chat_id}) · #{Map.get(bot, :bot_name) || "Unnamed bot #{String.slice(id, 0, 6)}"}"
      }
    end
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.label)
  end

  def targets(_), do: []

  def preview(state, params) when is_map(params) do
    with target when not is_nil(target) <- Enum.find(targets(state), &(&1.id == params["target"])),
         text when is_binary(text) <- params["text"],
         {:ok, datatype, attachment} <- payload(params, text),
         {:ok, topic} <- topic(params["topic"]) do
      {:ok,
       %{
         key: "manual-" <> Identifier.new(),
         target: target,
         text: text,
         datatype: datatype,
         attachment: attachment,
         topic: topic,
         previewed_at: System.monotonic_time(:millisecond)
       }}
    else
      _ -> {:error, :invalid_draft}
    end
  end

  def preview(_, _), do: {:error, :invalid_draft}

  def send(state, from, draft) do
    with %{key: key, target: %{id: id}, text: text, topic: topic, previewed_at: at} <- draft,
         true <- is_nil(topic) or is_integer(topic),
         true <-
           is_integer(at) and (System.monotonic_time(:millisecond) - at) in 0..@preview_lifetime,
         {:ok, current} <-
           preview(state, %{
             "target" => id,
             "text" => text,
             "datatype" => Map.get(draft, :datatype, "text"),
             "attachment" => Map.get(draft, :attachment),
             "topic" => if(topic, do: to_string(topic), else: "")
           }) do
      target = current.target

      attachment_identity =
        if current.attachment,
          do:
            {:crypto.hash(:sha256, current.attachment.data), current.attachment.file_name,
             current.attachment.mime_type}

      Idempotency.run(
        state,
        target.hook,
        key,
        {:manual, id, text, topic, current.datatype, attachment_identity},
        from,
        fn state ->
          admit(state, from, current)
        end
      )
    else
      _ -> Transition.reply(state, {:error, :stale_draft})
    end
  end

  defp admit(state, from, draft) do
    target = draft.target

    {data, opts} =
      if draft.attachment do
        {draft.attachment.data,
         [
           file_name: draft.attachment.file_name,
           mime_type: draft.attachment.mime_type,
           caption: draft.text
         ]}
      else
        {draft.text, []}
      end

    opts =
      Keyword.merge(opts,
        bot_name: target.bot_name,
        message_thread_id: draft.topic,
        parse_mode: "plain"
      )

    bytes = Exiron.Hub.SendBudget.payload_bytes(data, opts)

    with :ok <- Drain.admit(state),
         :ok <- Exiron.Hub.MessageMetadata.validate(draft.datatype, data, opts),
         {:ok, state} <- SendTasks.admit(state, target.hook, bytes) do
      bot =
        Enum.find(Telegram.configs(state.telegram), fn bot ->
          identity =
            {target.hook, target.service_id, target.chat_id, bot.bot_token,
             Map.get(bot, :bot_name)}

          Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(identity)), case: :lower) ==
            target.id and bot.chat_id == target.chat_id
        end)

      # A registry with only the reviewed bot prevents automatic fallback to a
      # different bot after a rejection. Normal worker pushes retain fallback.
      telegram = %{state.telegram | bots: Exiron.Hub.Telegram.BotRegistry.new([bot])}

      message =
        Message.outgoing(
          target.service_id,
          target.chat_id,
          draft.datatype,
          data,
          bot.bot_token,
          opts
        )

      command = %{SendCommand.push(from, target.hook) | payload_bytes: bytes}

      Transition.new(state,
        effects: [
          Effect.start_send(
            from,
            command,
            fn ->
              case Telegram.send_message(telegram, message) do
                {:ok, sent} -> {:ok, [sent]}
                error -> error
              end
            end,
            state
          )
        ]
      )
    else
      {:error, reason, state} -> Transition.reply(state, {:error, reason})
      error -> Transition.reply(state, error)
    end
  end

  defp payload(params, text) do
    case Map.get(params, "datatype", "text") do
      "text" ->
        if valid_text?(text) and is_nil(params["attachment"]),
          do: {:ok, "text", nil},
          else: {:error, :invalid_draft}

      datatype when datatype in ["image", "file"] ->
        with true <-
               String.valid?(text) and byte_size(text) <= 4096 and
                 Exiron.Hub.Telegram.TextSplitter.units(text) <= 1024,
             {:ok, attachment} <-
               Exiron.Hub.ManualAttachment.validate(datatype, params["attachment"]) do
          {:ok, datatype, attachment}
        else
          _ -> {:error, :invalid_draft}
        end

      _ ->
        {:error, :invalid_draft}
    end
  end

  defp valid_text?(text),
    do:
      String.valid?(text) and byte_size(text) <= 16_384 and String.trim(text) != "" and
        Exiron.Hub.Telegram.TextSplitter.units(text) <= 4096

  defp topic(value) when value in [nil, ""], do: {:ok, nil}

  defp topic(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 and id <= 2_147_483_647 -> {:ok, id}
      _ -> :error
    end
  end

  defp topic(_), do: :error
end
