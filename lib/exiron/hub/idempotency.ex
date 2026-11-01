defmodule Exiron.Hub.Idempotency do
  @moduledoc false
  alias Exiron.Hub.Transition
  @limit 500
  @ttl 600_000
  @result_bytes 65_536

  defstruct records: %{}, order: [], running: %{}

  def run(state, _hook, nil, _operation, _from, fun), do: fun.(state)

  def run(state, hook, key, operation, from, fun) do
    if valid_key?(key) do
      state = prune(state)
      identity = {hook, :crypto.hash(:sha256, key)}
      digest = :crypto.hash(:sha256, :erlang.term_to_binary(operation, [:deterministic]))

      case Map.get(state.idempotency.records, identity) do
        %{digest: ^digest, result: nil} ->
          Transition.reply(state, {:error, :idempotency_in_progress})

        %{digest: ^digest, result: result} ->
          Transition.reply(state, :erlang.binary_to_term(result, [:safe]))

        %{} ->
          Transition.reply(state, {:error, :idempotency_conflict})

        nil ->
          case room(state) do
            {:ok, _available} ->
              transition = fun.(state)

              if Enum.any?(
                   transition.effects,
                   &match?(%{kind: :start_send, payload: %{from: ^from}}, &1)
                 ) do
                record = %{digest: digest, result: nil, expires: nil}
                {:ok, next} = room(transition.next_state)

                cache = %{
                  next.idempotency
                  | records: Map.put(next.idempotency.records, identity, record),
                    order: [identity | next.idempotency.order],
                    running: Map.put(next.idempotency.running, from, identity)
                }

                %{transition | next_state: %{next | idempotency: cache}}
              else
                transition
              end

            :full ->
              Transition.reply(state, {:error, :idempotency_capacity_exceeded})
          end
      end
    else
      Transition.reply(state, {:error, :invalid_payload})
    end
  end

  def fingerprint_opts(opts) do
    opts
    |> Enum.reduce(%{}, fn {key, value}, acc -> Map.put_new(acc, key, value) end)
    |> Map.delete(:idempotency_key)
    |> Enum.sort()
  end

  def finish(%{idempotency: %__MODULE__{}} = state, from, reply) do
    case Map.pop(state.idempotency.running, from) do
      {nil, _} ->
        {state, reply}

      {identity, running} ->
        safe = safe_result(reply)
        encoded = :erlang.term_to_binary(safe)
        # Never evict a running operation or resend because its result is too big.
        {result, returned} =
          if byte_size(encoded) <= @result_bytes,
            do: {encoded, safe},
            else: {:erlang.term_to_binary({:error, :idempotency_result_unavailable}), reply}

        records =
          Map.update!(
            state.idempotency.records,
            identity,
            &%{&1 | result: result, expires: now() + @ttl}
          )

        {%{state | idempotency: %{state.idempotency | records: records, running: running}},
         returned}
    end
  end

  def finish(state, _from, reply), do: {state, reply}

  defp valid_key?(key),
    do:
      is_binary(key) and byte_size(key) in 1..128 and Regex.match?(~r/\A[A-Za-z0-9._:-]+\z/, key)

  defp now, do: System.monotonic_time(:millisecond)

  defp prune(state) do
    clock = now()

    records =
      Map.reject(state.idempotency.records, fn {_key, r} ->
        r.result != nil and r.expires <= clock
      end)

    cache = %{
      state.idempotency
      | records: records,
        order: Enum.filter(state.idempotency.order, &Map.has_key?(records, &1))
    }

    %{state | idempotency: cache}
  end

  defp room(state) when map_size(state.idempotency.records) < @limit, do: {:ok, state}

  defp room(state) do
    case Enum.find(Enum.reverse(state.idempotency.order), fn key ->
           state.idempotency.records[key].result != nil
         end) do
      nil ->
        :full

      key ->
        cache = %{
          state.idempotency
          | records: Map.delete(state.idempotency.records, key),
            order: List.delete(state.idempotency.order, key)
        }

        {:ok, %{state | idempotency: cache}}
    end
  end

  defp safe_result({:error, {:delivery_error, reason, diagnostic}}),
    do: {:error, {:delivery_error, safe_reason(reason), diagnostic}}

  defp safe_result({:error, reason}), do: {:error, safe_reason(reason)}
  defp safe_result(reply), do: reply
  defp safe_reason(%ExGram.Error{code: 403}), do: :telegram_bot_forbidden
  defp safe_reason(%ExGram.Error{}), do: :internal_error
  defp safe_reason(reason) when is_binary(reason), do: :invalid_payload

  defp safe_reason(reason) when is_atom(reason) do
    if Exiron.Protocol.error_code(reason) == "internal_error", do: :internal_error, else: reason
  end

  defp safe_reason(_), do: :internal_error
end
