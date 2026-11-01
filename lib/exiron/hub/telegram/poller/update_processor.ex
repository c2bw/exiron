defmodule Exiron.Hub.Telegram.Poller.UpdateProcessor do
  @moduledoc false

  require Logger

  alias Exiron.Hub.Message
  alias Exiron.Hub.Telegram
  alias Exiron.Hub.Telegram.{FileDownloader, MembershipEvent, MessageParser}

  @transient_http_statuses [408, 425, 429]

  def prioritize_callbacks(state, updates) do
    Enum.reduce(updates, state, fn
      %{callback_query: query, update_id: id} = update, state when is_map(query) ->
        if MapSet.member?(state.processed_callbacks, id) do
          state
        else
          case process_update(state, update) do
            :ok ->
              %{
                state
                | processed_callbacks:
                    state.processed_callbacks
                    |> MapSet.put(id)
                    |> Enum.sort(:desc)
                    |> Enum.take(1000)
                    |> MapSet.new()
              }

            _ ->
              state
          end
        end

      _, state ->
        state
    end)
  end

  def process(state, updates) do
    if state.group_albums and Enum.any?(updates, &Exiron.Hub.Telegram.AlbumBuffer.album?/1),
      do: process_album_batch(state, updates),
      else: process_individual(state, updates)
  end

  defp process_individual(state, updates) do
    # Telegram acknowledges every update below the next offset, so advance it
    # only after the corresponding update has been processed.
    Enum.reduce_while(updates, {:ok, state.offset}, fn update, {:ok, _offset} ->
      case process_update(state, update) do
        :ok ->
          {:cont, {:ok, update.update_id + 1}}

        {:retry, reason} ->
          # Using the failed update's id acknowledges earlier updates while
          # asking Telegram to return this update again on the next poll.
          {:halt, {:retry, update.update_id, reason}}
      end
    end)
  end

  defp process_album_batch(state, updates) do
    groups =
      updates
      |> Enum.filter(&Exiron.Hub.Telegram.AlbumBuffer.album?/1)
      |> Enum.group_by(&group_key/1)

    units =
      Enum.reduce(updates, {[], MapSet.new()}, fn update, {units, seen} ->
        key = group_key(update)

        cond do
          is_nil(key) -> {[{:single, update} | units], seen}
          MapSet.member?(seen, key) -> {units, seen}
          true -> {[{:album, groups[key]} | units], MapSet.put(seen, key)}
        end
      end)
      |> elem(0)
      |> Enum.reverse()

    Enum.reduce_while(units, :ok, fn unit, :ok ->
      result =
        case unit do
          {:single, update} -> process_update(state, update)
          {:album, group} -> process_album(state, group)
        end

      case result do
        :ok -> {:cont, :ok}
        {:retry, reason} -> {:halt, {:retry, hd(updates).update_id, reason}}
      end
    end)
    |> case do
      :ok -> {:ok, List.last(updates).update_id + 1}
      error -> error
    end
  end

  defp group_key(%{message: %{media_group_id: id, chat: %{id: chat}} = message})
       when is_binary(id) and id != "",
       do: {chat, Map.get(message, :message_thread_id), id}

  defp group_key(_), do: nil

  defp process_album(state, updates) do
    if length(updates) > 10 do
      Logger.warning("Telegram album ignored: too many items")
      :ok
    else
      result =
        Enum.reduce_while(updates, {:ok, [], 0}, fn %{message: message}, {:ok, items, size} ->
          remaining = state.max_download_bytes - size

          case content_from_message(%{state | max_download_bytes: max(remaining, 1)}, message) do
            {:ok, type, data, extra} when type in ["image", "video", "audio", "file"] ->
              total = size + byte_size(data)

              if total <= state.max_download_bytes do
                item =
                  MessageParser.metadata(message)
                  |> Map.merge(extra)
                  |> Map.merge(%{datatype: type, data: data})

                {:cont, {:ok, [item | items], total}}
              else
                {:halt, {:error, :telegram_file_too_large}}
              end

            {:error, reason} ->
              {:halt, {:error, reason}}

            _ ->
              {:halt, {:error, :invalid_payload}}
          end
        end)

      case result do
        {:ok, items, _} ->
          items = Enum.reverse(items)
          captioned = Enum.find(items, &(is_binary(&1.caption) and &1.caption != "")) || hd(items)

          dispatch_message(
            state,
            hd(updates).message,
            "album",
            Exiron.Hub.MediaAlbum.encode(items),
            %{caption: captioned.caption, caption_entities: captioned.caption_entities}
          )

        {:error, reason} ->
          if transient_media_error?(reason) and reason != :invalid_payload do
            {:retry, reason}
          else
            Logger.warning("Telegram album ignored: #{inspect(reason)}")
            :ok
          end
      end
    end
  end

  defp process_update(state, %{callback_query: query, update_id: id}) when is_map(query) do
    if MapSet.member?(state.processed_callbacks, id) do
      :ok
    else
      result =
        try do
          Exiron.Hub.incoming_callback(state.token, query)
        catch
          :exit, _ -> {:retry, :hub_unavailable}
        end

      if is_binary(Map.get(query, :id)), do: state.answer_callback.(state.token, query.id, result)

      case result do
        {:retry, _} = retry -> retry
        _ -> :ok
      end
    end
  end

  defp process_update(state, %{my_chat_member: update}) when is_map(update) do
    case MembershipEvent.from_update(update, bot_token: state.token, bot_name: state.bot_name) do
      nil -> :ok
      event -> Exiron.Hub.telegram_membership_changed(event)
    end
  end

  defp process_update(_state, %{message: nil}), do: :ok

  defp process_update(state, %{message: message}) do
    case content_from_message(state, message) do
      {:ok, datatype, data, opts} ->
        dispatch_message(state, message, datatype, data, opts)

      {:ok, datatype, data} ->
        dispatch_message(state, message, datatype, data)

      :ignore ->
        :ok

      {:error, reason} ->
        if transient_media_error?(reason) do
          {:retry, reason}
        else
          Logger.warning("Telegram message ignored: #{inspect(reason)}")
          :ok
        end
    end
  end

  defp process_update(_state, _update), do: :ok

  defp dispatch_message(state, telegram_message, datatype, data, extra_opts \\ %{}) do
    metadata = MessageParser.metadata(telegram_message)

    opts =
      [bot_name: state.bot_name]
      |> Keyword.merge(Map.to_list(metadata))
      |> Keyword.merge(Map.to_list(extra_opts))

    Exiron.Hub.incoming_service_message(
      Message.incoming(
        Telegram.service_id(),
        telegram_message.chat.id,
        datatype,
        data,
        Keyword.put(opts, :bot_token, state.token)
      )
    )
  end

  defp content_from_message(state, message) do
    case MessageParser.content(message) do
      {:file, file_id, datatype, opts} -> download_file(state, file_id, datatype, opts)
      result -> result
    end
  end

  defp download_file(state, file_id, datatype) do
    opts = [
      get_file: state.get_file,
      http_get: state.http_get,
      max_download_bytes: state.max_download_bytes
    ]

    case FileDownloader.download(state.token, file_id, opts) do
      {:ok, data} -> {:ok, datatype, data}
      error -> error
    end
  end

  defp download_file(state, file_id, datatype, opts) do
    case download_file(state, file_id, datatype) do
      {:ok, datatype, data} -> {:ok, datatype, data, opts}
      error -> error
    end
  end

  defp transient_media_error?(:telegram_file_too_large), do: false
  defp transient_media_error?(:telegram_file_path_empty), do: false

  defp transient_media_error?({:bad_status, status}) when is_integer(status),
    do: transient_http_status?(status)

  defp transient_media_error?(%ExGram.Error{code: code}) when is_integer(code),
    do: transient_http_status?(code)

  # ExGram wraps transport failures in its error code, while Req returns the
  # transport reason directly. Unknown download errors are therefore retried
  # unless they are one of the permanent validation failures above.
  defp transient_media_error?(_reason), do: true

  defp transient_http_status?(status),
    do: status in @transient_http_statuses or status >= 500
end
