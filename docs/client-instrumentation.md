# Optional API request observations

Go `Config.OnRequest func(exiron.RequestEvent)` and Elixir `on_request: callback`
are disabled by default. Enable them on the client constructor to observe one
completion per logical HTTP API request, including existing bounded safe retries.
This covers REST calls used by either transport; it does not observe WebSocket
frames or measure handler/Telegram end-to-end latency.

Events contain only `method`, `route`, `duration_ms`, `attempts`, `http_status`
and `error_kind`. Go exposes corresponding exported struct fields. Duration uses
a monotonic clock and includes retry waits. Attempts counts transport attempts;
status is the last response status, or 0 without a response. Unknown routes and
methods become `other` and `OTHER`. Query values, URLs, headers, request IDs,
credentials, bodies and arbitrary error text are never included.

Callbacks run synchronously in the calling process/goroutine and **must return
promptly**. Panics/exceptions/exits raised by callbacks are isolated from the
request result. Blocking callbacks can delay their caller; no extra worker or
timeout is introduced. Do not recursively issue requests through the same
observed client from its callback. Forward metadata to an application-owned sink.

Validation rejected before entering the request pipeline may produce no event.
An operation rejected inside it can report zero attempts. Mutations retain their
existing no-automatic-retry behavior. Observations add no network traffic and
cannot confirm delivery or make a retry safe. Existing error/raw-result access
remains unchanged. Arbitrary Go termination such as `runtime.Goexit` or an
external process kill cannot be isolated by a callback panic/exception guard.

```go
client, err := exiron.NewClient(exiron.Config{
    BaseURL: "http://localhost:4000", Token: token,
    OnRequest: func(event exiron.RequestEvent) { metrics.Record(event) },
})
```

```elixir
client = ExironClient.new(base_url: "http://localhost:4000", token: token,
  on_request: fn event -> MyMetrics.record(event) end)
```

Callbacks may run concurrently across handlers, lease watchers and background
reports. Use a concurrency-safe sink. REST control/report requests are observed
when they share the configured client; WebSocket ping/ack frames are not.

Delivery diagnostic lookups report `/api/deliveries/:id`, never the actual
identifier. The cancellation route is `/api/cancellations`.
