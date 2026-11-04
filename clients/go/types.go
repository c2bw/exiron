package exiron

import "time"

// AuthResponse is returned by /api/auth after a hook token is accepted.
type AuthResponse struct {
	AuthResponse    string   `json:"auth_response"`
	Hook            string   `json:"hook"`
	Msgtype         string   `json:"msgtype"`
	ServerVersion   string   `json:"server_version"`
	ProtocolVersion string   `json:"protocol_version"`
	Capabilities    []string `json:"capabilities"`
}

// ProtocolInfo describes the protocol negotiated with the server.
type ProtocolInfo struct {
	Version      string
	Capabilities []string
}

// Supports reports whether the server advertised capability.
func (p ProtocolInfo) Supports(capability string) bool {
	for _, candidate := range p.Capabilities {
		if candidate == capability {
			return true
		}
	}
	return false
}

// Message is a queued Exiron request or listen message.
//
// Data is decoded payload data. For text payloads, it is the UTF-8 message
// text. For callbacks, it is application button data. For file-like payloads,
// it is the raw file bytes.
// FileUniqueID optionally identifies a Telegram sticker for deduplication; it
// cannot be used to download or send a file. StickerID remains the sendable file_id.
type Message struct {
	// FollowupReqID links an inherited follow-up to the immediate previous request.
	FollowupReqID    *string         `json:"followup_req_id,omitempty"`
	CallbackQuery    *CallbackQuery  `json:"callback_query,omitempty"`
	Msgtype          string          `json:"msgtype"`
	ReqID            string          `json:"req_id"`
	From             *TelegramUser   `json:"from"`
	ServiceID        int64           `json:"service_id"`
	ChatID           int64           `json:"chat_id"`
	Instance         *string         `json:"instance"`
	Datatype         Datatype        `json:"datatype"`
	Data             []byte          `json:"-"`
	FileUniqueID     *string         `json:"file_unique_id"`
	StickerID        *string         `json:"sticker_id"`
	StickerEmoji     *string         `json:"sticker_emoji"`
	EmojiList        []string        `json:"emoji_list"`
	MessageID        *int64          `json:"message_id"`
	ReplyToMessageID *int64          `json:"reply_to_message_id"`
	MessageThreadID  *int64          `json:"message_thread_id,omitempty"`
	MediaGroupID     *string         `json:"media_group_id,omitempty"`
	Caption          *string         `json:"caption,omitempty"`
	Entities         []MessageEntity `json:"entities,omitempty"`
	CaptionEntities  []MessageEntity `json:"caption_entities,omitempty"`
	FileName         *string         `json:"file_name,omitempty"`
	MIMEType         *string         `json:"mime_type,omitempty"`
	MediaItems       []MediaItem     `json:"-"`
}

// TelegramUser identifies the user who sent a Telegram message.
type TelegramUser struct {
	ID           int64   `json:"id"`
	IsBot        bool    `json:"is_bot"`
	FirstName    string  `json:"first_name"`
	LastName     *string `json:"last_name"`
	Username     *string `json:"username"`
	LanguageCode *string `json:"language_code"`
}

// OkResponse is returned by endpoints that only acknowledge success.
type OkResponse struct {
	MessageIDs []int64 `json:"message_ids,omitempty"`
	OK         bool    `json:"ok"`
	Final      *bool   `json:"final,omitempty"`
	MessageID  *int64  `json:"message_id,omitempty"`
}

// PushResponse is returned by /api/push.
type PushResponse struct {
	OK   bool `json:"ok"`
	Sent int  `json:"sent"`
}

// PushOptions controls optional /api/push delivery behavior.
type PushOptions struct {
	// IdempotencyKey identifies one response/push operation for safe result replay.
	IdempotencyKey string
	// CaptionOverflow sends excess media caption text as following messages.
	CaptionOverflow bool `json:"caption_overflow,omitempty"`
	InlineKeyboard  *InlineKeyboard
	// StickerEmoji is sent with sticker payloads to associate an emoji.
	StickerEmoji string
	// Bot selects a configured Telegram bot name for the target chat.
	Bot             string
	MessageThreadID *int64          `json:"message_thread_id,omitempty"`
	Caption         string          `json:"caption,omitempty"`
	Entities        []MessageEntity `json:"entities,omitempty"`
	CaptionEntities []MessageEntity `json:"caption_entities,omitempty"`
	FileName        string          `json:"file_name,omitempty"`
	MIMEType        string          `json:"mime_type,omitempty"`
	ParseMode       string          `json:"parse_mode,omitempty"`
}

