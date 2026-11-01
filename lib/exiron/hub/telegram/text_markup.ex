defmodule Exiron.Hub.Telegram.TextMarkup do
  @moduledoc false
  alias Exiron.Hub.Telegram.TextSplitter

  # Tokens retain source markup while exposing rendered UTF-16 length. Each open
  # token carries its matching close, allowing the splitter to balance every part.
  def tokens(text, "plain"), do: {:ok, text_tokens(text)}
  def tokens(text, "HTML"), do: html(text, [], [])
  def tokens(text, mode) when mode in ["Markdown", "MarkdownV2"], do: markdown(text, mode, [], [])

  defp text_tokens(text),
    do: Enum.map(String.graphemes(text), &{:text, &1, TextSplitter.units(&1)})

  defp html("", [], acc), do: {:ok, Enum.reverse(acc)}
  defp html("", _, _), do: {:error, :invalid_payload}

  defp html("<" <> _ = text, stack, acc) do
    case Regex.run(~r/^<\/?[a-zA-Z][a-zA-Z0-9-]*(?:\s+(?:[^<>"']|"[^"]*"|'[^']*')*)?\s*>/u, text) do
      [tag] ->
        [_, closing, name] = Regex.run(~r/^<(\/?)([a-zA-Z][a-zA-Z0-9-]*)/, tag)
        rest = binary_part(text, byte_size(tag), byte_size(text) - byte_size(tag))

        cond do
          closing == "" -> html(rest, [name | stack], [{:open, tag, "</#{name}>"} | acc])
          stack != [] and hd(stack) == name -> html(rest, tl(stack), [:close | acc])
          true -> {:error, :invalid_payload}
        end

      _ ->
        {:error, :invalid_payload}
    end
  end

  defp html("&" <> _ = text, stack, acc) do
    case Regex.run(~r/^&(?:#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/, text) do
      [entity] ->
        case entity_units(entity) do
          {:ok, count} ->
            html(
              binary_part(text, byte_size(entity), byte_size(text) - byte_size(entity)),
              stack,
              [{:text, entity, count} | acc]
            )

          _ ->
            {:error, :invalid_payload}
        end

      _ ->
        {:error, :invalid_payload}
    end
  end

  defp html(text, stack, acc) do
    {g, rest} = String.next_grapheme(text)
    html(rest, stack, [{:text, g, TextSplitter.units(g)} | acc])
  end

  defp entity_units(entity) when entity in ["&lt;", "&gt;", "&amp;", "&quot;"], do: {:ok, 1}

  defp entity_units("&#" <> value) do
    value = String.trim_trailing(value, ";")

    {value, base} =
      case value do
        <<x, rest::binary>> when x in [?x, ?X] -> {rest, 16}
        _ -> {value, 10}
      end

    case Integer.parse(value, base) do
      {char, ""} when char > 0 and char <= 0x10FFFF and char not in 0xD800..0xDFFF ->
        {:ok, if(char > 0xFFFF, do: 2, else: 1)}

      _ ->
        {:error, :invalid_payload}
    end
  end

  defp entity_units(_), do: {:error, :invalid_payload}

  defp markdown("", _mode, [], acc), do: {:ok, Enum.reverse(acc)}
  defp markdown("", "MarkdownV2", [{">", _}], acc), do: {:ok, Enum.reverse([:close | acc])}
  defp markdown("", _mode, _, _), do: {:error, :invalid_payload}

  defp markdown("\\" <> rest, mode, stack, acc) when rest != "" do
    {char, tail} = String.next_codepoint(rest)
    in_code? = match?([{marker, _} | _] when marker in ["`", "```"], stack)

    escaped? =
      cond do
        in_code? -> char in ["`", "\\"]
        mode == "MarkdownV2" -> byte_size(char) == 1 and :binary.first(char) in 1..126
        true -> char in ["_", "*", "`", "["]
      end

    if escaped?,
      do: markdown(tail, mode, stack, [{:text, "\\" <> char, TextSplitter.units(char)} | acc]),
      else: markdown(rest, mode, stack, [{:text, "\\", 1} | acc])
  end

  defp markdown(text, mode, [{marker, _} | _] = stack, acc) when marker in ["`", "```"] do
    if String.starts_with?(text, marker) do
      markdown(drop(text, marker), mode, tl(stack), [:close | acc])
    else
      next_markdown_text(text, mode, stack, acc)
    end
  end

  defp markdown(">" <> rest, "MarkdownV2", stack, acc) do
    stack = if Enum.any?(stack, &(elem(&1, 0) == ">")), do: stack, else: stack ++ [{">", ">"}]

    context =
      Enum.map(stack, fn {marker, opening} ->
        {opening, if(marker == ">", do: "", else: marker)}
      end)

    markdown(rest, "MarkdownV2", stack, [{:context, context} | acc])
  end

  defp markdown("\n" <> rest, "MarkdownV2", stack, acc) do
    stack = Enum.reject(stack, &(elem(&1, 0) == ">"))
    context = Enum.map(stack, fn {marker, opening} -> {opening, marker} end)
    markdown(rest, "MarkdownV2", stack, [{:text, "\n", 1}, {:context, context} | acc])
  end

  # An expandable blockquote ends with || outside a spoiler. Keep the suffix
  # on its final part without counting it as rendered text.
  defp markdown("||" <> rest, "MarkdownV2", [{">", _}] = stack, acc)
       when rest == "" or binary_part(rest, 0, 1) == "\n" do
    markdown(rest, "MarkdownV2", stack, [{:text, "||", 0} | acc])
  end

  defp markdown("```" <> rest, mode, stack, acc) do
    prefix =
      case Regex.run(~r/^[a-zA-Z0-9_+-]*\n/, rest) do
        [language] -> language
        _ -> ""
      end

    opening = "```" <> prefix

    markdown(drop(rest, prefix), mode, [{"```", opening} | stack], [{:open, opening, "```"} | acc])
  end

  defp markdown("`" <> rest, mode, stack, acc),
    do: markdown(rest, mode, [{"`", "`"} | stack], [{:open, "`", "`"} | acc])

  defp markdown(text, mode, stack, acc) do
    case Regex.run(~r/^(!?\[)((?:\\.|[^\]\\])*)\]\(((?:\\.|[^)\\])*)\)/us, text) do
      [source, opening, label, url] ->
        with {:ok, label_tokens} <- tokens(label, mode) do
          tokens = [{:open, opening, "](" <> url <> ")"}] ++ label_tokens ++ [:close]
          markdown(drop(text, source), mode, stack, Enum.reverse(tokens, acc))
        end

      _ ->
        markers = if mode == "MarkdownV2", do: ["__", "||", "*", "_", "~"], else: ["*", "_"]

        markers =
          if String.starts_with?(text, "___") and match?([{"_", _} | _], stack),
            do: ["_"],
            else: markers

        case Enum.find(markers, &String.starts_with?(text, &1)) do
          nil ->
            next_markdown_text(text, mode, stack, acc)

          marker ->
            case stack do
              [{^marker, _} | rest] ->
                markdown(drop(text, marker), mode, rest, [:close | acc])

              _ ->
                markdown(drop(text, marker), mode, [{marker, marker} | stack], [
                  {:open, marker, marker} | acc
                ])
            end
        end
    end
  end

  defp next_markdown_text(text, mode, stack, acc) do
    {g, rest} = String.next_grapheme(text)
    markdown(rest, mode, stack, [{:text, g, TextSplitter.units(g)} | acc])
  end

  defp drop(text, prefix),
    do: binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))
end
