package exiron

import (
	"context"
	"sync/atomic"
)

// handleBatch keeps one delivery in flight and bounds handler execution inside
// it. Retrying a message continues to occupy its slot. After a failure, active
// siblings finish before returning so reconnect cannot overlap their execution.
func (r *Runner) handleBatch(ctx context.Context, messages []Message) error {
	if r.handlerTimeout > 0 {
		ctx = context.WithValue(ctx, handlerBatchDeadlineKey{}, &atomic.Bool{})
	}
	defer r.statusBatch(len(messages))()
	limit := r.handlerConcurrency
	if limit <= 1 {
		for _, message := range messages {
			if err := r.handleMessage(ctx, message); err != nil {
				return err
			}
		}
		return nil
	}
	if r.handlerOrderByChat {
		return r.handleOrderedBatch(ctx, messages)
	}
	if limit > len(messages) {
		limit = len(messages)
	}
	results := make(chan error, limit)
	next, active := 0, 0
	var failure error
	for next < len(messages) || active > 0 {
		for failure == nil && ctx.Err() == nil && !handlerBatchExpired(ctx) && active < limit && next < len(messages) {
			message := messages[next]
			next++
			active++
			go func() { results <- r.handleMessage(ctx, message) }()
		}
		if active == 0 {
			break
		}
		err := <-results
		active--
		if failure == nil && err != nil {
			failure = err
		}
	}
	if failure != nil {
		return failure
	}
	if handlerBatchExpired(ctx) {
		return handlerTimeoutError
	}
	return ctx.Err()
}
