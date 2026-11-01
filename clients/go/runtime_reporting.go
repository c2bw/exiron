package exiron

import (
	"context"
	"net/http"
	"time"
)

const runtimeReportInterval = 5 * time.Second

// ClientRuntimeReport contains only bounded, self-reported gauges and a session
// fence. Reports do not renew leases, acknowledge batches, or prove liveness.
type ClientRuntimeReport struct {
	ClientID            string `json:"client_id"`
	RuntimeRef          string `json:"runtime_ref"`
	Sequence            int64  `json:"sequence"`
	Phase               string `json:"phase"`
	ActiveHandlers      int    `json:"active_handlers"`
	OverdueHandlers     int    `json:"overdue_handlers"`
	QuarantinedMessages int    `json:"quarantined_messages"`
	QuarantineBytes     int64  `json:"quarantine_bytes"`
	QuarantineEnabled   bool   `json:"quarantine_enabled"`
	QuarantineAvailable bool   `json:"quarantine_available"`
}

// ClientRuntimeObservation is the last server-received report for a session.
// ReportedAt and freshness are determined by the server, not a client clock.
type ClientRuntimeObservation struct {
	Phase               string    `json:"phase"`
	ActiveHandlers      int       `json:"active_handlers"`
	OverdueHandlers     int       `json:"overdue_handlers"`
	QuarantinedMessages int       `json:"quarantined_messages"`
	QuarantineBytes     int64     `json:"quarantine_bytes"`
	QuarantineEnabled   bool      `json:"quarantine_enabled"`
	QuarantineAvailable bool      `json:"quarantine_available"`
	ReportedAt          time.Time `json:"reported_at"`
	AgeMS               int64     `json:"age_ms"`
	StaleAfterMS        int64     `json:"stale_after_ms"`
	Stale               bool      `json:"stale"`
	Status              string    `json:"status"`
}

func (c *Client) ReportRuntime(ctx context.Context, report ClientRuntimeReport) error {
	var result struct {
		OK bool `json:"ok"`
	}
	err := c.request(ctx, http.MethodPost, "/api/client-runtime", c.token, report, &result)
	if err == nil && !result.OK {
		return invalidResponse("invalid runtime report response", nil)
	}
	return err
}
func (r *Runner) setRuntimeRef(ref string) {
	if !r.runtimeReporting {
		return
	}
	r.statusMu.Lock()
	changed := r.runtime.runtimeRef != ref
	r.runtime.runtimeRef = ref
	r.statusMu.Unlock()
	life := r.lifetime()
	if changed && life != nil {
		select {
		case life.reportWake <- struct{}{}:
		default:
		}
	}
}
func (r *Runner) startRuntimeReporting(ctx context.Context, life *runnerLifetime) func() {
	reportCtx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() { defer close(done); r.runtimeReportLoop(reportCtx, life.reportWake) }()
	return func() { cancel(); <-done }
}
func (r *Runner) runtimeReportLoop(ctx context.Context, wake <-chan struct{}) {
	var last time.Time
	var sequence int64
	for {
		delay := runtimeReportInterval
		if !last.IsZero() {
			delay = max(0, runtimeReportInterval-time.Since(last))
		}
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-wake:
			timer.Stop()
		case <-timer.C:
		}
		if !last.IsZero() && time.Since(last) < runtimeReportInterval {
			continue
		}
		last = time.Now()
		r.statusMu.RLock()
		ref := r.runtime.runtimeRef
		r.statusMu.RUnlock()
		if ref == "" {
			continue
		}
		sequence++
		snapshot := r.Status()
		active := max(0, min(64, snapshot.ActiveHandlers))
		report := ClientRuntimeReport{ClientID: r.client.clientID, RuntimeRef: ref, Sequence: sequence,
			Phase: snapshot.Phase, ActiveHandlers: active, OverdueHandlers: max(0, min(active, snapshot.OverdueHandlers)),
			QuarantinedMessages: max(0, min(1_000_000_000, snapshot.Quarantine.Count)), QuarantineBytes: max(0, min(int64(1_099_511_627_776), snapshot.Quarantine.Bytes)),
			QuarantineEnabled: r.quarantine != nil, QuarantineAvailable: r.quarantine.valid()}
		requestCtx, cancel := context.WithTimeout(ctx, time.Second)
		_ = r.client.ReportRuntime(requestCtx, report) // Best effort, one attempt, no handler callbacks.
		cancel()
	}
}
