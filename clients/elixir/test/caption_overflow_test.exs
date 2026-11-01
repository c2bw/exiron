defmodule ExironClient.CaptionOverflowTest do
  use ExUnit.Case, async: true
  alias ExironClient.{MediaItem, Wire.Payload}
  import ExironClient.FixtureHelpers, only: [contract_json: 1]

  test "response and push options match the shared wire contract" do
    opts = [caption: "report", caption_overflow: true]

    assert json(Payload.response("req-1", "file", "bytes", opts)) ==
             contract_json("response_caption_overflow_payload.json")

    assert json(Payload.push_to_chat(123, "file", "bytes", opts)) ==
             contract_json("push_caption_overflow_payload.json")

    refute Map.has_key?(Payload.response("req-1", "file", "bytes"), :caption_overflow)
  end

  test "album helpers retain member formatting and overflow options" do
    parent = self()

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [
          adapter: fn req ->
            send(parent, {:request, req.url.path, Jason.decode!(req.body)})
            {req, Req.Response.json(%{ok: true})}
          end
        ]
      )

    items = [
      %MediaItem{datatype: "image", data: "one", caption: "<b>Photos</b>", parse_mode: "HTML"},
      %MediaItem{datatype: "video", data: "two"}
    ]

    assert {:ok, _} = ExironClient.reply_album(client, "req-1", items, caption_overflow: true)
    assert_receive {:request, "/api/responses", %{"caption_overflow" => true, "data" => data}}
    assert {:ok, ^items} = MediaItem.decode(Base.decode64!(data))
    assert {:ok, _} = ExironClient.push_album_to_chat(client, 123, items, caption_overflow: true)
    assert_receive {:request, "/api/push", %{"caption_overflow" => true}}
  end

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
end
