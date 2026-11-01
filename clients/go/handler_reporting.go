package exiron

import (
	"context"
	"errors"
	"net/http"
	"time"
)

type handlerDeliveryKey struct{}

// HandlerReport contains bounded diagnostics only. Application errors stay local.
type HandlerReport struct {
	RequestID   string `json:"req_id"`
	ClientID    string `json:"client_id"`
	DeliveryID  string `json:"delivery_id"`
	Attempt     int    `json:"attempt"`
	MaxAttempts int    `json:"max_attempts"`
	State       string `json:"state"`
	Category    string `json:"category,omitempty"`
}

// ReportHandler sends diagnostics without acknowledging work or renewing a lease.
// Calls are not retried. Managed runners add a one-second deadline.
func (c *Client) ReportHandler(ctx context.Context, report HandlerReport) error {
	return c.request(ctx, http.MethodPost, "/api/handler-reports", c.token, report, nil)
}

func (r *Runner) reportHandler(ctx context.Context, message Message, attempt, max int, state string, err error) {
	batch, _ := ctx.Value(handlerDeliveryKey{}).(string)
	if !r.reportHandlerFailures || message.ReqID == "" || message.Msgtype == "listen" || batch == "" || ctx.Err() != nil {
		return
	}
	category := ""
	if state != "recovered" {
		category = "handler_error"
		var clientErr *Error
		if errors.As(err, &clientErr) {
			category = "client_error"
		}
	}
	report := HandlerReport{RequestID: message.ReqID, ClientID: r.client.clientID, DeliveryID: batch,
		Attempt: attempt, MaxAttempts: max, State: state, Category: category}
	reportCtx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	_ = r.client.ReportHandler(reportCtx, report)
}
