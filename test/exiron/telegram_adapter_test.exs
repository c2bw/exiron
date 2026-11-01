defmodule Exiron.TelegramAdapterTest do
  use ExUnit.Case, async: true
  alias Exiron.TelegramAdapter

  test "preserves Telegram retry_after objects and sends only one HTTP request" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, :http_attempt)

      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{
        "ok" => false,
        "error_code" => 429,
        "description" => "Too Many Requests",
        "parameters" => %{"retry_after" => 2}
      })
    end)

    assert {:error, %ExGram.Error{code: 429} = error} =
             TelegramAdapter.request(
               :post,
               "/bottest/sendMessage",
               %{chat_id: 123, text: "hello"},
               plug: {Req.Test, __MODULE__}
             )

    assert Exiron.Hub.Telegram.SendCoordinator.retry_delay(error) == 2000
    assert_receive :http_attempt
    refute_receive :http_attempt
  end

  test "ExGram preserves structured rate-limit hints through the configured adapter" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{
        "ok" => false,
        "error_code" => 429,
        "description" => "Too Many Requests",
        "parameters" => %{"retry_after" => 3}
      })
    end)

    assert {:error, %ExGram.Error{} = error} =
             ExGram.send_message(123, "hello",
               token: "synthetic-token",
               adapter_opts: [plug: {Req.Test, __MODULE__}]
             )

    assert Exiron.Hub.Telegram.SendCoordinator.retry_delay(error) == 3000
  end

  test "decodes successful results without creating atoms from unknown fields" do
    unknown = "unknown_telegram_field_#{System.unique_integer([:positive])}"

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"ok" => true, "result" => %{"message_id" => 7, unknown => "value"}})
    end)

    assert {:ok, %{message_id: 7} = result} =
             TelegramAdapter.request(:post, "/bottest/sendMessage", %{},
               plug: {Req.Test, __MODULE__}
             )

    assert result[unknown] == "value"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "retains model fields independently of runtime module loading" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "ok" => true,
        "result" => %{
          "user_chat_id" => 123,
          "from" => %{"is_bot" => false, "first_name" => "Alice"}
        }
      })
    end)

    assert {:ok, result} =
             TelegramAdapter.request(:post, "/bottest/getUpdates", %{},
               plug: {Req.Test, __MODULE__}
             )

    assert result[String.to_existing_atom("user_chat_id")] == 123

    assert result[String.to_existing_atom("from")][String.to_existing_atom("first_name")] ==
             "Alice"
  end

  test "encodes media multipart bodies and preserves binary payloads" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "content-type")
             |> hd()
             |> String.starts_with?("multipart/form-data")

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "payload-bytes"
      assert body =~ "picture.jpg"
      Req.Test.json(conn, %{"ok" => true, "result" => %{"message_id" => 8}})
    end)

    assert {:ok, %{message_id: 8}} =
             TelegramAdapter.request(
               :post,
               "/bottest/sendPhoto",
               {:multipart,
                [{"chat_id", "123"}, {:file_content, "photo", "payload-bytes", "picture.jpg"}]},
               plug: {Req.Test, __MODULE__}
             )
  end
end
