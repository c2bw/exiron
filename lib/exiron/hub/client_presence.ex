defmodule Exiron.Hub.ClientPresence do
  @moduledoc false
  alias Exiron.Hub.PendingRequest

  # One credential-free observation per configured hook, retained after a lease
  # expires or a socket disconnects. It is evidence of contact, not handler work.
  def contact(state, hook, kind) do
    case Map.get(state.delivery.clients, hook) do
      %{client_id: id} = client when is_binary(id) ->
        if state.router && Map.has_key?(state.router.hooks, hook) do
          previous = Map.get(state.delivery.client_presence, hook) || %{}
          runtime = Map.get(previous, :runtime_report)

          runtime =
            if runtime && runtime.runtime_ref == Map.get(client, :runtime_ref), do: runtime

          record = %{
            runtime_report: runtime,
            runtime_ref: Map.get(client, :runtime_ref),
            client_id: id,
            client_identity: Map.get(client, :client_identity),
            transport: Map.get(client, :transport, :http),
            last_contact_at: DateTime.utc_now(),
            last_contact_kind: to_string(kind),
            disconnected_at: nil
          }

          put_in(state.delivery.client_presence[hook], record)
        else
          state
        end

      _ ->
        state
    end
  end

  def socket_contact(state, hook, id, pid, kind) do
    case Map.get(state.delivery.clients, hook) do
      %{client_id: ^id, pid: ^pid, transport: :websocket} -> contact(state, hook, kind)
      _ -> state
    end
  end

  def disconnected(state, hook, client) do
    case {Map.get(state.delivery.client_presence, hook), client} do
      {%{client_id: id} = record, %{client_id: id}} ->
        put_in(state.delivery.client_presence[hook], %{
          record
          | disconnected_at: DateTime.utc_now()
        })

      _ ->
        state
    end
  end

  def snapshot(state, hook) do
    current = Map.get(state.delivery.clients, hook) || %{}
    observed = Map.get(state.delivery.client_presence, hook) || %{}
    id = Map.get(current, :client_id) || Map.get(observed, :client_id)
    presence = identity(state, hook, id, nil)

    counts =
      Enum.reduce(
        state.delivery.pending,
        %{awaiting_response: 0, sending_requests: 0, other_assigned_requests: 0},
        fn {_id, pending}, counts ->
          if pending.hook == hook and claimed?(pending) do
            if is_binary(id) and Map.get(pending, :assigned_client_id) == id do
              key =
                if PendingRequest.responding?(pending),
                  do: :sending_requests,
                  else: :awaiting_response

              Map.update!(counts, key, &(&1 + 1))
            else
              Map.update!(counts, :other_assigned_requests, &(&1 + 1))
            end
          else
            counts
          end
        end
      )

    Map.merge(presence, counts)
  end

  def for_request(_state, _trace, nil), do: nil

  def for_request(state, trace, pending) do
    id = trace.client_id || Map.get(pending, :assigned_client_id)
    value = identity(state, trace.hook, id, Map.get(pending, :assigned_client_transport))
    if is_nil(id), do: %{value | state: "unassigned"}, else: value
  end

  defp identity(state, hook, id, transport) do
    current = Map.get(state.delivery.clients, hook) || %{}
    observed = Map.get(state.delivery.client_presence, hook) || %{}
    same_current? = is_binary(id) and Map.get(current, :client_id) == id
    seen = if Map.get(observed, :client_id) == id, do: observed, else: %{}

    transport =
      if same_current?,
        do: Map.get(current, :transport) || transport,
        else: transport || Map.get(seen, :transport)

    status =
      cond do
        is_nil(id) -> "never_seen"
        same_current? and transport == :websocket -> "websocket_connected"
        same_current? -> "http_polling"
        is_binary(Map.get(current, :client_id)) -> "different_client"
        transport == :websocket -> "websocket_disconnected"
        true -> "http_lease_expired"
      end

    identity =
      if same_current?,
        do: Map.get(current, :client_identity),
        else: Map.get(seen, :client_identity)

    %{
      client_sdk: identity && identity.sdk,
      client_version: identity && identity.version,
      client_id: id,
      current_client_id: Map.get(current, :client_id),
      transport: if(transport, do: to_string(transport)),
      state: status,
      last_contact_at: Map.get(seen, :last_contact_at),
      last_contact_kind: Map.get(seen, :last_contact_kind),
      disconnected_at: Map.get(seen, :disconnected_at),
      runtime: Exiron.Hub.ClientRuntimeReports.snapshot(state, hook, id)
    }
  end

  defp claimed?(%PendingRequest{claimed?: value}), do: value
  defp claimed?(pending), do: Map.get(pending, :claimed?, false)
end
