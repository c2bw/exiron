# Configuration diagnostics

The authenticated `/config` page shows advisory warnings for the displayed saved
configuration. Links take you to the affected hook, middleware, chat route or
resolved route. These describe the saved file, which can differ from the active
Hub configuration; check its activation banner.

The change review panel analyzes the **proposed** configuration, including quick-add
changes and rollback targets. Its warnings stay separate from saved-file warnings.
Proposed entries may not exist on the saved page yet, so review warnings identify
the entries by name without linking to potentially different saved entries.
Warnings do not disable **Save and activate** or **Restore and activate**.

Diagnostics currently identify:

- **Unreachable hook:** no resolved route points to the hook. Defining it in an
  unused middleware does not make it reachable.
- **Unused middleware:** no chat route references the middleware.
- **Overlapping prefixes:** in the same service/chat address, a longer command
  shares a whole-command prefix with a route to a different hook or a different
  passthrough policy. The longer match takes precedence. For example,
  `/ai summary` overlaps `/ai`; `/aiv` does not. Matching commands in separate
  chats and equivalent routes to the same hook/passthrough policy are excluded.
  Ambiguous identical prefixes to different hooks remain validation errors.
- **Empty push route:** a chat route enables push but expands to no hooks.
  Push destinations are built from those resolved hook/chat routes. A reachable
  hook with push disabled is valid and does not produce this warning.

Intentional unused entries or overlaps can remain configured. No automated changes
are made. An invalid source displays its validation error instead of a misleading
clean diagnostics result.

These are static configuration checks. A clean result does not verify Telegram
credentials, bot membership, downstream connectivity or intended business behavior.