// Status is the authenticated hook's view returned by /api/status.
type Status struct {
	Enabled              bool              `json:"enabled"`
	TelegramPolling      bool              `json:"telegram_polling"`
	TelegramLastPolledAt *time.Time        `json:"telegram_last_polled_at"`
	Version              string            `json:"version"`
	Requested            int               `json:"requested"`
	Chats                []ChatStatus      `json:"chats"`
	Hooks                []HookStatus      `json:"hooks"`
	Routes               []Route           `json:"routes"`
	Events               []Event           `json:"events"`
	SendFailures         []SendFailure     `json:"send_failures"`
	OverloadEvents       []OverloadEvent   `json:"overload_events"`
	MembershipEvents     []MembershipEvent `json:"membership_events"`
	BotMemberships       []BotMembership   `json:"bot_memberships"`
	ClientEvents         []ClientEvent     `json:"client_events"`
}

// ChatStatus describes polling and bot membership state for a Telegram chat.
type ChatStatus struct {
	ID             int64           `json:"id"`
	Aliases        []string        `json:"aliases"`
	DefaultBot     *string         `json:"default_bot"`
	CurrentBot     *string         `json:"current_bot"`
	BotMemberships []BotMembership `json:"bot_memberships"`
	Polling        bool            `json:"polling"`
	LastPolledAt   *time.Time      `json:"last_polled_at"`
}

// SendFailure describes a recent failed Telegram delivery.
type SendFailure struct {
	Delivery  *DeliveryDiagnostics `json:"delivery,omitempty"`
	ID        string               `json:"id"`
	At        time.Time            `json:"at"`
	Operation string               `json:"operation"`
	Hook      string               `json:"hook"`
	ChatID    int64                `json:"chat_id"`
	BotName   *string              `json:"bot_name"`
	Datatype  Datatype             `json:"datatype"`
	Preview   string               `json:"preview"`
	Reason    string               `json:"reason"`
}

// MembershipEvent describes a Telegram bot being added to or removed from a chat.
type MembershipEvent struct {
	ID        string    `json:"id"`
	At        time.Time `json:"at"`
	Action    string    `json:"action"`
	ChatID    int64     `json:"chat_id"`
	ChatTitle *string   `json:"chat_title"`
	BotName   *string   `json:"bot_name"`
	BotUserID *int64    `json:"bot_user_id"`
	OldStatus *string   `json:"old_status"`
	NewStatus *string   `json:"new_status"`
}

// BotMembership describes the latest known membership state for a bot and chat.
type BotMembership struct {
	ChatID    int64   `json:"chat_id"`
	BotName   *string `json:"bot_name"`
	BotUserID *int64  `json:"bot_user_id"`
	Status    string  `json:"status"`
	Present   bool    `json:"present"`
	Error     *string `json:"error"`
}

// OverloadEvent describes a recent queue or pending-cap rejection.
type OverloadEvent struct {
	ID           string    `json:"id"`
	At           time.Time `json:"at"`
	Hook         string    `json:"hook"`
	Reason       string    `json:"reason"`
	ServiceID    int64     `json:"service_id"`
	ChatID       int64     `json:"chat_id"`
	Datatype     string    `json:"datatype"`
	PayloadBytes int       `json:"payload_bytes"`
}

// HookStatus describes an Exiron hook connection.
type HookStatus struct {
	Client    *HookClientPresence `json:"client,omitempty"`
	Health    *HookDeliveryHealth `json:"health,omitempty"`
	Name      string              `json:"name"`
	Connected bool                `json:"connected"`
	Listening bool                `json:"listening"`
	Queued    int                 `json:"queued"`
}

// Route describes a configured Exiron route.
type Route struct {
	ID         int      `json:"id"`
	To         string   `json:"to"`
	ServiceID  int64    `json:"service_id"`
	ChatID     int64    `json:"chat_id"`
	ChatAlias  string   `json:"chat_alias"`
	Messages   []string `json:"messages"`
	Push       bool     `json:"push"`
	DefaultBot *string  `json:"default_bot"`
}

// Event describes a recent Exiron hub event.
type Event struct {
	ID               string    `json:"id"`
	At               time.Time `json:"at"`
	Direction        string    `json:"direction"`
	Target           string    `json:"target"`
	Kind             string    `json:"kind"`
	ServiceID        int64     `json:"service_id"`
	ChatID           int64     `json:"chat_id"`
	BotName          *string   `json:"bot_name"`
	Datatype         Datatype  `json:"datatype"`
	Preview          string    `json:"preview"`
	Caption          *string   `json:"caption"`
	Hook             *string   `json:"hook"`
	ImageSrc         *string   `json:"image_src"`
	FileUniqueID     *string   `json:"file_unique_id"`
	StickerID        *string   `json:"sticker_id"`
	StickerEmoji     *string   `json:"sticker_emoji"`
	EmojiList        []string  `json:"emoji_list"`
	MessageID        *int64    `json:"message_id"`
	ReplyToMessageID *int64    `json:"reply_to_message_id"`
}

// ClientEvent describes a recent managed HTTP client lifecycle event.
type ClientEvent struct {
	ID        string    `json:"id"`
	At        time.Time `json:"at"`
	Action    string    `json:"action"`
	Hook      string    `json:"hook"`
	ClientID  string    `json:"client_id"`
	Listening bool      `json:"listening"`
}

