defmodule Exiron.Hub.Telegram.AlbumProcessingTest do
  use ExUnit.Case, async: false
  use Exiron.HubCase
  alias Exiron.Hub
  alias Exiron.Hub.{MediaAlbum, Message}
  alias Exiron.Hub.Telegram.{MessageParser, PollerState}
  alias Exiron.Hub.Telegram.Poller.UpdateProcessor

  test "captioned albums become one routed request with every member's metadata" do
    {:ok, []} = Hub.poll("ai-token")

    updates = [
      %{
        update_id: 10,
        message: %{
          chat: %{id: 123},
          message_id: 10,
          message_thread_id: 7,
          media_group_id: "photos",
          photo: [%{file_id: "one"}],
          caption: "/ai photos",
          caption_entities: [%{type: "bold", offset: 4, length: 6}]
        }
      },
      %{
        update_id: 11,
        message: %{
          chat: %{id: 123},
          message_id: 11,
          message_thread_id: 7,
          media_group_id: "photos",
          video: %{file_id: "two", file_name: "clip.mp4", mime_type: "video/mp4"}
        }
      }
    ]

    assert {:ok, 12} = UpdateProcessor.process(poller_state(), updates)
    assert {:ok, [request]} = Hub.poll("ai-token")
    assert request.datatype == "album"
    assert request.message_thread_id == 7
    assert request.media_group_id == "photos"
    assert request.caption == "/ai photos"
    assert {:ok, [one, two]} = request.data |> Base.decode64!() |> MediaAlbum.decode()
    assert one.data == "one"
    assert one.message_id == 10
    assert two.data == "two"
    assert two.file_name == "clip.mp4"
    assert two.mime_type == "video/mp4"
    assert :ok = Hub.respond("ai-token", request.req_id, "text", "reply")
  end

  test "an album media failure does not acknowledge earlier members" do
    state = %{
      poller_state()
      | http_get: fn _url, _opts -> {:ok, %Req.Response{status: 500, body: "failed"}} end
    }

    updates =
      for id <- [10, 11],
          do: %{
            update_id: id,
            message: %{
              chat: %{id: 123},
              message_id: id,
              media_group_id: "group",
              photo: [%{file_id: "one"}]
            }
          }

    assert {:retry, 10, {:bad_status, 500}} = UpdateProcessor.process(state, updates)
  end

  test "individual media retain captions, document metadata and entities" do
    metadata =
      MessageParser.metadata(%{
        message_id: 1,
        message_thread_id: 7,
        caption: "/ai document",
        document: %{file_id: "document", file_name: "report.pdf", mime_type: "application/pdf"}
      })

    assert metadata.file_name == "report.pdf"
    assert metadata.mime_type == "application/pdf"
    message = Message.new(222, 123, "file", "bytes", nil, Map.to_list(metadata))
    assert Message.text(message) == "/ai document"
    assert Message.to_client(message, "req").caption == "/ai document"
  end

  test "the poller collects an album across polls without acknowledging it early" do
    parent = self()
    {:ok, []} = Hub.poll("ai-token")

    updates =
      for id <- [10, 11],
          do: %{
            update_id: id,
            message: %{
              chat: %{id: 123},
              message_id: id,
              media_group_id: "collected",
              caption: if(id == 10, do: "/ai photos", else: nil),
              photo: [%{file_id: "one"}]
            }
          }

    count = start_supervised!({Agent, fn -> 0 end})

    poller =
      start_supervised!(
        {Exiron.Hub.Telegram.Poller,
         token: "bot-token",
         group_albums: true,
         max_download_bytes: 1024,
         get_updates: fn opts ->
           n = Agent.get_and_update(count, &{&1, &1 + 1})
           send(parent, {:poll_options, n, opts})

           cond do
             Keyword.get(opts, :offset) == 12 -> {:error, %ExGram.Error{code: 401}}
             n == 0 -> {:ok, Enum.take(updates, 1)}
             true -> {:ok, updates}
           end
         end,
         get_file: poller_state().get_file,
         http_get: poller_state().http_get}
      )

    ref = Process.monitor(poller)
    assert_receive {:poll_options, 0, first}
    assert first[:timeout] == 25
    assert_receive {:poll_options, 1, second}, 1000
    assert second[:timeout] == 0
    refute Keyword.has_key?(second, :offset)
    assert_receive {:DOWN, ^ref, :process, ^poller, :normal}, 2000
    assert {:ok, [%{datatype: "album"} = request]} = Hub.poll("ai-token")
    assert {:ok, items} = request.data |> Base.decode64!() |> MediaAlbum.decode()
    assert length(items) == 2
  end

  test "default intake preserves individual media delivery for existing handlers" do
    {:ok, []} = Hub.poll("ai-token", listen: true)

    updates =
      for id <- [21, 22],
          do: %{
            update_id: id,
            message: %{
              chat: %{id: 123},
              message_id: id,
              media_group_id: "legacy",
              photo: [%{file_id: "one"}]
            }
          }

    assert {:ok, 23} = UpdateProcessor.process(%{poller_state() | group_albums: false}, updates)
    assert {:ok, [one, two]} = Hub.poll("ai-token", listen: true)
    assert one.datatype == "image"
    assert two.datatype == "image"
    assert one.msgtype == "listen"
    assert two.msgtype == "listen"
    assert one.media_group_id == "legacy"
    assert Base.decode64!(one.data) == "one"
  end

  defp poller_state do
    %PollerState{
      token: "bot-token",
      group_albums: true,
      max_download_bytes: 1024,
      get_file: fn id, _opts -> {:ok, %{file_path: "files/" <> id}} end,
      http_get: fn url, _opts ->
        {:ok, %Req.Response{status: 200, body: List.last(String.split(url, "/"))}}
      end
    }
  end
end
