# Configuration history and rollback

Open the authenticated **Configuration** page at `/config`. YAML edits and
quick-add forms first open a **Review configuration changes** panel. Confirm
**Save and activate** to write the reviewed source and request a full reload.
Advisory diagnostics describe the proposed configuration before confirmation;
see [configuration diagnostics](configuration-diagnostics.md) for their scope.
Cancel leaves the file untouched. Editing the YAML draft cancels its pending
review. Quick-add changes are based on the saved file; they do not include an
unsaved YAML draft.

The review shows normalized JSON derived from YAML, with additions and removals.
Comments and formatting are omitted; formatting-only changes are identified.
Telegram tokens, hook credential values and fields named like passwords, secrets
or API keys are redacted. Credential-only changes remain visible as redacted
before/after values. The YAML editor still contains credentials and requires the
same care as the configuration file. Large unchanged sections are collapsed.
Reviews exceeding 500 displayed lines cannot be confirmed; make smaller changes.

## Restore a revision

1. Select **Review rollback**, or expand **Browse saved revisions** and select
   **Review restore** on a particular revision.
2. Review the redacted changes.
3. Select **Restore and activate**.

The shortcut prefers the most recently activated noncurrent revision, falling
back to the most recently saved valid revision. Successful activation means the
Hub loaded the file; it does not prove its routes or credentials are correct.
Choose an older revision from the list if needed.

Restoring validates the target again, checkpoints the current file, replaces it
atomically, and requests activation. Saved and active status remain separate:
an activation failure leaves the restored file saved and the failure visible.
**Activate saved configuration** retries activation without another write.

History and the YAML editor remain available if the current YAML is invalid,
including after a failed boot. Invalid current bytes are backed up before
replacement, but invalid backups cannot be restored through the dashboard.
When the current source cannot be parsed, review shows only the redacted target.
Another session's changes invalidate a pending review; reload the page and
review again. External filesystem writers do not participate in Exiron's lock.

## Storage and retention

For `config/config.yml`, history lives in
`config/.config.yml.exiron-history/`. Other paths use the same adjacent hidden
directory naming scheme. No separate database or environment variable is needed.
Mount the whole configuration directory in Docker so history survives container
replacement; the standard Compose setup already does this.

History records **up to 20 distinct source revisions**. Identical source bytes
reuse one record. The most recently activated revision is protected from pruning;
the remaining records favor recent saves. Checkpoints are recorded at successful
boot/full reload, before dashboard writes, after dashboard saves, and when the
configuration page first opens with a valid source. Arbitrary external edits are
not continuously versioned.

History contains complete credentials. Its directory is mode `0700`, records
are `0600`, and repository/build ignore rules exclude it. Protect backups and
keep the directory writable by the application user. A pre-change checkpoint
failure prevents the dashboard write. A post-save checkpoint failure is reported
separately because the file has already been written. Boot and activation continue
if checkpointing fails, with a warning in application logs.

This is local recovery history, not a remote backup or a guarantee against disk
failure or power loss. There is no recovery for versions never checkpointed.
Deleting the history directory removes the available rollback revisions.
