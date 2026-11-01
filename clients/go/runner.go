package exiron

import (
	"context"
	"errors"
	"sync"
	"time"
)

const defaultPollInterval = time.Second
const defaultDisconnectTimeout = 2 * time.Second

// MessageHandler handles one message returned by Requests.
type MessageHandler func(context.Context, Message) error

// ConnectHandler is called when a runner starts maintaining its polling lease.
type ConnectHandler func(context.Context)

// ProtocolHandler receives protocol metadata from a WebSocket connected frame.
type ProtocolHandler func(context.Context, ProtocolInfo)

// DisconnectHandler is called when a connected runner stops maintaining its
// polling lease.
type DisconnectHandler func(context.Context, error)

// RunnerOptions configures a managed polling loop.
type RunnerOptions struct {
	// RuntimeReporting requires runtime reporting support instead of negotiating it
	// automatically. By default reports run every 5s when the server supports them.
	RuntimeReporting bool
	// DisableRuntimeReporting opts out of automatic reports and their discovery.
	// Cannot be combined with RuntimeReporting.
	DisableRuntimeReporting bool
	// HandlerTimeout bounds total processing/retries per occupied message slot.
	// Zero disables it. Expiry is cooperative and never releases a running slot.
	HandlerTimeout time.Duration
	// HandlerFailurePolicy defaults to stop. Quarantine requires an explicit store.
	HandlerFailurePolicy HandlerFailurePolicy
	Quarantine           *Quarantine
	// OnQuarantined observes retained metadata after exhausted handler attempts.
	// It runs in the occupied handler slot, outside store locks.
	OnQuarantined func(context.Context, QuarantineEntry)
	// GracefulShutdown enables Drain and HTTP lease renewal for the current batch.
	GracefulShutdown bool
	// HTTPLeaseRenewal keeps an owned HTTP batch alive while handlers run.
	// Default false; requires the server capability and HTTP transport.
	HTTPLeaseRenewal bool
	// HandlerConcurrency bounds concurrent messages in one batch (1..64).
	// Zero defaults to 1. Values above 1 require concurrency-safe handlers and callbacks.
	HandlerConcurrency int
	// HandlerOrderByChat serializes each service/chat/topic within a batch.
	// Default false. Different conversations can use concurrent handler slots.
	HandlerOrderByChat bool
	// ReportHandlerFailures opts in to bounded diagnostic reports. Default false.
	ReportHandlerFailures bool
	// CooperativeCancellation opts in to per-request server cancellation/expiry checks.
	CooperativeCancellation bool
	// CancellationInterval defaults to one second and must be at least 100ms.
	CancellationInterval time.Duration
	// OnRequestCancelled must return promptly; it runs in the state watcher.
	OnRequestCancelled func(context.Context, RequestCancellation)
	// HandlerMaxAttempts defaults to 1 (stop on the first handler error).
	// Set 2..10 to retry only the failing message before acknowledging its batch.
	HandlerMaxAttempts int
	// HandlerRetryDelay defaults to 250ms and observes context cancellation.
	HandlerRetryDelay time.Duration
	// OnHandlerError reports each failure, including request ID and retry decision.
	OnHandlerError func(context.Context, *HandlerFailure)

	// PollInterval controls how long the runner waits after each successful
	// poll. Defaults to one second, comfortably below the server's three-second
	// client lease.
	PollInterval time.Duration
	// DisconnectTimeout controls the target maximum time after the previous
	// healthy poll before recoverable polling failures are reported as a local
	// disconnect. Defaults to two seconds.
	DisconnectTimeout time.Duration
	// Handler is called once for each returned message. Handler calls are
	// serial by default; errors stop the runner after active siblings finish.
	Handler MessageHandler
	// OnConnect is called after the first successful poll in a connected
	// stretch.
	OnConnect ConnectHandler
	// OnProtocol is called before OnConnect when a WebSocket server advertises its protocol.
	OnProtocol ProtocolHandler
	// OnDisconnect is called with the stop reason when a previously connected
	// runner exits or loses polling.
	OnDisconnect DisconnectHandler
}

