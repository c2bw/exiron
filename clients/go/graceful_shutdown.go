package exiron

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"time"
)

var errRunnerDrained = errors.New("exiron: runner drained")

type runnerLifetime struct {
	reportWake chan struct{}
	mu         sync.Mutex
	drain      bool
	active     bool
	retiring   bool
	last       string
	wake       chan struct{}
	done       chan struct{}
	cancel     context.CancelFunc
	result     error
}

// RetireDelivery confirms a completed batch and releases its fenced session.
// It never fetches work and is never automatically retried.
func (c *Client) RetireDelivery(ctx context.Context, deliveryID string) error {
	if deliveryID == "" {
		return invalidResponse("delivery ID required for retirement", nil)
	}
	var response struct {
		OK bool `json:"ok"`
	}
	err := c.request(ctx, http.MethodPost, "/api/client-retire", c.token, map[string]string{"client_id": c.clientID, "delivery_id": deliveryID}, &response)
	if err == nil && !response.OK {
		return invalidResponse("invalid client retirement response", nil)
	}
	return err
}

// Drain stops new polling, finishes the current batch, and confirms its retirement.
// Enable RunnerOptions.GracefulShutdown before Run. The deadline cancels the run;
// Go handlers must observe their context to stop promptly.
func (r *Runner) Drain(ctx context.Context) error {
	if !r.gracefulShutdown {
		return invalidResponse("graceful shutdown is not enabled", nil)
	}
	life := r.lifetime()
	if life == nil {
		return invalidResponse("runner is not running", nil)
	}
	life.mu.Lock()
	deadline, _ := ctx.Deadline()
	r.statusDrain(life, deadline)
	if !life.drain {
		life.drain = true
		close(life.wake)
	}
	life.mu.Unlock()
	if err := ctx.Err(); err != nil {
		r.statusDrainError(life, err)
		life.cancel()
		return err
	}
	select {
	case <-life.done:
		life.mu.Lock()
		defer life.mu.Unlock()
		return life.result
	case <-ctx.Done():
		r.statusDrainError(life, ctx.Err())
		life.cancel()
		return ctx.Err()
	}
}

func (r *Runner) retireDelivery(ctx context.Context, id string) error {
	control, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	return r.client.RetireDelivery(control, id)
}

func (r *Runner) lifetime() *runnerLifetime { r.runMu.Lock(); defer r.runMu.Unlock(); return r.runLife }
func (r *Runner) draining() bool {
	if !r.gracefulShutdown {
		return false
	}
	life := r.lifetime()
	if life == nil {
		return false
	}
	life.mu.Lock()
	defer life.mu.Unlock()
	return life.drain
}
func (r *Runner) acceptSocketBatch() bool {
	if !r.gracefulShutdown {
		return true
	}
	life := r.lifetime()
	life.mu.Lock()
	defer life.mu.Unlock()
	if life.drain {
		return false
	}
	life.active = true
	return true
}
func (r *Runner) socketBatchComplete(id string) bool {
	if !r.gracefulShutdown {
		return false
	}
	life := r.lifetime()
	life.mu.Lock()
	defer life.mu.Unlock()
	life.active = false
	if id != "" {
		life.last = id
	}
	if life.drain && !life.retiring {
		life.retiring = true
		return true
	}
	return false
}
func (r *Runner) claimIdleRetirement() (string, bool) {
	life := r.lifetime()
	life.mu.Lock()
	defer life.mu.Unlock()
	if life.active || life.retiring {
		return "", false
	}
	life.retiring = true
	return life.last, true
}

func (r *Runner) waitNext(ctx context.Context, delay time.Duration) error {
	if !r.gracefulShutdown {
		wait := r.wait
		if wait == nil {
			wait = waitPollInterval
		}
		return wait(ctx, delay)
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-r.lifetime().wake:
		return nil
	case <-timer.C:
		return nil
	}
}
