package exiron

import (
	"bytes"
	"context"
	"encoding/gob"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
)

// HandlerFailurePolicy controls exhausted application handler failures.
type HandlerFailurePolicy string

const (
	HandlerFailureStop       HandlerFailurePolicy = "stop"
	HandlerFailureQuarantine HandlerFailurePolicy = "quarantine"
)

var (
	ErrQuarantineFull     = errors.New("exiron: quarantine capacity exceeded")
	ErrQuarantineNotFound = errors.New("exiron: quarantine entry not found")
	ErrQuarantineBusy     = errors.New("exiron: quarantine entry is being recovered")
)

// QuarantineOptions bounds retained encoded messages. Zero selects 100 entries
// and 8 MiB. No entry is evicted to make room for another failure.
type QuarantineOptions struct {
	MaxMessages int
	MaxBytes    int64
}

// QuarantineEntry is metadata only. Recovery is the explicit payload access API.
type QuarantineEntry struct {
	ID         uint64
	RequestID  string
	Attempts   int
	Bytes      int64
	CreatedAt  time.Time
	Recovering bool
}

// QuarantineStats contains no payloads, identifiers, or raw errors.
type QuarantineStats struct {
	Count       int
	Bytes       int64
	MaxMessages int
	MaxBytes    int64
	Recovering  int
}
type quarantinedMessage struct {
	entry   QuarantineEntry
	encoded []byte
}

// Quarantine is a bounded in-memory store independent of a runner's lifetime.
// Reuse it when restarting a runner. Process restart loses all retained work.
// Use a separate store per logical hook/application consumer.
type Quarantine struct {
	mu          sync.Mutex
	maxMessages int
	maxBytes    int64
	bytes       int64
	next        uint64
	entries     map[uint64]*quarantinedMessage
}

func NewQuarantine(opts QuarantineOptions) (*Quarantine, error) {
	if opts.MaxMessages == 0 {
		opts.MaxMessages = 100
	}
	if opts.MaxBytes == 0 {
		opts.MaxBytes = 8 * 1024 * 1024
	}
	if opts.MaxMessages < 1 || opts.MaxBytes < 1 {
		return nil, invalidResponse("quarantine limits must be positive", nil)
	}
	return &Quarantine{maxMessages: opts.MaxMessages, maxBytes: opts.MaxBytes, entries: make(map[uint64]*quarantinedMessage)}, nil
}
func (q *Quarantine) valid() bool {
	return q != nil && q.maxMessages > 0 && q.maxBytes > 0 && q.entries != nil
}
func (q *Quarantine) Stats() QuarantineStats {
	q.mu.Lock()
	defer q.mu.Unlock()
	s := QuarantineStats{Count: len(q.entries), Bytes: q.bytes, MaxMessages: q.maxMessages, MaxBytes: q.maxBytes}
	for _, item := range q.entries {
		if item.entry.Recovering {
			s.Recovering++
		}
	}
	return s
}
func (q *Quarantine) Entries() []QuarantineEntry {
	q.mu.Lock()
	defer q.mu.Unlock()
	entries := make([]QuarantineEntry, 0, len(q.entries))
	for _, item := range q.entries {
		entries = append(entries, item.entry)
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].ID < entries[j].ID })
	return entries
}

// Recover invokes callback exactly once for this explicit recovery call, outside
// all store locks. Only nil success with a live context removes the entry.
// Errors, panics, and cancellation retain it; concurrent recovery is rejected.
// No managed retries, leases, acknowledgements or cancellation watchers are added.
func (q *Quarantine) Recover(ctx context.Context, id uint64, callback MessageHandler) (result error) {
	if callback == nil {
		return invalidResponse("recovery callback is required", nil)
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	q.mu.Lock()
	item, ok := q.entries[id]
	if !ok {
		q.mu.Unlock()
		return ErrQuarantineNotFound
	}
	if item.entry.Recovering {
		q.mu.Unlock()
		return ErrQuarantineBusy
	}
	item.entry.Recovering = true
	q.mu.Unlock()
	success := false
	defer func() {
		q.mu.Lock()
		defer q.mu.Unlock()
		if success {
			delete(q.entries, id)
			q.bytes -= item.entry.Bytes
		} else {
			item.entry.Recovering = false
		}
	}()
	var message Message
	if err := gob.NewDecoder(bytes.NewReader(item.encoded)).Decode(&message); err != nil {
		return invalidResponse("invalid quarantined message", nil)
	}
	result = callback(ctx, message)
	if result == nil {
		result = ctx.Err()
	}
	success = result == nil
	return result
}

// Encoding before the first attempt isolates retained work from handlers that
// mutate nested message slices/pointers. Gob includes Data and MediaItems even
// though their JSON tags intentionally exclude them.
func (q *Quarantine) snapshot(message Message) ([]byte, error) {
	writer := &quarantineWriter{max: q.maxBytes}
	if err := gob.NewEncoder(writer).Encode(message); err != nil {
		return nil, ErrQuarantineFull
	}
	return bytes.Clone(writer.Bytes()), nil
}

type quarantineWriter struct {
	bytes.Buffer
	max int64
}

func (w *quarantineWriter) Write(p []byte) (int, error) {
	if int64(len(p)) > w.max-int64(w.Len()) {
		return 0, ErrQuarantineFull
	}
	return w.Buffer.Write(p)
}
func (q *Quarantine) put(snapshot []byte, requestID string, attempts int) (QuarantineEntry, error) {
	q.mu.Lock()
	defer q.mu.Unlock()
	size := int64(len(snapshot))
	if len(q.entries) >= q.maxMessages || size > q.maxBytes-q.bytes {
		return QuarantineEntry{}, ErrQuarantineFull
	}
	q.next++
	entry := QuarantineEntry{ID: q.next, RequestID: strings.Clone(requestID), Attempts: attempts, Bytes: size, CreatedAt: time.Now()}
	q.entries[entry.ID] = &quarantinedMessage{entry: entry, encoded: snapshot}
	q.bytes += size
	return entry, nil
}
func (r *Runner) quarantineFailure(ctx context.Context, failure *HandlerFailure, snapshot []byte, snapshotErr error) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if IsClientLeaseLost(failure.Err) || r.handlerFailurePolicy != HandlerFailureQuarantine {
		return failure
	}
	if snapshotErr == nil {
		var entry QuarantineEntry
		entry, snapshotErr = r.quarantine.put(snapshot, failure.RequestID, failure.Attempt)
		if snapshotErr == nil {
			r.statusMu.Lock()
			r.runtime.BatchQuarantined++
			r.statusMu.Unlock()
			if r.onQuarantined != nil {
				r.onQuarantined(ctx, entry)
			}
			return ctx.Err()
		}
	}
	copy := *failure
	copy.Err = errors.Join(failure.Err, snapshotErr)
	return &copy
}

// String and GoString deliberately format counts instead of retained payloads.
func (q *Quarantine) String() string   { return fmt.Sprintf("Quarantine%+v", q.Stats()) }
func (q *Quarantine) GoString() string { return q.String() }
