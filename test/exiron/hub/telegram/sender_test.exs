defmodule Exiron.Hub.Telegram.SenderTest do
  use ExUnit.Case, async: false

  alias Exiron.Hub.Message
  alias Exiron.Hub.Telegram.Sender

  setup do
    previous_adapter = Application.get_env(:ex_gram, :adapter)
    Application.put_env(:ex_gram, :adapter, ExGram.Adapter.Test)
    _adapter = start_supervised!(ExGram.Adapter.Test)
    :ok = ExGram.Test.set_global()

    on_exit(fn ->
      if previous_adapter do
        Application.put_env(:ex_gram, :adapter, previous_adapter)
      else
        Application.delete_env(:ex_gram, :adapter)
      end
    end)

    :ok
  end

  test "sends text with Markdown parsing" do
    ExGram.Test.stub(:send_message, {:ok, %{message_id: 1}})

    assert :ok = Sender.send("secret-token", Message.new(222, 123, "text", "hello"))
    assert [{:post, :send_message, _body}] = ExGram.Test.get_calls()
  end

  test "retries text without Markdown after a parse failure" do
    error = %ExGram.Error{code: 400, message: "can't parse entities: bad markup"}
    ExGram.Test.expect(:send_message, {:error, error})
    ExGram.Test.stub(:send_message, {:ok, %{message_id: 2}})

    assert :ok = Sender.send("secret-token", Message.new(222, 123, "text", "*broken"))
    assert [first, second] = ExGram.Test.get_calls()
    assert {:post, :send_message, _} = first
    assert {:post, :send_message, _} = second
  end

  test "sends media and sticker message types" do
    ExGram.Test.stub(:send_photo, {:ok, %{message_id: 3}})
    ExGram.Test.stub(:send_sticker, {:ok, %{message_id: 4}})

    assert :ok = Sender.send("secret-token", Message.new(222, 123, "image", "image-bytes"))

    assert :ok =
             Sender.send(
               "secret-token",
               Message.new(222, 123, "sticker", "sticker-file", nil, sticker_emoji: "😀")
             )

    assert [{:post, :send_photo, _}, {:post, :send_sticker, _}] = ExGram.Test.get_calls()
  end
end
