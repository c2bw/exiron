defmodule ExironWeb.EventMediaControllerTest do
  use ExironWeb.ConnCase, async: false

  alias Exiron.Hub
  alias Exiron.Hub.EventMediaStore
  alias Exiron.Hub.Telegram

  setup do
    :ok = Hub.configure(router!(), Telegram.new([]))
    :ok = EventMediaStore.clear()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "dashboard authentication retrieves media bytes with the stored MIME type", %{conn: conn} do
    assert {:ok, id} =
             EventMediaStore.put(EventMediaStore, "png-bytes", "image/png", {:hook, "assistant"})

    conn =
      conn
      |> log_in()
      |> recycle()
      |> get("/api/event-media/#{id}")

    assert response(conn, 200) == "png-bytes"
    assert [content_type] = get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "image/png")
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "a hook bearer can retrieve only media belonging to that hook", %{conn: conn} do
    assert {:ok, assistant_id} =
             EventMediaStore.put(
               EventMediaStore,
               "assistant-bytes",
               "image/png",
               {:hook, "assistant"}
             )

    assert {:ok, other_id} =
             EventMediaStore.put(EventMediaStore, "other-bytes", "image/png", {:hook, "other"})

    assistant_conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> get("/api/event-media/#{assistant_id}")

    assert response(assistant_conn, 200) == "assistant-bytes"

    forbidden_conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer ai-token")
      |> get("/api/event-media/#{other_id}")

    assert response(forbidden_conn, 404) == ""
  end

  test "accepts image media types and applies API rate limits", %{conn: conn} do
    :ets.delete_all_objects(:rate_limit_entries)

    assert {:ok, id} =
             EventMediaStore.put(EventMediaStore, "png-bytes", "image/png", {:hook, "assistant"})

    conn =
      conn
      |> put_req_header("accept", "image/png")
      |> put_req_header("authorization", "Bearer ai-token")
      |> get("/api/event-media/#{id}")

    assert response(conn, 200) == "png-bytes"

    namespaces =
      :rate_limit_entries
      |> :ets.tab2list()
      |> Enum.map(fn {{namespace, _identity, _bucket}, _count} -> namespace end)

    assert :api_ip in namespaces
    assert :api_token in namespaces
  end

  test "requires dashboard or hook authentication and returns 404 for missing media", %{
    conn: conn
  } do
    unauthenticated = get(conn, "/api/event-media/missing")
    assert %{"error" => "missing bearer token"} = json_response(unauthenticated, 401)

    missing =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> get("/api/event-media/missing")

    assert response(missing, 404) == ""
  end

  defp router! do
    {:ok, router} =
      Exiron.Hub.Router.load_definitions(%{
        "aliases" => %{"telegram" => %{"home" => 123}},
        "routes" => %{"home" => %{"middleware" => ["family"]}},
        "middlewares" => %{
          "family" => %{
            "routes" => %{
              "assistant" => %{"messages" => ["/ai"]},
              "other" => %{"messages" => ["/other"]}
            }
          }
        },
        "hooks" => %{"assistant" => "ai-token", "other" => "other-token"}
      })

    router
  end
end
