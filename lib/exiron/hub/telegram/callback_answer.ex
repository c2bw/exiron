defmodule Exiron.Hub.Telegram.CallbackAnswer do
  @moduledoc false

  # A separate bounded pool keeps acknowledgements independent of uploads and
  # per-bot send cooldowns. Answer failures never replay an accepted callback.
  def answer(token, id, result) do
    Task.Supervisor.start_child(Exiron.Hub.CallbackAnswers, fn ->
      opts = [
        token: token,
        adapter_opts: [receive_timeout: 1000, pool_timeout: 1000, connect_timeout: 1000]
      ]

      opts =
        case result do
          :ok -> opts
          {:ok, text} when is_binary(text) -> Keyword.put(opts, :text, String.slice(text, 0, 200))
          _ -> Keyword.put(opts, :text, "This button is unavailable. Please try again.")
        end

      ExGram.answer_callback_query(id, opts)
    end)

    :ok
  end
end
