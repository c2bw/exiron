defmodule ExironClient.OTPStatus do
  @moduledoc false

  def redact(status, state_formatter) when is_map(status) and is_function(state_formatter, 1) do
    status
    |> update_if_present(:state, state_formatter)
    |> update_if_present(:message, &message_kind/1)
    |> update_if_present(:reason, &reason_kind/1)
    |> update_if_present(:log, fn _log -> [] end)
  end

  def message_kind({:"$gen_call", _from, request}), do: {:call, message_kind(request)}
  def message_kind({:"$gen_cast", request}), do: {:cast, message_kind(request)}
  def message_kind(message) when is_atom(message), do: message

  def message_kind(message) when is_tuple(message) and tuple_size(message) > 0 do
    case elem(message, 0) do
      name when is_atom(name) -> name
      _name -> :redacted
    end
  end

  def message_kind(_message), do: :redacted

  def reason_kind(reason) when is_atom(reason), do: reason

  def reason_kind(%{__struct__: module}) when is_atom(module),
    do: {:exception, module}

  def reason_kind(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      name when is_atom(name) -> name
      _name -> :redacted
    end
  end

  def reason_kind(_reason), do: :redacted

  def client(%ExironClient{} = client) do
    %{
      base_url: client.base_url,
      client_id: client.client_id,
      listen?: client.listen?
    }
  end

  def client(_client), do: :redacted

  defp update_if_present(map, key, fun) do
    if Map.has_key?(map, key), do: Map.update!(map, key, fun), else: map
  end
end
