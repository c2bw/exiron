package exiron

import (
	"context"
	"errors"
	"math"
	"net/http"
	"time"
)

// ErrClientLeaseLost also covers an unconfirmed renewal after a control failure.
var ErrClientLeaseLost = errors.New("exiron: HTTP client lease could not be confirmed")

type ClientLease struct {
	OK        bool  `json:"ok"`
	TimeoutMS int64 `json:"lease_timeout_ms"`
}

// RenewLease renews only the client's existing HTTP batch. It never reclaims,
// consumes or acknowledges work, and is not retried automatically.
func (c *Client) RenewLease(ctx context.Context, deliveryID string) (*ClientLease, error) {
	var result ClientLease
	payload := map[string]string{"client_id": c.clientID, "delivery_id": deliveryID}
	if err := c.request(ctx, http.MethodPost, "/api/client-lease", c.token, payload, &result); err != nil {
		return nil, err
	}
	if !result.OK || result.TimeoutMS < 1 || result.TimeoutMS > math.MaxInt64/int64(time.Millisecond) {
		return nil, invalidResponse("invalid HTTP lease renewal response", nil)
	}
	return &result, nil
}

func IsClientLeaseLost(err error) bool {
	var apiErr *Error
	return errors.Is(err, ErrClientLeaseLost) || errors.As(err, &apiErr) && apiErr.Reason == "client_lease_lost"
}

func leaseLost(err error) error {
	return &Error{Reason: "client_lease_lost", Code: "client_lease_lost", Message: "HTTP client lease could not be confirmed", Err: errors.Join(ErrClientLeaseLost, err)}
}

func leaseBudget(ttl time.Duration) time.Duration {
	return max(time.Millisecond, min(time.Second, ttl/4))
}

func (r *Runner) renewHTTPLease(ctx context.Context, batch string, budget time.Duration) (time.Duration, error) {
	started := time.Now()
	requestCtx, cancel := context.WithTimeout(ctx, budget)
	defer cancel()
	lease, err := r.client.RenewLease(requestCtx, batch)
	if err != nil {
		return 0, leaseLost(err)
	}
	ttl := time.Duration(lease.TimeoutMS) * time.Millisecond
	if time.Since(started) >= leaseBudget(ttl) {
		return 0, leaseLost(context.DeadlineExceeded)
	}
	if r.pollInterval >= ttl {
		return 0, leaseLost(invalidResponse("poll interval must be shorter than HTTP lease timeout", nil))
	}
	return ttl, nil
}

func (r *Runner) handleHTTPBatch(ctx context.Context, batch string, messages []Message) error {
	handlerCtx := context.WithValue(ctx, handlerDeliveryKey{}, batch)
	if !r.httpLeaseRenewal || batch == "" || len(messages) == 0 {
		return r.handleBatch(handlerCtx, messages)
	}
	ttl, err := r.renewHTTPLease(ctx, batch, time.Second)
	if err != nil {
		return err
	}
	batchCtx, cancelBatch := context.WithCancelCause(handlerCtx)
	defer cancelBatch(nil)
	watchCtx, stop := context.WithCancel(ctx)
	defer stop()
	done := make(chan error, 1)
	go func() {
		timer := time.NewTimer(max(time.Millisecond, ttl/3))
		defer timer.Stop()
		for {
			select {
			case <-watchCtx.Done():
				done <- nil
				return
			case <-timer.C:
				next, err := r.renewHTTPLease(watchCtx, batch, leaseBudget(ttl))
				if err != nil {
					if watchCtx.Err() != nil {
						done <- nil
						return
					}
					cancelBatch(ErrClientLeaseLost)
					done <- err
					return
				}
				ttl = next
				timer.Reset(max(time.Millisecond, ttl/3))
			}
		}
	}()
	handlerErr := r.handleBatch(batchCtx, messages)
	stop()
	renewalErr := <-done
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if renewalErr != nil {
		return renewalErr
	}
	if handlerErr != nil {
		return handlerErr
	}
	// Protect the ordinary polling delay before the acknowledgement is sent.
	_, err = r.renewHTTPLease(ctx, batch, time.Second)
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return err
}
