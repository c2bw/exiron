# Optional idempotency keys

Protocol 1.14 advertises `idempotent_mutations`. Keyed responses and pushes can
replay a retained result after a client loses the HTTP response, without starting
another Telegram operation. Keys are optional; unkeyed calls keep their existing
behavior. The cache is in memory and does not change the delivery durability contract.

## Use one key per operation

Go:

```go
reply, err := client.RespondWithOptions(ctx, reqID, exiron.DatatypeText,
    []byte("Hello"), exiron.ResponseOptions{IdempotencyKey: "reply-123"})

push, err := client.PushTextWithOptions(ctx, "Notice",
    exiron.PushOptions{IdempotencyKey: "notice-456"})
```

Elixir:

```elixir
ExironClient.respond(client, request, "text", "Hello", idempotency_key: "reply-123")
ExironClient.push(client, "text", "Notice", idempotency_key: "notice-456")
```

Generate an opaque key once, before the original operation. Reuse **that same key
and operation** when explicitly retrying after a lost HTTP response. A fresh key
identifies new work and can send another message. Keys accept 1–128 ASCII letters,
digits, `.`, `_`, `:`, and `-`. Go's empty string and Elixir's omitted/nil option
disable keying. An explicitly empty Elixir key is rejected.

The key namespace is the authenticated hook, shared across responses and pushes.
A reused key must have the same operation kind, target/request ID, datatype,
byte-identical decoded data, and normalized options. Differences return 409
`idempotency_conflict`; they do not start a send. Option order is ignored, but
explicit defaults and omitted options can differ. Metadata, final/partial state,
reply context, captions, buttons and bot selection are part of the operation.

Keys are supported for responses (including albums, callback responses and partial
updates) and pushes. Completed-reply edits and chat actions do not support keys.
Both clients reject keyed completed edits instead of silently ignoring the option.

## Dedicated endpoints and older servers

The SDKs select these routes only when a key is supplied:

- `POST /api/idempotent/responses`
- `POST /api/idempotent/push`

Their body is the normal response or push payload plus `idempotency_key`.
Authentication, payload limits, routing, send capacity and rate limits still apply.
No extra authentication request is needed for each mutation.

Older servers return an unsupported-route error instead of ignoring the key.
Clients **never fall back** to an unkeyed mutation and never automatically retry
these POST calls. Deploy the server first. For manual integrations, use the
dedicated routes; sending an unknown key field to an old ordinary endpoint cannot
provide idempotency protection.

## In-progress and completed results

The Hub serializes reservation with send admission. It does not keep a list of
waiting duplicate callers:

| Result | Behavior |
| --- | --- |
| Matching operation still running | 409 `idempotency_in_progress`, with a one-second retry hint. No second send starts. |
| Matching operation completed | Its recorded result is returned, including success, partial/unknown delivery diagnostics, timeout or cancellation. |
| Same key, changed operation | 409 `idempotency_conflict`. |
| All receipt slots occupied by running operations | 503 `idempotency_capacity_exceeded`; the new operation is not started. |
| Completed result too large to retain | The original call receives its result; duplicates get 409 `idempotency_result_unavailable`. The operation is not resent. |

A successful replay still works after the pending request has been completed and
removed. A lost original HTTP caller does not discard the receipt. Cached replay
of a push is available during drain because it starts no new work. Normal
validation/admission failures before an operation is accepted do not reserve keys.
An accepted operation's failure is retained; repeating its key returns that failure,
even if a later attempt with a **new** key might be allowed.

Partial and unknown delivery remain partial and unknown. Repeating the same key
within retention returns those outcomes; it does not retry the rejected or uncertain
Telegram parts. Inspect delivery diagnostics before deliberately creating new work.
Canonical error categories and sanitized delivery diagnostics are retained, not raw
downstream exception metadata. Unkeyed error handling remains unchanged.

Clients expose these classifiers:

```go
exiron.IsIdempotencyInProgress(err)
exiron.IsIdempotencyConflict(err)
exiron.IsIdempotencyUnavailable(err) // capacity or retained-result limit
```

```elixir
ExironClient.Error.idempotency_in_progress?(error)
ExironClient.Error.idempotency_conflict?(error)
ExironClient.Error.idempotency_unavailable?(error)
```

These helpers do not implement retry policy. A replayed diagnostic describes the
original operation at completion, not the request's current lifecycle state.

## Streaming

Low-level partial updates and finalization are separate mutations and need separate
keys. Replaying an old partial update returns its receipt; it does **not** edit a
newer visible reply back to that old text.

High-level `StreamText` / `stream_text` helpers accept a **base key** and derive a
separate opaque operation key from the base, request ID, full text and final flag:

```go
_, err := client.StreamText(ctx, reqID, chunks, exiron.StreamOptions{
    ResponseOptions: exiron.ResponseOptions{IdempotencyKey: "stream-123"},
})
```

```elixir
ExironClient.stream_text(client, request, chunks, idempotency_key: "stream-123")
```

Partial and final snapshots therefore never reuse one key for different operations.
The helpers still stop on errors and keep their existing coalescing and one-shot
alternatives. They do not automatically replay an entire stream. Replaying a whole
producer with different chunk timing can create different partial snapshots and
will not reliably recover a lost final response; retry the specific operation when
its payload/key is known. The two SDKs use the same deterministic derivation.

## Bounds and guarantees

The Hub retains at most **500 running/completed entries**. Running entries are never
evicted to make room for new sends. Completed receipts expire **ten minutes after
completion**, without extending their lifetime on lookup. Expiry is checked lazily
on keyed calls. When capacity is needed, the oldest eligible completed entry can
be evicted earlier. Each encoded result is capped at **64 KiB**; oversized results
leave a small non-replayable-result tombstone instead. Keys and operation payloads
are stored as SHA-256 fingerprints; the cache does not retain message bodies or
raw keys. Existing delivery history keeps its own separate bounds.

**After expiry, eviction, Hub reset, crash or restart, the key may be treated as
new and the operation may execute again.** Do not blindly retry an old uncertain
operation after those boundaries. There is no durable receipt store, exactly-once
Telegram guarantee, or protection for unrelated handler side effects. Separate
instances do not share receipts. This matches the accepted
[in-memory delivery contract](delivery-guarantees.md).
