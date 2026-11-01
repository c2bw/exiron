defmodule Exiron.Hub.Telegram.TextSplitterTest do
  use ExUnit.Case, async: true
  alias Exiron.Hub.Message
  alias Exiron.Hub.Telegram.TextSplitter

  test "plain splitting preserves graphemes and UTF-16 boundaries" do
    text = String.duplicate("a", 4095) <> "😀" <> String.duplicate("é", 3000)
    assert {:ok, parts} = split(text)
    assert Enum.map_join(parts, & &1.data) == text
    assert Enum.all?(parts, &(String.valid?(&1.data) and TextSplitter.units(&1.data) <= 4096))
    assert hd(parts).data == String.duplicate("a", 4095)
    assert Enum.at(parts, 1).data |> String.starts_with?("😀")
    refute Enum.any?(parts, &String.starts_with?(&1.data, "́"))
  end

  test "entities crossing parts retain attributes with adjusted UTF-16 offsets" do
    text = String.duplicate("a", 4094) <> "😀" <> "tail"

    assert {:ok, [first, second]} =
             split(text,
               entities: [
                 %{type: "text_link", offset: 4094, length: 6, url: "https://example.com"}
               ]
             )

    assert first.entities == [
             %{type: "text_link", offset: 4094, length: 2, url: "https://example.com"}
           ]

    assert second.entities == [
             %{type: "text_link", offset: 0, length: 4, url: "https://example.com"}
           ]

    assert first.data <> second.data == text
  end

  test "HTML formatting is balanced with escaped text and long links" do
    body = String.duplicate("a", 4095) <> "&amp;" <> "&#x1F600;tail"

    assert {:ok, [first, second]} =
             split("<b><a href=\"https://example.com?q=x&gt;y\">" <> body <> "</a></b>",
               parse_mode: "HTML"
             )

    assert first.data ==
             "<b><a href=\"https://example.com?q=x&gt;y\">" <>
               String.duplicate("a", 4095) <> "&amp;</a></b>"

    assert second.data == "<b><a href=\"https://example.com?q=x&gt;y\">&#x1F600;tail</a></b>"
  end

  test "MarkdownV2 style, links, escapes and code fences balance across parts" do
    for {opening, closing} <- [
          {"*__", "__*"},
          {"[", "](https://example.com)"},
          {"```elixir\n", "```"},
          {"`", "`"},
          {"||", "||"}
        ] do
      assert {:ok, [first, second]} =
               split(opening <> String.duplicate("x", 4096) <> "tail" <> closing,
                 parse_mode: "MarkdownV2"
               )

      assert first.data == opening <> String.duplicate("x", 4096) <> closing
      assert second.data == opening <> "tail" <> closing
    end

    assert {:ok, parts} = split(String.duplicate("\\*", 4097), parse_mode: "MarkdownV2")
    assert Enum.map_join(parts, & &1.data) == String.duplicate("\\*", 4097)
  end

  test "MarkdownV2 quotes and triple-underscore formatting survive a boundary" do
    assert {:ok, [first, second]} =
             split(">" <> String.duplicate("x", 4096) <> "tail", parse_mode: "MarkdownV2")

    assert first.data == ">" <> String.duplicate("x", 4096)
    assert second.data == ">tail"

    assert {:ok, parts} =
             split("___" <> String.duplicate("x", 4097) <> "___", parse_mode: "MarkdownV2")

    assert Enum.all?(
             parts,
             &(String.starts_with?(&1.data, "___") and String.ends_with?(&1.data, "___"))
           )
  end

  test "formatting starting at a boundary does not produce empty markup" do
    assert {:ok, [first, second]} =
             split(String.duplicate("a", 4096) <> "*x*", parse_mode: "MarkdownV2")

    assert first.data == String.duplicate("a", 4096)
    assert second.data == "*x*"
  end

  test "malformed legacy Markdown falls back to plain while explicit markup fails before sending" do
    text = "*" <> String.duplicate("a", 5000)
    assert {:ok, parts} = split(text, parse_mode: "Markdown")
    assert Enum.map_join(parts, & &1.data) == text
    assert Enum.all?(parts, &(&1.parse_mode == "plain"))
    assert {:error, :invalid_payload} = split(text, parse_mode: "MarkdownV2")
    assert {:error, :invalid_payload} = split("<b>" <> text, parse_mode: "HTML")
  end

  test "a trailing newline stays with text instead of becoming an empty message" do
    text = String.duplicate("x", 4096) <> "\n"
    assert {:ok, [first, second]} = split(text)
    assert first.data <> second.data == text
    assert second.data == "x\n"
    assert {:ok, [first, second]} = split("<b>" <> text <> "</b>", parse_mode: "HTML")
    assert first.data == "<b>" <> String.duplicate("x", 4095) <> "</b>"
    assert second.data == "<b>x\n</b>"
  end

  test "logical text and oversized grapheme limits are checked before delivery" do
    assert {:ok, parts} = split(String.duplicate("a", 131_072))
    assert length(parts) == 32
    assert {:error, :invalid_payload} = split(String.duplicate("a", 131_073))
    assert {:error, :invalid_payload} = split("a" <> String.duplicate("́", 4096))
  end

  defp split(text, opts \\ []),
    do:
      TextSplitter.split(
        Message.outgoing(
          222,
          123,
          "text",
          text,
          "token",
          Keyword.put_new(opts, :parse_mode, "plain")
        )
      )
end
