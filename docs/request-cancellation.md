# Request cancellation

Protocol 1.4 advertises `request_cancellation`. A hook can cancel its pending
requests, including queued requests, unfinished streams, responses waiting for a
bot send slot, and multipart replies still being delivered. Existing reply,
streaming, edit and push APIs remain available.

```http
POST /api/cancellations
Authorization: Bearer <hook-token>
Content-Type: application/json

{"req_id":"request-1"}
```

A successful response closes the request and reports delivery at cancellation:

```json
{"ok":true,"cancelled":true,"delivery_status":"partial","message_ids":[901,902]}
```

| `delivery_status` | Meaning |
| --- | --- |
| `not_started` | No reply was confirmed and no attempt is in flight or has an unknown outcome. Queued work was stopped before delivery. |
| `partial` | Reply content was confirmed; no reply attempt is currently in flight or has an unknown outcome. Already delivered messages remain visible. |
| `unknown` | A reply attempt is in flight, or an earlier attempt has an uncertain outcome. Telegram may still deliver it. |

`message_ids` contains known confirmed reply message IDs and may be incomplete for
`unknown`. Typing actions do not count as reply content. Cancellation does not
recall an HTTP request already sent to Telegram, delete delivered text, or undo
application side effects. Do not assume an empty ID list means nothing arrived
when status is `unknown`.

## Ownership and ordering

Only the request's hook can cancel it. Other hooks receive
`request_not_assigned` (409). Unknown, expired and completed requests return
`request_not_found` (404). Completed replies can still be edited using the
existing edit API; cancellation targets pending work.

Cancellation removes the request from queued and retained HTTP/WebSocket batches,
terminates its active send tasks, releases their timers and callers, and prevents
later parts or retries from starting. A send permission check runs after a bot
slot is acquired, before every Telegram attempt. Cancelled send callers and later
updates, actions or edits receive `request_cancelled` (409). Late send results and
acknowledgements cannot reopen the request. The monitor shows a terminal
**Cancelled** outcome.

The Hub's processing order resolves races: if cancellation wins, the pending
request is closed; if final completion or expiry wins first, cancellation returns
404. A cancellation racing with an HTTP attempt reports `unknown` conservatively.
Expiry also stops active sends and removes expired requests from retained batches;
already initiated HTTP requests may still have reached Telegram.

The latest 500 cancellation receipts are retained in memory. Repeating a cancel
for a retained request returns the same snapshot without repeating work. After
receipt eviction or restart the request returns 404, and further responses remain
rejected. No request bodies or bot credentials are stored in cancellation receipts.

## Elixir client

```elixir
{:ok, result} = ExironClient.cancel_request(client, request_or_id)
result["delivery_status"]
result["message_ids"]

# Recognize an update rejected after cancellation:
ExironClient.Error.request_cancelled?(error)
```

Call cancellation from another process while a stream helper is running. The
stream stops on the next server rejection and does not finalize or retry it.
Stop your text producer or local task as well if it is doing independent work or
waiting for more input; cancellation does not kill application handler processes.

## Go client

```go
result, err := client.CancelRequest(cancelCtx, request.ReqID)
if err == nil {
    fmt.Println(result.DeliveryStatus, result.MessageIDs)
}

if exiron.IsRequestCancelled(err) {
    // Stop producing updates for this request.
}
```

Use a live context for `CancelRequest`, including when the stream's own context
has already been cancelled. It can run from a separate goroutine. Cancelling a Go
context alone retains its existing local behavior; it does not implicitly issue a
server cancellation. Stop the local producer/context too when appropriate. A
server 409 stops `StreamText` without a final update or automatic retry.

Both managed clients treat `request_cancelled` from a handler as terminal handled
work: they do not retry that request or block unrelated messages in the same
batch, and the batch can be acknowledged normally. Other handler errors retain
the existing retry policy. For example, handlers returning the result of a stream
helper naturally stop once the server rejects an update after cancellation.

Cancellation is for requests with a `req_id`; independent pushes remain unchanged.

## Monitor action

Authenticated dashboard operators can cancel an inspected request from its detail
panel. The panel shows the current delivery certainty and confirmed Telegram IDs
before the action, then the retained cancellation result afterward. It uses the
same cancellation behavior as the hook API; the server derives hook ownership
from the live request, and no hook token is passed to the browser. The hook API
continues to enforce its existing ownership checks.

Cancellation is disabled while monitor updates are paused. Resume live updates
before acting. A completion or expiry that wins the race is shown as closed,
with a message that nothing was cancelled. Repeated cancellation returns the
retained result without repeating work. Results remain visible when reopening
the request while its trace and cancellation receipt are retained.

The action stops remaining sends and rejects later response updates. It does not
remove messages already accepted by Telegram, stop a downstream application's
independent computation, or make an in-flight delivery result certain. An
`unknown` result remains uncertain; inspect Telegram before sending new work.
