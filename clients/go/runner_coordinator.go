package exiron

import (
	"context"
	"errors"
	"time"
)

// runnerCoordinator owns the state shared by the runner's transport-specific
// loops. Keeping that state here makes reconnect behavior identical for HTTP
// polling and WebSocket sessions.
type runnerCoordinator struct {
	runner       *Runner
	connected    bool
	retryDelay   time.Duration
	retryStarted time.Time
}

func newRunnerCoordinator(runner *Runner) *runnerCoordinator {
	return &runnerCoordinator{runner: runner, retryDelay: runner.pollInterval, retryStarted: time.Now()}
}

func (c *runnerCoordinator) run(ctx context.Context, poll func(context.Context) error) error {
	for {
		phase := "connecting"
		if c.runner.client.transport == TransportHTTP {
			phase = "polling"
		}
		c.runner.statusPhase(phase)
		err := poll(ctx)
		if errors.Is(err, errRunnerDrained) {
			c.disconnect(ctx, nil)
			return err
		}
		if err != nil {
			c.runner.statusError(err)
			if c.connected {
				c.retryStarted = time.Now()
			}
			c.disconnect(ctx, err)
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if c.runner.draining() {
				return err
			}
			if !isRecoverableRunnerError(err) {
				return err
			}
		}

		delay := c.runner.pollInterval
		if err != nil {
			delay = retryDelay(c.runner.client.retry, c.retryDelay, err)
			if c.runner.client.transport == TransportWebSocket && !canRetry(c.runner.client.retry, c.retryStarted, delay) {
				return err
			}
			c.retryDelay = nextRetryDelay(c.retryDelay, c.runner.client.retry.MaxDelay)
		} else {
			c.retryDelay = c.runner.pollInterval
		}

		c.runner.statusWait(delay, err != nil)
		if waitErr := c.runner.waitNext(ctx, delay); waitErr != nil {
			if c.connected {
				c.disconnect(ctx, ctx.Err())
			}
			return waitErr
		}
		if err != nil && c.runner.client.transport == TransportWebSocket && !canRetry(c.runner.client.retry, c.retryStarted, 0) {
			return err
		}
	}
}

func (c *runnerCoordinator) connect(ctx context.Context) {
	if c.connected {
		return
	}
	c.connected = true
	c.runner.statusConnect()
	c.runner.statusPhase("waiting")
	c.retryDelay = c.runner.pollInterval
	if c.runner.onConnect != nil {
		c.runner.onConnect(ctx)
	}
}

func (c *runnerCoordinator) disconnect(ctx context.Context, err error) {
	if !c.connected {
		return
	}
	c.connected = false
	c.runner.statusMu.Lock()
	c.runner.runtime.Connected = false
	c.runner.statusMu.Unlock()
	if c.runner.onDisconnect != nil {
		c.runner.onDisconnect(ctx, err)
	}
}