// ResponseOptions adds opt-in streaming and metadata to existing response calls.
// A nil Final preserves one-shot completion; false keeps a text request open.
type ResponseOptions struct {
	// IdempotencyKey identifies one response operation (a base key in StreamText).
	IdempotencyKey string
	// CaptionOverflow sends excess media caption text as following messages.
	CaptionOverflow bool
	// ReplyToOriginal anchors the first reply to the incoming Telegram message.
	// Choose it when starting a response; streams retain their initial context.
	ReplyToOriginal bool
	InlineKeyboard  *InlineKeyboard
	// EditOrigin targets the clicked message; valid only for callback requests.
	EditOrigin      bool
	Final           *bool
	StickerEmoji    string
	Caption         string
	Entities        []MessageEntity
	CaptionEntities []MessageEntity
	FileName        string
	MIMEType        string
	ParseMode       string
}

// MessageEntity uses Telegram's UTF-16 code-unit offsets and lengths.
type MessageEntity struct {
	UnixTime       *int64        `json:"unix_time,omitempty"`
	DateTimeFormat *string       `json:"date_time_format,omitempty"`
	Type           string        `json:"type"`
	Offset         int           `json:"offset"`
	Length         int           `json:"length"`
	URL            *string       `json:"url,omitempty"`
	User           *TelegramUser `json:"user,omitempty"`
	Language       *string       `json:"language,omitempty"`
	CustomEmojiID  *string       `json:"custom_emoji_id,omitempty"`
}

// MediaItem is one album member; Data contains decoded file bytes.
type MediaItem struct {
	ParseMode       string          `json:"parse_mode,omitempty"`
	Datatype        Datatype        `json:"datatype"`
	Data            []byte          `json:"data"`
	Caption         *string         `json:"caption,omitempty"`
	CaptionEntities []MessageEntity `json:"caption_entities,omitempty"`
	FileName        *string         `json:"file_name,omitempty"`
	MIMEType        *string         `json:"mime_type,omitempty"`
	MessageID       *int64          `json:"message_id,omitempty"`
	MessageThreadID *int64          `json:"message_thread_id,omitempty"`
	MediaGroupID    *string         `json:"media_group_id,omitempty"`
}

// InlineKeyboard is a list of button rows. A pointer to an empty keyboard removes
// existing buttons; nil leaves an edited message's keyboard unchanged.
type InlineKeyboard [][]InlineKeyboardButton

// InlineKeyboardButton has exactly one of CallbackData (1..64 UTF-8 bytes) or URL.
type InlineKeyboardButton struct {
	Text         string `json:"text"`
	CallbackData string `json:"callback_data,omitempty"`
	URL          string `json:"url,omitempty"`
}

// CallbackQuery identifies a click; Message.From is the user who clicked.
type CallbackQuery struct {
	ID          string  `json:"id"`
	OriginReqID *string `json:"origin_req_id"`
}

// CancelResponse reports a stopped request. Known message IDs may be incomplete
// when DeliveryStatus is "unknown"; already delivered messages remain visible.
type CancelResponse struct {
	OK             bool    `json:"ok"`
	Cancelled      bool    `json:"cancelled"`
	DeliveryStatus string  `json:"delivery_status"`
	MessageIDs     []int64 `json:"message_ids"`
}

// HookDeliveryHealth exposes a hook's active send capacity and rejection count.
// It is optional when connected to an older Exiron server.
type HookDeliveryHealth struct {
	InFlightSendBytes          int64 `json:"in_flight_send_bytes"`
	InFlightSendBytesLimit     int64 `json:"in_flight_send_bytes_limit"`
	SendByteCapacityRejections int64 `json:"send_byte_capacity_rejections"`
	InFlightSends              int   `json:"in_flight_sends"`
	InFlightSendLimit          int   `json:"in_flight_send_limit"`
	SendCapacityRejections     int64 `json:"send_capacity_rejections"`
}

// HookClientPresence describes observed contact and assigned work, not proof that
// an application handler is running. An expired HTTP lease can mean processing.
type HookClientPresence struct {
	ClientSDK             *string                   `json:"client_sdk"`
	ClientVersion         *string                   `json:"client_version"`
	Runtime               *ClientRuntimeObservation `json:"runtime"`
	ClientID              *string                   `json:"client_id"`
	CurrentClientID       *string                   `json:"current_client_id"`
	Transport             *string                   `json:"transport"`
	State                 string                    `json:"state"`
	LastContactAt         *time.Time                `json:"last_contact_at"`
	LastContactKind       *string                   `json:"last_contact_kind"`
	DisconnectedAt        *time.Time                `json:"disconnected_at"`
	AwaitingResponse      int                       `json:"awaiting_response"`
	SendingRequests       int                       `json:"sending_requests"`
	OtherAssignedRequests int                       `json:"other_assigned_requests"`
}
