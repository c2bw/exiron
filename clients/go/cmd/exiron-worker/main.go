// Command exiron-worker is an interactive reference worker, not a deployment manager.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	exiron "github.com/c2bw/exiron/clients/go"
)

type worker struct {
	client     *exiron.Client
	quarantine *exiron.Quarantine
	mode       string
	feedback   bool
	runner     *exiron.Runner
	done       chan error
	cancel     context.CancelFunc
	running    bool // Owned by the console goroutine.
	notices    chan exiron.QuarantineEntry
}

func main() {
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "Reference worker: EXIRON_HOOK_TOKEN is required. Optional EXIRON_OBSERVE_REQUESTS=true|false, EXIRON_FEEDBACK=true|false, EXIRON_BASE_URL, EXIRON_CLIENT_ID, EXIRON_TRANSPORT=http|websocket, EXIRON_REPLY_MODE=one-shot|stream. See docs/managed-worker-examples.md.")
	}
	flag.Parse()
	if flag.NArg() != 0 {
		flag.Usage()
		os.Exit(2)
	}
	logger := log.New(os.Stderr, "worker: ", log.LstdFlags)
	cfg, mode, err := configuration(os.Getenv)
	if err != nil {
		logger.Print(err)
		os.Exit(2)
	}
	feedback, err := feedbackEnabled(os.Getenv)
	if err != nil {
		logger.Print(err)
		os.Exit(2)
	}
	client, err := exiron.NewClient(cfg)
	if err != nil {
		logger.Print("invalid client configuration; check the server URL and client ID")
		os.Exit(2)
	}
	w := newWorker(client, mode)
	w.feedback = feedback
	signals := make(chan os.Signal, 2)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(signals)
	if err := console(w, os.Stdin, os.Stdout, signals, logger); err != nil {
		logger.Print("worker stopped with an error; review status and delivery diagnostics")
		os.Exit(1)
	}
}

