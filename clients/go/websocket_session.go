package exiron

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type webSocketSession struct {
	runner      *Runner
	coordinator *runnerCoordinator
}

func newWebSocketSession(runner *Runner, coordinator *runnerCoordinator) *webSocketSession {
	return &webSocketSession{runner: runner, coordinator: coordinator}
}

func (s *webSocketSession) run(ctx context.Context) error {
	conn, err := s.dialWebSocket(ctx)
	if err != nil {
		return err
	}

	err = s.readWebSocket(ctx, conn)
	_ = conn.Close()
	return err
}

func (s *webSocketSession) dialWebSocket(ctx context.Context) (*websocket.Conn, error) {
	socketURL, err := s.runner.client.socketURL()
	if err != nil {
		return nil, err
	}
	headers := http.Header{"authorization": []string{"Bearer " + s.runner.client.token}}
	headers.Set("x-exiron-sdk", "go")
	headers.Set("x-exiron-sdk-version", Version())

	conn, resp, err := s.runner.client.websocketDialer().DialContext(ctx, socketURL, headers)
	if err == nil {
		return conn, nil
	}
	if resp != nil && resp.Body != nil {
		defer resp.Body.Close()
		body, readErr := readResponseBody(resp.Body, s.runner.client.maxResponseBytes)
		if readErr != nil {
			return nil, readErr
		}
		if resp.StatusCode > 0 {
			apiErr := responseError(resp.StatusCode, body, resp.Header, time.Now())
			apiErr.retryableConnection = resp.StatusCode == http.StatusTooManyRequests
			return nil, apiErr
		}
	}
	return nil, transportError(err)
}

func (c *Client) websocketDialer() *websocket.Dialer {
	dialer := *websocket.DefaultDialer

	if transport, ok := c.httpClient.Transport.(*http.Transport); ok {
		dialer.Proxy = transport.Proxy
		dialer.NetDialContext = transport.DialContext
		dialer.TLSClientConfig = transport.TLSClientConfig
	}

	return &dialer
}

func (s *webSocketSession) readWebSocket(ctx context.Context, conn *websocket.Conn) error {
	runner := s.runner
	coordinator := s.coordinator
	conn.SetReadLimit(runner.client.maxResponseBytes)

	workerCtx := ctx
	stopWorker := func() {}
	if runner.cooperativeCancellation || runner.gracefulShutdown {
		workerCtx, stopWorker = context.WithCancel(ctx)
	}
	done := make(chan struct{})
	deliveryQueue := make(chan socketDelivery, 64)
	workerErr := make(chan error, 1)
	workerDone := make(chan struct{})
	writeMu := &sync.Mutex{}
	defer func() {
		stopWorker()
		close(done)
		// Close the connection before waiting for the delivery worker. The worker
		// may be blocked writing an acknowledgement to a peer that stopped
		// reading, and closing the connection is what releases that write.
		_ = conn.Close()
		close(deliveryQueue)
		<-workerDone
	}()
	go runner.pingWebSocket(ctx, conn, done, writeMu)
	go func() {
		defer close(workerDone)
		runner.handleWebSocketDeliveries(workerCtx, conn, deliveryQueue, workerErr, writeMu)
	}()
	go closeWebSocketOnContextDone(ctx, conn, done)

	if runner.gracefulShutdown {
		go func() {
			select {
			case <-runner.lifetime().wake:
			case <-done:
				return
			}
			last, claimed := runner.claimIdleRetirement()
			if claimed {
				err := errRunnerDrained
				if last != "" {
					if retireErr := runner.retireDelivery(ctx, last); retireErr != nil {
						err = retireErr
					}
				}
				reportWorkerError(workerErr, err)
				_ = conn.Close()
			}
		}()
	}

	for {
		select {
		case err := <-workerErr:
			return err
		default:
		}

		_ = conn.SetReadDeadline(time.Now().Add(runner.disconnectTimeout))
		var frame wireSocketFrame
		if err := conn.ReadJSON(&frame); err != nil {
			select {
			case workerErr := <-workerErr:
				return workerErr
			default:
			}
			if isReplacedWebSocketClose(err) {
				return replacedError(err)
			}
			if errors.Is(err, websocket.ErrReadLimit) {
				return invalidResponse("websocket frame exceeds configured size limit", err)
			}
			return transportError(err)
		}
		_ = conn.SetReadDeadline(time.Time{})
		switch frame.Type {
		case socketFrameTypeConnected:
			if runner.runtimeReporting && (len(frame.RuntimeRef) < 1 || len(frame.RuntimeRef) > 128) {
				return invalidResponse("runtime reporting requires a session reference", nil)
			}
			runner.setRuntimeRef(frame.RuntimeRef)
			if s.runner.onProtocol != nil {
				s.runner.onProtocol(ctx, ProtocolInfo{Version: frame.ProtocolVersion, Capabilities: frame.Capabilities})
			}
			coordinator.connect(ctx)
		case socketFrameTypeMessages:
			if !runner.acceptSocketBatch() {
				continue
			}
			decoded, err := decodeMessages(frame.Messages)
			if err != nil {
				return err
			}
			if runner.gracefulShutdown && len(decoded) > 0 && frame.DeliveryID == "" {
				return invalidResponse("graceful shutdown requires a batch identity", nil)
			}
			delivery := socketDelivery{id: frame.DeliveryID, messages: decoded}
			select {
			case err := <-workerErr:
				return err
			case deliveryQueue <- delivery:
			case <-ctx.Done():
				return ctx.Err()
			}
		case socketFrameTypeError:
			return socketFrameError(frame)
		}
	}
}

