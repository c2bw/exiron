# Manual message composer

Use the pencil icon in the dashboard header, `/compose`, or **Compose message**
in a hook workspace. Dashboard login is required. Choose a known push-enabled
hook/chat/bot destination, optionally supply a positive forum topic ID, and enter
one Telegram message or attach a photo/file. The preview shows the content,
exact plain-text caption and destination.
Markup is displayed literally; HTML is escaped in the browser.

Preview never sends. Editing or a configuration notification clears the preview.
**Send message** sends only the reviewed draft, expires after ten minutes, and
rechecks that the destination still exists. One reviewed bot is used; no alternate
bot is tried after rejection. Existing SDK push fallback remains available.

Sends share normal intake drain, send capacity, byte budget, coordinator and
idempotency limits. Repeated confirmations of a retained draft replay its result;
the browser also disables confirmation while sending and clears it on completion.
This protection uses the existing bounded in-memory idempotency cache, not a
persistent outbox. A new preview represents a new operation.

An uncertain result asks you to inspect the monitor rather than automatically
retrying. Restart, eviction and Telegram acceptance before a timeout still limit
what Exiron can prove. Successful manual sends appear in ordinary push history.
The composer never exposes hook or bot credentials to the browser. Destinations
without a bot name are still usable and have a short opaque identifier.

The composer remembers the last valid destination in the current browser tab's
`sessionStorage`. Explicit hook links take precedence, and restored choices are
revalidated against current destinations. A successful send clears message text
while keeping the destination. Removed destinations are cleared. Message bodies
and topic IDs are not stored in the browser; storage-disabled browsers still work.

Typing a message enables a leave warning for dashboard links, browser history,
reload and tab close. Cancelling navigation keeps the draft in the composer.
Successful delivery removes the warning; uncertain delivery retains it. Browsers
control whether their native reload/close warning is displayed and its wording.
This is protection against accidental navigation, not durable draft storage.

## Photos and files

Choose **Photo** or **File** to upload one attachment of up to 10 MB. Photos accept
PNG or JPEG content; files are sent as documents. Message text becomes an optional
plain-text caption, limited to 1024 UTF-16 units. Preview shows the photo or file
name/size and the exact caption. Document contents are never rendered as HTML.
Changing type, editing fields, replacing or removing an upload invalidates review.

Uploads use LiveView's temporary storage; no public upload directory is created.
The reviewed draft retains bounded bytes in its LiveView process until replaced,
sent or closed. Delivery revalidates contents, destination and preview lifetime,
includes bytes and metadata in the usual send budget, and keys duplicate protection
to content and metadata. The reviewed bot remains fixed. Successful sends remove
temporary uploads; closing the page also cleans them up. Attachment-only drafts
receive the same leave warning, and attachment bytes are not put in browser storage.
