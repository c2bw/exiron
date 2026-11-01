# Local persistent monitoring

This Linux setup runs Prometheus on **127.0.0.1:9090**, scrapes Exiron's protected
`/metrics` endpoint, and stores history in the named Docker volume
`exiron-monitoring_prometheus_data`. Retention is 15 days or 2 GB of blocks,
whichever expires first. WAL/head data also uses disk, so 2 GB is not a hard
quota. No new application dependencies or external services are required.

## Start against the application

Generate a dedicated token once; do not reuse a dashboard password or hook token:

```sh
install -d -m 700 monitoring/secrets
test -f monitoring/secrets/metrics_token || openssl rand -hex 32 > monitoring/secrets/metrics_token
chmod 644 monitoring/secrets/metrics_token
```

The directory is private to your host user; the mounted file must be readable
by the non-root Prometheus container. This directory is ignored by Git. Keep the token private.

Start/restart the application with the same token file:

```sh
EXIRON_METRICS_TOKEN_FILE=monitoring/secrets/metrics_token mix phx.server
```

For a release, use an absolute path readable by the release user.
`EXIRON_METRICS_TOKEN` can supply the value directly and takes precedence over
the file setting. The existing application Compose file forwards that variable;
it defaults to empty. Without a token, `/metrics` returns 404. Missing/wrong
bearer credentials return 401. Browser sessions and hook tokens do not grant
metrics access.

Then, from the repository root:

```sh
docker compose -p exiron-monitoring -f monitoring/compose.yml up -d
```

Open <http://127.0.0.1:9090/query> for graphs, `/targets` to check scraping, and
`/alerts` for evaluated alerts. The default target is `127.0.0.1:4000`; edit
`monitoring/prometheus.yml` for another port. Linux host networking lets the
container reach a loopback-bound application. Prometheus also binds only to
loopback. This is a local operator setup, not a public monitoring service.

Restart after edits to the mounted scrape configuration or rules:

```sh
docker compose -p exiron-monitoring -f monitoring/compose.yml restart prometheus
```

To switch between default and benchmark configuration mounts, use `up -d`;
`restart` does not recreate mounts. `docker compose ... stop` stops monitoring
without deleting history. Do not use `down -v` if history should be preserved.

## Useful graphs

| Question | PromQL |
| --- | --- |
| Offline rejections per second by hook | `rate(exiron_hook_unavailable_rejections_total[5m])` |
| Overload rejections per second by hook | `rate(exiron_hook_overload_rejections_total[5m])` |
| Queued payload bytes | `exiron_hook_queued_bytes` |
| Active Telegram rejection cooldowns | `exiron_telegram_suppressions` |
| Skipped Telegram attempts / probes / recoveries | `exiron_telegram_suppressed_attempts_total`, `exiron_telegram_rejection_probes_total`, `exiron_telegram_recoveries_total` |
| Global active send payload bytes / limit | `exiron_in_flight_send_bytes`, `exiron_in_flight_send_bytes_limit` |
| Hook active send bytes / limit | `exiron_hook_in_flight_send_bytes`, `exiron_hook_in_flight_send_bytes_limit` |
| Send byte admission rejections | `exiron_send_byte_capacity_rejections_total`, `exiron_hook_send_byte_capacity_rejections_total` |
| Global queued plus unacknowledged bytes / limit | `exiron_buffered_bytes`, `exiron_buffered_bytes_limit` |
| Global unacknowledged bytes | `exiron_buffered_awaiting_ack_bytes` |
| Global budget rejections | `exiron_buffer_request_rejections_total`, `exiron_buffer_listener_rejections_total` |
| Queued plus unacknowledged delivery bytes | `exiron_hook_buffered_bytes` |
| Pending requests by hook | `exiron_hook_pending_requests` |
| Pending work versus its limit | `exiron_pending_requests / exiron_pending_limit` |
| Successful response p95 / p99 | `exiron:response_p95_seconds:5m` / `exiron:response_p99_seconds:5m` |
| Failed operations per second by hook | `rate(exiron_hook_send_failures_total[5m])` |
| Timed send attempts by outcome | `sum by (outcome) (rate(exiron_send_duration_seconds_count[5m]))` |
| BEAM memory | `exiron_vm_memory_bytes` |
| BEAM scheduler pressure | `exiron_vm_run_queue` |

