defmodule ExironClient.ErrorClassificationTest do
  use ExUnit.Case, async: true
  alias ExironClient.Error

  test "control and transport outcomes have distinct categories without parsing messages" do
    for {error, expected} <- [
          {nil, :none},
          {Error.from_exception(%Req.TransportError{reason: :timeout}), :transport_timeout},
          {Error.new(:handler_deadline_exceeded, "deadline"), :handler_deadline_exceeded},
          {Error.new(:client_lease_lost, "lease"), :client_lease_lost},
          {Error.new(:request_cancelled, "cancelled"), :request_cancelled},
          {Error.new(:request_expired, "expired"), :request_expired},
          {Error.new(:telegram_delivery_timeout, "uncertain", status: 504), :client_error},
          {Error.new(:transport_error, "timeout in arbitrary message"), :transport_error}
        ] do
      assert Error.classify(error) == expected
      assert Error.transport_timeout?(error) == (expected == :transport_timeout)
      assert Error.handler_deadline_exceeded?(error) == (expected == :handler_deadline_exceeded)
    end
  end
end
