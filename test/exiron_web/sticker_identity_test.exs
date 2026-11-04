defmodule ExironWeb.StickerIdentityTest do
  use ExironWeb.ConnCase, async: false

  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}
  alias Exiron.Hub.Telegram.MessageParser
  alias ExironWeb.ClientSocket
  import Exiron.Support.RouterHelper

  setup do
    :ok = Hub.configure(load_router!("sticker-identity"), Telegram.new([]))
  end

  test "HTTP delivers parsed sticker identity in routed requests and listen copies", %{conn: conn} do
    assert {:ok, []} = Hub.poll("ai-token", client_id: "sticker-http", listen: :all)
    :ok = Hub.incoming_service_message(sticker_message())

    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(~p"/api/requests?client_id=sticker-http&listen=all")

    assert %{"requests" => messages} = json_response(conn, 200)
    assert_identity(messages)
  end

  test "WebSocket frames preserve parsed sticker identity for requests and listen copies" do
    assert {:push, _, state} =
             ClientSocket.init(%{token: "ai-token", client_id: "sticker-ws", listen: :all})

    :ok = Hub.incoming_service_message(sticker_message())
    assert_receive {:exiron_messages, delivery_ref, messages}

    assert {:push, {:text, frame}, state} =
             ClientSocket.handle_info({:exiron_messages, delivery_ref, messages}, state)

    assert_identity(Jason.decode!(frame)["messages"])
    assert :ok = ClientSocket.terminate(:normal, state)
  end

  defp sticker_message do
    {:file, "sendable-id", "file", opts} =
      MessageParser.content(%{
        sticker: %{file_id: "sendable-id", file_unique_id: "unique-sticker", emoji: "🙂"}
      })

    # A caption selects the configured route while retaining downloaded sticker bytes.
    Message.incoming(
      222,
      123,
      "file",
      "sticker bytes",
      Map.to_list(opts) ++ [caption: "/ai sticker"]
    )
  end

  defp assert_identity(messages) do
    assert Enum.sort(Enum.map(messages, & &1["msgtype"])) == ["listen", "request"]

    for message <- messages do
      assert message["file_unique_id"] == "unique-sticker"
      assert message["sticker_id"] == "sendable-id"
      assert Base.decode64!(message["data"]) == "sticker bytes"
    end
  end
end
