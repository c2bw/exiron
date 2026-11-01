# Delivery diagnostics

Protocol 1.5 advertises `delivery_diagnostics`. Delivery errors include an optional
`delivery` object; successful response shapes and existing HTTP error codes stay
the same. Replies, edits, chat actions and pushes use the same diagnostic model.
Pre-send validation/authentication/capacity errors can have no diagnostic because
no delivery task was started. Existing direct Elixir Hub calls preserve their
error tuples; HTTP adds diagnostic context.

Fetch the most recent operation for a request, or a specific diagnostic ID:

```http
GET /api/deliveries/request-id-or-diagnostic-id
Authorization: Bearer <hook-token>
```

Only the owning hook can read a record. Other hooks receive
`request_not_assigned` (409); missing/evicted records return `delivery_not_found`
(404). Active operations are available while running. The last 500 completed,
failed, timed-out, cancelled or expired operation records are retained in memory.
Restart loses these records. A request lookup returns its latest operation; use
the diagnostic ID to keep referring to a particular update or edit. Push error
responses and send-failure history contain diagnostic IDs because pushes have no
request ID.

## Reading a snapshot

Each record contains:

- `operation` and `outcome`: what was attempted, and whether it is sending,
  succeeded, failed, timed out, cancelled or expired.
- `delivery_status`: `not_started`, `confirmed`, `partial` or `unknown`.
- `parts`: chat, bot name, position, operation (`send`, `edit`, `delete`, `action`),
  attempt count, message IDs and outcome for each retained part.
- Counts of planned, confirmed, rejected, uncertain, in-flight and unattempted parts.
- `last_error`: a safe category and description, Telegram error code when available,
  and `retry_after_ms` when Telegram supplied a valid retry delay.
- `retry_available`, `retry_safe` and `retry_action`: whether the original operation
  remains usable and how to proceed without blindly duplicating delivery.

A part is one Telegram operation. An album is one part with several message IDs.
Multipart text has one part per text message, plus any surplus-message deletions
needed when editing it shorter. A push can have parts in several chats. Confirmed
edits/deletions are operations that changed existing messages, rather than new
messages. Repeated 429 attempts update the same part instead of increasing the
part count. A recovered error can remain visible in a successfully delivered
part's `error` and the record's `last_error`.

Part details are capped at 128 per operation. `omitted_parts` reports truncation;
summary totals still count all parts. Message IDs are meaningful together with
the part's chat and bot. The arrays contain confirmed IDs when available; an
empty array does not prove non-delivery for an uncertain result.

| Retry action | What to do |
| --- | --- |
| `wait` | Delivery is still running; wait before another update. |
| `retry_request` | No delivery was confirmed or uncertain; wait the indicated delay and retry explicitly. |
| `fix_request` | Correct the payload or bot setup before explicitly retrying. |
| `inspect_chat` | Some work was confirmed or remains uncertain. Inspect the chat before deciding how to resume. |
| `request_closed` | The original request/receipt is closed; start new work explicitly if needed. |
| `none` | No retry is needed. |

`retry_safe` concerns duplicate **Telegram delivery**, not application handler side
effects. It is false for partial/unknown results. `retry_available` can be true
while `retry_safe` is false: the API may accept another update, but it could
duplicate an uncertain earlier send. Cancellation and expiry close pending work;
confirmed text stays visible. An HTTP timeout does not prove Telegram rejected
the request. Guidance is conservative and never enables automatic retries or an
automatic resume operation. Use confirmed/rejected/unattempted rows to decide what
remaining work is needed; do not replay a whole multipart response blindly.

## Clients

Go exposes typed diagnostics on `*exiron.Error` and on failed status entries:

```go
var apiErr *exiron.Error
if errors.As(err, &apiErr) && apiErr.Delivery != nil {
    d := apiErr.Delivery
    fmt.Println(d.DeliveryStatus, d.RetryAction, d.RetrySafe)
    if d.LastError != nil {
        fmt.Println(d.LastError.Code, d.LastError.RetryAfterMS)
    }
}

d, err := client.DeliveryStatus(ctx, requestID) // or diagnostic ID
```

Elixir exposes the same wire map on `%ExironClient.Error{delivery: diagnostic}`:

```elixir
case ExironClient.respond(client, request, "text", text) do
  {:error, %ExironClient.Error{delivery: diagnostic}} when is_map(diagnostic) ->
    {diagnostic["delivery_status"], diagnostic["retry_action"]}
  result -> result
end

{:ok, diagnostic} = ExironClient.delivery_status(client, request_id)
```

Both clients continue decoding legacy errors without diagnostics. A lookup after
a validation failure may describe an **older** operation; use the diagnostic
attached to the error when one is present.

## Monitor and privacy

Inspect a request in the monitor to see delivery counts, per-part outcomes, IDs,
Telegram codes and retry guidance. Send-issue cards also offer **Inspect delivery**,
including for pushes. Pause mode preserves the captured view. Diagnostic records
contain no message bodies, raw Telegram descriptions, bot tokens or hook tokens.
Telegram descriptions can echo submitted data, so diagnostics use a fixed safe
error catalog. The numeric Telegram code and validated delay are retained.
Telegram documents error fields and `retry_after` in the
[Bot API](https://core.telegram.org/bots/api#responseparameters).
