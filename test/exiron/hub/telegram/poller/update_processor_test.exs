defmodule Exiron.Hub.Telegram.Poller.UpdateProcessorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Exiron.Hub.Telegram.Poller.UpdateProcessor
  alias Exiron.Hub.Telegram.PollerState

  test "empty polls preserve the current offset" do
    assert UpdateProcessor.process(%PollerState{offset: 12}, []) == {:ok, 12}
  end

  test "processed updates advance to one past the final update id" do
    state = %PollerState{offset: 12}
    updates = [%{update_id: 15, message: nil}, %{update_id: 19, message: nil}]

    assert UpdateProcessor.process(state, updates) == {:ok, 20}
  end

  test "transient media failures retain the failed update and stop the batch" do
    parent = self()

    state = %PollerState{
      token: "bot-token",
      offset: 12,
      max_download_bytes: 1_024,
      get_file: fn file_id, [token: "bot-token"] ->
        send(parent, {:get_file, file_id})
        {:ok, %{file_path: "documents/#{file_id}.txt"}}
      end,
      http_get: fn _url, _opts ->
        {:ok, %Req.Response{status: 500, body: "unavailable"}}
      end
    }

    updates = [
      %{update_id: 15, message: %{chat: %{id: 123}, document: %{file_id: "failed"}}},
      %{update_id: 16, message: %{chat: %{id: 123}, document: %{file_id: "later"}}}
    ]

    assert UpdateProcessor.process(state, updates) == {:retry, 15, {:bad_status, 500}}
    assert_receive {:get_file, "failed"}
    refute_receive {:get_file, "later"}
  end

  test "permanent media failures are acknowledged" do
    state = %PollerState{
      token: "bot-token",
      offset: 12,
      max_download_bytes: 1_024,
      get_file: fn "missing", [token: "bot-token"] ->
        {:ok, %{file_path: "documents/missing.txt"}}
      end,
      http_get: fn _url, _opts ->
        {:ok, %Req.Response{status: 404, body: "not found"}}
      end
    }

    updates = [
      %{update_id: 15, message: %{chat: %{id: 123}, document: %{file_id: "missing"}}}
    ]

    capture_log(fn ->
      assert UpdateProcessor.process(state, updates) == {:ok, 16}
    end)
  end
end
