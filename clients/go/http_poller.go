package exiron

import "context"

type httpPoller struct {
	runner        *Runner
	coordinator   *runnerCoordinator
	deliveryAck   string
	lastCompleted string
}

func newHTTPPoller(runner *Runner, coordinator *runnerCoordinator) *httpPoller {
	return &httpPoller{runner: runner, coordinator: coordinator}
}

func (p *httpPoller) poll(ctx context.Context) error {
	if p.runner.draining() {
		if p.lastCompleted != "" {
			if err := p.runner.retireDelivery(ctx, p.lastCompleted); err != nil {
				return err
			}
		}
		return errRunnerDrained
	}
	pollCtx, cancelPoll := context.WithTimeout(ctx, p.runner.pollTimeout)
	messages, deliveryID, runtimeRef, err := p.runner.client.requestsDeliveryRuntime(pollCtx, p.deliveryAck)
	cancelPoll()
	if err != nil {
		return err
	}

	if p.runner.gracefulShutdown && len(messages) > 0 && deliveryID == "" {
		return invalidResponse("graceful shutdown requires a batch identity", nil)
	}
	if p.runner.runtimeReporting && (len(runtimeRef) < 1 || len(runtimeRef) > 128) {
		return invalidResponse("runtime reporting requires a session reference", nil)
	}
	p.runner.setRuntimeRef(runtimeRef)
	p.coordinator.connect(ctx)
	if err := p.runner.handleHTTPBatch(ctx, deliveryID, messages); err != nil {
		return err
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	p.deliveryAck = deliveryID
	if deliveryID != "" {
		p.lastCompleted = deliveryID
	}
	return nil
}
