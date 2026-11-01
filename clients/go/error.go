package exiron

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"unicode"
)

// Error is a normalized Exiron client error.
type Error struct {
	retryableConnection bool
	Delivery            *DeliveryDiagnostics
	Reason              string
	Code                string
	Message             string
	StatusCode          int
	RetryAfterMS        int
	Body                []byte
	Err                 error
}

func (e *Error) Error() string {
	if e == nil {
		return ""
	}
	if e.StatusCode > 0 {
		return fmt.Sprintf("exiron: %s (HTTP %d)", e.Message, e.StatusCode)
	}
	return "exiron: " + e.Message
}

func (e *Error) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Err
}

func apiError(status int, body []byte) *Error {
	var parsed struct {
		Delivery     *DeliveryDiagnostics `json:"delivery"`
		Error        string               `json:"error"`
		Code         string               `json:"code"`
		RetryAfterMS int                  `json:"retry_after_ms"`
	}
	if err := json.Unmarshal(body, &parsed); err == nil && parsed.Error != "" {
		return &Error{
			Delivery:     parsed.Delivery,
			Reason:       reasonFromCode(parsed.Code, parsed.Error),
			Code:         parsed.Code,
			Message:      parsed.Error,
			StatusCode:   status,
			RetryAfterMS: parsed.RetryAfterMS,
			Body:         body,
		}
	}

	return &Error{
		Reason:     "http_error",
		Message:    fmt.Sprintf("Exiron server returned HTTP %d", status),
		StatusCode: status,
		Body:       body,
	}
}

func transportError(err error) *Error {
	return &Error{
		Reason:  "transport_error",
		Message: err.Error(),
		Err:     err,
	}
}

func invalidResponse(message string, err error) *Error {
	return &Error{
		Reason:  "invalid_response",
		Message: message,
		Err:     err,
	}
}

// IsHookAlreadyConnected reports whether err means another client ID is
// currently polling with the same hook token.
func IsHookAlreadyConnected(err error) bool {
	var apiErr *Error
	return errors.As(err, &apiErr) && apiErr.Reason == "hook_already_connected"
}

// IsTelegramDeliveryTimeout reports whether err means a response or push timed
// out while waiting for Telegram's delivery result. The server may still
// complete the Telegram send after returning this error, so callers should
// treat delivery as unknown rather than safely retryable.
func IsTelegramDeliveryTimeout(err error) bool {
	var apiErr *Error
	return errors.As(err, &apiErr) && (apiErr.Reason == "telegram_delivery_timeout" || apiErr.Reason == "telegram_delivery_result_timed_out")
}

func reasonFromCode(code, fallbackMessage string) string {
	if _, known := protocolErrorCodes[code]; known {
		return code
	}
	return reasonFromMessage(fallbackMessage)
}

func reasonFromMessage(message string) string {
	var b strings.Builder
	underscore := false

	for _, r := range strings.ToLower(message) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			if underscore && b.Len() > 0 {
				b.WriteByte('_')
			}
			b.WriteRune(r)
			underscore = false
			continue
		}
		underscore = b.Len() > 0
	}

	reason := b.String()
	if reason == "" {
		return "http_error"
	}
	return reason
}

// IsRequestCancelled reports a terminal server-side request cancellation.
func IsRequestCancelled(err error) bool {
	var apiErr *Error
	return errors.As(err, &apiErr) && apiErr.Reason == "request_cancelled"
}

// IsSendCapacityExceeded reports a send rejected before starting due to global
// or per-hook capacity. Retry explicitly after RetryAfterMS; do not replay an
// entire stream. This does not classify transport or partial delivery failures.
func IsSendCapacityExceeded(err error) bool {
	var apiErr *Error
	return errors.As(err, &apiErr) && (apiErr.Reason == "send_queue_full" || apiErr.Reason == "hook_send_queue_full")
}

// IsDraining reports rejection of new work while the operator drains the server.
// Existing pending responses remain available; retry new work only after resume.
func IsDraining(err error) bool {
	var apiErr *Error
	return errors.As(err, &apiErr) && apiErr.Reason == "draining"
}
