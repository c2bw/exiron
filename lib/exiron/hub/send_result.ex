defmodule Exiron.Hub.SendResult do
  @moduledoc false

  @type status :: :ok | :error | :partial_error

  @type t :: %__MODULE__{
          status: status(),
          value: term(),
          reason: term() | nil,
          original: term() | nil,
          messages: [term()],
          failures: [{term(), term()}]
        }

  defstruct status: :ok, value: nil, reason: nil, original: nil, messages: [], failures: []

  def ok(value), do: %__MODULE__{status: :ok, value: value}
  def error(reason), do: %__MODULE__{status: :error, reason: reason}

  def partial_error(reason, messages, failures \\ []) do
    %__MODULE__{status: :partial_error, reason: reason, messages: messages, failures: failures}
  end

  @doc false
  def normalize(%__MODULE__{} = result), do: result
  def normalize(:ok), do: ok(nil)
  def normalize({:ok, value}), do: ok(value)
  def normalize({:error, reason}), do: %{error(reason) | original: {:error, reason}}
  def normalize({:partial_error, reason, messages}), do: partial_error(reason, messages)

  def normalize({:partial_error, reason, messages, failures}),
    do: partial_error(reason, messages, failures)

  def normalize(value), do: ok(value)
end
