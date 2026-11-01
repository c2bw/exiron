defmodule Exiron.Hub.ReloadIntegrationTest do
  use Exiron.HubCase, async: false

  import ExUnit.CaptureLog

  alias Exiron.Hub
  alias Exiron.Hub.{Message, State}

  test "reload_configuration refreshes routes and Telegram bots together" do
    path =
      write_router!("hub-reload-configuration", """
      version: "1"
      telegram:
        bots:
          - name: "helper-two"
            token: "new-bot-token"
            chats:
              home: 123
      routes:
        home:
          middleware:
            - family
      middlewares:
        family:
          routes:
            assistant:
              messages:
                - "/ai"
      hooks:
        assistant: "#{Exiron.Hub.HookToken.hash("new-token")}"
      """)

    hub_config = Application.get_env(:exiron, :hub, [])

    Application.put_env(
      :exiron,
      :hub,
      hub_config
      |> Keyword.put(:config_path, path)
      |> Keyword.put(:telegram_pollers_enabled, false)
    )

    on_exit(fn ->
      Application.put_env(:exiron, :hub, hub_config)
    end)

    assert :ok = Hub.reload_configuration()

    assert %{status: :active, activated_at: %DateTime{}} =
             Hub.configuration_status(File.read!(path))

    assert %{status: :pending} = Hub.configuration_status(File.read!(path) <> "\n# not loaded\n")
    refute Map.has_key?(Hub.status(), :configuration_digest)
    assert {:error, :invalid_token} = Hub.authenticate("ai-token")
    assert {:ok, %{hook: "assistant"}} = Hub.authenticate("new-token")

    assert [
             %{
               bot_name: "helper-two",
               bot_tag: "@helper-two",
               token_fingerprint: "new-bo...oken"
             }
           ] = Hub.telegram_bots()
  end

  test "reload_configuration recovers after a boot configuration failure" do
    path = write_router!("hub-boot-failure-recovery", "routes: [\n")
    hub_config = Application.get_env(:exiron, :hub, [])

    opts =
      hub_config
      |> Keyword.put(:enabled, true)
      |> Keyword.put(:config_path, path)
      |> Keyword.put(:telegram_pollers_enabled, false)

    Application.put_env(:exiron, :hub, opts)

    on_exit(fn ->
      Application.put_env(:exiron, :hub, hub_config)
    end)

    log =
      capture_log(fn ->
        assert {:ok, %State{enabled?: false, boot_failed?: true} = state} = Hub.init(opts)
        :sys.replace_state(Hub, fn _current_state -> state end)
      end)

    assert log =~ "Exiron disabled after boot failure"
    assert %{enabled: false} = Hub.status()

    File.write!(path, """
    version: "1"
    hooks:
      assistant: "#{Exiron.Hub.HookToken.hash("ai-token")}"
    """)

    assert :ok = Hub.reload_configuration()
    assert %{enabled: true} = Hub.status()
    assert {:ok, %{hook: "assistant"}} = Hub.authenticate("ai-token")
    refute :sys.get_state(Hub).boot_failed?
  end

  test "reload_configuration preserves active work when hook credentials are unchanged" do
    path =
      write_router!("hub-reload-configuration-preserves-work", """
      version: "1"
      telegram:
        bots:
          - name: "helper-two"
            token: "bot-token"
            chats:
              home: 123
      routes:
        home:
          middleware:
            - family
      middlewares:
        family:
          routes:
            assistant:
              messages:
                - "/ai"
      hooks:
        assistant: "#{Exiron.Hub.HookToken.hash("ai-token")}"
      """)

    hub_config = Application.get_env(:exiron, :hub, [])

    Application.put_env(
      :exiron,
      :hub,
      hub_config
      |> Keyword.put(:config_path, path)
      |> Keyword.put(:telegram_pollers_enabled, false)
    )

    on_exit(fn ->
      Application.put_env(:exiron, :hub, hub_config)
    end)

    assert {:ok, %{messages: []}} =
             Hub.connect_socket("ai-token", client_id: "socket", listen: true, pid: self())

    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

    assert_receive {:exiron_messages, delivery_ref, [request]}
    pending_timer = :sys.get_state(Hub).delivery.pending[request.req_id].timer

    assert :ok = Hub.reload_configuration()
    refute_receive {:exiron_socket_replaced, _pid}

    state = :sys.get_state(Hub)
    assert state.delivery.clients["assistant"].pid == self()
    assert state.delivery.clients["assistant"].socket_delivery.ref == delivery_ref
    assert state.delivery.pending[request.req_id].claimed?
    assert is_integer(Process.read_timer(pending_timer))
    assert [%{connected: true, listening: true}] = Hub.status().hooks
  end

  test "reload_configuration invalidates active websocket sessions when tokens rotate" do
    path =
      write_router!("hub-reload-configuration-rotated-token", """
      version: "1"
      telegram:
        bots:
          - name: "helper-two"
            token: "new-bot-token"
            chats:
              home: 123
      routes:
        home:
          middleware:
            - family
      middlewares:
        family:
          routes:
            assistant:
              messages:
                - "/ai"
      hooks:
        assistant: "#{Exiron.Hub.HookToken.hash("new-token")}"
      """)

    hub_config = Application.get_env(:exiron, :hub, [])

    Application.put_env(
      :exiron,
      :hub,
      hub_config
      |> Keyword.put(:config_path, path)
      |> Keyword.put(:telegram_pollers_enabled, false)
    )

    on_exit(fn ->
      Application.put_env(:exiron, :hub, hub_config)
    end)

    assert {:ok, %{messages: []}} =
             Hub.connect_socket("ai-token", client_id: "socket", listen: true, pid: self())

    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))
    assert_receive {:exiron_messages, _delivery_ref, [request]}

    assert [%{connected: true, listening: true}] = Hub.status().hooks

    assert :ok = Hub.reload_configuration()
    assert_receive {:exiron_socket_replaced, _pid}

    assert {:error, :invalid_token} = Hub.authenticate("ai-token")
    assert {:ok, %{hook: "assistant"}} = Hub.authenticate("new-token")
    assert [%{connected: false, listening: false}] = Hub.status().hooks

    state = :sys.get_state(Hub)
    assert state.delivery.clients == %{}
    assert Map.has_key?(state.delivery.pending, request.req_id)
    refute state.delivery.pending[request.req_id].claimed?

    assert {:ok, [redelivered]} = Hub.poll("new-token")
    assert redelivered.req_id == request.req_id
  end

  test "reload_bots preserves active websocket sessions" do
    path =
      write_router!("hub-reload-bots-preserves-clients", """
      version: "1"
      telegram:
        bots:
          - name: "helper-one"
            token: "bot-token"
            chats:
              home: 123
      routes:
        home:
          middleware:
            - family
      middlewares:
        family:
          routes:
            assistant:
              messages:
                - "/ai"
      hooks:
        assistant: "#{Exiron.Hub.HookToken.hash("ai-token")}"
      """)

    hub_config = Application.get_env(:exiron, :hub, [])

    Application.put_env(
      :exiron,
      :hub,
      hub_config
      |> Keyword.put(:config_path, path)
      |> Keyword.put(:telegram_pollers_enabled, false)
    )

    on_exit(fn ->
      Application.put_env(:exiron, :hub, hub_config)
    end)

    assert {:ok, %{messages: []}} =
             Hub.connect_socket("ai-token", client_id: "socket", listen: false, pid: self())

    assert :ok = Hub.reload_bots()
    assert [%{connected: true, listening: false}] = Hub.status().hooks

    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

    assert_receive {:exiron_messages, _delivery_ref, [request]}
    assert request.msgtype == "request"
    refute_receive {:exiron_socket_replaced, _pid}
  end

  test "reload_bots removes memberships for bots that are no longer configured" do
    :ok =
      Hub.telegram_membership_changed(%{
        chat_id: 123,
        bot_token: "bot-token",
        bot_name: "helper-one",
        bot_user_id: 42,
        new_status: "member",
        action: "added"
      })

    assert [%{chat_id: 123, present: true}] = Hub.status().bot_memberships

    path =
      write_router!("hub-reload-bots-prunes-memberships", """
      version: "1"
      telegram:
        bots:
          - name: "helper-two"
            token: "new-bot-token"
            chats:
              work: 456
      routes:
        work:
          middleware:
            - family
      middlewares:
        family:
          routes:
            assistant:
              messages:
                - "/ai"
      hooks:
        assistant: "#{Exiron.Hub.HookToken.hash("ai-token")}"
      """)

    hub_config = Application.get_env(:exiron, :hub, [])

    Application.put_env(
      :exiron,
      :hub,
      hub_config
      |> Keyword.put(:config_path, path)
      |> Keyword.put(:telegram_pollers_enabled, false)
    )

    on_exit(fn ->
      Application.put_env(:exiron, :hub, hub_config)
    end)

    assert :ok = Hub.reload_bots()
    assert Hub.status().bot_memberships == []
  end

  test "reload_bots skips automatic bot name lookups when Telegram pollers are disabled" do
    path =
      write_router!("hub-bot-name-lookup-disabled", """
      version: "1"
      telegram:
        bots:
          - token: bot-token
            chats:
              home: 123
      routes:
        home:
          middleware:
            - family
      middlewares:
        family:
          routes:
            assistant:
              messages:
                - "/ai"
      hooks:
        assistant: "#{Exiron.Hub.HookToken.hash("ai-token")}"
      """)

    hub_config = Application.get_env(:exiron, :hub, [])

    Application.put_env(
      :exiron,
      :hub,
      hub_config
      |> Keyword.put(:config_path, path)
      |> Keyword.put(:telegram_pollers_enabled, false)
      |> Keyword.put(:bot_name_resolver, fn _token ->
        send(self(), :unexpected_bot_name_lookup)
        {:ok, "assistant-bot"}
      end)
    )

    on_exit(fn ->
      Application.put_env(:exiron, :hub, hub_config)
    end)

    assert :ok = Hub.reload_bots()
    assert [%{bot_name: nil}] = Hub.telegram_bots()
    refute_receive :unexpected_bot_name_lookup
  end

  test "reload_bots resolves missing Telegram bot names asynchronously" do
    parent = self()

    path =
      write_router!("hub-bot-name-lookup", """
      version: "1"
      telegram:
        bots:
          - token: bot-token
            chats:
              home: 123
      routes:
        home:
          middleware:
            - family
      middlewares:
        family:
          routes:
            assistant:
              messages:
                - "/ai"
      hooks:
        assistant: "#{Exiron.Hub.HookToken.hash("ai-token")}"
      """)

    hub_config = Application.get_env(:exiron, :hub, [])

    Application.put_env(
      :exiron,
      :hub,
      hub_config
      |> Keyword.put(:config_path, path)
      |> Keyword.put(:telegram_pollers_enabled, false)
      |> Keyword.put(:telegram_identity_lookups_enabled, true)
      |> Keyword.put(:bot_name_resolver, fn "bot-token" ->
        send(parent, {:bot_name_lookup_started, self()})

        receive do
          :finish_bot_name_lookup -> {:ok, "assistant-bot"}
        end
      end)
    )

    on_exit(fn ->
      Application.put_env(:exiron, :hub, hub_config)
    end)

    :ok = Hub.subscribe_status()

    task = Task.async(fn -> Hub.reload_bots() end)
    assert_receive {:bot_name_lookup_started, lookup_pid}
    assert Task.await(task, 100) == :ok
    assert [%{bot_name: nil}] = Hub.telegram_bots()
    refute_receive {:hub_status_delta, _delta}, 50

    send(lookup_pid, :finish_bot_name_lookup)
    assert_receive {:hub_status_delta, %{collections: %{chats: _chats}}}
    assert [%{bot_name: "assistant-bot", bot_tag: "@assistant-bot"}] = Hub.telegram_bots()
  end

  test "reload_bots resolves bot user ids and checks configured chat membership" do
    parent = self()

    path =
      write_router!("hub-bot-membership-lookup", """
      version: "1"
      telegram:
        bots:
          - token: bot-token
            chats:
              home: 123
      routes:
        home:
          middleware:
            - family
      middlewares:
        family:
          routes:
            assistant:
              messages:
                - "/ai"
      hooks:
        assistant: "#{Exiron.Hub.HookToken.hash("ai-token")}"
      """)

    hub_config = Application.get_env(:exiron, :hub, [])

    Application.put_env(
      :exiron,
      :hub,
      hub_config
      |> Keyword.put(:config_path, path)
      |> Keyword.put(:telegram_pollers_enabled, false)
      |> Keyword.put(:telegram_identity_lookups_enabled, true)
      |> Keyword.put(:telegram_membership_lookups_enabled, true)
      |> Keyword.put(:bot_identity_resolver, fn "bot-token" ->
        {:ok, %{bot_name: "assistant-bot", bot_user_id: 42}}
      end)
      |> Keyword.put(:bot_membership_resolver, fn target ->
        send(parent, {:bot_membership_lookup, target})
        {:ok, %{status: "member"}}
      end)
    )

    on_exit(fn ->
      Application.put_env(:exiron, :hub, hub_config)
    end)

    :ok = Hub.subscribe_status()
    assert :ok = Hub.reload_bots()

    assert_receive {:hub_status_delta, %{collections: %{chats: _chats}}}

    assert_receive {:bot_membership_lookup,
                    %{
                      chat_id: 123,
                      bot_token: "bot-token",
                      bot_name: "assistant-bot",
                      bot_user_id: 42
                    }}

    assert_eventually(fn ->
      assert [%{bot_name: "assistant-bot", bot_user_id: 42}] = Hub.telegram_bots()

      assert [
               %{
                 chat_id: 123,
                 bot_name: "assistant-bot",
                 bot_user_id: 42,
                 status: "member",
                 present: true
               }
             ] = Hub.status().bot_memberships

      assert [%{bot_memberships: [%{status: "member"}]}] = Hub.status().chats
    end)
  end
end
