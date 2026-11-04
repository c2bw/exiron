defmodule ExironClient.RequestOptionsTest do
  use ExUnit.Case, async: true

  alias ExironClient.RequestOptions

  test "pool timeouts use the installed Req syntax and preserve named pools" do
    opts = RequestOptions.normalize(finch: :custom_pool, pool_timeout: 123)

    if RequestOptions.nested_finch?() do
      assert opts == [finch: [pool_timeout: 123, name: :custom_pool]]
    else
      assert opts == [finch: :custom_pool, pool_timeout: 123]
    end
  end

  test "runtime reports reach Req without deprecated pool options" do
    parent = self()

    client =
      ExironClient.new(
        base_url: "http://localhost",
        token: "test",
        req_options: [
          adapter: fn request ->
            send(parent, {:options, request.options})
            {request, Req.Response.json(%{"ok" => true})}
          end,
          connect_options: [timeout: 321]
        ]
      )

    assert {:ok, _} =
             ExironClient.Request.request(client, :post, "/api/client-runtime",
               json: %{active_handlers: 0},
               receive_timeout: 1000,
               pool_timeout: 1000
             )

    assert_receive {:options, opts}

    if RequestOptions.nested_finch?() do
      refute Map.has_key?(opts, :pool_timeout)
      refute Map.has_key?(opts, :connect_options)
      assert opts[:finch][:pool_timeout] == 1000
      assert opts[:finch][:conn_opts][:transport_opts][:timeout] == 321
    else
      assert opts[:pool_timeout] == 1000
      assert opts[:connect_options][:timeout] == 321
    end
  end

  if RequestOptions.nested_finch?() do
    test "nested request options preserve pool configuration and deadline limits" do
      opts =
        RequestOptions.normalize(
          pool_timeout: 500,
          connect_options: [timeout: 321],
          finch: [pool_timeout: 900, receive_timeout: 40, conn_max_idle_time: 12_000]
        )

      assert opts[:finch][:pool_timeout] == 500
      assert opts[:finch][:conn_max_idle_time] == 12_000
      assert opts[:finch][:conn_opts][:transport_opts][:timeout] == 321

      assert {:ok, bounded} =
               ExironClient.HandlerDeadline.with_budget([handler_timeout_ms: 1000], fn ->
                 ExironClient.HandlerDeadline.request_options(opts)
               end)

      assert bounded[:finch][:pool_timeout] == 500
      assert bounded[:finch][:receive_timeout] == 40
      assert bounded[:finch][:conn_opts] == opts[:finch][:conn_opts]

      assert {:ok, capped} =
               ExironClient.HandlerDeadline.with_budget([handler_timeout_ms: 1000], fn ->
                 ExironClient.HandlerDeadline.request_options(
                   finch: [name: :custom_pool, pool_timeout: 5000, receive_timeout: 5000]
                 )
               end)

      assert capped[:finch][:name] == :custom_pool
      assert capped[:finch][:pool_timeout] <= 1000
      assert capped[:finch][:receive_timeout] <= 1000
    end
  end
end
