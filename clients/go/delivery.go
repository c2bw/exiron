package exiron

import (
	"context"
	"net/http"
	"net/url"
)

// DeliveryDiagnostics is a bounded snapshot of one delivery operation.
// RetrySafe concerns duplicate delivery only; retries are never automatic.
type DeliveryDiagnostics struct {
	ID               string                 `json:"id"`
	RequestID        *string                `json:"request_id"`
	Operation        string                 `json:"operation"`
	Outcome          string                 `json:"outcome"`
	DeliveryStatus   string                 `json:"delivery_status"`
	Attempts         int                    `json:"attempts"`
	PlannedParts     int                    `json:"planned_parts"`
	ConfirmedParts   int                    `json:"confirmed_parts"`
	RejectedParts    int                    `json:"rejected_parts"`
	UnknownParts     int                    `json:"unknown_parts"`
	InFlightParts    int                    `json:"in_flight_parts"`
	UnattemptedParts int                    `json:"unattempted_parts"`
	OmittedParts     int                    `json:"omitted_parts"`
	RetryAvailable   bool                   `json:"retry_available"`
	RetrySafe        bool                   `json:"retry_safe"`
	RetryAction      string                 `json:"retry_action"`
	LastError        *TelegramDeliveryError `json:"last_error"`
	Parts            []DeliveryPart         `json:"parts"`
}

// TelegramDeliveryError uses safe descriptions, with no raw Telegram payloads.
type TelegramDeliveryError struct {
	Category     string `json:"category"`
	Message      string `json:"message"`
	Code         *int   `json:"code"`
	RetryAfterMS *int   `json:"retry_after_ms"`
}

// DeliveryPart records a send, edit, delete or chat action in one chat.
type DeliveryPart struct {
	ID         string                 `json:"id"`
	Index      int                    `json:"index"`
	Ordinal    int                    `json:"ordinal"`
	ChatID     int64                  `json:"chat_id"`
	BotName    *string                `json:"bot_name"`
	Operation  string                 `json:"operation"`
	Status     string                 `json:"status"`
	Attempts   int                    `json:"attempts"`
	MessageID  *int64                 `json:"message_id"`
	MessageIDs []int64                `json:"message_ids"`
	Error      *TelegramDeliveryError `json:"error"`
}

// DeliveryStatus looks up diagnostics by diagnostic ID or the latest operation
// for a request ID. Diagnostic IDs are returned on delivery errors.
func (c *Client) DeliveryStatus(ctx context.Context, id string) (*DeliveryDiagnostics, error) {
	var result DeliveryDiagnostics
	if err := c.request(ctx, http.MethodGet, "/api/deliveries/"+url.PathEscape(id), c.token, nil, &result); err != nil {
		return nil, err
	}
	return &result, nil
}