// Runner owns an Exiron polling loop for a client.
type Runner struct {
	runtimeReporting        bool
	requireRuntimeReporting bool
	disableRuntimeReporting bool
	handlerTimeout          time.Duration
	handlerFailurePolicy    HandlerFailurePolicy
	quarantine              *Quarantine
	onQuarantined           func(context.Context, QuarantineEntry)
	statusMu                sync.RWMutex
	runtime                 runnerStatusState
	gracefulShutdown        bool
	runMu                   sync.Mutex
	runLife                 *runnerLifetime
	httpLeaseRenewal        bool
	handlerConcurrency      int
	handlerOrderByChat      bool
	reportHandlerFailures   bool
	cooperativeCancellation bool
	cancellationInterval    time.Duration
	onRequestCancelled      func(context.Context, RequestCancellation)
	handlerMaxAttempts      int
	handlerRetryDelay       time.Duration
	onHandlerError          func(context.Context, *HandlerFailure)
	handlerWait             func(context.Context, time.Duration) error

	client            *Client
	pollInterval      time.Duration
	pollTimeout       time.Duration
	disconnectTimeout time.Duration
	handler           MessageHandler
	onConnect         ConnectHandler
	onProtocol        ProtocolHandler
	onDisconnect      DisconnectHandler
	wait              func(context.Context, time.Duration) error
}

// NewRunner builds a managed polling loop for the client.
func (c *Client) NewRunner(opts RunnerOptions) *Runner {
	interval := opts.PollInterval
	if interval <= 0 {
		interval = defaultPollInterval
	}
	disconnectTimeout := opts.DisconnectTimeout
	if disconnectTimeout <= 0 {
		disconnectTimeout = defaultDisconnectTimeout
	}

	concurrency := opts.HandlerConcurrency
	if concurrency == 0 {
		concurrency = 1
	}
	attempts := opts.HandlerMaxAttempts
	if attempts == 0 {
		attempts = 1
	}
	delay := opts.HandlerRetryDelay
	if delay == 0 {
		delay = 250 * time.Millisecond
	}

	cancellationInterval := opts.CancellationInterval
	if cancellationInterval == 0 {
		cancellationInterval = time.Second
	}
	policy := opts.HandlerFailurePolicy
	if policy == "" {
		policy = HandlerFailureStop
	}
	return &Runner{
		requireRuntimeReporting: opts.RuntimeReporting,
		disableRuntimeReporting: opts.DisableRuntimeReporting,
		handlerTimeout:          opts.HandlerTimeout,
		handlerFailurePolicy:    policy, quarantine: opts.Quarantine, onQuarantined: opts.OnQuarantined,
		httpLeaseRenewal:        opts.HTTPLeaseRenewal || (opts.GracefulShutdown && c.transport == TransportHTTP),
		gracefulShutdown:        opts.GracefulShutdown,
		handlerConcurrency:      concurrency,
		handlerOrderByChat:      opts.HandlerOrderByChat,
		reportHandlerFailures:   opts.ReportHandlerFailures,
		cooperativeCancellation: opts.CooperativeCancellation,
		cancellationInterval:    cancellationInterval,
		onRequestCancelled:      opts.OnRequestCancelled,
		handlerMaxAttempts:      attempts,
		handlerRetryDelay:       delay,
		onHandlerError:          opts.OnHandlerError,
		handlerWait:             waitPollInterval,
		client:                  c,
		pollInterval:            interval,
		pollTimeout:             pollRetryTimeout(disconnectTimeout, interval),
		disconnectTimeout:       disconnectTimeout,
		handler:                 opts.Handler,
		onConnect:               opts.OnConnect,
		onProtocol:              opts.OnProtocol,
		onDisconnect:            opts.OnDisconnect,
		wait:                    waitPollInterval,
	}
}

