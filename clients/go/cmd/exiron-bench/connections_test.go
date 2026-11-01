package main

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httptrace"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestTracksUnusedAndUsedConnections(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("ok")) }))
	defer server.Close()
	tracker := &connectionTracker{}
	address := strings.TrimPrefix(server.URL, "http://")
	unused, err := tracker.dial("http")(context.Background(), "tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	if err := unused.Close(); err != nil {
		t.Fatal(err)
	}
	snapshot := tracker.snapshot()
	if snapshot["closed_unused_http"] != 1 {
		t.Fatalf("unused connection not tracked: %v", snapshot)
	}
	examples := snapshot["closed_unused_examples"].([]connectionExample)
	if len(examples) != 1 || examples[0].Written != 0 || examples[0].Uses != 0 {
		t.Fatalf("bad unused connection summary: %v", examples)
	}

	client := &http.Client{Transport: &http.Transport{DialContext: tracker.dial("http")}}
	req, _ := http.NewRequest("GET", server.URL, nil)
	req = req.WithContext(httptrace.WithClientTrace(req.Context(), tracker.trace()))
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
	client.CloseIdleConnections()
	if tracker.snapshot()["closed_unused_http"] != 1 {
		t.Fatal("used connection was counted as unused")
	}
}

// Force a dial to finish after a different connection becomes reusable. net/http
// can retain that late connection without ever assigning it an HTTP request.
func TestFiniteIdleTimeoutClosesAnUnusedSpeculativeDial(t *testing.T) {
	var requests atomic.Int64
	firstStarted := make(chan struct{})
	releaseFirst := make(chan struct{})
	secondDialStarted := make(chan struct{})
	releaseSecondDial := make(chan struct{})
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if requests.Add(1) == 1 {
			close(firstStarted)
			select {
			case <-releaseFirst:
			case <-r.Context().Done():
				return
			}
		}
		_, _ = w.Write([]byte("ok"))
	}))
	defer server.Close()
	// Release gates even if an assertion fails, so cleanup cannot hang.
	defer func() {
		select {
		case <-releaseFirst:
		default:
			close(releaseFirst)
		}
		select {
		case <-releaseSecondDial:
		default:
			close(releaseSecondDial)
		}
	}()
	tracker := &connectionTracker{}
	var dials atomic.Int64
	transport := &http.Transport{IdleConnTimeout: 50 * time.Millisecond}
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		number := dials.Add(1)
		conn, err := tracker.dial("http")(ctx, network, address)
		if err != nil {
			return nil, err
		}
		if number == 2 {
			close(secondDialStarted)
			select {
			case <-releaseSecondDial:
			case <-ctx.Done():
				_ = conn.Close()
				return nil, ctx.Err()
			}
		}
		return conn, nil
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}
	request := func() error {
		req, _ := http.NewRequestWithContext(ctx, "GET", server.URL, nil)
		req = req.WithContext(httptrace.WithClientTrace(req.Context(), tracker.trace()))
		response, err := client.Do(req)
		if err != nil {
			return err
		}
		_, err = io.Copy(io.Discard, response.Body)
		_ = response.Body.Close()
		return err
	}
	firstDone := make(chan error, 1)
	go func() { firstDone <- request() }()
	select {
	case <-firstStarted:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	secondDone := make(chan error, 1)
	go func() { secondDone <- request() }()
	select {
	case <-secondDialStarted:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	close(releaseFirst)
	for _, done := range []chan error{firstDone, secondDone} {
		select {
		case err := <-done:
			if err != nil {
				t.Fatal(err)
			}
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
	}
	close(releaseSecondDial)
	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	for {
		snapshot := tracker.snapshot()
		if snapshot["closed_unused_http"].(int) > 0 {
			examples := snapshot["closed_unused_examples"].([]connectionExample)
			if examples[0].Written != 0 || examples[0].Uses != 0 {
				t.Fatalf("unexpected unused connection: %v", examples)
			}
			return
		}
		select {
		case <-ticker.C:
		case <-ctx.Done():
			t.Fatal("unused speculative connection was not closed")
		}
	}
}
