Code.require_file("../examples/managed_worker.exs", __DIR__)

defmodule ExironClient.ManagedWorkerExampleTest do
  use ExUnit.Case, async: false

  for mode <- [:one_shot, :stream] do
    @mode mode
    test "reference worker replies with #{@mode} and drains before releasing its store" do
      parent = self()
      client = gateway(parent, "hello")

      start_supervised!(
        {ExironExampleWorker, client: client, transport: :http, reply_mode: @mode}
      )

      assert_receive {:final, body}, 2000
      assert Base.decode64!(body.data) == "Received: hello"
      assert body.parse_mode == "plain"
      assert :ok = ExironExampleWorker.drain()
      assert_receive :retired, 1000

      assert %{worker: {:error, :not_running}, quarantine: {:ok, %{count: 0}}} =
               ExironExampleWorker.status()

      if @mode == :one_shot,
        do: refute_received({:partial, _}),
        else: assert_receive({:partial, _})
    end
  end

  test "quarantine survives drain and explicit recovery sends only the operator's replacement" do
    parent = self()
    client = gateway(parent, "/ai /worker-fail")

    root =
      start_supervised!(
        {ExironExampleWorker,
         client: client,
         transport: :http,
         reply_mode: :stream,
         on_quarantined: fn entry -> send(parent, {:quarantined, entry}) end}
      )

    assert_receive {:quarantined, entry}, 1000
    assert :ok = ExironExampleWorker.drain()
    assert {:ok, [retained]} = ExironExampleWorker.quarantine()
    assert retained.id == entry.id
    refute_received {:final, _}
    assert :ok = ExironExampleWorker.recover_text(entry.id, "Reviewed replacement")
    assert_receive {:final, body}
    assert Base.decode64!(body.data) == "Reviewed replacement"
    refute_received {:partial, _}
    assert {:ok, []} = ExironExampleWorker.quarantine()
    _ = :sys.get_state(root)
    assert {:ok, _poller} = ExironExampleWorker.restart()
    assert :ok = ExironExampleWorker.drain()
  end

  for mode <- [:one_shot, :stream] do
    @mode mode
    test "feedback and follow-up context work with #{@mode} replies" do
      {:ok, [[button, _]]} = ExironClient.Feedback.keyboard()

      requests = [
        %{
          req_id: "one",
          msgtype: "request",
          datatype: "text",
          data: Base.encode64("more"),
          service_id: 1,
          chat_id: 1,
          followup_req_id: "parent"
        },
        %{
          req_id: "vote",
          msgtype: "request",
          datatype: "callback",
          data: Base.encode64(button.callback_data),
          service_id: 1,
          chat_id: 1,
          from: %{id: 42},
          callback_query: %{id: "click", origin_req_id: "one"}
        }
      ]

      start_supervised!(
        {ExironExampleWorker,
         client: gateway(self(), requests), transport: :http, reply_mode: @mode, feedback: true}
      )

      assert_receive {:final, reply}, 2000
      assert Base.decode64!(reply.data) == "Follow-up received: more"
      assert [[_, _]] = reply.inline_keyboard
      assert_receive {:final, acknowledgement}, 2000
      assert Base.decode64!(acknowledgement.data) == "Thanks for the feedback."
      refute Map.has_key?(acknowledgement, :inline_keyboard)
      assert :ok = ExironExampleWorker.drain()
    end
  end

  test "unsupported feedback fails before polling" do
    assert {:error, _} =
             start_supervised(
               {ExironExampleWorker,
                client: gateway(self(), "hello", false), feedback: true, transport: :http}
             )

    refute_received :offered
  end

  test "invalid feedback option fails before consuming work" do
    assert_raise ArgumentError, "feedback must be boolean", fn ->
      ExironExampleWorker.start(client: gateway(self(), "hello"), feedback: :invalid)
    end
  end

  test "invalid observation flag fails before connecting" do
    previous =
      Map.new(["EXIRON_HOOK_TOKEN", "EXIRON_OBSERVE_REQUESTS"], &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)
    end)

    System.put_env("EXIRON_HOOK_TOKEN", "synthetic")
    System.put_env("EXIRON_OBSERVE_REQUESTS", "invalid")

    assert_raise ArgumentError, "EXIRON_OBSERVE_REQUESTS must be true or false", fn ->
      ExironExampleWorker.start()
    end
  end

  defp gateway(parent, text, feedback_supported? \\ true) do
    offered = start_supervised!({Agent, fn -> false end})

    ExironClient.new(
      base_url: "http://example.test",
      token: "token",
      client_id: "example",
      req_options: [
        adapter: fn req ->
          body =
            case req.url.path do
              "/api/capabilities" ->
                %{
                  protocol_version: "1.17",
                  capabilities:
                    ~w(client_retirement client_runtime_reporting http_lease_renewal cooperative_cancellation handler_failure_reporting) ++
                      if(feedback_supported?, do: ~w(inline_keyboards callback_queries), else: [])
                }

              "/api/requests" ->
                send(parent, :offered)

                if Agent.get_and_update(offered, fn old -> {old, true} end),
                  do: %{runtime_ref: "session", requests: []},
                  else: %{
                    runtime_ref: "session",
                    delivery_id: "batch",
                    requests:
                      if(is_list(text),
                        do: text,
                        else: [
                          %{
                            req_id: "one",
                            msgtype: "request",
                            datatype: "text",
                            data: Base.encode64(text),
                            service_id: 1,
                            chat_id: 1
                          }
                        ]
                      )
                  }

              "/api/request-state" ->
                %{req_id: "one", state: "active"}

              "/api/client-lease" ->
                %{ok: true, lease_timeout_ms: 3000}

              "/api/client-retire" ->
                send(parent, :retired)
                %{ok: true}

              "/api/client-runtime" ->
                %{ok: true}

              "/api/handler-reports" ->
                %{ok: true}

              "/api/responses" ->
                payload = req.options[:json]
                send(parent, {if(payload[:final] == false, do: :partial, else: :final), payload})
                %{ok: true}
            end

          {req, Req.Response.json(body)}
        end
      ]
    )
  end
end
