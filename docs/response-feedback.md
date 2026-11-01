# Optional response feedback

Both SDKs can append a 👍 / 👎 row to a response keyboard and parse its ratings.
This is opt-in application behavior using the existing `inline_keyboards` and
`callback_queries` capabilities (protocol 1.2 or newer), over HTTP or WebSockets.
No new server protocol, process or persistence service is required. Existing
one-shot, streaming, ordinary callbacks and custom keyboards remain available.

## Build a reply keyboard

Go:

```go
keyboard, err := exiron.WithFeedback(existingKeyboard) // nil starts a new keyboard
if err != nil {
    return err
}
_, err = client.RespondWithOptions(ctx, message.ReqID, exiron.DatatypeText,
    []byte("Here is the answer."), exiron.ResponseOptions{InlineKeyboard: &keyboard})
return err
```

Elixir:

```elixir
{:ok, keyboard} = ExironClient.Feedback.keyboard(existing_keyboard) # [] for a new keyboard
ExironClient.respond(client, request, "text", "Here is the answer.",
  inline_keyboard: keyboard)
```

The builders copy/preserve existing buttons and append a row. They reject an
existing feedback row or a keyboard without room for one row and two buttons;
they never silently drop buttons. Other keyboard validation remains unchanged.
Only applications that handle ratings should opt in. Negotiate both existing
capabilities before enabling this against an older server. Constructors and the
keyboard helpers make no network calls.

For streamed text, keep using your chosen stream API. To offer feedback only on
the completed answer, send partial updates without buttons, then attach the
feedback keyboard to the final `RespondWithOptions` / `respond` call. Supplying
it in ordinary stream options instead shows the buttons during the stream.
This does not force a switch from one-shot to streaming or vice versa.

## Handle a rating

Go:

```go
if rating, ok := exiron.ParseFeedback(message); ok {
    // Apply your storage policy to rating.OriginReqID, rating.UserID, rating.Vote.
    _, err := client.ReplyText(ctx, rating.RequestID, "Thanks for the feedback.")
    return err
}
// Continue handling ordinary requests and application buttons.
```

Elixir:

```elixir
case ExironClient.Feedback.from_message(message) do
  {:ok, rating} ->
    # Apply your policy to rating.origin_req_id, rating.user_id and rating.vote.
    ExironClient.reply_text(client, rating.request_id, "Thanks for the feedback.")
  :error ->
    # Continue your ordinary request/callback handling.
    :not_feedback
end
```

Parsers accept only identified callback requests with an originating request ID;
ordinary text/listen messages, other buttons and push buttons without a request
origin are not ratings. `request_id` / `RequestID` is the **new callback request**
to finish; `origin_req_id` / `OriginReqID` is the answer being rated. Click IDs are
also exposed. Vote values are `positive` / `negative` (`:positive` / `:negative`
in Elixir). Application button data uses `exiron:feedback:v1:positive` and
`exiron:feedback:v1:negative`; Telegram sees Exiron's usual opaque references.

Bindings remain scoped to the bot, chat and message, with existing lifetime and
capacity bounds. Current hook access lists apply to the clicker. Any permitted
group user may rate; the application chooses whether only the original requester
can rate, whether votes can change, and whether to store feedback. Deduplicate
storage by origin request/user if you want one current rating per person, and by
callback ID for replay handling. Handler retries and distinct repeated clicks can
otherwise repeat application side effects. The server does not create a durable
vote database or automatically remove custom buttons.