// Run receives work until ctx is canceled or a fatal handler error occurs.
func (r *Runner) Run(ctx context.Context) (runErr error) {
	r.runMu.Lock()
	if r.runLife != nil {
		select {
		case <-r.runLife.done:
		default:
			r.runMu.Unlock()
			return invalidResponse("runner is already running", nil)
		}
	}
	runCtx, cancel := context.WithCancel(ctx)
	life := &runnerLifetime{wake: make(chan struct{}), reportWake: make(chan struct{}, 1), done: make(chan struct{}), cancel: cancel}
	r.statusMu.Lock()
	r.runtime = runnerStatusState{life: life, RunnerStatus: RunnerStatus{Phase: "connecting"}}
	r.statusMu.Unlock()
	r.runLife = life
	r.runMu.Unlock()
	ctx = runCtx
	defer func() {
		cancel()
		r.statusError(runErr)
		r.statusMu.Lock()
		r.runtime.Phase = "stopped"
		r.runtime.Connected = false
		r.runtime.RetryAt = time.Time{}
		r.runtime.batchStarted = time.Time{}
		r.statusMu.Unlock()
		life.mu.Lock()
		life.result = runErr
		close(life.done)
		life.mu.Unlock()
	}()
	if r.requireRuntimeReporting && r.disableRuntimeReporting {
		return invalidResponse("RuntimeReporting and DisableRuntimeReporting cannot both be true", nil)
	}
	r.runtimeReporting = false
	if r.requireRuntimeReporting && (len(r.client.clientID) < 1 || len(r.client.clientID) > 128) {
		return invalidResponse("runtime reporting requires a client ID of 1..128 bytes", nil)
	}
	if r.gracefulShutdown && (len(r.client.clientID) < 1 || len(r.client.clientID) > 128) {
		return invalidResponse("graceful shutdown requires a client ID of 1..128 bytes", nil)
	}
	if r.handlerFailurePolicy != HandlerFailureStop && r.handlerFailurePolicy != HandlerFailureQuarantine {
		return invalidResponse("handler failure policy must be stop or quarantine", nil)
	}
	if r.handlerFailurePolicy == HandlerFailureQuarantine && !r.quarantine.valid() {
		return invalidResponse("quarantine policy requires a store from NewQuarantine", nil)
	}
	if r.handlerTimeout < 0 {
		return invalidResponse("handler timeout must not be negative", nil)
	}
	if r.handler == nil {
		return invalidResponse("runner handler is required", nil)
	}
	if r.handlerConcurrency < 1 || r.handlerConcurrency > 64 {
		return invalidResponse("handler concurrency must be 1..64", nil)
	}
	if r.handlerMaxAttempts < 1 || r.handlerMaxAttempts > 10 || r.handlerRetryDelay < 0 {
		return invalidResponse("handler attempts must be 1..10 and retry delay must not be negative", nil)
	}
	if r.cooperativeCancellation && r.cancellationInterval < 100*time.Millisecond {
		return invalidResponse("cancellation interval must be at least 100ms", nil)
	}
	if r.httpLeaseRenewal && r.client.transport != TransportHTTP {
		return invalidResponse("HTTP lease renewal requires HTTP transport", nil)
	}
	requiredFeatures := r.cooperativeCancellation || r.reportHandlerFailures || r.httpLeaseRenewal || r.gracefulShutdown || r.requireRuntimeReporting
	autoReporting := !r.disableRuntimeReporting && len(r.client.clientID) >= 1 && len(r.client.clientID) <= 128
	if requiredFeatures || autoReporting {
		discoveryCtx := ctx
		cancelDiscovery := func() {}
		if !requiredFeatures {
			discoveryCtx, cancelDiscovery = context.WithTimeout(ctx, time.Second)
		}
		protocol, err := r.client.Capabilities(discoveryCtx)
		cancelDiscovery()
		if err != nil && requiredFeatures {
			return err
		}
		supported := map[string]bool{}
		if err == nil {
			for _, capability := range protocol.Capabilities {
				supported[capability] = true
			}
		}
		if r.requireRuntimeReporting && !supported["client_runtime_reporting"] {
			return invalidResponse("server does not support client_runtime_reporting", nil)
		}
		r.runtimeReporting = (autoReporting || r.requireRuntimeReporting) && supported["client_runtime_reporting"]
		if r.gracefulShutdown && !supported["client_retirement"] {
			return invalidResponse("server does not support client_retirement", nil)
		}
		if r.httpLeaseRenewal && !supported["http_lease_renewal"] {
			return invalidResponse("server does not support http_lease_renewal", nil)
		}
		if r.cooperativeCancellation && !supported["cooperative_cancellation"] {
			return invalidResponse("server does not support cooperative_cancellation", nil)
		}
		if r.reportHandlerFailures && !supported["handler_failure_reporting"] {
			return invalidResponse("server does not support handler_failure_reporting", nil)
		}
	}
	if r.draining() {
		return nil
	}
	if r.runtimeReporting {
		defer r.startRuntimeReporting(ctx, life)()
	}
	coordinator := newRunnerCoordinator(r)
	if r.client.transport == TransportHTTP {
		runErr = coordinator.run(ctx, newHTTPPoller(r, coordinator).poll)
	} else {
		runErr = coordinator.run(ctx, newWebSocketSession(r, coordinator).run)
	}
	if errors.Is(runErr, errRunnerDrained) {
		return nil
	}
	return runErr
}

func isRecoverableRunnerError(err error) bool {
	var failure *HandlerFailure
	if errors.As(err, &failure) {
		return false
	}
	var apiErr *Error
	return isTransportError(err) || IsHookAlreadyConnected(err) || (errors.As(err, &apiErr) && apiErr.retryableConnection)
}

func pollRetryTimeout(disconnectTimeout, interval time.Duration) time.Duration {
	timeout := disconnectTimeout - interval
	if timeout <= 0 {
		return time.Nanosecond
	}
	return timeout
}

func waitPollInterval(ctx context.Context, interval time.Duration) error {
	timer := time.NewTimer(interval)
	defer timer.Stop()

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
