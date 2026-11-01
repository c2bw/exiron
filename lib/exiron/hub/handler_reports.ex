defmodule Exiron.Hub.HandlerReports do
  @moduledoc false
  alias Exiron.Hub.{Delivery, Effect, RequestTrace, Transition}

  @keys ~w(req_id client_id delivery_id attempt max_attempts state category)
  @categories ~w(handler_error client_error exception)

  def record(state, hook, payload) do
    with :ok <- validate(payload),
         {:ok, trace} <- trace(state, payload["req_id"], hook),
         :ok <- delivery(state, hook, payload) do
      previous = Map.get(trace, :handler)

      if stale_or_duplicate?(previous, payload) do
        Transition.reply(state, {:ok, %{ok: true}})
      else
        report = payload |> Map.take(~w(delivery_id attempt max_attempts state category))
        status = status(trace.status, payload["state"])
        kind = kind(payload["state"])

        detail =
          "Attempt #{payload["attempt"]}/#{payload["max_attempts"]}" <>
            if(payload["category"], do: " · #{payload["category"]}", else: "")

        state = state |> RequestTrace.record(trace.id, kind, status: status, detail: detail)
        state = put_in(state.activity.traces[trace.id].handler, report)
        Transition.new(state, reply: {:ok, %{ok: true}}, effects: [Effect.broadcast_status()])
      end
    else
      {:error, _} = error -> Transition.reply(state, error)
    end
  end

  defp validate(payload) when is_map(payload) do
    valid? =
      Enum.all?(Map.keys(payload), &(&1 in @keys)) and
        Enum.all?(~w(req_id client_id delivery_id), fn key ->
          value = payload[key]
          is_binary(value) and byte_size(value) in 1..128
        end) and
        is_integer(payload["attempt"]) and is_integer(payload["max_attempts"]) and
        payload["max_attempts"] in 1..10 and payload["attempt"] in 1..payload["max_attempts"]

    valid? =
      valid? and
        case payload["state"] do
          "retrying" ->
            payload["attempt"] < payload["max_attempts"] and payload["category"] in @categories

          "exhausted" ->
            payload["attempt"] == payload["max_attempts"] and payload["category"] in @categories

          "recovered" ->
            payload["attempt"] >= 2 and is_nil(payload["category"])

          _ ->
            false
        end

    if valid?, do: :ok, else: {:error, :invalid_payload}
  end

  defp validate(_), do: {:error, :invalid_payload}

  defp trace(state, id, hook) do
    case Map.get(state.activity.traces, id) do
      %{hook: ^hook} = trace -> {:ok, trace}
      nil -> {:error, :request_not_found}
      _ -> {:error, :request_not_assigned}
    end
  end

  defp delivery(state, hook, payload) do
    case Map.get(state.delivery.clients, hook) do
      %{client_id: id} = client when id == :erlang.map_get("client_id", payload) ->
        if Enum.any?([client.http_delivery, client.socket_delivery], fn
             %Delivery{ref: ref, items: items} ->
               ref == payload["delivery_id"] and
                 Enum.any?(
                   items,
                   &match?(
                     %{msgtype: "request", req_id: id}
                     when id == :erlang.map_get("req_id", payload),
                     &1
                   )
                 )

             _ ->
               false
           end), do: :ok, else: {:error, :request_not_assigned}

      _ ->
        {:error, :request_not_assigned}
    end
  end

  defp stale_or_duplicate?(%{"delivery_id" => batch, "attempt" => attempt} = previous, report) do
    batch == report["delivery_id"] and
      (attempt > report["attempt"] or
         (attempt == report["attempt"] and
            (previous["state"] == report["state"] or
               previous["state"] in ["exhausted", "recovered"])))
  end

  defp stale_or_duplicate?(_, _), do: false
  defp kind("retrying"), do: :handler_retrying
  defp kind("exhausted"), do: :handler_exhausted
  defp kind("recovered"), do: :handler_recovered

  defp status(status, "recovered") when status in [:handler_retrying, :handler_exhausted],
    do: :awaiting_response

  defp status(status, "recovered"), do: status
  defp status(status, _) when status in [:sending, :send_failed], do: status
  defp status(_status, "retrying"), do: :handler_retrying
  defp status(_status, "exhausted"), do: :handler_exhausted
end
