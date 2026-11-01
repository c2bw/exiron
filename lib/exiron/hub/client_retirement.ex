defmodule Exiron.Hub.ClientRetirement do
  @moduledoc false
  alias Exiron.Hub.{ClientEventLog, ClientLeases, ClientState, Delivery, RequestTrace}

  def retire(state, hook, id, batch)
      when is_binary(id) and byte_size(id) in 1..128 and is_binary(batch) and
             byte_size(batch) in 1..128 do
    with %{client_id: ^id} = client <- ClientState.get(state, hook),
         true <- live?(client),
         true <- owns?(client, batch) do
      # A normal ack may already have pulled a newer batch. Preserve and requeue
      # that newer work, while last_ack_ref fences retirement to this session.
      field = if client.transport == :http, do: :http_delivery, else: :socket_delivery

      state =
        case Map.get(client, field) do
          %Delivery{ref: ^batch, items: items} ->
            state
            |> RequestTrace.items(items, :client_acknowledged, status: :awaiting_response)
            |> put_in(
              [Access.key!(:delivery), Access.key!(:clients), hook, Access.key!(field)],
              nil
            )

          _ ->
            state
        end

      ClientLeases.release_resources(client)

      state =
        state |> ClientState.remove(hook) |> ClientEventLog.record("disconnected", hook, client)

      {:ok, state}
    else
      _ -> {:error, :client_lease_lost}
    end
  end

  def retire(_, _, _, _), do: {:error, :invalid_payload}

  defp live?(%{transport: :websocket}), do: true
  defp live?(%{timer: timer}) when is_reference(timer), do: (Process.read_timer(timer) || 0) > 0
  defp live?(_), do: false
  defp owns?(%{last_ack_ref: batch}, batch), do: true
  defp owns?(%{transport: :http, http_batch_ref: batch}, batch), do: true
  defp owns?(%{transport: :websocket, socket_delivery: %Delivery{ref: batch}}, batch), do: true
  defp owns?(_, _), do: false
end
