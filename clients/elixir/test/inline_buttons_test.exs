defmodule ExironClient.InlineButtonsTest do
  use ExUnit.Case, async: true
  alias ExironClient.{Message, Wire}
  import ExironClient.FixtureHelpers, only: [contract_json: 1]

  test "shared callback fixture retains clicker, source, topic and application data" do
    payload = contract_json("requests_callback_response.json")
    assert {:ok, [message]} = Message.from_server_list(payload["requests"], :request)
    assert Message.callback_data(message) == "next:2"
    assert message.callback_query == %{"id" => "query-1", "origin_req_id" => "req-1"}
    assert message.from["id"] == 42
    assert message.message_id == 901
    assert message.message_thread_id == 7
    assert Message.text(message) == ""
  end

  test "keyboard payloads match the shared contract, including explicit removal" do
    keyboard = [
      [%{text: "Next", callback_data: "next:2"}, %{text: "Help", url: "https://example.com/help"}]
    ]

    assert json(Wire.Payload.response("req-1", "text", "Choose", inline_keyboard: keyboard)) ==
             contract_json("response_keyboard_payload.json")

    assert json(
             Wire.Payload.response("callback-request", "keyboard", "",
               inline_keyboard: [],
               edit_origin: true
             )
           ) == contract_json("callback_keyboard_payload.json")

    refute Map.has_key?(Wire.Payload.response("id", "text", "text"), :inline_keyboard)
  end

  test "helpers preserve one-shot defaults and choose the correct operation" do
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

    assert {:ok, _} =
             ExironClient.edit_callback_text(client, "click", "Updated", inline_keyboard: [])

    assert_receive {:request, "/api/responses",
                    %{"edit_origin" => true, "inline_keyboard" => []} = body}

    refute Map.has_key?(body, "final")
    assert {:ok, _} = ExironClient.edit_callback_keyboard(client, "click", [])

    assert_receive {:request, "/api/responses",
                    %{"datatype" => "keyboard", "edit_origin" => true, "data" => ""}}

    assert {:ok, _} = ExironClient.edit_keyboard(client, "original", [])
    assert_receive {:request, "/api/edits", %{"datatype" => "keyboard", "inline_keyboard" => []}}
    assert {:ok, _} = ExironClient.reply_text(client, "click", "New message")
    assert_receive {:request, "/api/responses", body}
    refute Map.has_key?(body, "edit_origin")
  end

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
end
