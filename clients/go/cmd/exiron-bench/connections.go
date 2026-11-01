package main

import (
	"context"
	"net"
	"net/http/httptrace"
	"sync"
	"sync/atomic"
	"time"
)

// Keep live connection records and at most 32 unused-close examples. No
// request content, URLs, tokens or response buffers are retained.
type connectionRecord struct {
	Port    int          `json:"local_port"`
	Kind    string       `json:"kind"`
	Created time.Time    `json:"-"`
	Uses    atomic.Int64 `json:"-"`
	Written atomic.Int64 `json:"-"`
	Read    atomic.Int64 `json:"-"`
}
type connectionExample struct {
	Port    int    `json:"local_port"`
	Kind    string `json:"kind"`
	AgeMS   int64  `json:"age_ms"`
	Uses    int64  `json:"uses"`
	Written int64  `json:"written_bytes"`
	Read    int64  `json:"read_bytes"`
}
type connectionTracker struct {
	sync.Mutex
	active                           map[*connectionRecord]bool
	opened, closedUnused, peakActive int
	examples                         []connectionExample
}
type trackedConnection struct {
	net.Conn
	record  *connectionRecord
	tracker *connectionTracker
	once    sync.Once
}

func (t *connectionTracker) dial(kind string) func(context.Context, string, string) (net.Conn, error) {
	return func(ctx context.Context, network, address string) (net.Conn, error) {
		c, err := (&net.Dialer{}).DialContext(ctx, network, address)
		if err != nil {
			return nil, err
		}
		record := &connectionRecord{Kind: kind, Created: time.Now()}
		if addr, ok := c.LocalAddr().(*net.TCPAddr); ok {
			record.Port = addr.Port
		}
		t.Lock()
		if t.active == nil {
			t.active = make(map[*connectionRecord]bool)
		}
		t.active[record] = true
		t.opened++
		if len(t.active) > t.peakActive {
			t.peakActive = len(t.active)
		}
		t.Unlock()
		return &trackedConnection{Conn: c, record: record, tracker: t}, nil
	}
}
func (c *trackedConnection) Write(p []byte) (int, error) {
	n, err := c.Conn.Write(p)
	c.record.Written.Add(int64(n))
	return n, err
}
func (c *trackedConnection) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	c.record.Read.Add(int64(n))
	return n, err
}
func (c *trackedConnection) Close() error {
	err := c.Conn.Close()
	c.once.Do(func() {
		t := c.tracker
		t.Lock()
		defer t.Unlock()
		delete(t.active, c.record)
		if c.record.Uses.Load() == 0 && c.record.Kind == "http" {
			t.closedUnused++
			if len(t.examples) < 32 {
				t.examples = append(t.examples, connectionSummary(c.record))
			}
		}
	})
	return err
}
func connectionSummary(r *connectionRecord) connectionExample {
	return connectionExample{r.Port, r.Kind, time.Since(r.Created).Milliseconds(), r.Uses.Load(), r.Written.Load(), r.Read.Load()}
}
func (t *connectionTracker) trace() *httptrace.ClientTrace {
	return &httptrace.ClientTrace{GotConn: func(info httptrace.GotConnInfo) {
		if c, ok := info.Conn.(*trackedConnection); ok {
			c.record.Uses.Add(1)
		}
	}}
}
func (t *connectionTracker) snapshot() map[string]any {
	t.Lock()
	defer t.Unlock()
	activeUnused := []connectionExample{}
	for r := range t.active {
		if r.Kind == "http" && r.Uses.Load() == 0 && len(activeUnused) < 32 {
			activeUnused = append(activeUnused, connectionSummary(r))
		}
	}
	return map[string]any{"opened": t.opened, "peak_active": t.peakActive, "active_at_report": len(t.active), "closed_unused_http": t.closedUnused, "closed_unused_examples": t.examples, "active_unused_examples": activeUnused}
}
