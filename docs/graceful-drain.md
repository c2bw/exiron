# Draining before a restart

Drain mode pauses new work while accepted requests and Telegram sends finish.
It is an operator action, not an automatic delay on SIGTERM. Keep the process
running until it drains, then restart it using your normal deployment command.

## Monitor

Open the authenticated `/monitor` page and use **Prepare for restart**:

1. Choose a timeout (1–3600 seconds, default 60) and select **Start drain**.
2. Keep downstream clients connected and keep routing response traffic to this
   instance. Existing one-shot replies, stream updates, chat actions, cancellation,
   client reconnection and batch acknowledgements remain available.
3. Wait for **Drained · intake paused**. The four counts must all reach zero:
   pending requests, queued messages, active sends, and unacknowledged client
   batches. These counts overlap; they are not summed into a work total.
4. Restart the instance. A new instance starts with intake enabled. Alternatively,
   select **Resume intake** to cancel the maintenance pause.

The timeout never kills work, restarts the application, or resumes intake. If it
elapses with work outstanding, the monitor shows **Timed out · intake paused**.
Existing work can still finish; the phase becomes drained when all tracked work
is gone. Starting drain again while active preserves its original timeout. Resume
first to start a new drain. Drain controls are unavailable while activity updates
are paused, but drain progress continues to refresh.

## Release console

### Automated isolated smoke check

On Linux with dependencies installed and GNU/BusyBox `timeout` available:

```sh
MIX_ENV=test mix run --no-start scripts/release_smoke.exs
```

The script builds a temporary test release, disables its web server and Telegram
pollers, and binds its Erlang distribution listener to loopback under a unique
node name. It clears inherited release targets and Exiron credentials. It checks
drain-only, an actual restart/new boot/readiness, invalid-configuration startup
failure (exit 3), and rejection of drain against the failed Hub without restart.
It stops its own VM and removes its temporary release even on failure. It does
not operate on a deployed instance. The separate Linux CI job runs this check;
`mix precommit` remains the ordinary cross-platform quality gate.

### Wait and restart with the release helper

New releases include an executable `bin/exiron-safe-restart` beside `bin/exiron`:

```sh
bin/exiron-safe-restart --timeout 120 --startup-timeout 90
```

The helper starts (or joins) the running instance's drain, prints all four work
counts every second, and requests the normal release `restart` only after drain
completes. The timeout is 1–3600 whole seconds, default 60. Existing drain
deadlines are preserved; joining an already timed-out drain fails while work
remains. Its own wait deadline also prevents waiting indefinitely on a longer
existing drain. RPC calls have the Hub's normal call timeout.

Normal restart also captures the current application boot identity **before**
drain. After requesting restart, it waits for a different boot identity and a
ready Hub before returning success. Application boot identity changes even when
`System.restart/0` retains the OS PID; the old ready instance cannot satisfy the
check. `--startup-timeout` is a separate 1–3600-second budget, default 60 seconds.

Verification runs in a separate release `eval` VM and uses a monotonic deadline.
RPC probes have at most five seconds each, limited by the remaining budget,
rounded up to whole seconds, plus a one-second forced-kill grace. Allow local VM
startup and that small final-probe overhead in the deployment job's total timeout.
Boot-identity and restart-command RPCs each have their own five-second bound.
The host must provide `timeout` with `-k` support (GNU coreutils or modern BusyBox,
already available in the Alpine image); this is checked before normal drain.

Progress reports bounded states: `awaiting_restart`, `hub_unavailable`, `starting`,
`not_initialized`, `draining`, and `ready`. A new boot with `boot_failed` or
`disabled` fails immediately. Other states are retried until the startup deadline;
the failure message includes the last state. Verification failures exit **3**;
other failures are also nonzero. Inspect the existing service/container logs for
startup details. No second restart, automatic rollback, or intake change is
performed on verification failure: the restart has already been requested.

Readiness uses the same Hub criteria as `/health/ready` and also requires the
Exiron OTP application to have completed startup. It does not test public HTTP
routing, TLS, Telegram connectivity, or downstream client availability. Keep any
external health checks in your deployment process.

Drain timeout, a disabled/unreachable Hub, cancellation, replacement of the drain,
or a drain RPC failure produces a nonzero exit and **skips restart**. Outstanding work is
not cancelled or discarded. The process remains running if it was running before
the failure. Intake stays paused once drain has started, unless another operator
resumed it. Inspect status and explicitly resume if abandoning maintenance:

```sh
bin/exiron rpc 'IO.inspect(Exiron.Hub.drain_status())'
bin/exiron rpc 'Exiron.Hub.resume_intake()'
```

