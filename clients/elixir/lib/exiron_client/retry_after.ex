defmodule ExironClient.RetryAfter do
  @moduledoc false

  def apply_header(%{status: 429} = error, [value]) do
    case delay_ms(String.trim(value)) do
      delay when is_integer(delay) and delay > 0 ->
        %{error | retry_after_ms: max(error.retry_after_ms || 0, delay)}

      _ ->
        error
    end
  end

  def apply_header(error, _headers), do: error

  defp delay_ms(value) do
    if value != "" and String.match?(value, ~r/^[0-9]+$/) do
      String.to_integer(value) * 1000
    else
      case Req.Utils.parse_http_date(value) do
        {:ok, date} -> div(DateTime.diff(date, DateTime.utc_now(), :microsecond) + 999, 1000)
        _ -> nil
      end
    end
  end
end
