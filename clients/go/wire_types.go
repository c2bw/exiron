package exiron

import "time"

// The wire types below intentionally remain private. Public response models
// are converted from these DTOs at the endpoint boundary so changes in the
// JSON contract do not change the client's stable model surface.
type wireRequestsResponse struct {
	RuntimeRef string        `json:"runtime_ref"`
	DeliveryID string        `json:"delivery_id"`
	Requests   []wireMessage `json:"requests"`
}

type wireMessage struct {
	FollowupReqID    *string           `json:"followup_req_id,omitempty"`
	CallbackQuery    *CallbackQuery    `json:"callback_query,omitempty"`
	Msgtype          string            `json:"msgtype"`
	ReqID            string            `json:"req_id"`
	From             *wireTelegramUser `json:"from"`
	ServiceID        int64             `json:"service_id"`
	ChatID           int64             `json:"chat_id"`
	Instance         *string           `json:"instance"`
	Datatype         string            `json:"datatype"`
	Data             *string           `json:"data"`
	FileUniqueID     *string           `json:"file_unique_id"`
	StickerID        *string           `json:"sticker_id"`
	StickerEmoji     *string           `json:"sticker_emoji"`
	EmojiList        []string          `json:"emoji_list"`
	MessageID        *int64            `json:"message_id"`
	ReplyToMessageID *int64            `json:"reply_to_message_id"`
	MessageThreadID  *int64            `json:"message_thread_id,omitempty"`
	MediaGroupID     *string           `json:"media_group_id,omitempty"`
	Caption          *string           `json:"caption,omitempty"`
	Entities         []MessageEntity   `json:"entities,omitempty"`
	CaptionEntities  []MessageEntity   `json:"caption_entities,omitempty"`
	FileName         *string           `json:"file_name,omitempty"`
	MIMEType         *string           `json:"mime_type,omitempty"`
}

type wireTelegramUser struct {
	ID           int64   `json:"id"`
	IsBot        bool    `json:"is_bot"`
	FirstName    string  `json:"first_name"`
	LastName     *string `json:"last_name"`
	Username     *string `json:"username"`
	LanguageCode *string `json:"language_code"`
}

type wireAuthRequest struct {
	HookToken string `json:"hook_token,omitempty"`
}

type wireAuthResponse struct {
	AuthResponse    string   `json:"auth_response"`
	Hook            string   `json:"hook"`
	Msgtype         string   `json:"msgtype"`
	ServerVersion   string   `json:"server_version"`
	ProtocolVersion string   `json:"protocol_version"`
	Capabilities    []string `json:"capabilities"`
}

type wireOKResponse struct {
	MessageIDs []int64 `json:"message_ids,omitempty"`
	OK         bool    `json:"ok"`
	Final      *bool   `json:"final,omitempty"`
	MessageID  *int64  `json:"message_id,omitempty"`
}

type wirePushResponse struct {
	OK   bool `json:"ok"`
	Sent int  `json:"sent"`
}

type wireDataPayload struct {
	IdempotencyKey  string          `json:"idempotency_key,omitempty"`
	CaptionOverflow bool            `json:"caption_overflow,omitempty"`
	InlineKeyboard  *InlineKeyboard `json:"inline_keyboard,omitempty"`
	Datatype        string          `json:"datatype"`
	Data            string          `json:"data"`
	StickerEmoji    *string         `json:"sticker_emoji,omitempty"`
	Bot             *string         `json:"bot,omitempty"`
	MessageThreadID *int64          `json:"message_thread_id,omitempty"`
	Caption         *string         `json:"caption,omitempty"`
	Entities        []MessageEntity `json:"entities,omitempty"`
	CaptionEntities []MessageEntity `json:"caption_entities,omitempty"`
	FileName        *string         `json:"file_name,omitempty"`
	MIMEType        *string         `json:"mime_type,omitempty"`
	ParseMode       *string         `json:"parse_mode,omitempty"`
}

type wireDataPayloadWithChatID struct {
	IdempotencyKey  string          `json:"idempotency_key,omitempty"`
	CaptionOverflow bool            `json:"caption_overflow,omitempty"`
	InlineKeyboard  *InlineKeyboard `json:"inline_keyboard,omitempty"`
	ChatID          int64           `json:"chat_id"`
	Datatype        string          `json:"datatype"`
	Data            string          `json:"data"`
	StickerEmoji    *string         `json:"sticker_emoji,omitempty"`
	Bot             *string         `json:"bot,omitempty"`
	MessageThreadID *int64          `json:"message_thread_id,omitempty"`
	Caption         *string         `json:"caption,omitempty"`
	Entities        []MessageEntity `json:"entities,omitempty"`
	CaptionEntities []MessageEntity `json:"caption_entities,omitempty"`
	FileName        *string         `json:"file_name,omitempty"`
	MIMEType        *string         `json:"mime_type,omitempty"`
	ParseMode       *string         `json:"parse_mode,omitempty"`
}

