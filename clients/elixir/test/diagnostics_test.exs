defmodule ExironClient.DiagnosticsTest do
  use ExUnit.Case, async: true
  alias ExironClient.Error

  test "safe summaries exclude raw fields and retain explicit diagnostic access" do
    error =
      Error.new(:transport_error, "secret message", body: %{token: "private-token"}, status: 503)

    assert Error.summary(error) == %{kind: :transport_error, http_status: 503}
    refute inspect(Error.summary(error)) =~ "secret"
    assert error.body.token == "private-token"

    assert Error.summary(Error.new(:private_reason, "secret")) == %{
             kind: :client_error,
             http_status: nil
           }

    assert Error.summary(%RuntimeError{message: "secret"}) == %{kind: :error, http_status: nil}
    assert Error.summary(nil).kind == :none
  end
end
