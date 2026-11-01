# Chat interactions

Interaction features are opt-in on individual middleware routes. Existing routes
keep their behavior. Add this alongside `messages` in the YAML editor:

```yaml
interaction:
  request_controls: true
```

Accepted requests receive a separate Status / Cancel card, without replacing the
worker's reply or keyboard. Status shows Exiron's current observation (queued,
delivered to a worker, sending, completed, cancelled or expired). Delivery to a
worker does not prove its handler has started. Status is refreshed on demand.

Only the requesting Telegram user can operate the card, in its original bot,
chat and message. Cancellation stops remaining local work; already accepted
Telegram sends may still arrive. Controls remain available while intake drains.
Cards and request history are bounded and in memory; restart loss is acceptable.
Old cards become unavailable after their bindings expire or are evicted. No
persistence or automatic retry is introduced. The route must still enable controls.

## Reply-based follow-ups

Add `followups: true` to `interaction` to let people reply to an answer without
repeating its command. Explicit commands always take precedence; unknown slash
commands do not inherit the previous destination. Text and media retain their
ordinary request payloads, reply references and topics, and both reply modes work.

Only answers accepted while follow-ups were enabled can establish context. The
reply must match the answer's bot, service, chat and topic. The original command
route must still exist and enable follow-ups. Context lives in the existing
500-receipt in-memory window and expires after 24 hours; restart, eviction,
cancellation or configuration changes can make a reply require a command again.

## Chat-scoped help

Add `help: true`, and optional `description` (up to 240 bytes) and `example`
(up to 400 bytes), to a route's `interaction` map. `/help` lists only enabled
routes in the current chat. `/help@BotName` responds only when the receiving bot's
known name matches. An explicitly configured `/help` route keeps precedence.
Help stays in the same topic, replies to the original message, uses plain text,
and is not copied into listener queues. Lists are bounded to 20 routes / 3,500
characters. This does not register global Telegram bot commands.

## User access and administrators

Configuration version `"2"` supports explicit Telegram user ID lists:

```yaml
interaction:
  allowed_user_ids: [12345678]
  admin_user_ids: [87654321]
  request_controls: true
```

`allowed_user_ids` restricts new routed requests, inherited follow-ups, application
callbacks and listener copies for that hook/chat. Omit it for the existing open
behavior; an empty list denies everyone, including messages without a user ID.
A denied command is not copied to any listener. Help lists only permitted routes.
Every route to the same hook in a chat must agree on both access lists.

`admin_user_ids` allows the listed users to operate another person's Status /
Cancel card. It does not grant hook invocation or dashboard access. Request owners
can still cancel their own accepted work. These lists do not automatically follow
Telegram group administrators; use numeric IDs, never usernames. Each list allows
up to 1,000 IDs. Restrictions apply in private chats as well as groups. Previously
accepted work continues unless cancelled.

Version 1 configurations continue to load without access lists. Access lists
require version 2, which older binaries reject rather than silently ignoring the
restriction. Before rolling back to an older binary, deliberately migrate to a
reviewed version 1 configuration without these controls. Quick edits and canonical
YAML exports preserve the lists; public status snapshots omit them.

### Follow-up context in clients

Protocol 1.18 advertises `followup_context`. An inherited follow-up request has
an optional `followup_req_id` linking to the **immediate request whose answer was
replied to**. Go exposes `Message.FollowupReqID` and Elixir exposes
`Message.followup_req_id`. Its own `req_id` remains the new request to answer.

The field is omitted for explicit commands, ordinary requests and listener
copies. It does not contain message history or establish a durable conversation;
applications choose how to keep context and handle missing/evicted history.
Both transports carry the same request payload. Older SDKs can ignore the
additive field, while newer SDKs receive nil when an older server omits it.
Routing still validates the originating bot/chat/topic and current route/access
policy before exposing the link to the destination hook.

### Command buttons

For an identified user, `/help` includes up to 20 **Run /command** buttons for
permitted standard slash commands (1–32 ASCII letters, digits or underscores).
Selecting a button submits that command **without arguments** as a new text
request in the same chat and topic. To supply arguments, type the command with
your text instead. Other configured prefixes remain listed as text.

Only the user who requested the menu can use its buttons. Buttons use opaque,
bot/chat/message-bound references and recheck the destination, help setting and
current user access list at selection time. New command intake remains paused
during drain; recent retries of the same Telegram callback are deduplicated.
Existing explicit `/help` routes retain precedence. Unknown users receive the
text list without buttons, and normal application callbacks remain unchanged.
Menus share existing in-memory callback limits and expiry, so an old menu may
require requesting `/help` again. No command is executed just by opening help.

### Guided command input

**Write /command** opens a selective reply prompt instead of invoking the hook.
Reply to that prompt with text within five minutes. Exiron combines the command
and your text, then uses normal admission, route rewriting, controls and delivery.
The prompt is bound to the requesting user, actual sending bot, chat and topic;
current help/access settings are checked again. An accepted reply consumes the
prompt. **Run /command** and manually typed commands keep their existing behavior.

Explicit commands take precedence even when replying to a prompt. Known expired,
consumed or unauthorized prompts reject input without forwarding listener copies.
Prompts use the normal bounded send path and retain at most 500 small in-memory
records, without question bodies. Restart or eviction loses context; request
`/help` again. Ignore a prompt to abandon it. No request is created until you reply.
