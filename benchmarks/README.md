# Performance benchmarks

Keep generated measurements outside source control. The examples write to
`/tmp`; `benchmarks/results/` is also ignored by Git for local output.

Run the repeatable Hub hot-path benchmark from the repository root:

```sh
mix run benchmarks/hub_hot_paths.exs
```

The benchmark covers indexed route matching, bounded queue insertion, and
client payload encoding. It reports median and p95 latency without enforcing
machine-dependent thresholds. Precommit runs the lightweight `--smoke` mode so
the benchmark cannot silently drift out of date.

## Concurrent Hub workloads

Run in a **fresh VM**, with application startup controlled by the script:

```sh
MIX_ENV=test mix run --no-start benchmarks/hub_concurrent.exs --output /tmp/exiron-concurrent.json
```

The script disables real Telegram polling and the web listener before starting
Exiron. It uses fake tokens and an injected sender with a 10 ms delay; it never
sends messages to Telegram or loads deployment route configuration.

After a short warm-up, it runs six scenarios: 1, 8 and 24 concurrent hooks,
each with text-only and mixed 1 MiB media traffic. Each hook performs 30 batches
of four routed requests. Odd hooks use explicit HTTP delivery semantics; even
hooks use socket delivery semantics. Each second batch verifies HTTP replay
before acknowledgement. Mixed scenarios also receive a file listen event and
push a file on each second batch. Every routed request receives a response.
A status subscriber serializes updates while reading a full snapshot every
100 ms. A separate sampler observes Hub mailbox length, process memory and
whole-VM memory approximately every 10 ms.

The harness asserts exact delivery counts, unique request IDs per batch,
unchanged HTTP replay, media content integrity, successful responses/pushes,
and no remaining queues, pending requests, sends or overload events. Precommit
runs a small smoke scenario covering both transports and replay.

Results include throughput, batch completion/ingress/response p50/p95/p99,
status-read latency, sampled mailbox peak, Hub process memory peak and VM memory
peak. Memory fields are bytes. Hub process memory excludes shared off-heap
binary payloads; VM memory includes the load generator, sampler and observer.
Peaks are samples, not guaranteed absolute maxima. Throughput counts completed
routed requests, excluding listen events and pushes.

### Interpretation and limits

This is a closed-loop benchmark: each hook waits for its batch to complete
before creating more work. It measures contention under concurrent delivery,
not overload under a fixed arrival rate. The 10 ms simulated sends create a
throughput ceiling even with no Hub bottleneck. The one-hook baseline uses HTTP;
larger scenarios mix transports equally. Media is listener traffic plus pushes,
not media downloaded by actual Telegram pollers.

Transport methods are invoked directly on the Hub. JSON serialization is
included, but network framing, TLS, Phoenix controllers/rate limits, actual
WebSocket connections, LiveView rendering and Telegram latency variation are
excluded. One monitoring subscriber is simulated. These results cannot establish
full-system capacity or predict saturation, outages or sustained memory growth.

Repeat runs on representative hardware and compare text/media cases at each
concurrency. Before partitioning the Hub, collect production traffic sizes and
arrival rates, define an acceptable end-to-end p95/p99, and run an open-loop
network load test plus a longer soak with slow clients, reconnects and send
failures. If those miss the objective, correlate mailbox backlog with status
publication and serialization costs before changing state ownership.

## Profiling and monitoring isolation

Limit the workload to one scenario to profile only the Hub process:

```sh
MIX_ENV=test mix run --no-start benchmarks/hub_concurrent.exs \
  --hooks 24 --rounds 10 --media-bytes 0 \
  --profile /tmp/hub.eprof --output /tmp/hub-profile.json
```

The OTP `tools` application supplies eprof. Function call counts and exclusive
traced time are written to the profile file; the workload report is marked
`profiled: true`. Tracing substantially slows execution: do not compare its
throughput or latency to normal runs. Shorter profiled runs reduce overhead.

Use `--no-observer` to remove the synthetic PubSub subscriber and periodic
snapshot reader. This does **not** disable internal status publication; it
separates subscriber/read overhead from the publication work the Hub performs
regardless of subscribers. `--hooks`, `--rounds` and `--media-bytes` also work
without profiling.

## Real HTTP and WebSocket workload

```sh
MIX_ENV=test mix run --no-start benchmarks/network.exs \
  --duration 120 --rate 100 --hooks 24 --output /tmp/exiron-network.json
```

The launcher starts a dedicated Bandit server on an ephemeral **loopback-only**
port and a Go load generator using the existing gorilla/websocket dependency.
It compiles the generator to a temporary binary and removes it on completion.
Go and the installed client module dependencies must be available. No new
application dependency or production route is added.

Clients traverse the actual Phoenix endpoint, bearer authentication, rate
limits, HTTP JSON handling and raw WebSocket upgrade/frame handling. HTTP clients
poll every 200 ms; odd hooks poll and even hooks use sockets. A status API reader
runs every 500 ms. The controlled ingress endpoint is mounted only by the
benchmark Plug, requires a random per-run control token, and substitutes for
Telegram polling/downloads. Normal application routes do not expose it.

