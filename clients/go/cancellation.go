package exiron

import (
	"context"
	"net/http"
)

// CancelRequest cancels queued work and remaining sends for a pending request.
// Use a live context, even when the stream's own context has been cancelled.
func (c *Client) CancelRequest(ctx context.Context, reqID string) (*CancelResponse, error) {
	payload := struct {
		ReqID string `json:"req_id"`
	}{ReqID: reqID}
	var result wireCancelResponse
	if err := c.request(ctx, http.MethodPost, "/api/cancellations", c.token, payload, &result); err != nil {
		return nil, err
	}
	return &CancelResponse{OK: result.OK, Cancelled: result.Cancelled, DeliveryStatus: result.DeliveryStatus, MessageIDs: result.MessageIDs}, nil
}
