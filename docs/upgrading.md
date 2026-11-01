# Upgrading Exiron and its clients

Check the [changelog](../CHANGELOG.md), [compatibility reference](compatibility.md)
and [client reference](client-reference.md) before updating. Server, SDK,
protocol and configuration schema versions have different purposes.

1. Record the current artifact/commit, enabled SDK features and active configuration.
   Keep a known-good artifact and a configuration compatible with it. Configuration
   history contains credentials and must retain its existing private permissions.
2. Build and verify the candidate separately. Run `mix precommit` and the isolated
   release smoke command in [graceful drain](graceful-drain.md). These checks use
   synthetic traffic and do not migrate a deployed instance.
3. Deploy server support before enabling new negotiated client features. The SDKs
   fail startup for unsupported opt-ins. Old clients retain supported existing APIs;
   additive protocol fields do not require every worker to adopt new controls.
4. Keep the old instance and its downstream clients running while draining. Use its
   `bin/exiron-safe-restart --timeout 120 --drain-only`, then run your existing
   artifact-switch/service restart operation only when drain succeeds. Older
   versions without the helper need the manual drain RPC procedure first.
5. Verify startup, Hub readiness and intended routing. The helper's normal restart
   mode verifies its current release; it does not install a different artifact or
   check public routing, Telegram credentials or downstream application side effects.
6. Upgrade workers as required, retaining their explicit streaming/one-shot choice.
   Drain and join the old managed run before replacing it. Reuse an existing live
   quarantine store when appropriate and explicitly resolve retained entries before
   terminating that store.

## Failure and rollback

A drain timeout leaves intake paused and work running; inspect status rather than
forcing a restart. Resume intake explicitly if abandoning maintenance. A startup
verification failure after restart cannot undo that restart. It returns nonzero
for operator/deployment handling and does not automatically roll back.

For an application rollback, select the previous known-good artifact and compatible
configuration using your existing deployment mechanism. Coordinate drain before
stopping a running instance whenever possible. Configuration rollback and artifact
rollback are separate decisions; consult [configuration history](configuration-history.md).

Exiron uses an in-memory delivery model. Restart can lose pending
work, quarantined messages and idempotency receipts. Drain reduces avoidable loss
but does not persist data, undo uncertain Telegram sends, or make application side
effects exactly-once. Inspect delivery diagnostics before replaying a mutation.

Configuration schema 2 adds optional Telegram user access lists. Schema 1 remains
supported, but access lists require schema 2. Older servers reject schema 2;
rolling back requires a reviewed older configuration as well. See
[chat interactions](chat-interactions.md#user-access-and-administrators).
