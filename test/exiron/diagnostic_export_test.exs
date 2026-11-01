defmodule Exiron.DiagnosticExportTest do
  use ExUnit.Case, async: true
  alias Exiron.Hub.DiagnosticExport

  test "export retains useful timings and counts without unstructured data or identities" do
    secret = "SENSITIVE-CANARY"

    trace = %{
      status: :sending,
      at: DateTime.utc_now(),
      pending?: true,
      elapsed_ms: 42,
      chat_id: secret,
      id: secret,
      hook: secret,
      bot_name: secret,
      client_id: secret,
      handler: %{reason: secret},
      bot_token: secret,
      data: secret,
      steps: [%{kind: :queued, at: DateTime.utc_now(), elapsed_ms: 0, detail: %{nested: secret}}],
      delivery: %{
        outcome: "failed",
        attempts: 2,
        last_error: %{category: "forbidden", code: 403, message: secret},
        parts: [
          %{
            ordinal: 1,
            attempts: 2,
            chat_id: secret,
            bot_name: secret,
            message_ids: [secret],
            status: "rejected",
            operation: "send",
            error: %{category: "forbidden", code: 403, message: secret}
          }
        ]
      }
    }

    export = DiagnosticExport.build(trace)
    refute Jason.encode!(export) =~ secret
    assert export.request.elapsed_ms == 42
    assert export.timeline |> hd() |> Map.fetch!(:kind) == "queued"
    assert export.delivery.error == %{category: "forbidden", code: 403, retry_after_ms: nil}
    assert export.delivery.parts |> hd() |> Map.fetch!(:attempts) == 2
    changed = put_in(trace, [:delivery, :last_error, :category], secret)
    refute Jason.encode!(DiagnosticExport.build(changed)) =~ secret
  end
end
