package exiron

import (
	"context"
	"errors"
	"time"
)

// RuntimeError is a bounded error summary. It never contains raw error text,
// request IDs, URLs, credentials, or response bodies.
type RuntimeError struct {
	Kind       string
	HTTPStatus int
	At         time.Time
}

// RunnerStatus is an independent point-in-time copy, safe to read during Run,
// from handlers/callbacks, and after Run returns. Durations use monotonic time.
type RunnerStatus struct {
	HandlerTimeout   time.Duration
	OverdueHandlers  int
	OldestOverdueFor time.Duration
	BatchTimedOut    int
	BatchQuarantined int
	Quarantine       QuarantineStats
	Phase            string
	Connected        bool
	ActiveHandlers   int
	BatchSize        int
	BatchCompleted   int
	BatchAge         time.Duration
	LastConnectedAt  time.Time
	LastError        RuntimeError
	RetryAt          time.Time
	RetryIn          time.Duration
	DrainStartedAt   time.Time
	DrainDeadline    time.Time
	DrainRemaining   time.Duration
}

type runnerStatusState struct {
	runtimeRef string
	life       *runnerLifetime
	RunnerStatus
	batchStarted time.Time
	budgets      map[*handlerBudget]struct{}
}

// Status reads local runtime state without network I/O or waiting for handlers.
// Before the first Run, Phase is "idle". Each Run resets the previous snapshot.
func (r *Runner) Status() RunnerStatus {
	r.statusMu.RLock()
	defer r.statusMu.RUnlock()
	s := r.runtime.RunnerStatus
	s.HandlerTimeout = r.handlerTimeout
	for budget := range r.runtime.budgets {
		if budget.expired.Load() || (budget.parent.Err() == nil && !time.Now().Before(budget.deadline)) {
			s.OverdueHandlers++
			s.OldestOverdueFor = max(s.OldestOverdueFor, time.Since(budget.deadline))
		}
	}
	if r.quarantine != nil {
		s.Quarantine = r.quarantine.Stats()
	}
	if s.Phase == "" {
		s.Phase = "idle"
	}
	if !r.runtime.batchStarted.IsZero() {
		s.BatchAge = time.Since(r.runtime.batchStarted)
	}
	if !s.RetryAt.IsZero() {
		s.RetryIn = max(0, time.Until(s.RetryAt))
	}
	if !s.DrainDeadline.IsZero() && s.Phase != "stopped" {
		s.DrainRemaining = max(0, time.Until(s.DrainDeadline))
	}
	return s
}

func (r *Runner) statusPhase(phase string) {
	r.statusMu.Lock()
	defer r.statusMu.Unlock()
	if r.runtime.Phase != "draining" {
		r.runtime.Phase = phase
	}
	r.runtime.RetryAt = time.Time{}
}
func (r *Runner) statusConnect() {
	r.statusMu.Lock()
	defer r.statusMu.Unlock()
	r.runtime.Connected = true
	r.runtime.LastConnectedAt = time.Now()
}
func (r *Runner) statusError(err error) {
	if err == nil || errors.Is(err, errRunnerDrained) {
		return
	}
	summary := runtimeError(err)
	r.statusMu.Lock()
	defer r.statusMu.Unlock()
	r.runtime.LastError = summary
}
func runtimeError(err error) RuntimeError {
	e := RuntimeError{Kind: "error", At: time.Now()}
	var failure *HandlerFailure
	var api *Error
	switch {
	case errors.Is(err, ErrHandlerDeadlineExceeded):
		e.Kind = "handler_deadline_exceeded"
	case errors.As(err, &failure):
		e.Kind = "handler_error"
	case errors.Is(err, context.Canceled):
		e.Kind = "cancelled"
	case errors.Is(err, context.DeadlineExceeded):
		e.Kind = "deadline_exceeded"
	case errors.As(err, &api):
		e.Kind = "client_error"
		if api.StatusCode >= 100 && api.StatusCode <= 599 {
			e.HTTPStatus = api.StatusCode
		}
		switch api.Reason {
		case "transport_error", "hook_already_connected", "client_lease_lost", "invalid_response", "http_error", "draining":
			e.Kind = api.Reason
		}
	}
	return e
}
func (r *Runner) statusWait(delay time.Duration, retry bool) {
	r.statusMu.Lock()
	defer r.statusMu.Unlock()
	if r.runtime.Phase == "draining" {
		return
	}
	r.runtime.Phase = "waiting"
	if retry {
		r.runtime.Phase = "backing_off"
		r.runtime.RetryAt = time.Now().Add(delay)
	}
}
func (r *Runner) statusDrain(life *runnerLifetime, deadline time.Time) {
	r.statusMu.Lock()
	defer r.statusMu.Unlock()
	if r.runtime.life != life || r.runtime.Phase == "stopped" {
		return
	}
	if r.runtime.DrainStartedAt.IsZero() {
		r.runtime.DrainStartedAt = time.Now()
	}
	r.runtime.Phase = "draining"
	r.runtime.RetryAt = time.Time{}
	if !deadline.IsZero() && (r.runtime.DrainDeadline.IsZero() || deadline.Before(r.runtime.DrainDeadline)) {
		r.runtime.DrainDeadline = deadline
	}
}
func (r *Runner) statusBatch(size int) func() {
	r.statusMu.Lock()
	r.runtime.BatchSize, r.runtime.BatchCompleted, r.runtime.BatchQuarantined, r.runtime.BatchTimedOut = size, 0, 0, 0
	if size > 0 {
		r.runtime.batchStarted = time.Now()
		if r.runtime.Phase != "draining" {
			r.runtime.Phase = "handling"
		}
	}
	r.statusMu.Unlock()
	return func() {
		r.statusMu.Lock()
		defer r.statusMu.Unlock()
		r.runtime.batchStarted = time.Time{}
		if r.runtime.Phase != "draining" {
			r.runtime.Phase = "waiting"
		}
	}
}
func (r *Runner) statusHandler(delta int, completed bool) {
	r.statusMu.Lock()
	defer r.statusMu.Unlock()
	r.runtime.ActiveHandlers += delta
	if completed {
		r.runtime.BatchCompleted++
	}
}

func (r *Runner) statusDrainError(life *runnerLifetime, err error) {
	summary := runtimeError(err)
	r.statusMu.Lock()
	defer r.statusMu.Unlock()
	if r.runtime.life == life && r.runtime.Phase != "stopped" {
		r.runtime.LastError = summary
	}
}
