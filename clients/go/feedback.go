package exiron

import "errors"

const feedbackPositiveData = "exiron:feedback:v1:positive"
const feedbackNegativeData = "exiron:feedback:v1:negative"

// FeedbackVote describes an optional response rating.
type FeedbackVote string

const (
	FeedbackPositive FeedbackVote = "positive"
	FeedbackNegative FeedbackVote = "negative"
)

// Feedback identifies a callback rating and the response being rated.
// RequestID is the new callback request; OriginReqID is the rated request.
// Applications choose how to retain votes and deduplicate by OriginReqID/UserID.
type Feedback struct {
	Vote        FeedbackVote
	OriginReqID string
	RequestID   string
	UserID      int64
	CallbackID  string
}

// WithFeedback copies a keyboard and appends a thumbs-up/down row. It never
// removes existing buttons or changes reply mode. Full keyboards and duplicate
// feedback rows return a local error before any network request.
func WithFeedback(keyboard InlineKeyboard) (InlineKeyboard, error) {
	invalid := errors.New("exiron: feedback needs room for one row and two buttons without an existing feedback row")
	if len(keyboard) >= 20 {
		return nil, invalid
	}
	total := 0
	for _, row := range keyboard {
		if len(row) < 1 || len(row) > 8 {
			return nil, invalid
		}
		total += len(row)
		for _, button := range row {
			if button.CallbackData == feedbackPositiveData || button.CallbackData == feedbackNegativeData {
				return nil, invalid
			}
		}
	}
	if total > 98 {
		return nil, invalid
	}
	result := make(InlineKeyboard, len(keyboard)+1)
	for i, row := range keyboard {
		result[i] = append([]InlineKeyboardButton(nil), row...)
	}
	result[len(keyboard)] = []InlineKeyboardButton{
		{Text: "👍", CallbackData: feedbackPositiveData},
		{Text: "👎", CallbackData: feedbackNegativeData},
	}
	return result, nil
}

// ParseFeedback recognizes only complete callback requests with a rated request
// and an identified clicker. Ordinary messages, listens and push callbacks with
// no originating request are not ratings.
func ParseFeedback(message Message) (Feedback, bool) {
	if message.Msgtype != "request" || message.Datatype != DatatypeCallback || message.ReqID == "" ||
		message.From == nil || message.From.ID <= 0 || message.CallbackQuery == nil ||
		message.CallbackQuery.ID == "" || message.CallbackQuery.OriginReqID == nil || *message.CallbackQuery.OriginReqID == "" {
		return Feedback{}, false
	}
	var vote FeedbackVote
	switch string(message.Data) {
	case feedbackPositiveData:
		vote = FeedbackPositive
	case feedbackNegativeData:
		vote = FeedbackNegative
	default:
		return Feedback{}, false
	}
	return Feedback{Vote: vote, OriginReqID: *message.CallbackQuery.OriginReqID,
		RequestID: message.ReqID, UserID: message.From.ID, CallbackID: message.CallbackQuery.ID}, true
}
