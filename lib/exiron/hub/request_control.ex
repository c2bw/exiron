defmodule Exiron.Hub.RequestControl do
  @moduledoc false
  @limit 500

  def expired(state, id, hook) do
    order = [id | List.delete(state.delivery.expiration_order, id)] |> Enum.take(@limit)
    records = state.delivery.expirations |> Map.put(id, %{hook: hook}) |> Map.take(order)
    %{state | delivery: %{state.delivery | expirations: records, expiration_order: order}}
  end

  def snapshot(state, hook, id) when is_binary(id) and byte_size(id) in 1..128 do
    candidates = [
      {Map.get(state.delivery.cancellations, id), "cancelled"},
      {Map.get(state.delivery.pending, id), "active"},
      {Map.get(state.delivery.expirations, id), "expired"},
      {Map.get(state.delivery.replies, id), "completed"},
      {Map.get(state.activity.traces, id), nil}
    ]

    case Enum.find(candidates, fn {record, _} -> not is_nil(record) end) do
      {%{hook: ^hook} = record, status} ->
        status = status || terminal(Map.get(record, :status))
        remaining = if status == "active", do: remaining(record), else: nil
        {:ok, %{req_id: id, state: status, expires_in_ms: remaining}}

      {%{hook: _}, _} ->
        {:error, :request_not_assigned}

      nil ->
        {:error, :request_not_found}
    end
  end

  def snapshot(_state, _hook, _id), do: {:error, :invalid_payload}
  defp remaining(%{timer: timer}) when is_reference(timer), do: Process.read_timer(timer) || 0
  defp remaining(_), do: nil
  defp terminal(:expired), do: "expired"
  defp terminal(:cancelled), do: "cancelled"
  defp terminal(:completed), do: "completed"
  defp terminal(_), do: "closed"
end
