defmodule Exiron.Hub.DiagnosticExport do
  @moduledoc false
  # Export from an allowlist, rather than recursively removing known secrets.
  # In particular, never copy arbitrary error text, handler data or step details.
  @numbers ~w(age_ms elapsed_ms deliveries omitted_steps expires_in_ms waiting_ms)a
  @counts ~w(attempts planned_parts confirmed_parts rejected_parts unknown_parts in_flight_parts unattempted_parts omitted_parts)a
  @categories ~w(bad_request unauthorized forbidden rate_limited telegram_unavailable telegram_error bot_not_configured delivery_timeout invalid_payload transport_error)

  def build(trace) do
    %{
      format_version: 1,
      exported_at: DateTime.utc_now(),
      software: %{
        server: Exiron.Hub.server_version(),
        protocol: Exiron.Protocol.protocol_version()
      },
      request:
        numbers(trace, @numbers)
        |> Map.merge(%{
          status: atom(trace[:status]),
          received_at: timestamp(trace[:at]),
          pending: trace[:pending?] == true,
          wait_phase: atom(trace[:wait_phase])
        }),
      timeline:
        Enum.take(trace[:steps] || [], 32)
        |> Enum.map(fn step ->
          %{
            kind: atom(step[:kind]),
            at: timestamp(step[:at]),
            elapsed_ms: number(step[:elapsed_ms])
          }
        end),
      delivery: delivery(trace[:delivery]),
      omitted: [
        "credentials",
        "message_content",
        "user_chat_bot_hook_client_and_request_identifiers",
        "step_details",
        "raw_errors",
        "handler_metadata"
      ]
    }
  end

  defp delivery(nil), do: nil

  defp delivery(value) do
    numbers(value, @counts)
    |> Map.merge(%{
      operation:
        choice(value[:operation], ~w(respond edit action push unavailable overloaded interaction)),
      outcome: choice(value[:outcome], ~w(sending succeeded failed cancelled expired)),
      delivery_status: choice(value[:delivery_status], ~w(unknown confirmed partial not_started)),
      retry_safe: value[:retry_safe] == true,
      retry_action:
        choice(
          value[:retry_action],
          ~w(wait none inspect_chat request_closed retry_request fix_request)
        ),
      error: error(value[:last_error]),
      parts:
        Enum.take(value[:parts] || [], 128)
        |> Enum.map(fn part ->
          numbers(part, [:ordinal, :attempts])
          |> Map.merge(%{
            operation: choice(part[:operation], ~w(send edit delete action)),
            status: choice(part[:status], ~w(queued in_flight confirmed rejected unknown)),
            error: error(part[:error])
          })
        end)
    })
  end

  defp error(nil), do: nil

  defp error(value),
    do: %{
      category: choice(value[:category], @categories),
      code: number(value[:code]),
      retry_after_ms: number(value[:retry_after_ms])
    }

  defp numbers(map, keys), do: Map.new(keys, &{&1, number(map[&1])})
  defp number(value) when is_integer(value) and value >= 0, do: value
  defp number(_), do: nil
  defp timestamp(%DateTime{} = value), do: value
  defp timestamp(_), do: nil
  defp atom(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp atom(_), do: nil
  defp choice(value, allowed), do: if(value in allowed, do: value, else: "other")
end
