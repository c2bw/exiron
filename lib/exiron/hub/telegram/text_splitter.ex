defmodule Exiron.Hub.Telegram.TextSplitter do
  @moduledoc false
  @limit 4096
  @max_units 131_072
  @max_bytes 524_288

  def max_units, do: @max_units
  def max_bytes, do: @max_bytes

  def units(text),
    do: div(byte_size(:unicode.characters_to_binary(text, :utf8, {:utf16, :little})), 2)

  def valid?(text) when is_binary(text),
    do:
      text != "" and String.valid?(text) and byte_size(text) <= @max_bytes and
        units(text) <= @max_units

  def valid?(_), do: false

  def split(message, opts \\ []) do
    mode = if is_list(message.entities), do: "plain", else: message.parse_mode || "Markdown"

    with true <- valid?(message.data),
         {:ok, tokens, mode} <-
           markup_tokens(message.data, mode, Keyword.get(opts, :strict_markup, false)),
         {:ok, chunks} <- pack(tokens, Keyword.get(opts, :first_limit, @limit)),
         true <- length(chunks) <= Keyword.get(opts, :max_parts, 32) do
      {parts, _} =
        Enum.map_reduce(chunks, 0, fn {text, size}, offset ->
          entities = slice_entities(message.entities, offset, size)
          {%{message | data: text, entities: entities, parse_mode: mode}, offset + size}
        end)

      {:ok, parts}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp markup_tokens(text, mode, strict?) do
    case Exiron.Hub.Telegram.TextMarkup.tokens(text, mode) do
      {:ok, tokens} ->
        {:ok, tokens, mode}

      _ when mode == "Markdown" and not strict? ->
        {:ok, tokens} = Exiron.Hub.Telegram.TextMarkup.tokens(text, "plain")
        {:ok, tokens, "plain"}

      error ->
        error
    end
  end

  defp pack(tokens, first_limit) do
    Enum.reduce_while(reserve_tail(tokens), {:ok, [], [], [], [], 0}, fn token,
                                                                         {:ok, chunks, body,
                                                                          stack, active, size} ->
      case token do
        {:open, opening, closing} ->
          {:cont, {:ok, chunks, body, [{opening, closing} | stack], active, size}}

        {:context, context} ->
          {:cont, {:ok, chunks, body, context, active, size}}

        :close ->
          {:cont, {:ok, chunks, body, tl(stack), active, size}}

        {:text, source, count, reserve} when count + reserve <= @limit ->
          limit = if chunks == [], do: first_limit, else: @limit

          if size + count + reserve > limit do
            chunk = finish(body, active)

            {:cont,
             {:ok, [{chunk, size} | chunks], [source, transition([], stack)], stack, stack, count}}
          else
            {:cont,
             {:ok, chunks, [source, transition(active, stack) | body], stack, stack, size + count}}
          end

        _ ->
          {:halt, {:error, :invalid_payload}}
      end
    end)
    |> case do
      {:ok, chunks, body, [], active, size} when size > 0 ->
        {:ok, Enum.reverse([{finish(body, active), size} | chunks])}

      _ ->
        {:error, :invalid_payload}
    end
  end

  # Keep a final newline/space run with the preceding visible grapheme. A
  # whitespace-only last message can be rejected as empty by Telegram.
  defp reserve_tail(tokens) do
    tokens
    |> Enum.reverse()
    |> Enum.map_reduce({0, false}, fn
      {:text, source, count}, {tail, false} ->
        if String.trim(source) == "" do
          {{:text, source, count, 0}, {tail + count, false}}
        else
          {{:text, source, count, tail}, {tail, true}}
        end

      {:text, source, count}, state ->
        {{:text, source, count, 0}, state}

      token, state ->
        {token, state}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp transition(active, next) do
    active = Enum.reverse(active)
    next = Enum.reverse(next)
    shared = Enum.zip(active, next) |> Enum.take_while(fn {a, b} -> a == b end) |> length()

    [
      active |> Enum.drop(shared) |> Enum.reverse() |> Enum.map(&elem(&1, 1)),
      next |> Enum.drop(shared) |> Enum.map(&elem(&1, 0))
    ]
  end

  defp finish(body, stack),
    do: IO.iodata_to_binary([Enum.reverse(body), Enum.map(stack, &elem(&1, 1))])

  defp slice_entities(nil, _, _), do: nil

  defp slice_entities(entities, offset, size) do
    entities
    |> Exiron.Hub.MessageMetadata.sanitize_entities()
    |> Enum.flat_map(fn entity ->
      start = max(entity.offset, offset)
      stop = min(entity.offset + entity.length, offset + size)
      if stop > start, do: [%{entity | offset: start - offset, length: stop - start}], else: []
    end)
  end
end