func configuration(env func(string) string) (exiron.Config, string, error) {
	cfg := exiron.Config{BaseURL: env("EXIRON_BASE_URL"), Token: env("EXIRON_HOOK_TOKEN"), ClientID: env("EXIRON_CLIENT_ID"), HTTPClient: &http.Client{Timeout: 10 * time.Second}}
	if strings.TrimSpace(cfg.Token) == "" {
		return cfg, "", errors.New("EXIRON_HOOK_TOKEN is required")
	}
	switch env("EXIRON_OBSERVE_REQUESTS") {
	case "", "false":
	case "true":
		cfg.OnRequest = func(event exiron.RequestEvent) { log.Printf("api request: %+v", event) }
	default:
		return cfg, "", errors.New("EXIRON_OBSERVE_REQUESTS must be true or false")
	}
	if cfg.BaseURL == "" {
		cfg.BaseURL = "http://localhost:4000"
	}
	switch env("EXIRON_TRANSPORT") {
	case "", "websocket":
		cfg.Transport = exiron.TransportWebSocket
	case "http":
		cfg.Transport = exiron.TransportHTTP
	default:
		return cfg, "", errors.New("EXIRON_TRANSPORT must be http or websocket")
	}
	mode := env("EXIRON_REPLY_MODE")
	if mode == "" {
		mode = "one-shot"
	}
	if mode != "one-shot" && mode != "stream" {
		return cfg, "", errors.New("EXIRON_REPLY_MODE must be one-shot or stream")
	}
	return cfg, mode, nil
}
func feedbackEnabled(env func(string) string) (bool, error) {
	switch env("EXIRON_FEEDBACK") {
	case "", "false":
		return false, nil
	case "true":
		return true, nil
	default:
		return false, errors.New("EXIRON_FEEDBACK must be true or false")
	}
}
func newWorker(client *exiron.Client, mode string) *worker {
	store, _ := exiron.NewQuarantine(exiron.QuarantineOptions{MaxMessages: 100, MaxBytes: 8 * 1024 * 1024})
	return &worker{client: client, mode: mode, quarantine: store, notices: make(chan exiron.QuarantineEntry, 16)}
}
func (w *worker) start() error {
	if w.running {
		return errors.New("worker is already running")
	}
	if w.feedback {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		protocol, err := w.client.Capabilities(ctx)
		if err != nil {
			return err
		}
		if !protocol.Supports("inline_keyboards") || !protocol.Supports("callback_queries") {
			return errors.New("feedback requires inline_keyboards and callback_queries")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	w.cancel = cancel
	w.runner = w.client.NewRunner(exiron.RunnerOptions{
		Handler: w.handle, GracefulShutdown: true, RuntimeReporting: true,
		HandlerConcurrency: 2, HandlerOrderByChat: true, HandlerTimeout: 30 * time.Second,
		CooperativeCancellation: true, ReportHandlerFailures: true,
		HandlerMaxAttempts:   1, // Never replay a send/partial stream automatically.
		HandlerFailurePolicy: exiron.HandlerFailureQuarantine, Quarantine: w.quarantine,
		OnQuarantined: func(_ context.Context, entry exiron.QuarantineEntry) {
			// Notify without blocking a handler or logging payload/error contents.
			select {
			case w.notices <- entry:
			default:
			}
		},
	})
	done := make(chan error, 1)
	runner := w.runner
	w.done = done
	w.running = true
	go func() { done <- runner.Run(ctx) }()
	return nil
}
func (w *worker) drain() error {
	if !w.running {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	err := w.runner.Drain(ctx)
	// Cancel only after attempting drain. These example handlers and producers
	// observe context cancellation; wait for their actual exit before restarting.
	w.cancel()
	result := <-w.done
	w.done = nil
	w.running = false
	if err != nil {
		return err
	}
	return result
}
func (w *worker) handle(ctx context.Context, m exiron.Message) error {
	if m.Msgtype != "request" {
		return nil
	}
	if w.feedback {
		if _, ok := exiron.ParseFeedback(m); ok {
			_, err := w.client.RespondWithOptions(ctx, m.ReqID, exiron.DatatypeText, []byte("Thanks for the feedback."), exiron.ResponseOptions{ParseMode: "plain"})
			return err
		}
	}
	if m.Datatype != exiron.DatatypeText {
		return errors.New("this example handles text requests only")
	}
	words := strings.Fields(m.Text())
	if len(words) > 0 && words[len(words)-1] == "/worker-fail" {
		return errors.New("example failure before sending")
	}
	text := []rune(m.Text())
	if len(text) > 1024 {
		text = text[:1024]
	}
	prefix := "Received: "
	if m.FollowupReqID != nil {
		prefix = "Follow-up received: "
	}
	answer := prefix + string(text)
	options, err := w.replyOptions()
	if err != nil {
		return err
	}
	if w.mode == "one-shot" {
		_, err := w.client.RespondWithOptions(ctx, m.ReqID, exiron.DatatypeText, []byte(answer), options)
		return err
	}
	return w.stream(ctx, m.ReqID, answer)
}
func (w *worker) stream(ctx context.Context, id, answer string) error {
	producerCtx, stop := context.WithCancel(ctx)
	chunks := make(chan string)
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		defer close(chunks)
		runes := []rune(answer)
		for len(runes) > 0 {
			n := min(128, len(runes))
			part := string(runes[:n])
			runes = runes[n:]
			timer := time.NewTimer(150 * time.Millisecond)
			select {
			case <-producerCtx.Done():
				timer.Stop()
				return
			case <-timer.C:
			}
			select {
			case <-producerCtx.Done():
				return
			case chunks <- part:
			}
		}
	}()
	defer func() { stop(); <-finished }() // No detached producer after a failed stream.
	options, err := w.replyOptions()
	if err != nil {
		return err
	}
	_, err = w.client.StreamText(ctx, id, chunks, exiron.StreamOptions{Interval: 300 * time.Millisecond, ResponseOptions: options})
	return err
}
func (w *worker) replyOptions() (exiron.ResponseOptions, error) {
	options := exiron.ResponseOptions{ParseMode: "plain"}
	if w.feedback {
		keyboard, err := exiron.WithFeedback(nil)
		if err != nil {
			return options, err
		}
		options.InlineKeyboard = &keyboard
	}
	return options, nil
}
func (w *worker) recoverText(id uint64, text string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	// Independent context: recovery still works after the managed runner drains.
	return w.quarantine.Recover(ctx, id, func(ctx context.Context, m exiron.Message) error {
		if m.ReqID == "" || m.Msgtype != "request" {
			return errors.New("entry has no routed request")
		}
		_, err := w.client.RespondWithOptions(ctx, m.ReqID, exiron.DatatypeText, []byte(text), exiron.ResponseOptions{ParseMode: "plain"})
		return err
	})
}
func console(w *worker, input io.Reader, output io.Writer, signals <-chan os.Signal, logger *log.Logger) error {
	if err := w.start(); err != nil {
		return err
	}
	defer func() {
		if w.running {
			_ = w.drain()
		}
		logger.Printf("exiting with %d in-memory quarantine entries", w.quarantine.Stats().Count)
	}()
	scanCtx, stopScan := context.WithCancel(context.Background())
	defer stopScan()
	commands := readCommands(scanCtx, input)
	fmt.Fprintln(output, "Commands: status | quarantine | recover ID REPLACEMENT_TEXT | resolve ID | drain | restart | quit")
	for {
		select {
		case <-signals:
			return w.drain()
		case err := <-w.done:
			w.cancel()
			w.done = nil
			w.running = false
			logger.Printf("managed loop stopped; category=%s; inspect quarantine before restart", exiron.SummarizeError(err).Kind)
			if commands == nil {
				return err
			}
		case entry := <-w.notices:
			logger.Printf("quarantined entry=%d; use quarantine to inspect metadata", entry.ID)
		case line, ok := <-commands:
			if !ok {
				commands = nil
				if !w.running {
					return errors.New("no active worker or recovery console")
				}
				continue
			}
			fields := strings.Fields(line)
			if len(fields) == 0 {
				continue
			}
			switch fields[0] {
			case "status":
				writeJSON(output, w.runner.Status())
			case "quarantine":
				writeJSON(output, w.quarantine.Entries())
			case "drain":
				if w.drain() != nil {
					logger.Print("drain failed; inspect status before restart")
				} else {
					fmt.Fprintln(output, "Drained. Quarantine retained; recover, resolve, restart, or quit.")
				}
			case "restart":
				if w.start() != nil {
					fmt.Fprintln(output, "Worker already running.")
				}
			case "recover", "resolve":
				id, err := entryID(fields)
				if err != nil || (fields[0] == "recover" && len(fields) < 3) {
					fmt.Fprintln(output, "Use recover ID REPLACEMENT_TEXT or resolve ID")
					continue
				}
				if fields[0] == "recover" {
					err = w.recoverText(id, strings.Join(fields[2:], " "))
				} else {
					// Explicit operator acknowledgement: already resolved externally; no send.
					err = w.quarantine.Recover(context.Background(), id, func(context.Context, exiron.Message) error { return nil })
				}
				if err != nil {
					fmt.Fprintln(output, "Recovery failed; entry retained unless it no longer exists. Review expiry and delivery diagnostics.")
				} else {
					fmt.Fprintln(output, "Entry resolved.")
				}
			case "quit":
				return w.drain()
			default:
				fmt.Fprintln(output, "Use status, quarantine, recover ID TEXT, resolve ID, drain, restart, or quit.")
			}
		}
	}
}
func entryID(fields []string) (uint64, error) {
	if len(fields) < 2 {
		return 0, errors.New("missing ID")
	}
	return strconv.ParseUint(fields[1], 10, 64)
}
func writeJSON(output io.Writer, value any) { _ = json.NewEncoder(output).Encode(value) }
func readCommands(ctx context.Context, input io.Reader) <-chan string {
	lines := make(chan string)
	go func() {
		defer close(lines)
		scanner := bufio.NewScanner(input)
		scanner.Buffer(make([]byte, 4096), 64*1024)
		for scanner.Scan() {
			select {
			case lines <- scanner.Text():
			case <-ctx.Done():
				return
			}
		}
	}()
	return lines
}
