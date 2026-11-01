# Shareable monitor views

Monitor keeps hook, chat, client, request, outcome and time-range filters in the
address bar. Selecting a request or delivery adds its inspection ID; closing
details preserves filters. Bookmark the current address or copy **Link to this
view**. Opening the link requires dashboard login and restores the same controls.

Filter edits replace the current history entry, so typing does not create an
entry per keystroke. Opening or closing an inspector creates a history entry;
Back and Forward restore those selections. URLs contain filter values and opaque
inspection IDs, without message bodies, bot tokens or hook credentials.

Views query the retained in-memory history rather than saving a dataset. Expired
request/delivery IDs show an unavailable notice. Relative time ranges are applied
when the link opens, and unavailable dropdown choices normalize to the current
configuration. Paused snapshots remain local to their LiveView; changing filters
or inspection while paused uses that snapshot. A fresh link fetches current data.