Histograms use fixed buckets from 10 ms through 60 s plus infinity. Quantiles
are bucket estimates across all hooks, not exact or per-hook percentiles.
Successful response latency includes queueing, retries, client processing and
observed Telegram completion; it excludes time before acceptance by the Hub.
The collector has 17 fixed histogram rows, uses atomic ETS updates, and retains
no individual samples or hook names.

Per-hook counters come from current Hub state and reset with that state.
Removed hooks disappear from new scrapes. Histograms reset when the collector
restarts and otherwise span Hub resets. `rate`/`increase` handle observed counter
resets. Neither persists inside Exiron: Prometheus persists scraped history.
Events between the last scrape and a crash can be lost.

If the Hub cannot answer within one second, the scrape still exposes
`exiron_hub_snapshot_available 0` and VM/collector metrics. The dedicated Hub
snapshot excludes histories, payloads, credentials, chat IDs and configuration
digests. Hook names are the only configurable metric labels.

## Alert rules

`rules.yml` includes scrape/collector availability, offline/overload rejections,
sustained pending/buffer pressure, slow successful responses, and a high timed
send failure ratio. Default latency thresholds are p95 500 ms and p99 1 s.
Pressure at 80% of configured limits and a 5% failed attempt ratio are starting
thresholds; tune them to observed traffic and service requirements. Low-volume
guards suppress latency/failure alerts below 100 observations in five minutes. Persistence windows reduce noise.

Retries can recover failed attempts. Offline rejection is the current admission
policy and is expected during fault tests. Neither signal proves accepted work
was lost. No memory-growth alert is enabled: synthetic instrumentation and GC
affect the short-run baseline. Review longer real workloads before selecting a
memory budget.

Alerts are evaluated locally. **Notifications are not sent**: an Alertmanager
and a notification destination are needed for delivery. The included setup does
not configure notification services.

Validate syntax and alert behavior:

```sh
docker run --rm --network none --entrypoint /bin/promtool \
  -v "$PWD/monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  -v "$PWD/monitoring/rules.yml:/etc/prometheus/rules.yml:ro" \
  -v "$PWD/monitoring/secrets/metrics_token:/etc/prometheus/metrics_token:ro" \
  prom/prometheus:v3.13.5 check config /etc/prometheus/prometheus.yml
docker run --rm --network none --entrypoint /bin/promtool \
  -v "$PWD/monitoring:/work:ro" -w /work \
  prom/prometheus:v3.13.5 test rules rules-test.yml
```

## Isolated monitored soak

This uses fake Telegram traffic and a dedicated loopback server. It never
injects work into an existing deployment or mounts the injector in production:

```sh
PROMETHEUS_CONFIG=./prometheus-benchmark.yml \
  docker compose -p exiron-monitoring -f monitoring/compose.yml up -d
EXIRON_BENCH_METRICS_TOKEN_FILE=monitoring/secrets/metrics_token MIX_ENV=test \
  mix run --no-start benchmarks/network.exs --duration 600 --rate 100 \
  --hooks 24 --no-faults --port 4013 --output /tmp/exiron-monitored-steady.json --quiet
```

Repeat without `--no-faults` to test reconnects, slow clients, lost acknowledgements
and recoverable send failures. Inspect both `all_offers_completed` and
`all_offers_accounted_for`: explicit offline rejections count only toward the
latter. See the benchmark README for admission semantics.

The listener stops when the run ends; its target then becomes unavailable.
`workload="synthetic"` identifies raw benchmark series. After inspection, stop
the temporary monitoring stack or switch to the default configuration for a
running application. Keep synthetic results separate from deployment data.
A loopback run does not validate a remote machine, TLS proxy or real Telegram
latency; that requires an isolated staging target.

References: [text format](https://prometheus.io/docs/instrumenting/exposition_formats/),
[Docker installation](https://prometheus.io/docs/prometheus/latest/installation/),
[storage](https://prometheus.io/docs/prometheus/latest/storage/),
[pinned release](https://github.com/prometheus/prometheus/releases/tag/v3.13.5).
