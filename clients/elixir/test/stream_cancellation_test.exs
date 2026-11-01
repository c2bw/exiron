defmodule ExironClient.StreamCancellationTest do
  use ExUnit.Case, async: true
  alias ExironClient.{Cancellation, Error}

  setup do
    parent = self()

    client =
      ExironClient.new(
        base_url: "http://example.test",
        token: "synthetic",
        req_options: [
          adapter: fn req ->
            send(parent, {:sent, req.options[:json]})
            {req, Req.Response.json(%{ok: true})}
          end
        ]
      )

    flag = :atomics.new(1, [])
    Process.put(:exiron_request_cancellation, %Cancellation{req_id: "request", flag: flag})
    %{client: client, flag: flag}
  end

  for {flag_value, reason} <- [{1, :request_cancelled}, {2, :request_expired}] do
    @flag_value flag_value
    @reason reason
    test "#{reason} before enumeration does not consume the producer", %{
      client: client,
      flag: flag
    } do
      :atomics.put(flag, 1, @flag_value)

      chunks =
        Stream.resource(
          fn -> flunk("producer was consumed") end,
          fn _ -> {:halt, nil} end,
          fn _ -> :ok end
        )

      assert {:error, %Error{reason: @reason}} =
               ExironClient.stream_text(client, "request", chunks)

      refute_received {:sent, _}
    end

    test "#{reason} during producer completion suppresses finalization", %{
      client: client,
      flag: flag
    } do
      chunks =
        Stream.resource(
          fn -> 0 end,
          fn
            0 -> {["partial"], 1}
            1 -> {:halt, 1}
          end,
          fn _ -> :atomics.put(flag, 1, @flag_value) end
        )

      assert {:error, %Error{reason: @reason}} =
               ExironClient.stream_text(client, "request", chunks)

      assert_received {:sent, %{final: false}}
      refute_received {:sent, %{final: true}}
    end
  end
end
