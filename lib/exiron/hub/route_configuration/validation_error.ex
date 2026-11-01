defmodule Exiron.Hub.RouteConfiguration.ValidationError do
  @moduledoc false

  defexception errors: %{}, message: nil

  @type t :: %__MODULE__{errors: %{optional(atom()) => String.t()}, message: String.t()}

  @spec new([{atom(), String.t()}]) :: t()
  def new(errors) when is_list(errors) do
    message = errors |> List.first() |> elem_or_default("configuration value is invalid")
    %__MODULE__{errors: Map.new(errors), message: message}
  end

  @spec field_errors(t()) :: [{atom(), {String.t(), keyword()}}]
  def field_errors(%__MODULE__{errors: errors}) do
    Enum.map(errors, fn {field, message} -> {field, {message, []}} end)
  end

  def to_form_errors(%__MODULE__{} = error), do: field_errors(error)

  @spec message(t()) :: String.t()
  def message(%__MODULE__{message: message}) when is_binary(message), do: message
  def message(%__MODULE__{} = error), do: Exception.message(error)

  defp elem_or_default({_, message}, _default), do: message
  defp elem_or_default(nil, default), do: default
end
