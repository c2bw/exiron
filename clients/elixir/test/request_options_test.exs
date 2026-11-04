defmodule ExironClient.RequestOptionsTest do
  use ExUnit.Case, async: true

  alias ExironClient.{HandlerDeadline, RequestOptions}

  test "per-request Finch timeouts retain the client's named pool and other options" do
    opts =
      RequestOptions.merge(
        [finch: [name: :custom_pool, pool_timeout: 5000, receive_timeout: 40]],
        finch: [pool_timeout: 1000]
      )

    assert opts[:finch] == [name: :custom_pool, receive_timeout: 40, pool_timeout: 1000]
  end

  test "control requests retain transport configuration and bound connection timeouts" do
    client_options = [
      finch: [
        conn_max_idle_time: 12_000,
        receive_timeout: 5000,
        conn_opts: [transport_opts: [timeout: 5000, verify: :verify_peer]]
      ]
    ]

    opts = RequestOptions.control(client_options, json: %{active_handlers: 0})
    assert opts[:receive_timeout] == 1000
    assert opts[:finch][:pool_timeout] == 1000
    assert opts[:finch][:receive_timeout] == 1000
    assert opts[:finch][:conn_max_idle_time] == 12_000

    assert Map.new(opts[:finch][:conn_opts][:transport_opts]) == %{
             verify: :verify_peer,
             timeout: 1000
           }

    refute Keyword.has_key?(opts, :pool_timeout)
    refute Keyword.has_key?(opts, :connect_options)

    named = RequestOptions.control([finch: [name: :custom_pool]], [], 200)
    assert named[:receive_timeout] == 200

    assert Map.new(named[:finch]) == %{
             name: :custom_pool,
             pool_timeout: 200,
             receive_timeout: 200
           }
  end

  test "runtime reports reach Req with nested pool options" do
    parent = self()

    client =
      ExironClient.new(
        base_url: "http://localhost",
        token: "test",
        req_options: [
          finch: [conn_opts: [transport_opts: [timeout: 321]]],
          adapter: fn request ->
            send(parent, {:options, request.options})
            {request, Req.Response.json(%{"ok" => true})}
          end
        ]
      )

    opts = RequestOptions.control(client.req_options, json: %{active_handlers: 0})
    assert {:ok, _} = ExironClient.Request.request(client, :post, "/api/client-runtime", opts)
    assert_receive {:options, options}
    refute Map.has_key?(options, :pool_timeout)
    refute Map.has_key?(options, :connect_options)
    assert options[:finch][:pool_timeout] == 1000
  end

  test "handler deadlines cap nested timeouts without changing pool configuration" do
    opts = [
      finch: [pool_timeout: 500, receive_timeout: 40, conn_opts: [transport_opts: [timeout: 321]]]
    ]

    assert {:ok, bounded} =
             HandlerDeadline.with_budget([handler_timeout_ms: 1000], fn ->
               HandlerDeadline.request_options(opts)
             end)

    assert bounded[:finch][:pool_timeout] == 500
    assert bounded[:finch][:receive_timeout] == 40
    assert bounded[:finch][:conn_opts] == opts[:finch][:conn_opts]

    assert {:ok, capped} =
             HandlerDeadline.with_budget([handler_timeout_ms: 1000], fn ->
               HandlerDeadline.request_options(
                 finch: [name: :custom_pool, pool_timeout: 5000, receive_timeout: 5000]
               )
             end)

    assert capped[:finch][:name] == :custom_pool
    assert capped[:finch][:pool_timeout] <= 1000
    assert capped[:finch][:receive_timeout] <= 1000
  end
end
