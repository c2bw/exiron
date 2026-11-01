# Executable managed-client lifecycle scenarios

`managed.json` is shared by the Go and Elixir SDK tests. It contains ten cases:
five operations, each run over HTTP and WebSocket. The older `../scenarios/`
catalog remains focused on wire formats, error codes and capability discovery.

The lifecycle runners start the real managed client, handler worker, stream
helpers and lifecycle controls. Go uses a loopback HTTP/WebSocket gateway; Elixir
uses a Req adapter for HTTP requests and a loopback WebSocket server with real
handshake, frame masking and reconnects. All credentials/messages are synthetic.
These tests do not connect to Telegram or a deployed Exiron instance.

| Operation | Required observation |
| --- | --- |
| Handler fails while draining | Drain reports failure; no acknowledgement, retirement or reply. |
| Connection lost before acknowledgement is accepted | The first acknowledgement is dropped. HTTP safely repeats the same acknowledgement without repeating the handler. WebSocket reconnects and processes the retained batch again. |
| Local deadline during a stream | One partial reply; no final reply, acknowledgement or quarantine. |
| Server cancellation during a stream | The handler cooperates with cancellation; one partial, no final reply, then successful retirement. |
| Quarantine, explicit recovery, restart | Drain retains one failed message; explicit recovery sends the chosen reply and removes the entry; a new managed run reuses the store and handles the next request. |

The reconnect case deliberately permits WebSocket handler side effects to repeat.
It exercises at-least-once delivery, not exactly-once application behavior. The
HTTP gateway drops the first acknowledgement request before accepting it; its
retry confirms the same batch. The WebSocket gateway reads the first ack but
closes the connection without committing it, then redelivers on reconnect.
This is one specific failure boundary, not every possible network failure.

The catalog supplies message/reply text, options, ordered steps and the exact
expected observation: handler calls, partial/final replies, ack attempts/commits,
retirements, quarantine counts, normalized result and ordered reply contents with
request IDs. Both runners execute the same steps and compare all observations to
that data. Unknown operations/steps fail. The contract checker rejects missing or
unknown fields, invalid counters, transports, timing options and outcomes.

Barriers use handler notifications, observed protocol mutations and process/run
completion. Real timers are used for the configured cooperative cancellation and
handler deadline. No fixed sleeps synchronize the scenarios. Cancellation uses a
cooperating producer: Go observes the handler context; Elixir's lazy producer
yields after its cancellation signal and the stream helper rejects that late chunk. This does not promise that an arbitrary
producer which ignores cancellation will stop.

Run from the repository root:

```sh
MIX_ENV=test mix run scripts/check_contract.exs
cd clients/elixir
mix test test/lifecycle_scenarios_test.exs
cd ../go
go test -race -run '^TestSharedManagedLifecycleScenarios$' -count=1
```

`mix precommit` validates the catalog and executes both SDK suites. Adding a new
operation requires support in both runners, validator updates and an update to
the completeness test in `test/exiron/contract_conformance_test.exs`. Additional
cases may reuse existing operations/steps; update the intentional Go catalog
count assertion when extending coverage.