An interruption before the restart step skips restart and does not resume intake.
An interruption after restart was requested cannot undo that request. The remote
drain wait may finish after the RPC caller disconnects, but that wait never
restarts the VM. Serialize maintenance operations: do not resume intake, reload
configuration, replace the instance, or run another restart command between the
successful drain check and restart. The helper is not a deployment lock.

Use the same release environment, node name and cookie as the running instance.
RPC requires enabled release distribution and local administrative access; no
hook or metrics token is used. The helper targets its adjacent `bin/exiron`, not
an arbitrary command from `PATH`. It ships in `mix release` output and the Docker
image; it is not a `mix phx.server` restart command.

### Service managers and upgrades

To leave restart to systemd, a container orchestrator or a deployment script:

```sh
/path/to/current-release/bin/exiron-safe-restart --timeout 120 --drain-only &&
  sudo systemctl restart exiron
```

Replace the second command with your existing deployment operation. The `&&` is
essential: failure must prevent the stop/restart step. Run the helper **before**
stopping the service/container, while the Hub, endpoint and downstream clients
can still finish accepted work. Configure the deployment job's timeout to allow
the drain plus RPC overhead. Readiness becomes 503 during drain; readiness-driven
restarts or removal of response traffic must not terminate this wait early.

`--drain-only` preserves its existing behavior: it does not capture boot identity,
request restart, invoke the startup verifier, or require the `timeout` utility.
`--startup-timeout` has no effect in that mode. Your service manager/deployment
process owns startup verification after its own restart command.

The default helper invokes the release's `restart` command, which reboots the
existing runtime using the current release configuration. It does not install a
new release, switch symlinks, or invoke systemd. It verifies the restarted current
release's boot and Hub readiness.
For an upgrade, use `--drain-only` against the **old running release**, then switch
and restart using the deployment mechanism that starts the new release. Keep the
old instance and its clients available until the helper succeeds. Older releases
without `Exiron.ReleaseMaintenance` need the manual RPC procedure below for their
first upgrade. Restart loss remains part of the in-memory delivery contract.

### Manual RPC controls

The same controls are available through the existing Hub API, including from a
release's `bin/exiron rpc`:

```elixir
Exiron.Hub.start_drain(timeout_ms: 60_000)
Exiron.Hub.drain_status()
Exiron.Hub.resume_intake()
```

`start_drain/1` returns `{:ok, snapshot}`. `drain_status/0` returns a map with
`active`, `phase` (`running`, `draining`, `drained`, `timed_out`), `drained`,
`started_at`, `timeout_ms`, and the four work counts. `resume_intake/0` returns
`:ok`. These are administrative controls; hook bearer tokens cannot change them.
The full administrative status also includes a `drain` snapshot. Hook-scoped
status does not expose other hooks' drain counts.

## Intake and client behavior

The Telegram poller stops issuing new polls while draining. A poll already in
flight can still return. Hub admission rejects its new messages and callbacks
with a retry result before deduplication or request creation, so their update
IDs are not acknowledged as accepted. Polling resumes within roughly one second
of resume. Existing buffered albums remain in the poller until intake resumes.
Telegram may redeliver an update accepted before the pause if its next offset
had not yet been sent. Handlers must continue to tolerate duplicates.

New pushes and edits to completed replies return HTTP 503:

```json
{"error":"intake paused for drain","code":"draining"}
```

This happens before send admission; the rejected operation sent nothing.
Pending request replies and stream updates use the response endpoint and continue
to work. Both clients recognize the protocol 1.11 error:

```go
exiron.IsDraining(err)
```

```elixir
ExironClient.Error.draining?(error)
```

Mutation calls do not retry this rejection automatically. Resume intake before
retrying new work. Existing client handler signatures and response modes do not
change; older clients can still complete pending work during a drain.

`/health/ready` returns 503 with reason `draining` for the whole pause, including
after completion or timeout. `/health/live` remains healthy. Configure deployment
checks so failed readiness removes **new intake** without preventing existing
clients from sending responses or acknowledgements. A readiness-driven restart
or an immediate SIGTERM would defeat the drain.

## Limits

This preserves the existing [in-memory delivery contract](delivery-guarantees.md).
Drain does not persist messages, confirm uncertain Telegram results, guarantee
client application side effects have ended, or empty Telegram's upstream queue.
Legacy destructive polling and best-effort listener delivery do not give the
same acknowledgement visibility as managed explicit delivery. Requests can still
expire, clients can disconnect, and listeners can be dropped under existing
rules. Expiry or cancellation may remove tracked work without a successful reply.
Zero tracked work means Exiron has no retained requests, queued messages, active
sends or client batches; it is not a promise of successful delivery for every
accepted message. A crash or forced restart still loses in-memory state.
