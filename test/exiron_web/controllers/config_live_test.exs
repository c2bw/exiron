defmodule ExironWeb.ConfigLiveTest do
  use ExironWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Exiron.Hub
  alias Exiron.Hub.{Configuration, HookToken, RouteConfiguration, Telegram}
  alias Exiron.Support.TempPath
  alias ExironWeb.ConfigLive.RouteTesting

  setup do
    hub_config = Application.get_env(:exiron, :hub, [])

    source = """
    version: "1"
    telegram:
      bots:
        - name: "helper"
          token: "123456:abcdef"
          chats:
            home: 123
            work: 456
    routes:
      home:
        middleware:
          - shared
        push: true
      work:
        middleware:
          - shared
          - alerts
    middlewares:
      shared:
        routes:
          assistant:
            messages:
              - "/ai"
      alerts:
        routes:
          status:
            messages:
              - "/status"
    hooks:
      assistant: "#{HookToken.hash("ai-token")}"
      status: "#{HookToken.hash("status-token")}"
    """

    path = temp_config_path()
    File.write!(path, source)

    Application.put_env(
      :exiron,
      :hub,
      hub_config
      |> Keyword.put(:config_path, path)
      |> Keyword.put(:telegram_pollers_enabled, false)
    )

    {:ok, configuration} = Configuration.read(path)
    {:ok, route_configuration} = RouteConfiguration.load(path)
    :ok = Hub.configure(route_configuration.router, Telegram.new(configuration.telegram))

    on_exit(fn ->
      Application.put_env(:exiron, :hub, hub_config)
    end)

    %{config_path: path, source: source, route_configuration: route_configuration}
  end

  describe "route testing domain behavior" do
    test "matches incoming messages against configured routes", %{
      route_configuration: configuration
    } do
      assert %{
               status: :match,
               route: %{chat_alias: "work", to: "status"}
             } =
               RouteTesting.test_route(
                 {:ok, configuration},
                 %{"mode" => "incoming", "chat_alias" => "work", "message" => "/status now"}
               )
    end

    test "returns empty state when incoming message missing", %{
      route_configuration: configuration
    } do
      assert %{status: :idle} =
               RouteTesting.test_route({:ok, configuration}, %{
                 "mode" => "incoming",
                 "chat_alias" => "home",
                 "message" => ""
               })
    end

    test "returns push targets from hook selector", %{route_configuration: configuration} do
      assert %{status: :push_match, targets: targets} =
               RouteTesting.test_route(
                 {:ok, configuration},
                 %{
                   "mode" => "push",
                   "chat_alias" => "home",
                   "hook" => "assistant",
                   "message" => ""
                 }
               )

      assert [%{chat_alias: "home", chat_id: 123} = List.first(targets)]
    end

    test "renders push status text", %{route_configuration: configuration} do
      result = RouteTesting.test_route({:ok, configuration}, %{"mode" => "push"})

      assert RouteTesting.route_tester_status_text(result) == "Pushes to 1"
    end
  end

  describe "ConfigLive page behavior" do
    test "GET /config visualizes unified configuration", %{conn: conn} do
      conn = log_in(conn)

      {:ok, view, _html} = live(conn, ~p"/config")

      assert has_element?(view, "#nav-config[aria-current=page]")
      assert has_element?(view, "#exiron-telegram-bot-count", "1")
      assert has_element?(view, "#exiron-route-chat-count", "2")
      assert has_element?(view, "#exiron-route-count", "3")
      assert has_element?(view, "#exiron-middleware-count", "2")
      assert has_element?(view, "#exiron-hook-count", "2")
      assert has_element?(view, "#exiron-telegram-bot-1", "helper")
      assert has_element?(view, "#exiron-chat-route-home", "shared")
      assert has_element?(view, "#exiron-middlewares", "/status")
      assert has_element?(view, "#exiron-resolved-routes", "/ai")
    end

    test "keeps the YAML and quick-add forms addressable in the editor", %{conn: conn} do
      conn = log_in(conn)

      {:ok, view, _html} = live(conn, ~p"/config")

      refute has_element?(view, "#exiron-config-form")

      view |> element("#exiron-toggle-config-editor") |> render_click()

      assert has_element?(view, "#exiron-config-form")
      assert has_element?(view, "#exiron-config-form textarea")
      assert has_element?(view, "#exiron-telegram-bot-form")
      assert has_element?(view, "#exiron-chat-route-form")
      assert has_element?(view, "#exiron-middleware-route-form")
      assert has_element?(view, "#exiron-hook-form")
    end

    test "tests fake messages against resolved routes", %{conn: conn} do
      conn = log_in(conn)

      {:ok, view, _html} = live(conn, ~p"/config")

      view
      |> form("#exiron-route-tester-form",
        route_tester: %{chat_alias: "work", message: "/status now"}
      )
      |> render_change()

      assert has_element?(view, "#exiron-route-tester-status", "Routes to status")
      assert has_element?(view, "#exiron-resolved-routes .border-l-emerald-500", "/status")
    end

    test "shows push targets for a hook", %{conn: conn} do
      conn = log_in(conn)

      {:ok, view, _html} = live(conn, ~p"/config")

      view
      |> form("#exiron-route-tester-form",
        route_tester: %{mode: "push", hook: "assistant", chat_alias: "home", message: ""}
      )
      |> render_change()

      assert has_element?(view, "#exiron-route-tester-status", "Pushes to 1")
      assert has_element?(view, "#exiron-route-tester-targets", "home (123)")
      assert has_element?(view, "#exiron-resolved-routes .border-l-emerald-500", "/ai")
    end

    test "requires dashboard authentication", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/config")
    end

    test "saves YAML edits, auto-hashes plaintext hook tokens, and reloads the running hub", %{
      conn: conn,
      config_path: config_path,
      source: source
    } do
      conn = log_in(conn)

      {:ok, view, _html} = live(conn, ~p"/config")

      updated_source =
        source
        |> String.replace(~s(name: "helper"), ~s(name: "helper-two"))
        |> String.replace(
          ~s(assistant: "#{HookToken.hash("ai-token")}"),
          ~s(assistant: "new-token")
        )

      expected_saved_source =
        String.replace(
          updated_source,
          ~s(assistant: "new-token"),
          ~s(assistant: "#{HookToken.hash("new-token")}")
        )

      view
      |> element("#exiron-toggle-config-editor")
      |> render_click()

      view
      |> form("#exiron-config-form", config: %{source: updated_source})
      |> render_submit()

      view |> element("#exiron-confirm-config") |> render_click()

      assert File.read!(config_path) == expected_saved_source
      refute File.read!(config_path) =~ "new-token"
      assert {:ok, %{hook: "assistant"}} = Exiron.Hub.authenticate("new-token")
      assert [%{bot_name: "helper-two", bot_tag: "@helper-two"}] = Exiron.Hub.telegram_bots()
      assert has_element?(view, "#exiron-config-activation[data-state=active]")
      refute has_element?(view, "#exiron-activate-config")
    end

    test "a failed activation stays visible after remount and can be retried without saving", %{
      conn: conn,
      config_path: path,
      source: source
    } do
      assert :ok = Hub.reload_configuration()
      {:ok, view, _} = live(log_in(conn), ~p"/config")
      assert has_element?(view, "#exiron-config-activation[data-state=active]")
      view |> element("#exiron-toggle-config-editor") |> render_click()

      opts = Application.get_env(:exiron, :hub)
      # Fail the reload read independently of the successful file save.
      Application.put_env(:exiron, :hub, Keyword.put(opts, :config_path, Path.dirname(path)))
      updated = source |> String.replace(HookToken.hash("ai-token"), HookToken.hash("new-token"))
      view |> form("#exiron-config-form", config: %{source: updated}) |> render_submit()
      view |> element("#exiron-confirm-config") |> render_click()
      assert File.read!(path) == updated
      assert has_element?(view, "#flash-error", "saved, but activation failed")
      assert has_element?(view, "#exiron-config-activation[data-state=failed]")
      assert {:ok, _} = Hub.authenticate("ai-token")
      assert {:error, :invalid_token} = Hub.authenticate("new-token")

      Application.put_env(:exiron, :hub, opts)
      {:ok, remounted, _} = live(log_in(conn), ~p"/config")
      assert has_element?(remounted, "#exiron-config-activation[data-state=failed]")
      remounted |> element("#exiron-activate-config") |> render_click()
      assert has_element?(remounted, "#exiron-config-activation[data-state=active]")
      assert {:ok, _} = Hub.authenticate("new-token")
      assert File.read!(path) == updated

      assert_eventually(fn ->
        assert has_element?(view, "#exiron-config-activation[data-state=active]")
      end)
    end

    test "saving while disabled shows saved but not active", %{
      conn: conn,
      source: source,
      config_path: path
    } do
      :sys.replace_state(Hub, fn _state -> Exiron.Hub.State.new() end)
      {:ok, view, _} = live(log_in(conn), ~p"/config")
      view |> element("#exiron-toggle-config-editor") |> render_click()

      view
      |> form("#exiron-config-form", config: %{source: source <> "\n# saved while disabled\n"})
      |> render_submit()

      view |> element("#exiron-confirm-config") |> render_click()

      assert File.read!(path) =~ "saved while disabled"
      assert has_element?(view, "#exiron-config-activation[data-state=disabled]")
      assert has_element?(view, "#flash-error", "not activated: Hub is disabled")
      refute has_element?(view, "#exiron-activate-config")
    end

    test "another session's save updates activation status without overwriting an unsaved editor",
         %{conn: conn, source: source} do
      {:ok, first, _} = live(log_in(conn), ~p"/config")
      {:ok, other, _} = live(log_in(conn), ~p"/config")

      for view <- [first, other],
          do: view |> element("#exiron-toggle-config-editor") |> render_click()

      draft = source <> "\n# unsaved draft\n"
      other |> form("#exiron-config-form", config: %{source: draft}) |> render_change()

      first
      |> form("#exiron-config-form", config: %{source: source <> "\n# saved elsewhere\n"})
      |> render_submit()

      first |> element("#exiron-confirm-config") |> render_click()

      assert_eventually(fn ->
        assert has_element?(other, "#exiron-config-activation[data-state=changed]")
        assert has_element?(other, "#exiron-config-form textarea", "unsaved draft")
      end)

      refute has_element?(other, "#exiron-activate-config")
    end

    test "rejects stale saves from another dashboard session", %{
      conn: conn,
      config_path: config_path,
      source: source
    } do
      conn = log_in(conn)
      {:ok, first_view, _html} = live(conn, ~p"/config")
      {:ok, stale_view, _html} = live(conn, ~p"/config")

      first_view |> element("#exiron-toggle-config-editor") |> render_click()
      stale_view |> element("#exiron-toggle-config-editor") |> render_click()

      first_source =
        String.replace(
          source,
          ~s(assistant: "#{HookToken.hash("ai-token")}"),
          ~s(assistant: "first-token")
        )

      stale_source =
        String.replace(
          source,
          ~s(assistant: "#{HookToken.hash("ai-token")}"),
          ~s(assistant: "stale-token")
        )

      expected_first_source =
        String.replace(
          source,
          ~s(assistant: "#{HookToken.hash("ai-token")}"),
          ~s(assistant: "#{HookToken.hash("first-token")}")
        )

      first_view
      |> form("#exiron-config-form", config: %{source: first_source})
      |> render_submit()

      first_view |> element("#exiron-confirm-config") |> render_click()

      stale_view
      |> form("#exiron-config-form", config: %{source: stale_source})
      |> render_submit()

      assert File.read!(config_path) == expected_first_source
      assert has_element?(stale_view, "#flash-error", "Configuration changed on disk")
      assert {:ok, %{hook: "assistant"}} = Exiron.Hub.authenticate("first-token")
      assert {:error, :invalid_token} = Exiron.Hub.authenticate("stale-token")
    end

    test "does not report activation success for a different configuration file", %{
      conn: conn,
      source: source
    } do
      {:ok, view, _} = live(log_in(conn), ~p"/config")
      view |> element("#exiron-toggle-config-editor") |> render_click()
      other_path = temp_config_path()
      File.write!(other_path, Configuration.empty_source())
      opts = Application.get_env(:exiron, :hub)
      Application.put_env(:exiron, :hub, Keyword.put(opts, :config_path, other_path))

      view
      |> form("#exiron-config-form", config: %{source: source <> "\n# saved source\n"})
      |> render_submit()

      view |> element("#exiron-confirm-config") |> render_click()

      assert has_element?(view, "#exiron-config-activation[data-state=pending]")
      assert has_element?(view, "#flash-error", "not confirmed active")
    end

    test "shows validation errors before saving", %{conn: conn, config_path: config_path} do
      conn = log_in(conn)
      original_source = File.read!(config_path)

      {:ok, view, _html} = live(conn, ~p"/config")

      view
      |> element("#exiron-toggle-config-editor")
      |> render_click()

      view
      |> form("#exiron-config-form", config: %{source: "routes:\n  - bad"})
      |> render_change()

      assert has_element?(view, "#exiron-config-editor-summary", "Invalid configuration")

      view
      |> form("#exiron-config-form", config: %{source: "routes:\n  - bad"})
      |> render_submit()

      assert File.read!(config_path) == original_source
    end

    test "review is redacted and cancellation or editing does not write", %{
      conn: conn,
      source: source,
      config_path: path
    } do
      {:ok, view, _} = live(log_in(conn), ~p"/config")
      view |> element("#exiron-toggle-config-editor") |> render_click()
      updated = String.replace(source, "123456:abcdef", "999999:private")
      view |> form("#exiron-config-form", config: %{source: updated}) |> render_submit()
      assert has_element?(view, "#exiron-config-review[data-kind=save]")
      refute has_element?(view, "#exiron-config-review", "123456:abcdef")
      refute has_element?(view, "#exiron-config-review", "999999:private")
      assert File.read!(path) == source
      view |> element("#exiron-cancel-config-review") |> render_click()
      refute has_element?(view, "#exiron-config-review")
      assert File.read!(path) == source
      view |> form("#exiron-config-form", config: %{source: updated}) |> render_submit()
      view |> form("#exiron-config-form", config: %{source: source}) |> render_change()
      refute has_element?(view, "#exiron-config-review")
      assert File.read!(path) == source
    end

    test "restores the last activated configuration over invalid YAML while the Hub is boot-failed",
         %{conn: conn, source: source, config_path: path} do
      assert :ok = Hub.reload_configuration()
      broken = "telegram: ["
      File.write!(path, broken)
      :sys.replace_state(Hub, fn _ -> Exiron.Hub.State.new(%{boot_failed?: true}) end)
      {:ok, view, _} = live(log_in(conn), ~p"/config")
      assert has_element?(view, "#exiron-config-activation[data-state=invalid]")
      assert has_element?(view, "#exiron-config-history")
      view |> element("#exiron-rollback-previous") |> render_click()
      assert has_element?(view, "#exiron-config-review[data-kind=rollback]")
      assert File.read!(path) == broken
      view |> element("#exiron-confirm-config") |> render_click()
      assert File.read!(path) == source
      assert has_element?(view, "#exiron-config-activation[data-state=active]")
      assert {:ok, _} = Hub.authenticate("ai-token")

      assert {:ok, ^broken} =
               Exiron.Hub.ConfigurationHistory.fetch(
                 path,
                 Exiron.Hub.ConfigurationHistory.digest(broken)
               )
    end

    test "a reviewed change cannot overwrite an external edit", %{
      conn: conn,
      source: source,
      config_path: path
    } do
      {:ok, view, _} = live(log_in(conn), ~p"/config")
      view |> element("#exiron-toggle-config-editor") |> render_click()

      view
      |> form("#exiron-config-form", config: %{source: source <> "\n# reviewed"})
      |> render_submit()

      external = source <> "\n# external"
      File.write!(path, external)
      view |> element("#exiron-confirm-config") |> render_click()
      assert File.read!(path) == external
      assert has_element?(view, "#flash-error", "Configuration changed on disk")
    end

    test "can roll back a saved configuration after activation failed", %{
      conn: conn,
      source: source,
      config_path: path
    } do
      assert :ok = Hub.reload_configuration()
      {:ok, view, _} = live(log_in(conn), ~p"/config")
      view |> element("#exiron-toggle-config-editor") |> render_click()
      updated = String.replace(source, HookToken.hash("ai-token"), HookToken.hash("broken-token"))
      view |> form("#exiron-config-form", config: %{source: updated}) |> render_submit()
      opts = Application.get_env(:exiron, :hub)
      Application.put_env(:exiron, :hub, Keyword.put(opts, :config_path, Path.dirname(path)))
      view |> element("#exiron-confirm-config") |> render_click()
      assert has_element?(view, "#exiron-config-activation[data-state=failed]")
      Application.put_env(:exiron, :hub, opts)
      view |> element("#exiron-rollback-previous") |> render_click()
      view |> element("#exiron-confirm-config") |> render_click()
      assert File.read!(path) == source
      assert has_element?(view, "#exiron-config-activation[data-state=active]")
      assert {:ok, _} = Hub.authenticate("ai-token")
      assert {:error, :invalid_token} = Hub.authenticate("broken-token")
    end

    test "diagnostics describe the proposed configuration and remain advisory", %{
      conn: conn,
      source: source,
      config_path: path
    } do
      {:ok, view, _} = live(log_in(conn), ~p"/config")
      assert has_element?(view, "#exiron-config-diagnostics", "No configuration warnings")
      view |> element("#exiron-toggle-config-editor") |> render_click()

      {:ok, candidate} =
        RouteConfiguration.put_hook(source, %{"hook" => "unused", "token" => "unused-token"})

      view |> form("#exiron-config-form", config: %{source: candidate}) |> render_submit()
      assert has_element?(view, "#exiron-review-diagnostics [data-kind=unreachable_hook]")
      refute has_element?(view, "#exiron-config-diagnostics [data-kind=unreachable_hook]")
      refute has_element?(view, "#exiron-confirm-config[disabled]")
      refute has_element?(view, "#exiron-review-diagnostics", "unused-token")
      assert File.read!(path) == source
      view |> element("#exiron-confirm-config") |> render_click()

      assert has_element?(
               view,
               "#exiron-config-diagnostics [data-kind=unreachable_hook] a[href='#exiron-hook-unused']"
             )

      assert has_element?(view, "#exiron-hook-unused")
      assert has_element?(view, "#exiron-config-activation[data-state=active]")
      refute has_element?(view, "#exiron-review-diagnostics")
      assert {:ok, _} = Hub.authenticate("unused-token")

      # A subsequent review must remove stale warning rows from its stream.
      view |> form("#exiron-config-form", config: %{source: source}) |> render_submit()
      assert has_element?(view, "#exiron-review-diagnostics", "No configuration warnings")
      refute has_element?(view, "#exiron-review-diagnostics [data-kind=unreachable_hook]")
      view |> element("#exiron-confirm-config") |> render_click()
      assert has_element?(view, "#exiron-config-diagnostics", "No configuration warnings")
      refute has_element?(view, "#exiron-config-diagnostics [data-kind=unreachable_hook]")
    end

    test "invalid YAML does not display a misleading clean diagnostic result", %{
      conn: conn,
      config_path: path
    } do
      File.write!(path, "telegram: [")
      {:ok, view, _} = live(log_in(conn), ~p"/config")
      refute has_element?(view, "#exiron-config-diagnostics")
      assert has_element?(view, "#exiron-config-activation[data-state=invalid]")
    end

    test "adds values through GUI forms", %{conn: conn, config_path: config_path} do
      conn = log_in(conn)

      {:ok, view, _html} = live(conn, ~p"/config")

      view
      |> element("#exiron-toggle-config-editor")
      |> render_click()

      view
      |> form("#exiron-telegram-bot-form",
        telegram_bot: %{
          "bot_token" => "999999:qwerty",
          "bot_name" => "alerts-bot",
          "alias" => "alerts",
          "chat_id" => "789"
        }
      )
      |> render_submit()

      view |> element("#exiron-confirm-config") |> render_click()

      view
      |> form("#exiron-chat-route-form",
        chat_route: %{
          "alias" => "alerts",
          "chat_id" => "789",
          "middleware" => "alerts",
          "push" => "true"
        }
      )
      |> render_submit()

      view |> element("#exiron-confirm-config") |> render_click()

      view
      |> form("#exiron-hook-form", hook: %{"hook" => "notify", "token" => "notify-token"})
      |> render_submit()

      view |> element("#exiron-confirm-config") |> render_click()

      view
      |> form("#exiron-middleware-route-form",
        middleware_route: %{
          "middleware" => "alerts",
          "hook" => "notify",
          "messages" => "/notify",
          "passthrough" => "true"
        }
      )
      |> render_submit()

      view |> element("#exiron-confirm-config") |> render_click()

      yaml = File.read!(config_path)
      assert yaml =~ "name: alerts-bot"
      assert yaml =~ "token: \"999999:qwerty\""
      assert yaml =~ "alerts: 789"
      assert yaml =~ ~s(notify: "#{HookToken.hash("notify-token")}")
      refute yaml =~ "notify-token"
      assert yaml =~ "          - /notify"
      assert yaml =~ "        passthrough: true"
      assert {:ok, %{hook: "notify"}} = Exiron.Hub.authenticate("notify-token")
      assert {:ok, config} = RouteConfiguration.load(config_path)
      assert Enum.any?(config.resolved_routes, &(&1.to == "notify" and &1.passthrough))
    end
  end

  defp temp_config_path do
    TempPath.tmp_path("config-live")
  end
end