type wireResponsePayload struct {
	IdempotencyKey  string          `json:"idempotency_key,omitempty"`
	CaptionOverflow bool            `json:"caption_overflow,omitempty"`
	ReplyToOriginal bool            `json:"reply_to_original,omitempty"`
	EditOrigin      bool            `json:"edit_origin,omitempty"`
	InlineKeyboard  *InlineKeyboard `json:"inline_keyboard,omitempty"`
	ReqID           string          `json:"req_id"`
	Datatype        string          `json:"datatype"`
	Data            string          `json:"data"`
	StickerEmoji    *string         `json:"sticker_emoji,omitempty"`
	MessageThreadID *int64          `json:"message_thread_id,omitempty"`
	Caption         *string         `json:"caption,omitempty"`
	Entities        []MessageEntity `json:"entities,omitempty"`
	CaptionEntities []MessageEntity `json:"caption_entities,omitempty"`
	FileName        *string         `json:"file_name,omitempty"`
	MIMEType        *string         `json:"mime_type,omitempty"`
	ParseMode       *string         `json:"parse_mode,omitempty"`
	Final           *bool           `json:"final,omitempty"`
}

type wireStatus struct {
	Enabled              bool                  `json:"enabled"`
	TelegramPolling      bool                  `json:"telegram_polling"`
	TelegramLastPolledAt *time.Time            `json:"telegram_last_polled_at"`
	Version              string                `json:"version"`
	Requested            int                   `json:"requested"`
	Chats                []wireChatStatus      `json:"chats"`
	Hooks                []wireHookStatus      `json:"hooks"`
	Routes               []wireRoute           `json:"routes"`
	Events               []wireEvent           `json:"events"`
	SendFailures         []wireSendFailure     `json:"send_failures"`
	OverloadEvents       []wireOverloadEvent   `json:"overload_events"`
	MembershipEvents     []wireMembershipEvent `json:"membership_events"`
	BotMemberships       []wireBotMembership   `json:"bot_memberships"`
	ClientEvents         []wireClientEvent     `json:"client_events"`
}

type wireChatStatus struct {
	ID             int64               `json:"id"`
	Aliases        []string            `json:"aliases"`
	DefaultBot     *string             `json:"default_bot"`
	CurrentBot     *string             `json:"current_bot"`
	BotMemberships []wireBotMembership `json:"bot_memberships"`
	Polling        bool                `json:"polling"`
	LastPolledAt   *time.Time          `json:"last_polled_at"`
}

type wireSendFailure struct {
	Delivery  *DeliveryDiagnostics `json:"delivery,omitempty"`
	ID        string               `json:"id"`
	At        time.Time            `json:"at"`
	Operation string               `json:"operation"`
	Hook      string               `json:"hook"`
	ChatID    int64                `json:"chat_id"`
	BotName   *string              `json:"bot_name"`
	Datatype  string               `json:"datatype"`
	Preview   string               `json:"preview"`
	Reason    string               `json:"reason"`
}

type wireMembershipEvent struct {
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

type wireBotMembership struct {
	ChatID    int64   `json:"chat_id"`
	BotName   *string `json:"bot_name"`
	BotUserID *int64  `json:"bot_user_id"`
	Status    string  `json:"status"`
	Present   bool    `json:"present"`
	Error     *string `json:"error"`
}

type wireOverloadEvent struct {
	ID           string    `json:"id"`
	At           time.Time `json:"at"`
	Hook         string    `json:"hook"`
	Reason       string    `json:"reason"`
	ServiceID    int64     `json:"service_id"`
	ChatID       int64     `json:"chat_id"`
	Datatype     string    `json:"datatype"`
	PayloadBytes int       `json:"payload_bytes"`
}

type wireHookStatus struct {
	Client    *HookClientPresence `json:"client,omitempty"`
	Health    *HookDeliveryHealth `json:"health,omitempty"`
	Name      string              `json:"name"`
	Connected bool                `json:"connected"`
	Listening bool                `json:"listening"`
	Queued    int                 `json:"queued"`
}

type wireRoute struct {
	ID         int      `json:"id"`
	To         string   `json:"to"`
	ServiceID  int64    `json:"service_id"`
	ChatID     int64    `json:"chat_id"`
	ChatAlias  string   `json:"chat_alias"`
	Messages   []string `json:"messages"`
	Push       bool     `json:"push"`
	DefaultBot *string  `json:"default_bot"`
}

type wireEvent struct {
	ID               string    `json:"id"`
	At               time.Time `json:"at"`
	Direction        string    `json:"direction"`
	Target           string    `json:"target"`
	Kind             string    `json:"kind"`
	ServiceID        int64     `json:"service_id"`
	ChatID           int64     `json:"chat_id"`
	BotName          *string   `json:"bot_name"`
	Datatype         string    `json:"datatype"`
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

type wireClientEvent struct {
	ID        string    `json:"id"`
	At        time.Time `json:"at"`
	Action    string    `json:"action"`
	Hook      string    `json:"hook"`
	ClientID  string    `json:"client_id"`
	Listening bool      `json:"listening"`
}

type wireSocketFrame struct {
	RuntimeRef      string        `json:"runtime_ref"`
	Type            string        `json:"type"`
	DeliveryID      string        `json:"delivery_id"`
	Messages        []wireMessage `json:"messages"`
	Error           string        `json:"error"`
	RetryAfterMS    int           `json:"retry_after_ms"`
	Code            string        `json:"code"`
	ProtocolVersion string        `json:"protocol_version"`
	Capabilities    []string      `json:"capabilities"`
}

type wireCancelResponse struct {
	OK             bool    `json:"ok"`
	Cancelled      bool    `json:"cancelled"`
	DeliveryStatus string  `json:"delivery_status"`
	MessageIDs     []int64 `json:"message_ids"`
}
