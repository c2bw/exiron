defmodule ExironClient.Feedback do
  @moduledoc """
  Opt-in thumbs-up/down ratings using existing inline keyboards and callbacks.

  These helpers make no network calls. Application handlers choose how to store
  votes, deduplicate by origin request/user, and finish the callback request.
  """
  alias ExironClient.Message
  @positive "exiron:feedback:v1:positive"
  @negative "exiron:feedback:v1:negative"
  @type t :: %__MODULE__{
          vote: :positive | :negative,
          origin_req_id: String.t(),
          request_id: String.t(),
          user_id: pos_integer(),
          callback_id: String.t()
        }
  defstruct [:vote, :origin_req_id, :request_id, :user_id, :callback_id]

  @doc "Copies a keyboard and appends a feedback row, preserving existing buttons."
  @spec keyboard(list()) :: {:ok, list()} | {:error, :invalid_feedback_keyboard}
  def keyboard(existing \\ [])

  def keyboard(existing) when is_list(existing) and length(existing) < 20 do
    valid? =
      Enum.all?(existing, fn row ->
        is_list(row) and length(row) in 1..8 and
          Enum.all?(row, fn button ->
            is_map(button) and get(button, :callback_data) not in [@positive, @negative]
          end)
      end)

    if valid? and Enum.sum(Enum.map(existing, &length/1)) <= 98 do
      {:ok,
       existing ++
         [[%{text: "👍", callback_data: @positive}, %{text: "👎", callback_data: @negative}]]}
    else
      {:error, :invalid_feedback_keyboard}
    end
  end

  def keyboard(_), do: {:error, :invalid_feedback_keyboard}

  @doc "Recognizes a complete rating callback; ordinary messages return `:error`."
  @spec from_message(Message.t()) :: {:ok, t()} | :error
  def from_message(
        %Message{msgtype: "request", datatype: "callback", req_id: req, data: data} = message
      )
      when is_binary(req) and req != "" do
    with vote when vote in [:positive, :negative] <- vote(data),
         user when is_integer(user) and user > 0 <- get(message.from, :id),
         callback when is_binary(callback) and callback != "" <- get(message.callback_query, :id),
         origin when is_binary(origin) and origin != "" <-
           get(message.callback_query, :origin_req_id) do
      {:ok,
       %__MODULE__{
         vote: vote,
         origin_req_id: origin,
         request_id: req,
         user_id: user,
         callback_id: callback
       }}
    else
      _ -> :error
    end
  end

  def from_message(_), do: :error

  defp vote(@positive), do: :positive
  defp vote(@negative), do: :negative
  defp vote(_), do: nil
  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_, _), do: nil
end
