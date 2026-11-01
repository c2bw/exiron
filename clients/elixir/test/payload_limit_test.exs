defmodule ExironClient.PayloadLimitTest do
  use ExUnit.Case, async: true
  alias ExironClient.{Error, MediaItem, PayloadLimit, Request, Wire}

  test "request limits default to 51 MiB and require positive integers" do
    assert ExironClient.new(base_url: "http://exiron.test").max_request_bytes == 51 * 1024 * 1024

    for limit <- [0, -1, "100", nil] do
      assert_raise ArgumentError, fn -> client(limit) end
    end

    for size <- 0..20 do
      assert PayloadLimit.encoded_size(size) ==
               byte_size(Base.encode64(:binary.copy(<<0>>, size)))
    end
  end

  test "ordinary replies, pushes, edits and albums respect exact encoded JSON boundaries" do
    raw = <<0, 255, 1, 2, 3, 4, 5>>
    opts = [caption: "é<quoted>\n\"", idempotency_key: "key-1"]

    items = [
      %MediaItem{datatype: "file", data: raw, caption: opts[:caption]},
      %MediaItem{datatype: "image", data: ""}
    ]

    {:ok, album} = MediaItem.encode(items)

    for {payload, call} <- [
          {Wire.Payload.response("req", "file", raw),
           &ExironClient.respond(&1, "req", "file", raw)},
          {Wire.Payload.response("req", "file", raw, opts),
           &ExironClient.respond(&1, "req", "file", raw, opts)},
          {Wire.Payload.push("file", raw, opts), &ExironClient.push(&1, "file", raw, opts)},
          {Wire.Payload.push_to_chat(123, "file", raw, opts),
           &ExironClient.push(&1, 123, "file", raw, opts)},
          {Wire.Payload.response("req", "text", "hello", parse_mode: "plain"),
           &ExironClient.edit_text(&1, "req", "hello")},
          {Wire.Payload.response("req", "album", album, opts),
           &ExironClient.reply_album(&1, "req", items, opts)},
          {Wire.Payload.push("album", album, opts), &ExironClient.push_album(&1, items, opts)},
          {Wire.Payload.push_to_chat(123, "album", album, opts),
           &ExironClient.push_album_to_chat(&1, 123, items, opts)}
        ] do
      expected = Jason.encode!(payload)

      for delta <- [-1, 0, 1] do
        parent = self()

        client =
          client(byte_size(expected) + delta, fn req ->
            send(parent, {:sent, IO.iodata_to_binary(req.body)})
            {req, Req.Response.json(%{ok: true, sent: 1})}
          end)

        result = call.(client)

        if delta < 0 do
          assert {:error, %Error{reason: :payload_too_large, status: nil, message: message}} =
                   result

          assert message =~ "limit"
          refute_received {:sent, _}
        else
          assert {:ok, _} = result
          assert_received {:sent, ^expected}
        end
      end
    end
  end

  test "oversized data is rejected before encoding or HTTP" do
    client = client(32)

    build = fn
      "" -> Wire.Payload.push("file", "")
      _ -> flunk("encoded oversized data")
    end

    assert {:error, %Error{reason: :payload_too_large}} =
             Request.data(client, :post, "/api/push", :binary.copy(<<0>>, 30), build)
  end

  test "album counts match actual nested JSON including escaped metadata" do
    items = [
      %MediaItem{datatype: "file", data: <<0, 1>>, caption: "<é>\"\n"},
      %MediaItem{datatype: "video", data: "", file_name: "a\\b"}
    ]

    {:ok, data} = MediaItem.encode(items)
    assert {:ok, size} = MediaItem.encoded_size(items, 10000)
    assert size == byte_size(data)
    wire = Wire.Payload.push("album", data)
    size = byte_size(Jason.encode!(wire))
    assert :ok = PayloadLimit.check_album(client(size), items, Wire.Payload.push("album", ""))

    assert {:error, %Error{reason: :payload_too_large}} =
             PayloadLimit.check_album(client(size - 1), items, Wire.Payload.push("album", ""))

    assert {:error, %Error{reason: :payload_too_large}} =
             PayloadLimit.check_album(client(16), items, Wire.Payload.push("album", ""))

    assert {:error, %Error{reason: :invalid_payload}} =
             PayloadLimit.check_album(client(1000), [], %{})
  end

  test "control payloads, keyboard metadata and raw body overrides are limited" do
    client = client(24)

    assert {:error, %Error{reason: :payload_too_large}} =
             ExironClient.auth(%{client | token: String.duplicate("t", 25)})

    keyboard = [[%{text: String.duplicate("x", 40), callback_data: "ok"}]]

    assert {:error, %Error{reason: :payload_too_large}} =
             ExironClient.edit_keyboard(client, "req", keyboard)

    assert {:error, %Error{reason: :payload_too_large}} =
             Request.request(client, :post, "/api/push", body: String.duplicate("x", 25))

    assert {:error, %Error{reason: :payload_too_large}} =
             Request.request(client, :post, "/api/push", body: [String.duplicate("x", 25)])
  end

  test "stream stops locally at an oversized accumulated update without finalization" do
    parent = self()

    client =
      client(110, fn req ->
        send(parent, {:update, Jason.decode!(req.body)})
        {req, Req.Response.json(%{ok: true, final: false, message_id: 1})}
      end)

    assert {:error, %Error{reason: :payload_too_large}} =
             ExironClient.stream_text(client, "req", ["p", String.duplicate("x", 100)],
               interval_ms: 0
             )

    assert_received {:update, %{"final" => false}}
    refute_received {:update, _}
  end

  defp client(limit, adapter \\ fn _ -> flunk("unexpected HTTP request") end) do
    ExironClient.new(
      base_url: "http://exiron.test",
      token: "token",
      max_request_bytes: limit,
      req_options: [adapter: adapter]
    )
  end
end
