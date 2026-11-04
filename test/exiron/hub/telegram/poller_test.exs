defmodule Exiron.Hub.Telegram.PollerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Exiron.Support.Eventually
  alias Exiron.Hub
  alias Exiron.Hub.Telegram
  import Exiron.Support.RouterHelper

  setup do
    :ok = Hub.configure(load_router!("telegram-poller"), Telegram.new([]))
    :ok
  end

  test "records downloaded Telegram files as incoming messages" do
    start_poller!(
      get_file: fn "file-id", [token: "bot-token"] ->
        {:ok, %{file_path: "documents/file.txt"}}
      end,
      http_get: fn "https://api.telegram.org/file/botbot-token/documents/file.txt", opts ->
        assert Keyword.fetch!(opts, :finch) == Exiron.Finch
        collect_response(opts, [{:data, "hello "}, {:data, "file"}], 200)
      end
    )

    assert_eventually(fn ->
      assert [%{datatype: "file", preview: "file payload, 10 bytes"}] = Hub.status().events
    end)
  end

  test "accepts Telegram file responses with string keys" do
    start_poller!(
      get_file: fn "file-id", [token: "bot-token"] ->
        {:ok, %{"file_path" => "documents/file.txt"}}
      end,
      http_get: fn "https://api.telegram.org/file/botbot-token/documents/file.txt", opts ->
        collect_response(opts, [{:data, "hello file"}], 200)
      end
    )

    assert_eventually(fn ->
      assert [%{datatype: "file", preview: "file payload, 10 bytes"}] = Hub.status().events
    end)
  end

  test "records Telegram stickers as files with their emoji representation" do
    sticker_emoji = "\u{1F923}"

    emoji_list = [
      "\u{1F606}",
      "\u{1F923}",
      "\u{1F600}",
      "\u{1F602}",
      "\u{1F604}",
      "\u{1F603}",
      "\u{1F601}"
    ]

    assert {:ok, []} = Hub.poll("ai-token", listen: true)

    start_poller!(
      message: %{
        chat: %{id: 123},
        sticker: %{
          file_id: "sticker-id",
          file_unique_id: "sticker-unique-id",
          emoji: sticker_emoji
        }
      },
      get_file: fn "sticker-id", [token: "bot-token"] ->
        {:ok, %{file_path: "stickers/fire.webp"}}
      end,
      http_get: fn "https://api.telegram.org/file/botbot-token/stickers/fire.webp", opts ->
        assert Keyword.fetch!(opts, :finch) == Exiron.Finch
        collect_response(opts, [{:data, "sticker bytes"}], 200)
      end
    )

    assert_eventually(fn ->
      assert %{delivery: %{queues: %{"assistant" => queue}}} = :sys.get_state(Hub)
      assert [request] = Exiron.Hub.QueueBuffer.items(queue)
      assert request.msgtype == "listen"
      assert request.datatype == "file"
      assert Base.decode64!(request.data) == "sticker bytes"
      assert request.sticker_id == "sticker-id"
      assert request.file_unique_id == "sticker-unique-id"
      assert request.sticker_emoji == sticker_emoji
      assert request.emoji_list == emoji_list

      assert [
               %{
                 datatype: "file",
                 sticker_id: "sticker-id",
                 file_unique_id: "sticker-unique-id",
                 sticker_emoji: ^sticker_emoji,
                 emoji_list: ^emoji_list
               }
               | _events
             ] =
               Hub.status().events
    end)
  end

  test "records unmatched sticker emoji with an empty emoji list" do
    sticker_emoji = "\u{1F916}"
    assert {:ok, []} = Hub.poll("ai-token", listen: true)

    start_poller!(
      message: %{chat: %{id: 123}, sticker: %{file_id: "sticker-id", emoji: sticker_emoji}},
      get_file: fn "sticker-id", [token: "bot-token"] ->
        {:ok, %{file_path: "stickers/robot.webp"}}
      end,
      http_get: fn "https://api.telegram.org/file/botbot-token/stickers/robot.webp", opts ->
        assert Keyword.fetch!(opts, :finch) == Exiron.Finch
        collect_response(opts, [{:data, "sticker bytes"}], 200)
      end
    )

    assert_eventually(fn ->
      assert %{delivery: %{queues: %{"assistant" => queue}}} = :sys.get_state(Hub)
      assert [request] = Exiron.Hub.QueueBuffer.items(queue)
      assert request.sticker_emoji == sticker_emoji
      assert request.emoji_list == []

      assert [
               %{
                 datatype: "file",
                 sticker_id: "sticker-id",
                 sticker_emoji: ^sticker_emoji,
                 emoji_list: []
               }
               | _events
             ] =
               Hub.status().events
    end)
  end

  test "records captioned Telegram photos as image messages" do
    start_poller!(
      message: %{
        chat: %{id: 123},
        caption: "look at this",
        photo: [%{file_id: "small-photo"}, %{file_id: "large-photo"}]
      },
      get_file: fn "large-photo", [token: "bot-token"] ->
        {:ok, %{file_path: "photos/image.jpg"}}
      end,
      http_get: fn "https://api.telegram.org/file/botbot-token/photos/image.jpg", opts ->
        assert Keyword.fetch!(opts, :finch) == Exiron.Finch
        collect_response(opts, [{:data, "image bytes"}], 200)
      end
    )

    assert_eventually(fn ->
      assert [%{datatype: "image", preview: "image payload, 11 bytes"}] = Hub.status().events
    end)
  end

  test "records Telegram message ids, sender, and bot name" do
    assert {:ok, []} = Hub.poll("ai-token")

    start_poller!(
      bot_name: "assistant-bot",
      message: %{
        chat: %{id: 123},
        from: %{
          id: 42,
          is_bot: false,
          first_name: "Ada",
          last_name: "Lovelace",
          username: "ada",
          language_code: "en"
        },
        message_id: 1234,
        text: "/ai hello",
        reply_to_message: %{message_id: 1201}
      }
    )

    assert_eventually(fn ->
      assert %{delivery: %{queues: %{"assistant" => queue}}} = :sys.get_state(Hub)
      assert [request] = Exiron.Hub.QueueBuffer.items(queue)
      assert request.instance == "assistant-bot"
      assert request.message_id == 1234
      assert request.reply_to_message_id == 1201

      assert request.from == %{
               id: 42,
               is_bot: false,
               first_name: "Ada",
               last_name: "Lovelace",
               username: "ada",
               language_code: "en"
             }
    end)
  end

  test "records Telegram bot added and removed group membership events" do
    start_poller!(
      bot_name: "assistant-bot",
      get_updates_result:
        {:ok,
         [
           %{
             update_id: 1,
             my_chat_member: %{
               chat: %{id: 123, title: "Home"},
               old_chat_member: %{status: "left"},
               new_chat_member: %{status: "member", user: %{username: "assistant_bot"}}
             }
           },
           %{
             update_id: 2,
             my_chat_member: %{
               chat: %{id: 123, title: "Home"},
               old_chat_member: %{status: "member"},
               new_chat_member: %{status: "kicked", user: %{username: "assistant_bot"}}
             }
           }
         ]}
    )

    assert_eventually(fn ->
      assert [
               %{
                 action: "removed",
                 chat_id: 123,
                 chat_title: "Home",
                 bot_name: "assistant-bot",
                 old_status: "member",
                 new_status: "kicked"
               },
               %{
                 action: "added",
                 chat_id: 123,
                 chat_title: "Home",
                 bot_name: "assistant-bot",
                 old_status: "left",
                 new_status: "member"
               }
             ] = Hub.status().membership_events
    end)
  end

  test "ignores permanent Telegram file download failures" do
    start_poller!(
      get_file: fn "file-id", [token: "bot-token"] ->
        {:ok, %{file_path: "documents/file.txt"}}
      end,
      http_get: fn _url, opts -> collect_response(opts, [{:data, "nope"}], 404) end
    )

    refute_eventually(fn ->
      Hub.status().events != []
    end)
  end

  test "retries transient media failures without acknowledging the update" do
    parent = self()
    attempts = start_supervised!({Agent, fn -> 0 end})

    update = %{
      update_id: 41,
      message: %{chat: %{id: 123}, document: %{file_id: "file-id"}}
    }

    get_updates = fn options ->
      send(parent, {:poll_options, options})

      case Keyword.get(options, :offset) do
        nil -> {:ok, [update]}
        41 -> {:ok, [update]}
        42 -> {:ok, []}
      end
    end

    pid =
      start_supervised!(
        {Exiron.Hub.Telegram.Poller,
         token: "bot-token",
         get_updates: get_updates,
         get_file: fn "file-id", [token: "bot-token"] ->
           {:ok, %{file_path: "documents/file.txt"}}
         end,
         http_get: fn _url, opts ->
           attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)
           send(parent, {:download_attempt, attempt})

           status = if attempt == 1, do: 500, else: 200
           collect_response(opts, [{:data, "hello file"}], status)
         end,
         empty_poll_delay: 5_000}
      )

    assert_receive {:poll_options, initial_options}
    refute Keyword.has_key?(initial_options, :offset)
    assert_receive {:download_attempt, 1}

    assert_receive {:poll_options, retry_options}, 1_500
    assert Keyword.fetch!(retry_options, :offset) == 41
    assert_receive {:download_attempt, 2}

    assert_eventually(fn ->
      assert [%{datatype: "file", preview: "file payload, 10 bytes"}] = Hub.status().events
    end)

    assert_receive {:poll_options, acknowledged_options}
    assert Keyword.fetch!(acknowledged_options, :offset) == 42

    GenServer.stop(pid)
  end

  test "ignores downloaded Telegram files larger than the limit" do
    start_poller!(
      max_download_bytes: 8,
      get_file: fn "file-id", [token: "bot-token"] ->
        {:ok, %{file_path: "documents/file.txt"}}
      end,
      http_get: fn _url, opts -> collect_response(opts, [{:data, "too large"}], 200) end
    )

    refute_eventually(fn ->
      Hub.status().events != []
    end)
  end

  test "records the last Telegram poll time even when polling fails" do
    start_poller!(get_updates_result: {:error, :unauthorized})

    assert_eventually(fn ->
      assert %DateTime{} = Hub.status().telegram_last_polled_at
    end)
  end

  test "stops polling and reports unhealthy after Telegram unauthorized errors" do
    parent = self()
    unauthorized = %ExGram.Error{code: 401, message: "Unauthorized"}

    :ok =
      Hub.configure(
        load_router!("telegram-poller-unauthorized"),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}])
      )

    log =
      capture_log(fn ->
        pid =
          start_supervised!(
            {Exiron.Hub.Telegram.Poller,
             token: "bot-token",
             get_updates: fn options ->
               send(parent, {:poll_options, options})
               {:error, unauthorized}
             end}
          )

        assert_receive {:poll_options, _options}
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
        refute_receive {:poll_options, _options}, 50
      end)

    assert log =~ "Telegram polling stopped"
    assert log =~ "Unauthorized"

    assert_eventually(fn ->
      refute Hub.status().telegram_polling
      assert [%{polling: false}] = Hub.status().chats
    end)
  end

  test "reports unhealthy when a poller process terminates abruptly" do
    parent = self()

    :ok =
      Hub.configure(
        load_router!("telegram-poller-crash"),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}])
      )

    refute Hub.status().telegram_polling
    assert [%{polling: false}] = Hub.status().chats

    pid =
      start_supervised!(%{
        id: {:temporary_telegram_poller, make_ref()},
        start:
          {Exiron.Hub.Telegram.Poller, :start_link,
           [
             [
               token: "bot-token",
               get_updates: fn _options ->
                 send(parent, :poll_started)

                 receive do
                   :finish_poll -> {:ok, []}
                 end
               end
             ]
           ]},
        restart: :temporary
      })

    assert_receive :poll_started

    assert_eventually(fn ->
      assert %{pid: ^pid} = :sys.get_state(Hub).telegram_pollers["bot-token"]
      assert Hub.status().telegram_polling
    end)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert_eventually(fn ->
      refute Hub.status().telegram_polling
      assert [%{polling: false}] = Hub.status().chats
    end)
  end

  test "retries polling after Telegram forbidden errors" do
    parent = self()
    forbidden = %ExGram.Error{code: 403, message: "Forbidden: bot was kicked from the group chat"}

    pid =
      start_supervised!(
        {Exiron.Hub.Telegram.Poller,
         token: "bot-token",
         get_updates: fn options ->
           send(parent, {:poll_options, options})
           {:error, forbidden}
         end}
      )

    assert_receive {:poll_options, _options}
    assert_receive {:poll_options, _options}, 1_500

    GenServer.stop(pid)
  end

  test "retries polling after transient errors" do
    parent = self()

    pid =
      start_supervised!(
        {Exiron.Hub.Telegram.Poller,
         token: "bot-token",
         get_updates: fn options ->
           send(parent, {:poll_options, options})
           {:error, :transient}
         end}
      )

    assert_receive {:poll_options, _options}
    assert_receive {:poll_options, _options}, 1_500

    GenServer.stop(pid)
  end

  test "records the last Telegram poll time when a long poll starts" do
    parent = self()

    pid =
      start_supervised!(
        {Exiron.Hub.Telegram.Poller,
         token: "bot-token",
         get_updates: fn _options ->
           send(parent, :poll_started)

           receive do
             :finish_poll -> {:ok, []}
           end
         end}
      )

    assert_receive :poll_started

    assert_eventually(fn ->
      assert %DateTime{} = Hub.status().telegram_last_polled_at
    end)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  test "polls Telegram without incompatible adapter options" do
    parent = self()

    pid =
      start_supervised!(
        {Exiron.Hub.Telegram.Poller,
         token: "bot-token",
         get_updates: fn options ->
           send(parent, {:poll_options, options})
           {:ok, []}
         end,
         empty_poll_delay: 1_000}
      )

    assert_receive {:poll_options, options}
    refute Keyword.has_key?(options, :adapter_opts)

    assert Keyword.fetch!(options, :allowed_updates) == [
             "message",
             "my_chat_member",
             "callback_query"
           ]

    GenServer.stop(pid)
  end

  test "offset Telegram polling does not set incompatible adapter options" do
    parent = self()

    pid =
      start_supervised!(
        {Exiron.Hub.Telegram.Poller,
         token: "bot-token",
         get_updates: fn options ->
           send(parent, {:poll_options, options})

           case Keyword.get(options, :offset) do
             nil -> {:ok, [%{update_id: 1, message: nil}]}
             2 -> {:ok, []}
           end
         end,
         empty_poll_delay: 1_000}
      )

    assert_receive {:poll_options, options}
    refute Keyword.has_key?(options, :adapter_opts)

    assert Keyword.fetch!(options, :allowed_updates) == [
             "message",
             "my_chat_member",
             "callback_query"
           ]

    assert_receive {:poll_options, options}
    assert Keyword.fetch!(options, :offset) == 2
    refute Keyword.has_key?(options, :adapter_opts)

    assert Keyword.fetch!(options, :allowed_updates) == [
             "message",
             "my_chat_member",
             "callback_query"
           ]

    GenServer.stop(pid)
  end

  defp start_poller!(opts) do
    parent = self()
    poll_count = start_supervised!({Agent, fn -> 0 end})
    message = Keyword.get(opts, :message, %{chat: %{id: 123}, document: %{file_id: "file-id"}})

    get_updates_result =
      Keyword.get(opts, :get_updates_result, {
        :ok,
        [
          %{
            update_id: 1,
            message: message
          }
        ]
      })

    get_updates = fn options ->
      Agent.get_and_update(poll_count, fn
        0 ->
          send(parent, {:polled, options})

          {get_updates_result, 1}

        count ->
          {{:error, :done}, count + 1}
      end)
    end

    spec =
      {Exiron.Hub.Telegram.Poller,
       Keyword.merge(
         [
           token: "bot-token",
           get_updates: get_updates
         ],
         Keyword.delete(opts, :message)
       )}

    pid = start_supervised!(spec)
    assert_receive {:polled, _options}
    GenServer.stop(pid)
  end

  defp collect_response(opts, chunks, status) do
    collector = Keyword.fetch!(opts, :into)

    response =
      Enum.reduce_while(chunks, %Req.Response{status: status, body: ""}, fn chunk, response ->
        case collector.(chunk, {%Req.Request{}, response}) do
          {:cont, {_request, response}} -> {:cont, response}
          {:halt, {_request, response}} -> {:halt, response}
        end
      end)

    {:ok, response}
  end
end
