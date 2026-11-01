defmodule Exiron.Hub.Telegram.CaptionFormat do
  @moduledoc false
  alias Exiron.Hub.{MessageMetadata, Telegram.TextMarkup}

  @tags ~w(b strong i em u ins s strike del span tg-spoiler a tg-emoji tg-time code pre blockquote)
  @types ~w(mention hashtag cashtag bot_command url email phone_number bold italic underline strikethrough spoiler blockquote expandable_blockquote code pre text_link text_mention custom_emoji date_time)
  @reserved String.graphemes("_*[]()~`>#+-=|{}.!")

  def valid?(text, entities, _mode) when is_list(entities) do
    MessageMetadata.entities_valid?(entities, text) and
      Enum.all?(MessageMetadata.sanitize_entities(entities), &valid_entity?/1) and
      nested_entities?(MessageMetadata.sanitize_entities(entities))
  end

  def valid?(text, nil, mode) do
    with {:ok, tokens} <- TextMarkup.tokens(text, mode) do
      Enum.reduce_while(tokens, [], fn token, stack ->
        case step(token, stack, mode) do
          {:ok, stack} -> {:cont, stack}
          :error -> {:halt, :error}
        end
      end) == []
    else
      _ -> false
    end
  end

  def valid?(_, _, _), do: false

  defp step({:open, opening, closing}, stack, mode) do
    valid =
      if mode == "HTML",
        do: html_open?(opening, stack),
        else: markdown_open?(opening, closing, stack, mode)

    if valid, do: {:ok, [{opening, closing} | stack]}, else: :error
  end

  defp step(:close, [_ | rest], _), do: {:ok, rest}
  defp step({:context, context}, _stack, _), do: {:ok, context}

  defp step({:text, source, _}, stack, mode) do
    cond do
      String.contains?(source, <<0>>) ->
        :error

      mode == "MarkdownV2" and source == "\\" ->
        :error

      mode == "HTML" and source == ">" ->
        :error

      mode == "MarkdownV2" and not code?(stack) and not String.starts_with?(source, "\\") and
          source in @reserved ->
        :error

      mode in ["Markdown", "MarkdownV2"] and String.starts_with?(source, "\\") and
          byte_size(source) > 2 ->
        :error

      true ->
        {:ok, stack}
    end
  end

  defp step(_, _, _), do: :error

  defp html_open?(tag, stack) do
    [_, name] = Regex.run(~r/^<([a-zA-Z0-9-]+)/, tag)

    names =
      Enum.map(stack, fn {open, _} -> Regex.run(~r/^<([a-zA-Z0-9-]+)/, open) |> Enum.at(1) end)

    name in @tags and
      (not Enum.any?(names, &(&1 in ["pre", "code"])) or (name == "code" and names == ["pre"])) and
      (name not in ["pre", "code"] or names == [] or names == ["pre"] or names == ["blockquote"]) and
      (name != "blockquote" or "blockquote" not in names) and
      (name != "a" or "a" not in names) and
      case name do
        "a" ->
          valid_url?(attribute(tag, "href"))

        "span" ->
          attribute(tag, "class") == "tg-spoiler"

        "tg-emoji" ->
          numeric?(attribute(tag, "emoji-id"))

        "tg-time" ->
          numeric?(attribute(tag, "unix"))

        "code" ->
          is_nil(attribute(tag, "class")) or
            ("pre" in names and String.starts_with?(attribute(tag, "class"), "language-"))

        _ ->
          true
      end
  end

  defp markdown_open?(opening, closing, stack, mode) do
    cond do
      mode == "Markdown" and stack != [] ->
        false

      opening in ["[", "!["] ->
        valid_url?(
          String.slice(closing, 2, String.length(closing) - 3)
          |> String.replace("\\)", ")")
        )

      String.starts_with?(opening, "`") ->
        stack == [] or Enum.all?(stack, fn {open, _} -> open == ">" end)

      code?(stack) ->
        false

      true ->
        true
    end
  end

  defp code?(stack), do: Enum.any?(stack, fn {open, _} -> String.starts_with?(open, "`") end)

  defp valid_entity?(entity) do
    entity.type in @types and
      case entity.type do
        "text_link" -> valid_url?(entity[:url])
        "text_mention" -> is_map(entity[:user])
        "custom_emoji" -> numeric?(entity[:custom_emoji_id])
        "date_time" -> is_integer(entity[:unix_time])
        _ -> true
      end
  end

  defp nested_entities?(entities) do
    entities
    |> Enum.with_index()
    |> Enum.all?(fn {left, index} ->
      Enum.all?(Enum.drop(entities, index + 1), fn right ->
        a = left.offset
        b = a + left.length
        c = right.offset
        d = c + right.length
        disjoint = b <= c or d <= a
        contained = (a <= c and d <= b) or (c <= a and b <= d)

        disjoint or
          (contained and left.type not in ["code", "pre"] and right.type not in ["code", "pre"] and
             not (left.type in ["blockquote", "expandable_blockquote"] and
                    right.type in ["blockquote", "expandable_blockquote"]))
      end)
    end)
  end

  defp attribute(tag, name) do
    case Regex.run(~r/\b#{name}\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/, tag,
           capture: :all_but_first
         ) do
      values when is_list(values) -> Enum.find(values, &(&1 != ""))
      _ -> nil
    end
  end

  defp valid_url?(url) when is_binary(url) do
    uri = URI.parse(url)

    url != "" and not String.contains?(url, ["\r", "\n", <<0>>]) and
      uri.scheme in ["http", "https", "tg", "mailto", "tel", "ftp"]
  end

  defp valid_url?(_), do: false
  defp numeric?(s) when is_binary(s), do: Regex.match?(~r/^\d+$/, s)
  defp numeric?(_), do: false
end