func closeWebSocketOnContextDone(ctx context.Context, conn *websocket.Conn, done <-chan struct{}) {
	select {
	case <-ctx.Done():
		_ = conn.Close()
	case <-done:
	}
}

func (r *Runner) handleWebSocketDeliveries(ctx context.Context, conn *websocket.Conn, deliveries <-chan socketDelivery, workerErr chan<- error, writeMu *sync.Mutex) {
	for {
		select {
		case <-ctx.Done():
			return
		case delivery, ok := <-deliveries:
			if !ok {
				return
			}
			if err := r.handleBatch(context.WithValue(ctx, handlerDeliveryKey{}, delivery.id), delivery.messages); err != nil {
				reportWorkerError(workerErr, err)
				_ = conn.Close()
				return
			}
			if ctx.Err() != nil {
				return
			}
			if r.socketBatchComplete(delivery.id) {
				err := errRunnerDrained
				if delivery.id != "" {
					if retireErr := r.retireDelivery(ctx, delivery.id); retireErr != nil {
						err = retireErr
					}
				}
				reportWorkerError(workerErr, err)
				_ = conn.Close()
				return
			}
			if r.draining() {
				return
			}
			if delivery.id != "" {
				if err := writeWebSocketJSON(conn, writeMu, r.disconnectTimeout, map[string]string{
					"type":        socketFrameTypeAck,
					"delivery_id": delivery.id,
				}); err != nil {
					if r.draining() {
						return
					}
					reportWorkerError(workerErr, transportError(err))
					_ = conn.Close()
					return
				}
			}
		}
	}
}

func (r *Runner) pingWebSocket(ctx context.Context, conn *websocket.Conn, done <-chan struct{}, writeMu *sync.Mutex) {
	interval := r.disconnectTimeout / 2
	if interval <= 0 {
		interval = time.Second
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-done:
			return
		case <-ticker.C:
			_ = writeWebSocketJSON(
				conn,
				writeMu,
				r.disconnectTimeout,
				map[string]string{"type": socketFrameTypePing},
			)
		}
	}
}

func writeWebSocketJSON(conn *websocket.Conn, writeMu *sync.Mutex, timeout time.Duration, value any) error {
	writeMu.Lock()
	defer writeMu.Unlock()
	if err := conn.SetWriteDeadline(time.Now().Add(timeout)); err != nil {
		return err
	}
	return conn.WriteJSON(value)
}

func reportWorkerError(workerErr chan<- error, err error) {
	select {
	case workerErr <- err:
	default:
	}
}
