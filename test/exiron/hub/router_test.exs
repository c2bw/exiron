defmodule Exiron.Hub.RouterTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{Message, Router}
  import Exiron.Support.RouterHelper

  test "matches the longest command prefix for a Telegram message" do
    router = load_router!()

    message = Message.new(222, 123, "text", "/aiv explain this")

    assert {:ok, route} = Router.match(router, message)
    assert route.to == "assistant"
    assert route.messages == ["/aiv", "/ai"]
  end

  test "matches commands addressed to a Telegram bot username" do
    router = load_router!()

    assert {:ok, %{to: "assistant"}} =
             Router.match_text(router, 123, "/ai@AssistantBot explain this")

    assert {:ok, %{to: "assistant"}} =
             Router.match_text(router, 123, "/aiv@assistant_bot")

    assert {:ok, %{to: "powerwall"}} =
             Router.match_text(router, 123, "/power@StatusBot now")

    assert :error = Router.match_text(router, 123, "/unknown@AssistantBot")
    assert :error = Router.match_text(router, 123, "/aivextra@AssistantBot")
  end

  test "matches command prefixes followed by any whitespace boundary" do
    router = load_router!()

    for separator <- ["\t", "\n", "\r\n"] do
      assert {:ok, %{to: "assistant"}} =
               Router.match_text(router, 123, "/ai#{separator}explain this")
    end

    assert :error = Router.match_text(router, 123, "/aix explain this")
  end

  test "prefers an explicitly addressed route over a normalized command route" do
    path =
      write_router!("router-addressed-command", """
      aliases:
        telegram:
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
            powerwall:
              messages:
                - "/ai@SpecialBot"
      hooks:
        assistant: "ai-token"
        powerwall: "power-token"
      """)

    assert {:ok, router} = Router.load(path)

    assert {:ok, %{to: "powerwall"}} = Router.match_text(router, 123, "/ai@SpecialBot")
    assert {:ok, %{to: "assistant"}} = Router.match_text(router, 123, "/ai@OtherBot")
  end

  test "finds push targets for hooks marked pushable" do
    router = load_router!()

    assert Router.push_targets(router, "assistant") == [
             %{service_id: 222, chat_id: 123, default_bot: nil}
           ]

    assert Router.push_targets(router, "assistant", 123) == [
             %{service_id: 222, chat_id: 123, default_bot: nil}
           ]

    assert Router.push_targets(router, "assistant", 456) == []
    assert Router.push_targets(router, "missing") == []
  end

  test "indexes listener addresses and route snapshots by hook" do
    router = load_router!()

    assert Router.can_listen?(router, "assistant", %{service_id: 222, chat_id: 123})
    refute Router.can_listen?(router, "assistant", %{service_id: 222, chat_id: 456})
    refute Router.can_listen?(router, "missing", %{service_id: 222, chat_id: 123})

    assert Router.snapshot_for_hook(router, "assistant") ==
             router
             |> Router.snapshot()
             |> Enum.filter(&(&1.to == "assistant"))

    assert Router.snapshot_for_hook(router, "missing") == []
  end

  test "includes route default bot in push targets and snapshots" do
    path =
      write_router!("router-default-bot", """
      aliases:
        telegram:
          home: 123
      routes:
        home:
          middleware:
            - family
          push: true
          default_bot: helper-bot
      middlewares:
        family:
          routes:
            assistant:
              messages:
                - "/ai"
      hooks:
        assistant: "ai-token"
      """)

    assert {:ok, router} = Router.load(path)

    assert Router.push_targets(router, "assistant") == [
             %{service_id: 222, chat_id: 123, default_bot: "helper-bot"}
           ]

    assert [%{default_bot: "helper-bot"}] = Router.snapshot(router)
  end

  test "rejects empty route default bot" do
    path =
      write_router!("router-empty-default-bot", """
      aliases:
        telegram:
          home: 123
      routes:
        home:
          middleware:
            - family
          default_bot: " "
      middlewares:
        family:
          routes:
            assistant:
              messages:
                - "/ai"
      hooks:
        assistant: "ai-token"
      """)

    assert Router.load(path) == {:error, "routes.home.default_bot must be a non-empty string"}
  end

  test "rejects route files with non-map roots" do
    path = write_router!("router", "- not\n- a\n- map\n")

    assert Router.load(path) == {:error, "routes file must contain a map"}
  end

  test "returns useful errors for missing telegram aliases" do
    path =
      write_router!("router", """
      routes:
        missing:
          middleware:
            - family
      middlewares:
        family:
          routes:
            assistant:
              messages:
                - "/ai"
      hooks:
        assistant: "ai-token"
      """)

    assert Router.load(path) == {:error, "missing telegram alias: missing"}
  end

  test "rejects non-string route messages" do
    path =
      write_router!("router", """
      aliases:
        telegram:
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
                - 12
      hooks:
        assistant: "ai-token"
      """)

    assert Router.load(path) == {:error, "route messages must be strings"}
  end

  test "rejects non-map hooks" do
    path =
      write_router!("router", """
      hooks:
        - assistant
      """)

    assert Router.load(path) == {:error, "hooks must be a map"}
  end

  test "rejects empty hook tokens" do
    path =
      write_router!("router", """
      hooks:
        assistant: "   "
      """)

    assert Router.load(path) == {:error, ~s(hook "assistant" token must be a non-empty string)}
  end

  test "trims hook tokens" do
    path =
      write_router!("router", """
      hooks:
        assistant: " ai-token "
      """)

    assert {:ok, router} = Router.load(path)
    assert Router.hook_for_token(router, "ai-token") == "assistant"
    refute Router.hook_for_token(router, " ai-token ")
  end

  test "rejects duplicate hook tokens after trimming" do
    path =
      write_router!("router-duplicate-hook-tokens", """
      hooks:
        assistant: shared-token
        status: " shared-token "
      """)

    assert Router.load(path) == {:error, "hook tokens must be unique"}
  end

  test "strips matched command prefix when passthrough is true" do
    path =
      write_router!("router-passthrough", """
      aliases:
        telegram:
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
                - "/example"
                - "/example sub"
              passthrough: true
            powerwall:
              messages:
                - "/power"
      hooks:
        assistant: "ai-token"
        powerwall: "power-token"
      """)

    assert {:ok, router} = Router.load(path)

    msg1 = Message.new(222, 123, "text", "/example new")
    assert {:ok, route} = Router.match(router, msg1)
    assert route.passthrough == true
    assert Router.routed_message(msg1, route).data == "/new"

    msg2 = Message.new(222, 123, "text", "/example@AssistantBot   new item")
    assert Router.routed_message(msg2, route).data == "/new item"

    msg3 = Message.new(222, 123, "text", "/example sub extra")
    assert Router.routed_message(msg3, route).data == "/extra"

    msg4 = Message.new(222, 123, "text", "/example")
    assert Router.routed_message(msg4, route).data == "/"

    raw_msg = Message.new(222, 123, "text", "/power now")
    assert {:ok, raw_route} = Router.match(router, raw_msg)
    assert raw_route.passthrough == false
    assert Router.routed_message(raw_msg, raw_route).data == "/power now"
  end

  test "rejects non-boolean passthrough option" do
    path =
      write_router!("router-invalid-passthrough", """
      aliases:
        telegram:
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
              passthrough: "yes"
      hooks:
        assistant: "ai-token"
      """)

    assert Router.load(path) ==
             {:error, "middlewares.family.routes.assistant.passthrough must be a boolean"}
  end

  test "rejects conflicting passthrough settings for the same chat prefix" do
    path =
      write_router!("router-conflicting-passthrough", """
      aliases:
        telegram:
          home: 123
      routes:
        home:
          middleware:
            - first
            - second
      middlewares:
        first:
          routes:
            assistant:
              messages:
                - "/ai"
              passthrough: true
        second:
          routes:
            assistant:
              messages:
                - "/ai"
              passthrough: false
      hooks:
        assistant: "ai-token"
      """)

    assert Router.load(path) ==
             {:error,
              ~s(message prefix "/ai" for "assistant" has conflicting passthrough settings)}
  end

  defp load_router! do
    load_router!("router", """
    aliases:
      telegram:
        home: 123
    routes:
      home:
        middleware:
          - family
        push: true
    middlewares:
      family:
        routes:
          assistant:
            messages:
              - "/ai"
              - "/aiv"
          powerwall:
            messages:
              - "/power"
    hooks:
      assistant: "ai-token"
      powerwall: "power-token"
    """)
  end
end