Arrivals follow a fixed schedule independent of completed requests. Up to 64
injection calls can be in flight; excess offers are recorded as generator drops,
not silently postponed. Schedule-lag percentiles reveal a generator that cannot
maintain the requested arrival rate. Completion latency starts at the scheduled
arrival time and ends at a successful HTTP response-send acknowledgement, so
waiting, processing and retries are included.

Every 19th injection also supplies a file listen event (default 1 MiB, configurable
with `--media-bytes`). Deterministic content is checked on receipt. Fault mode is
on by default: every eighth hook waits 100 ms per request, HTTP clients omit
every tenth batch acknowledgement, sockets close before handling every twentieth
nonempty frame, and the fake sender fails the first attempt for every 97th
response. Only explicit `send_unavailable` is retried; unknown delivery results
are not blindly retried. Use `--no-faults` for a comparison without those faults.

The report records offers, injected/completed requests, unexpected errors,
duplicates suppressed, recovered send failures, reconnects, media observations,
latency and one-second VM/Hub/backlog samples. The generator waits up to 30 seconds
for routed work to drain. Correctness failures exit nonzero; machine-dependent
latency targets are evaluated in the report analysis, not enforced by precommit.
The smoke run covers both transports, replay, reconnect and a recoverable send
failure with small payloads. Listen delivery remains lossy by contract.

This is still a single-host synthetic experiment. It excludes TLS, real Telegram
network behavior, actual file downloads and LiveView browser rendering. VM memory
includes the server and instrumentation but excludes the separate Go generator.
Sampling can miss transient peaks; a two-minute soak is not a long-term leak
proof. Keep benchmarks and validation sequential to avoid contaminating results.

### Admission accounting during reconnects

A successful fixture injection means the Hub processed the incoming update; it
does not prove that a hook accepted routed work. The fake Telegram sender counts
explicit unavailable-hook notices by chat. At drain, the generator compares
missing request counts for each hook against those notices. Both
`all_offers_completed` and `all_offers_accounted_for` appear in the JSON.
Unexpected errors, unexplained missing work, overload and generator drops fail
the harness; known unavailable notices are reported without being mislabeled as
successful deliveries. `all_offers_completed` is false when such notices occur. Completion latency percentiles describe completed
requests only and must always be read alongside these counts.

Use `--quiet` to print a short accounting result while retaining full JSON with
`--output`. Network resource samples are whole-VM measurements; the benchmark's
attempt/outcome counters also consume memory, so growth cannot automatically be
attributed to the application.

For a longer run with persistent metric collection, see the
[monitored soak setup](../monitoring/README.md#isolated-monitored-soak).
`--port` selects a fixed loopback listener port for a scraper; the default remains
an ephemeral port. `EXIRON_BENCH_METRICS_TOKEN_FILE` enables authenticated scrapes
using a token file without printing its value.

### Long-run diagnostics

Network samples also include BEAM binary/process/ETS memory, the benchmark's
sender-attempt table row count and allocated ETS bytes, and histogram collector
row count/bytes. Steady mode retains no attempt records. Fault mode keeps only
the current failed response for each chat and deletes it on retry success; this
relies on the generator processing responses serially per hook. Subtracting table
memory from VM memory is not a complete leak analysis.

When `--output PATH` is supplied, `PATH.progress.jsonl` records a scalar progress
sample approximately once per minute, including a binary-owner profile. The
sampler reads the lightweight metrics snapshot rather than copying delivery
frames and history. Profiles keep the top twelve owners, referenced buffer sizes
and process module/function identities, never buffer contents. Shared buffers
are deduplicated globally; per-process reference totals must not be added.
Sampling is concurrent and can include references awaiting garbage collection.
The final JSON still contains all roughly
one-second samples and final drain/accounting checks.

`server_events` reports bounded counts from Bandit's request stop/exception
telemetry. It keeps only a known endpoint category, read-timeout/other category,
event kind and coarse span-duration bucket. `before_request` means no Plug.Conn
was available: an error occurred while reading headers or constructing the
connection. It does not prove which client caused it or that the TCP connection
was idle. No headers, credentials, request bodies, stack traces or arbitrary
exception messages are retained. The observer is detached when the run ends. The harness fails its integrity
check if the observer detached unexpectedly during the run.

Connection tracing keeps only live connection counters plus at most 32 server
error details and 32 client unused-close examples. `server_error_traces` includes
peer port, connection age, received-byte count, parsed-request count and socket
read-timeout count. The Go `transport_connections` summary tracks local ports,
bytes written/read, use count and age, so unused client dials can be correlated
with early server errors. It retains no HTTP content or credentials.

`--http-idle-ms` controls the benchmark HTTP pool's idle timeout (30,000 ms by
default). A value of zero
disables the HTTP pool idle timeout for diagnostic comparison.
The controlled timeout test demonstrates that an entirely idle TCP socket can
reach Bandit's pre-request read-timeout path; this alone does not identify the
cause of a naturally observed timeout. Connection-level evidence is required.
