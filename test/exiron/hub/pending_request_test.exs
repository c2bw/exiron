defmodule Exiron.Hub.PendingRequestTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{Message, PendingRequest}

  test "lifecycle transitions preserve ownership and expose explicit state" do
    request =
      Message.incoming(222, 7, "text", "hello", bot_token: "token", bot_name: "bot")
      |> PendingRequest.new("assistant", make_ref())

    refute request.claimed?
    refute PendingRequest.responding?(request)

    request = request |> PendingRequest.claim() |> PendingRequest.start_response()
    assert request.claimed?
    assert PendingRequest.responding?(request)
    assert request.lifecycle == :responding

    request = PendingRequest.clear_response(request)
    refute PendingRequest.responding?(request)
    assert request.lifecycle == :claimed

    request = PendingRequest.unclaim(request)
    refute request.claimed?
    assert request.lifecycle == :queued
  end
end
