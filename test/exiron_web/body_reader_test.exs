defmodule ExironWeb.BodyReaderTest do
  use ExUnit.Case, async: false

  alias ExironWeb.BodyReader

  setup do
    api_body_length = Application.get_env(:exiron, :api_body_length)
    hub_config = Application.get_env(:exiron, :hub, [])

    on_exit(fn ->
      Application.put_env(:exiron, :api_body_length, api_body_length)
      Application.put_env(:exiron, :hub, hub_config)
    end)

    :ok
  end

  test "uses the explicit API body length when configured" do
    Application.put_env(:exiron, :api_body_length, 123_456)

    assert BodyReader.api_body_length() == 123_456
  end

  test "uses a fixed upload default independent of queue capacity" do
    Application.delete_env(:exiron, :api_body_length)
    Application.put_env(:exiron, :hub, max_queue_bytes_per_hook: 10)

    assert BodyReader.api_body_length() == 51 * 1024 * 1024
    Application.put_env(:exiron, :hub, max_queue_bytes_per_hook: 500 * 1024 * 1024)
    assert BodyReader.api_body_length() == 51 * 1024 * 1024
  end

  test "read_body applies the configured API body length" do
    Application.put_env(:exiron, :api_body_length, 4)

    conn = Plug.Test.conn(:post, "/", "too large")

    assert {:more, "too ", _conn} = BodyReader.read_body(conn, [])
  end
end
