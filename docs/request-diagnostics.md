# Exportable request diagnostics

Inspect a request in Monitor and choose **Export diagnostic** to download its
sanitized JSON timeline. Dashboard login is required. Exports include timestamps,
phases, elapsed times, delivery counts, per-part outcomes, error categories and
numeric codes. They omit message content, credentials, all user/chat/bot/hook/
client/request identifiers, handler metadata, arbitrary step details and raw
error strings. Use the original monitor to inspect identity-dependent context.

The format is versioned independently (`format_version: 1`). Data is built from
an explicit field allowlist, with at most 32 timeline entries and 128 delivery
parts, and is served as an attachment with `Cache-Control: no-store`. A request
that has left the bounded in-memory trace window returns 404. Active requests
produce a snapshot; later progress requires downloading again. Timestamps and
operational counts are retained, so review them before sharing externally.
