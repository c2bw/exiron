defmodule ExironWeb.ComposerLiveTest do
  use ExironWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Exiron.Hub
  alias Exiron.Hub.Telegram

  setup do
    parent = self()

    :ok =
      Hub.configure(
        Exiron.HubCase.load_push_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token", bot_name: "PreviewBot"}],
          sender: fn _, message ->
            send(parent, {:sent, message})
            {:ok, %{message_id: 99}}
          end
        )
      )

    [target] = Hub.manual_targets()
    %{target: target}
  end

  test "composer requires login and never sends until confirmation", %{conn: conn, target: target} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/compose")
    {:ok, view, _} = live(log_in(conn), "/compose?hook=assistant")
    assert has_element?(view, "#composer-target option[value='#{target.id}'][selected]")

    form(view, "#composer-form", message: %{target: target.id, text: "<b>Hello</b>", topic: "7"})
    |> render_submit()

    assert has_element?(view, "#composer-message-preview", "<b>Hello</b>")
    refute has_element?(view, "#composer-message-preview b")

    preview =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#composer-message-preview")
      |> LazyHTML.text()

    assert preview == "<b>Hello</b>"
    refute_received {:sent, _}
    view |> element("#composer-send") |> render_click()
    render_async(view)
    assert_receive {:sent, message}
    assert message.message_thread_id == 7
    assert has_element?(view, "#composer-preview-empty")
    assert has_element?(view, "#composer-target option[value='#{target.id}'][selected]")
    refute has_element?(view, "#composer-send")
    render_hook(view, "send", %{})
    refute_received {:sent, _}
  end

  test "session destination restoration validates current choices and respects explicit selection",
       %{conn: conn, target: target} do
    {:ok, view, _} = live(log_in(conn), "/compose")
    render_hook(view, "restore_destination", %{target: "unknown"})
    refute has_element?(view, "#composer-target option[value='#{target.id}'][selected]")
    render_hook(view, "restore_destination", %{target: target.id})
    assert has_element?(view, "#composer-target option[value='#{target.id}'][selected]")
    render_hook(view, "restore_destination", %{target: "unknown"})
    assert has_element?(view, "#composer-target option[value='#{target.id}'][selected]")
    assert has_element?(view, "#composer-session[phx-hook=ComposerSession][phx-update=ignore]")
  end

  test "uploaded files preview metadata and captions before sending exact bytes", %{
    conn: conn,
    target: target
  } do
    {:ok, view, _} = live(log_in(conn), "/compose")
    params = %{target: target.id, datatype: "file", text: "<b>caption</b>", topic: "7"}
    form(view, "#composer-form", message: params) |> render_change()

    upload =
      file_input(view, "#composer-form", :attachment, [
        %{name: "report.txt", content: "FILE-CONTENT", type: "text/plain"}
      ])

    render_upload(upload, "report.txt")
    form(view, "#composer-form", message: params) |> render_submit()
    assert has_element?(view, "#composer-attachment-preview", "report.txt")
    assert has_element?(view, "#composer-message-preview", "<b>caption</b>")
    refute has_element?(view, "#composer-message-preview b")
    refute_received {:sent, _}
    view |> element("#composer-send") |> render_click()
    render_async(view)
    assert_receive {:sent, message}
    assert message.data == "FILE-CONTENT" and message.datatype == "file"
    assert message.caption == "<b>caption</b>" and message.message_thread_id == 7
    assert has_element?(view, "#composer-preview-empty")
    refute has_element?(view, "[id^=composer-upload-]")
  end

  test "removing attachments invalidates preview and non-images cannot become photo previews", %{
    conn: conn,
    target: target
  } do
    {:ok, view, _} = live(log_in(conn), "/compose")
    params = %{target: target.id, datatype: "image", text: "", topic: ""}
    form(view, "#composer-form", message: params) |> render_change()

    upload =
      file_input(view, "#composer-form", :attachment, [
        %{name: "fake.png", content: "not an image", type: "image/png"}
      ])

    render_upload(upload, "fake.png")
    form(view, "#composer-form", message: params) |> render_submit()
    refute has_element?(view, "#composer-send")
    refute has_element?(view, "#composer-attachment-preview")
    view |> element("[id^=composer-remove-]") |> render_click()
    refute has_element?(view, "[id^=composer-upload-]")
    refute_received {:sent, _}
  end

  test "editing invalidates the preview and removed destinations reject confirmation", %{
    conn: conn,
    target: target
  } do
    {:ok, view, _} = live(log_in(conn), "/compose")
    params = %{target: target.id, text: "hello", topic: ""}
    form(view, "#composer-form", message: params) |> render_submit()
    form(view, "#composer-form", message: %{params | text: "changed"}) |> render_change()
    refute has_element?(view, "#composer-send")
    form(view, "#composer-form", message: params) |> render_submit()
    :ok = Hub.configure(Exiron.HubCase.load_router!())
    send(view.pid, :configuration_changed)
    refute has_element?(view, "#composer-send")
    render_hook(view, "send", %{})
    refute_received {:sent, _}
    assert has_element?(view, "#composer-no-targets")
  end
end
