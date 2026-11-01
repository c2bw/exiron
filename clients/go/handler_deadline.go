package exiron

import (
	"context"
	"errors"
	"sync/atomic"
	"time"
)

// ErrHandlerDeadlineExceeded identifies a managed message's total time budget.
// It also matches context.DeadlineExceeded with errors.Is.
var ErrHandlerDeadlineExceeded error = handlerDeadlineError{}

type handlerDeadlineError struct{}

func (handlerDeadlineError) Error() string { return "exiron: handler execution deadline exceeded" }
func (handlerDeadlineError) Is(target error) bool {
	return target == ErrHandlerDeadlineExceeded || target == context.DeadlineExceeded
}

var handlerTimeoutError error = handlerDeadlineError{}

type handlerBudgetKey struct{}
type handlerBatchDeadlineKey struct{}
type handlerBudget struct {
	deadline time.Time
	parent   context.Context
	expired  atomic.Bool
	batch    *atomic.Bool
}

func handlerBatchExpired(ctx context.Context) bool {
	state, _ := ctx.Value(handlerBatchDeadlineKey{}).(*atomic.Bool)
	return state != nil && state.Load()
}
func handlerBudgetError(ctx context.Context) error {
	b, _ := ctx.Value(handlerBudgetKey{}).(*handlerBudget)
	if b == nil {
		return nil
	}
	if b.parent.Err() != nil {
		return b.parent.Err()
	}
	if b.expired.Load() || !time.Now().Before(b.deadline) {
		return handlerTimeoutError
	}
	return nil
}
func (r *Runner) withHandlerBudget(ctx context.Context, work func(context.Context) error) (result error) {
	if handlerBatchExpired(ctx) {
		return handlerTimeoutError
	}
	if r.handlerTimeout == 0 {
		return work(ctx)
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	batch, _ := ctx.Value(handlerBatchDeadlineKey{}).(*atomic.Bool)
	b := &handlerBudget{deadline: time.Now().Add(r.handlerTimeout), parent: ctx, batch: batch}
	budgetCtx, cancel := context.WithDeadlineCause(ctx, b.deadline, handlerTimeoutError)
	budgetCtx = context.WithValue(budgetCtx, handlerBudgetKey{}, b)
	r.statusMu.Lock()
	if r.runtime.budgets == nil {
		r.runtime.budgets = make(map[*handlerBudget]struct{})
	}
	r.runtime.budgets[b] = struct{}{}
	r.statusMu.Unlock()
	mark := func() {
		if b.expired.CompareAndSwap(false, true) {
			if b.batch != nil {
				b.batch.Store(true)
			}
			r.statusMu.Lock()
			r.runtime.BatchTimedOut++
			r.runtime.LastError = RuntimeError{Kind: "handler_deadline_exceeded", At: time.Now()}
			r.statusMu.Unlock()
		}
	}
	done := make(chan struct{})
	stop := context.AfterFunc(budgetCtx, func() {
		if errors.Is(context.Cause(budgetCtx), ErrHandlerDeadlineExceeded) && ctx.Err() == nil {
			mark()
		}
		close(done)
	})
	defer func() {
		if !stop() {
			<-done
		}
		if err := handlerBudgetError(budgetCtx); err != nil {
			if errors.Is(err, ErrHandlerDeadlineExceeded) {
				mark()
			}
			result = err
		}
		cancel()
		r.statusMu.Lock()
		delete(r.runtime.budgets, b)
		r.statusMu.Unlock()
	}()
	result = work(budgetCtx)
	if err := handlerBudgetError(budgetCtx); err != nil {
		if errors.Is(err, ErrHandlerDeadlineExceeded) {
			mark()
		}
		return err
	}
	return result
}
