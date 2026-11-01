defmodule ExironWeb.HookLiveFailure do
  @moduledoc false
  def summary(failure) do
    diagnostic = Map.get(failure, :delivery) || %{}
    category = get_in(diagnostic, [:last_error, :category])

    {title, action} =
      case category do
        "unauthorized" ->
          {"Bot credentials rejected", "Check the bot credentials before sending again."}

        "forbidden" ->
          {"Bot cannot access this chat", "Check the bot's chat membership and send permissions."}

        "bad_request" ->
          {"Telegram rejected the message",
           "Review message formatting, size and the reply or edit target."}

        "rate_limited" ->
          {"Telegram rate limit reached",
           "Wait for the retry delay shown in the delivery details."}

        "bot_not_configured" ->
          {"No bot available for this chat",
           "Check that this destination still has a configured bot."}

        "invalid_payload" ->
          {"Message could not be delivered", "Review the message format and payload limits."}

        "delivery_timeout" ->
          {"Delivery deadline reached", "Inspect the chat before deciding whether to send again."}

        _ ->
          {"Send did not complete", "Open the delivery details to check what Telegram confirmed."}
      end

    certainty =
      case diagnostic[:delivery_status] do
        "unknown" ->
          "Delivery is uncertain. A message may already be visible in Telegram."

        "partial" ->
          "Some parts were delivered. Sending the whole message again may create duplicates."

        "confirmed" ->
          "Telegram confirmed delivery; review the remaining operation before acting."

        "not_started" ->
          "No message parts were confirmed."

        _ ->
          "Delivery certainty is unavailable for this retained failure."
      end

    %{title: title, action: action, certainty: certainty}
  end
end
