package exiron

import (
	"context"
	"errors"
	"fmt"
)

// HandlerFailure identifies one failed attempt without embedding message contents.
type HandlerFailure struct {
	RequestID   string
	Attempt     int
	MaxAttempts int
	WillRetry   bool
	Err         error
}

func (e *HandlerFailure) Error() string {
	return fmt.Sprintf("exiron: handler failed for request %q (attempt %d/%d)", e.RequestID, e.Attempt, e.MaxAttempts)
}
func (e *HandlerFailure) Unwrap() error { return e.Err }

func (r *Runner) handleAttempts(ctx context.Context, message Message) error {
	var snapshot []byte
	var snapshotErr error
	if r.handlerFailurePolicy == HandlerFailureQuarantine {
		snapshot, snapshotErr = r.quarantine.snapshot(message)
	}
	maxAttempts := r.handlerMaxAttempts
	if maxAttempts == 0 {
		maxAttempts = 1
	}
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		if err := handlerBudgetError(ctx); err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		err := r.handler(ctx, message)
		if errors.Is(err, ErrHandlerDeadlineExceeded) {
			return err
		}
		if budgetErr := handlerBudgetError(ctx); budgetErr != nil {
			return budgetErr
		}
		if (r.cooperativeCancellation || r.httpLeaseRenewal || r.handlerFailurePolicy == HandlerFailureQuarantine) && ctx.Err() != nil {
			return ctx.Err()
		}
		if err == nil {
			if attempt > 1 {
				r.reportHandler(ctx, message, attempt, maxAttempts, "recovered", nil)
			}
			return nil
		}
		if IsRequestCancelled(err) {
			return nil
		}
		failure := &HandlerFailure{RequestID: message.ReqID, Attempt: attempt,
			MaxAttempts: maxAttempts, WillRetry: attempt < maxAttempts, Err: err}
		r.statusError(failure)
		state := "exhausted"
		if failure.WillRetry {
			state = "retrying"
		}
		r.reportHandler(ctx, message, attempt, maxAttempts, state, err)
		if r.onHandlerError != nil {
			r.onHandlerError(ctx, failure)
		}
		if err := handlerBudgetError(ctx); err != nil {
			return err
		}
		if !failure.WillRetry {
			if r.handlerFailurePolicy == HandlerFailureQuarantine {
				return r.quarantineFailure(ctx, failure, snapshot, snapshotErr)
			}
			return failure
		}
		wait := r.handlerWait
		if wait == nil {
			wait = waitPollInterval
		}
		if err := wait(ctx, r.handlerRetryDelay); err != nil {
			return err
		}
	}
	return nil
}
