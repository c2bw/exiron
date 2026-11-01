package exiron

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"time"
)

var ErrRequestCancelled = errors.New("exiron: request cancelled by server")
var ErrRequestExpired = errors.New("exiron: request expired on server")

// RequestState is a bounded, in-memory observation. Missing state is not cancellation.
type RequestState struct {
	RequestID   string `json:"req_id"`
	State       string `json:"state"`
	ExpiresInMS *int64 `json:"expires_in_ms"`
}

type RequestCancellation struct {
	RequestID string
	Reason    string
}

// RequestState reads state without consuming deliveries or renewing a polling lease.
func (c *Client) RequestState(ctx context.Context, requestID string) (*RequestState, error) {
	var response RequestState
	if err := c.request(ctx, http.MethodGet, "/api/request-state?"+url.Values{"req_id": {requestID}}.Encode(), c.token, nil, &response); err != nil {
		return nil, err
	}
	if response.RequestID != requestID {
		return nil, invalidResponse("request state ID mismatch", nil)
	}
	switch response.State {
	case "active", "cancelled", "expired", "completed", "closed":
	default:
		return nil, invalidResponse("unknown request state", nil)
	}
	return &response, nil
}

func (r *Runner) handleMessage(ctx context.Context, message Message) (result error) {
	r.statusHandler(1, false)
	defer func() { r.statusHandler(-1, result == nil) }()
	return r.withHandlerBudget(ctx, func(ctx context.Context) error { return r.handleMessageWork(ctx, message) })
}

func (r *Runner) handleMessageWork(ctx context.Context, message Message) error {
	if !r.cooperativeCancellation || message.ReqID == "" || message.Msgtype == "listen" {
		return r.handleAttempts(ctx, message)
	}
	handlerCtx, cancel := context.WithCancelCause(ctx)
	watchCtx, stop := context.WithCancel(ctx)
	done := make(chan struct{})
	initial := r.readRequestState(watchCtx, message.ReqID)
	notify := func(state string) {
		cause := ErrRequestCancelled
		if state == "expired" {
			cause = ErrRequestExpired
		}
		cancel(cause)
		if r.onRequestCancelled != nil {
			r.onRequestCancelled(ctx, RequestCancellation{RequestID: message.ReqID, Reason: state})
		}
	}
	if initial != nil && (initial.State == "cancelled" || initial.State == "expired") {
		notify(initial.State)
		stop()
		cancel(nil)
		return nil
	}
	go func() {
		defer close(done)
		if initial != nil && (initial.State == "completed" || initial.State == "closed") {
			return
		}
		ticker := time.NewTicker(r.cancellationInterval)
		defer ticker.Stop()
		for {
			select {
			case <-watchCtx.Done():
				return
			case <-ticker.C:
				state := r.readRequestState(watchCtx, message.ReqID)
				if state == nil {
					continue
				}
				switch state.State {
				case "cancelled", "expired":
					notify(state.State)
					return
				case "completed", "closed":
					return
				}
			}
		}
	}()
	defer func() { stop(); <-done; cancel(nil) }()
	err := r.handleAttempts(handlerCtx, message)
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if errors.Is(context.Cause(handlerCtx), ErrRequestCancelled) || errors.Is(context.Cause(handlerCtx), ErrRequestExpired) {
		return nil
	}
	return err
}

func (r *Runner) readRequestState(ctx context.Context, id string) *RequestState {
	timeoutCtx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	state, err := r.client.RequestState(timeoutCtx, id)
	if err != nil {
		return nil
	}
	return state
}
