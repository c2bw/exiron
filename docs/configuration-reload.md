# Saving and activating configuration

The authenticated `/config` page shows the saved file and its activation status
separately. The YAML editor and quick-add forms validate changes and open a redacted review.
**Save and activate** checkpoints the old file, writes the reviewed source and
requests a full Hub reload. **Saved** does not imply **active**.

A persistent banner compares the saved source with a private digest of the exact
source loaded by the last successful full activation. It also shows the last
full activation time. The digest is never exposed in the status API.

- **Active:** this exact saved source was loaded successfully by the Hub.
- **Not active:** the Hub loaded a different source.
- **Activation failed:** the latest full reload failed and this saved source is
  not confirmed active. Saving still succeeded; the file remains on disk.
- **Hub disabled:** the file is saved but cannot be activated while the Hub is
  deliberately disabled. Recovery from a failed boot can still be retried.
- **Not verified:** the Hub was configured directly or only routes/bots were
  reloaded. A full activation establishes the source comparison again.
- **File changed:** the displayed source differs from disk. Reload the saved
  file before saving or activating; unsaved edits are not replaced automatically.
- **Status unavailable:** the Hub could not be reached. Check status before
  retrying; a timed-out call may still finish later.

**Activate saved configuration** retries a reload without writing the file.
It validates the saved file and checks that its source still matches the page
under the existing per-file write lock. A stale page cannot activate changes it
has not loaded. Existing optimistic concurrency checks still protect saves.
External filesystem writers do not participate in that lock; activation status
is checked against the displayed saved source after the operation.

Other open configuration pages receive save/reload notifications and refresh
their activation banner without discarding editor drafts. **Check status** also
detects external file edits. A browser refresh reconstructs the status from the
saved file and Hub state rather than relying on a transient flash message.

Tables and route tests on this page describe the saved file, which can differ
from the running configuration after a failed activation. No automatic rollback
of the saved file is performed. Full activation still uses the existing reload
behavior, including client reconciliation for changed hook credentials.

[Configuration history and rollback](configuration-history.md) explains restoring
an earlier revision, including recovery when the current YAML cannot be parsed.
