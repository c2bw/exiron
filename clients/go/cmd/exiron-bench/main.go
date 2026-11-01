// Command exiron-bench exercises a dedicated loopback benchmark server only.
// Run through benchmarks/network.exs, which supplies the isolated fixture.
package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type message struct {
	Type string `json:"msgtype"`
	ID   string `json:"req_id"`
	Data string `json:"data"`
}
type frame struct {
	Type     string    `json:"type"`
	Delivery string    `json:"delivery_id"`
	Messages []message `json:"messages"`
	Requests []message `json:"requests"`
}
type outcomes struct {
	Unavailable map[string]int `json:"unavailable_by_hook"`
	Overloaded  int            `json:"overloaded"`
}

type stats struct {
	sync.Mutex
	starts                                                            map[int]time.Time
	done                                                              map[int]bool
	latencies                                                         []float64
	lag                                                               []float64
	errors                                                            map[string]int
	offered, injected, dropped, duplicate, media, retries, reconnects int
}
type bench struct {
	url, control                      string
	hooks, rate, duration, mediaBytes int
	faults                            bool
	http                              *http.Client
	s                                 stats
	connections                       connectionTracker
	httpIdleMS                        int
}

func main() {
	b := &bench{}
	flag.StringVar(&b.url, "url", "", "isolated server URL")
	flag.IntVar(&b.hooks, "hooks", 24, "concurrent hooks")
	flag.IntVar(&b.rate, "rate", 100, "fixed offered requests per second")
	flag.IntVar(&b.duration, "duration", 60, "offered-load seconds")
	flag.IntVar(&b.mediaBytes, "media-bytes", 1048576, "expected media bytes")
	flag.IntVar(&b.httpIdleMS, "http-idle-ms", 30000, "HTTP idle connection timeout (zero preserves baseline unlimited retention)")
	flag.BoolVar(&b.faults, "faults", true, "slow clients and reconnects")
	flag.Parse()
	b.control = os.Getenv("EXIRON_BENCH_CONTROL")
	parsed, parseErr := url.Parse(b.url)
	if parseErr != nil || parsed.Scheme != "http" || parsed.Hostname() != "127.0.0.1" || parsed.User != nil || b.control == "" || b.hooks < 1 || b.rate < 1 || b.duration < 1 || b.httpIdleMS < 0 {
		panic("use the isolated benchmarks/network.exs launcher")
	}
	b.http = &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{MaxIdleConns: 128, MaxIdleConnsPerHost: 64, DialContext: b.connections.dial("http"), IdleConnTimeout: time.Duration(b.httpIdleMS) * time.Millisecond}}
	defer b.http.CloseIdleConnections()
	b.s = stats{starts: map[int]time.Time{}, done: map[int]bool{}, errors: map[string]int{}}
	ctx, cancel := context.WithCancel(context.Background())
	var clients sync.WaitGroup
	ready := make(chan struct{}, b.hooks)
	for hook := 1; hook <= b.hooks; hook++ {
		clients.Add(1)
		go func(h int) {
			defer clients.Done()
			if h%2 == 0 {
				b.socket(ctx, h, ready)
			} else {
				b.poll(ctx, h, ready)
			}
		}(hook)
	}
	for i := 0; i < b.hooks; i++ {
		select {
		case <-ready:
		case <-time.After(15 * time.Second):
			panic("client startup timed out")
		}
	}
	clients.Add(1)
	go func() { defer clients.Done(); b.monitor(ctx) }()
	started := time.Now().Add(50 * time.Millisecond)
	sem := make(chan struct{}, 64)
	var injections sync.WaitGroup
	total := b.rate * b.duration
	for id := 1; id <= total; id++ {
		scheduled := started.Add(time.Duration(id-1) * time.Second / time.Duration(b.rate))
		if delay := time.Until(scheduled); delay > 0 {
			time.Sleep(delay)
		}
		b.s.Lock()
		b.s.offered++
		b.s.starts[id] = scheduled
		b.s.lag = append(b.s.lag, float64(time.Since(scheduled).Microseconds())/1000)
		b.s.Unlock()
		select {
		case sem <- struct{}{}:
			injections.Add(1)
			go func(n int) {
				defer injections.Done()
				defer func() { <-sem }()
				hook := (n-1)%b.hooks + 1
				code, _, err := b.request(ctx, "POST", "/__bench/ingress", b.control, map[string]any{"hook": hook, "id": strconv.Itoa(n), "media": n%19 == 0 && b.mediaBytes > 0})
				b.s.Lock()
				defer b.s.Unlock()
				if err != nil || code != 200 {
					b.s.errors[fmt.Sprintf("ingress_%d", code)]++
				} else {
					b.s.injected++
				}
			}(id)
		default:
			b.s.Lock()
			b.s.dropped++
			b.s.Unlock()
		}
	}
	injections.Wait()
	rejected := outcomes{}
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		b.s.Lock()
		done := len(b.s.done)
		injected := b.s.injected
		b.s.Unlock()
		code, raw, err := b.request(ctx, "GET", "/__bench/outcomes", b.control, nil)
		if err != nil || code != 200 || json.Unmarshal(raw, &rejected) != nil {
			b.failure("outcome_accounting")
			break
		}
		unavailable := 0
		for _, count := range rejected.Unavailable {
			unavailable += count
		}
		if done+unavailable >= injected {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	elapsed := time.Since(started)
	cancel()
	clients.Wait()
	b.s.Lock()
	defer b.s.Unlock()
	missingByHook := map[string]int{}
	for id := 1; id <= total; id++ {
		if !b.s.done[id] {
			missingByHook[strconv.Itoa((id-1)%b.hooks+1)]++
		}
	}
	accounted := len(b.s.errors) == 0 && b.s.dropped == 0 && rejected.Overloaded == 0
	for hook, count := range missingByHook {
		if rejected.Unavailable[hook] != count {
			accounted = false
		}
	}
	for hook, count := range rejected.Unavailable {
		if missingByHook[hook] != count {
			accounted = false
		}
	}
	report := map[string]any{
		"transport_connections": b.connections.snapshot(), "http_idle_timeout_ms": b.httpIdleMS,
		"unavailable_by_hook": rejected.Unavailable, "missing_by_hook": missingByHook, "overloaded": rejected.Overloaded,
		"all_offers_completed": len(b.s.done) == total, "all_offers_accounted_for": accounted,
		"hooks": b.hooks, "offered_rate": b.rate, "duration_seconds": b.duration, "faults": b.faults, "media_bytes": b.mediaBytes,
		"offered": b.s.offered, "injected": b.s.injected, "completed": len(b.s.done), "generator_drops": b.s.dropped, "errors": b.s.errors,
		"duplicates_suppressed": b.s.duplicate, "listen_media_received": b.s.media, "response_retries": b.s.retries, "forced_reconnects": b.s.reconnects,
		"completion_ms": percentiles(b.s.latencies), "generator_schedule_lag_ms": percentiles(b.s.lag), "elapsed_with_drain_seconds": elapsed.Seconds(),
		"completed_per_second_including_drain": float64(len(b.s.done)) / elapsed.Seconds(),
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(report); err != nil {
		panic(err)
	}
	if !accounted {
		os.Exit(1)
	}
}

func (b *bench) request(ctx context.Context, method, path, token string, body any) (int, []byte, error) {
	var data []byte
	if body != nil {
		var err error
		data, err = json.Marshal(body)
		if err != nil {
			return 0, nil, err
		}
	}
	req, err := http.NewRequestWithContext(ctx, method, b.url+path, bytes.NewReader(data))
	if err != nil {
		return 0, nil, err
	}
	req = req.WithContext(httptrace.WithClientTrace(req.Context(), b.connections.trace()))
	req.Header.Set("Authorization", "Bearer "+token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := b.http.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024*1024))
	return resp.StatusCode, raw, err
}
func (b *bench) failure(key string) { b.s.Lock(); b.s.errors[key]++; b.s.Unlock() }
func pause(ctx context.Context, d time.Duration) bool {
	select {
	case <-ctx.Done():
		return false
	case <-time.After(d):
		return true
	}
}
func token(h int) string { return fmt.Sprintf("token-%d", h) }
func (b *bench) handle(ctx context.Context, h int, items []message) bool {
	for _, m := range items {
		data, err := base64.StdEncoding.DecodeString(m.Data)
		if err != nil {
			b.failure("bad_base64")
			return false
		}
		if m.Type == "listen" {
			if len(data) != b.mediaBytes || !bytes.Equal(data, bytes.Repeat([]byte{42}, b.mediaBytes)) {
				b.failure("bad_media")
				return false
			}
			b.s.Lock()
			b.s.media++
			b.s.Unlock()
			continue
		}
		id, err := strconv.Atoi(strings.TrimPrefix(string(data), "/work "))
		if err != nil {
			b.failure("bad_request_marker")
			return false
		}
		b.s.Lock()
		seen := b.s.done[id]
		if seen {
			b.s.duplicate++
		}
		start, known := b.s.starts[id]
		b.s.Unlock()
		if !known || (id-1)%b.hooks+1 != h {
			b.failure("unknown_request_marker")
			return false
		}
		if seen {
			continue
		}
		if b.faults && h%8 == 0 && !pause(ctx, 100*time.Millisecond) {
			return false
		}
		success := false
		for attempt := 0; attempt < 3; attempt++ {
			code, raw, err := b.request(ctx, "POST", "/api/responses", token(h), map[string]any{"req_id": m.ID, "datatype": "text", "data": base64.StdEncoding.EncodeToString([]byte(strconv.Itoa(id)))})
			if ctx.Err() != nil {
				return false
			}
			if err == nil && code == 200 {
				success = true
				break
			}
			// Only the fixture's explicit pre-delivery failure is safe to retry.
			var descriptor struct {
				Code string `json:"code"`
			}
			_ = json.Unmarshal(raw, &descriptor)
			if err != nil || descriptor.Code != "send_unavailable" {
				b.failure(fmt.Sprintf("response_%d_%s", code, descriptor.Code))
				return false
			}
			b.s.Lock()
			b.s.retries++
			b.s.Unlock()
			if !pause(ctx, 50*time.Millisecond) {
				return false
			}
		}
		if !success {
			b.failure("response_retry_exhausted")
			return false
		}
		b.s.Lock()
		b.s.done[id] = true
		b.s.latencies = append(b.s.latencies, float64(time.Since(start).Microseconds())/1000)
		b.s.Unlock()
	}
	return true
}
func (b *bench) poll(ctx context.Context, h int, ready chan<- struct{}) {
	ack := ""
	started := false
	batches := 0
	for ctx.Err() == nil {
		path := fmt.Sprintf("/api/requests?client_id=bench-%d&listen=true&delivery_mode=explicit&delivery_ack=%s", h, ack)
		code, raw, err := b.request(ctx, "GET", path, token(h), nil)
		if ctx.Err() != nil {
			return
		}
		if err != nil || code != 200 {
			b.failure(fmt.Sprintf("poll_%d", code))
			return
		}
		var f frame
		if json.Unmarshal(raw, &f) != nil {
			b.failure("poll_decode")
			return
		}
		if !started {
			ready <- struct{}{}
			started = true
		}
		if !b.handle(ctx, h, f.Requests) {
			return
		}
		ack = f.Delivery
		if len(f.Requests) > 0 {
			batches++
			if b.faults && batches%10 == 0 {
				ack = ""
			}
		}
		if !pause(ctx, 200*time.Millisecond) {
			return
		}
	}
}
func (b *bench) socket(ctx context.Context, h int, ready chan<- struct{}) {
	started := false
	batches := 0
	for ctx.Err() == nil {
		url := strings.Replace(b.url, "http://", "ws://", 1) + fmt.Sprintf("/api/socket?client_id=bench-%d&listen=true", h)
		dialer := *websocket.DefaultDialer
		dialer.NetDialContext = b.connections.dial("websocket")
		c, resp, err := dialer.DialContext(ctx, url, http.Header{"Authorization": []string{"Bearer " + token(h)}})
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			if resp != nil && resp.StatusCode == 409 {
				if !pause(ctx, 100*time.Millisecond) {
					return
				}
				continue
			}
			b.failure("socket_connect")
			return
		}
		c.SetReadLimit(64 * 1024 * 1024)
		closed := make(chan struct{})
		go func() {
			select {
			case <-ctx.Done():
				_ = c.Close()
			case <-closed:
			}
		}()
		reconnect := false
		for ctx.Err() == nil {
			var f frame
			err = c.ReadJSON(&f)
			if err != nil {
				if ctx.Err() == nil {
					b.failure("socket_read")
				}
				break
			}
			if f.Type == "connected" {
				if !started {
					ready <- struct{}{}
					started = true
				}
				continue
			}
			if f.Type != "messages" {
				b.failure("socket_protocol")
				break
			}
			if len(f.Messages) == 0 {
				continue
			}
			batches++
			if b.faults && batches%20 == 0 {
				b.s.Lock()
				b.s.reconnects++
				b.s.Unlock()
				reconnect = true
				break
			}
			if !b.handle(ctx, h, f.Messages) {
				break
			}
			if err = c.WriteJSON(map[string]string{"type": "ack", "delivery_id": f.Delivery}); err != nil {
				if ctx.Err() == nil {
					b.failure("socket_ack")
				}
				break
			}
		}
		_ = c.Close()
		close(closed)
		if !reconnect {
			return
		}
		if !pause(ctx, 100*time.Millisecond) {
			return
		}
	}
}
func (b *bench) monitor(ctx context.Context) {
	for pause(ctx, 500*time.Millisecond) {
		code, _, err := b.request(ctx, "GET", "/api/status", token(1), nil)
		if ctx.Err() != nil {
			return
		}
		if err != nil || code != 200 {
			b.failure(fmt.Sprintf("status_%d", code))
			return
		}
	}
}
func percentiles(values []float64) map[string]float64 {
	sorted := append([]float64(nil), values...)
	sort.Float64s(sorted)
	out := map[string]float64{}
	for name, p := range map[string]float64{"p50": .5, "p95": .95, "p99": .99} {
		if len(sorted) == 0 {
			out[name] = 0
		} else {
			out[name] = sorted[int(math.Ceil(float64(len(sorted))*p))-1]
		}
	}
	return out
}
