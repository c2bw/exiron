package exiron

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestRunnerReceivesWebSocketMessages(t *testing.T) {
	var upgrader websocket.Upgrader
	var handled []string
	protocols := make(chan ProtocolInfo, 1)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/socket" {
			t.Fatalf("request = %s %s, want GET /api/socket", r.Method, r.URL.Path)
		}
		assertAuthorization(t, r, "Bearer ai-token")
		if r.Header.Get("x-exiron-sdk") != "go" || r.Header.Get("x-exiron-sdk-version") != Version() {
			t.Error("SDK identity missing from WebSocket handshake")
		}
		if r.URL.Query().Get("client_id") != "runner" {
			t.Fatalf("client_id query = %q, want runner", r.URL.Query().Get("client_id"))
		}

		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Fatalf("upgrade: %v", err)
		}
		defer conn.Close()

		if err := conn.WriteMessage(websocket.TextMessage, contractFixture(t, "websocket_connected_frame.json")); err != nil {
			t.Fatalf("write connected: %v", err)
		}
		if err := conn.WriteMessage(websocket.TextMessage, contractFixture(t, "websocket_messages_frame.json")); err != nil {
			t.Fatalf("write messages: %v", err)
		}
	}))
	defer server.Close()

	client, err := NewClient(Config{
		BaseURL:  server.URL,
		Token:    "ai-token",
		ClientID: "runner",
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true,
		PollInterval: time.Millisecond,
		OnProtocol:   func(_ context.Context, protocol ProtocolInfo) { protocols <- protocol },
		Handler: func(_ context.Context, message Message) error {
			handled = append(handled, message.Text())
			cancel()
			return nil
		},
	})

	if err := runner.Run(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("Run error = %v, want context canceled", err)
	}
	if want := []string{"hello"}; !reflect.DeepEqual(handled, want) {
		t.Fatalf("handled = %v, want %v", handled, want)
	}
	protocol := <-protocols
	if protocol.Version != ProtocolVersion || !protocol.Supports("websocket") {
		t.Fatalf("protocol = %#v, want current websocket protocol", protocol)
	}
}

func TestRunnerAcknowledgesWebSocketDeliveryAfterHandling(t *testing.T) {
	var upgrader websocket.Upgrader
	handled := make(chan string, 1)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Fatalf("upgrade: %v", err)
		}
		defer conn.Close()

		if err := conn.WriteJSON(map[string]any{
			"type": "connected", "hook": "assistant", "client_id": "runner",
			"listen": false, "server_version": "0.1.0",
		}); err != nil {
			t.Fatalf("write connected: %v", err)
		}
		if err := conn.WriteJSON(map[string]any{
			"type": "messages", "delivery_id": "delivery-1",
			"messages": []map[string]any{
				{"msgtype": "request", "req_id": "req-1", "datatype": "text", "data": "aGVsbG8="},
			},
		}); err != nil {
			t.Fatalf("write messages: %v", err)
		}

		var acknowledgement wireSocketFrame
		if err := conn.ReadJSON(&acknowledgement); err != nil {
			t.Fatalf("read acknowledgement: %v", err)
		}
		if acknowledgement.Type != "ack" || acknowledgement.DeliveryID != "delivery-1" {
			t.Fatalf("acknowledgement = %#v, want delivery-1 ack", acknowledgement)
		}

		if err := conn.WriteJSON(map[string]string{"type": "error", "error": "stop"}); err != nil {
			t.Fatalf("write stop: %v", err)
		}
	}))
	defer server.Close()

	client, err := New(server.URL, WithToken("ai-token"), WithClientID("runner"))
	if err != nil {
		t.Fatalf("New returned error: %v", err)
	}

	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true,
		Handler: func(_ context.Context, message Message) error {
			handled <- message.Text()
			return nil
		},
	})

	err = runner.Run(context.Background())
	if apiErr := requireAPIError(t, err); apiErr.Message != "stop" {
		t.Fatalf("Run error = %#v, want stop", apiErr)
	}
	if got := <-handled; got != "hello" {
		t.Fatalf("handled = %q, want hello", got)
	}
}

func TestSocketFrameErrorDecodesSharedContractFixture(t *testing.T) {
	var frame wireSocketFrame
	if err := json.Unmarshal(contractFixture(t, "websocket_error_frame.json"), &frame); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}

	apiErr := requireAPIError(t, socketFrameError(frame))
	if apiErr.Reason != "hook_already_connected" || apiErr.RetryAfterMS != 12 {
		t.Fatalf("error = %#v, want hook already connected with retry hint", apiErr)
	}
}

func TestSocketURLPreservesBasePath(t *testing.T) {
	client, err := NewClient(Config{
		BaseURL:    "https://example.test/exiron/",
		ClientID:   "runner",
		ListenMode: ListenOn,
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	socketURL, err := client.socketURL()
	if err != nil {
		t.Fatalf("socketURL returned error: %v", err)
	}
	if socketURL != "wss://example.test/exiron/api/socket?client_id=runner&listen=true" {
		t.Fatalf("socketURL = %q", socketURL)
	}
}

func TestSocketURLUsesListenAllMode(t *testing.T) {
	client, err := NewClient(Config{
		BaseURL:    "https://example.test",
		ClientID:   "runner",
		ListenMode: ListenAll,
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	socketURL, err := client.socketURL()
	if err != nil {
		t.Fatalf("socketURL returned error: %v", err)
	}
	if socketURL != "wss://example.test/api/socket?client_id=runner&listen=all" {
		t.Fatalf("socketURL = %q", socketURL)
	}
}

func TestWebSocketDialerUsesHTTPClientProxy(t *testing.T) {
	var proxyCalled atomic.Bool
	proxyURL := "http://127.0.0.1:1"

	parsedProxyURL, err := url.Parse(proxyURL)
	if err != nil {
		t.Fatalf("parse proxy URL: %v", err)
	}

	client, err := NewClient(Config{
		BaseURL:  "http://example.test",
		Token:    "ai-token",
		ClientID: "runner",
		HTTPClient: &http.Client{
			Transport: &http.Transport{
				Proxy: func(r *http.Request) (*url.URL, error) {
					proxyCalled.Store(true)
					if r.URL.String() != "http://example.test/api/socket?client_id=runner&listen=false" {
						t.Fatalf("proxy request URL = %q", r.URL.String())
					}
					return parsedProxyURL, nil
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, Handler: func(context.Context, Message) error {
		return nil
	}})
	_, _ = newWebSocketSession(runner, nil).dialWebSocket(context.Background())

	if !proxyCalled.Load() {
		t.Fatal("websocket dialer did not use HTTP client proxy")
	}
}

func TestRunnerKeepsWebSocketDisconnectTimeoutWhenPollIntervalIsLong(t *testing.T) {
	client, err := NewClient(Config{
		BaseURL:  "http://exiron.test",
		ClientID: "runner",
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true,
		PollInterval:      2 * time.Second,
		DisconnectTimeout: time.Second,
		Handler: func(context.Context, Message) error {
			return nil
		},
	})

	if runner.disconnectTimeout != time.Second {
		t.Fatalf("disconnectTimeout = %v, want 1s", runner.disconnectTimeout)
	}
	if runner.pollTimeout != time.Nanosecond {
		t.Fatalf("pollTimeout = %v, want 1ns", runner.pollTimeout)
	}
}

func TestRunnerDoesNotTimeOutWebSocketWhileHandlingMessage(t *testing.T) {
	var upgrader websocket.Upgrader
	var handled atomic.Int32
	firstHandled := make(chan struct{})
	releaseHandler := make(chan struct{})

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Fatalf("upgrade: %v", err)
		}
		defer conn.Close()

		if err := conn.WriteJSON(map[string]any{
			"type":           "connected",
			"hook":           "assistant",
			"client_id":      "runner",
			"listen":         false,
			"server_version": "0.1.0",
		}); err != nil {
			t.Fatalf("write connected: %v", err)
		}
		if err := conn.WriteJSON(map[string]any{
			"type": "messages",
			"messages": []map[string]any{
				{"msgtype": "request", "req_id": "req-1", "datatype": "text", "data": "Zmlyc3Q="},
			},
		}); err != nil {
			t.Fatalf("write first messages: %v", err)
		}

		<-firstHandled
		time.Sleep(30 * time.Millisecond)

		if err := conn.WriteJSON(map[string]string{"type": "pong"}); err != nil {
			t.Fatalf("write pong: %v", err)
		}
		if err := conn.WriteJSON(map[string]any{
			"type": "messages",
			"messages": []map[string]any{
				{"msgtype": "request", "req_id": "req-2", "datatype": "text", "data": "c2Vjb25k"},
			},
		}); err != nil {
			t.Fatalf("write second messages: %v", err)
		}
		close(releaseHandler)
	}))
	defer server.Close()

	client, err := NewClient(Config{
		BaseURL:  server.URL,
		Token:    "ai-token",
		ClientID: "runner",
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true,
		PollInterval:      time.Millisecond,
		DisconnectTimeout: 100 * time.Millisecond,
		Handler: func(_ context.Context, message Message) error {
			switch handled.Add(1) {
			case 1:
				close(firstHandled)
				<-releaseHandler
			case 2:
				cancel()
			default:
				t.Fatalf("unexpected message: %s", message.Text())
			}
			return nil
		},
	})

	if err := runner.Run(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("Run error = %v, want context canceled", err)
	}
	if handled.Load() != 2 {
		t.Fatalf("handled = %d, want 2", handled.Load())
	}
}

func TestRunnerReadsWebSocketCloseWhileHandlerIsRunning(t *testing.T) {
	var upgrader websocket.Upgrader
	handlerStarted := make(chan struct{})
	closeSent := make(chan struct{})
	releaseHandler := make(chan struct{}, 1)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Fatalf("upgrade: %v", err)
		}
		defer conn.Close()

		if err := conn.WriteJSON(map[string]any{
			"type":           "connected",
			"hook":           "assistant",
			"client_id":      "runner",
			"listen":         false,
			"server_version": "0.1.0",
		}); err != nil {
			t.Fatalf("write connected: %v", err)
		}
		if err := conn.WriteJSON(map[string]any{
			"type": "messages",
			"messages": []map[string]any{
				{"msgtype": "request", "req_id": "req-1", "datatype": "text", "data": "aGVsbG8="},
			},
		}); err != nil {
			t.Fatalf("write messages: %v", err)
		}

		<-handlerStarted
		message := websocket.FormatCloseMessage(websocket.CloseNormalClosure, "replaced")
		if err := conn.WriteControl(websocket.CloseMessage, message, time.Now().Add(time.Second)); err != nil {
			t.Fatalf("write close: %v", err)
		}
		close(closeSent)
	}))
	defer server.Close()
	defer close(releaseHandler)

	client, err := NewClient(Config{
		BaseURL:  server.URL,
		Token:    "ai-token",
		ClientID: "runner",
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true,
		PollInterval:      time.Millisecond,
		DisconnectTimeout: 200 * time.Millisecond,
		Handler: func(context.Context, Message) error {
			close(handlerStarted)
			<-releaseHandler
			return nil
		},
	})

	result := make(chan error, 1)
	go func() {
		result <- runner.Run(context.Background())
	}()

	select {
	case <-closeSent:
	case <-time.After(100 * time.Millisecond):
		t.Fatal("server did not send websocket close")
	}

	select {
	case err := <-result:
		t.Fatalf("Run returned before handler completed: %v", err)
	case <-time.After(20 * time.Millisecond):
	}

	releaseHandler <- struct{}{}

	select {
	case err := <-result:
		apiErr := requireAPIError(t, err)
		if apiErr.Reason != "client_replaced" {
			t.Fatalf("Run error = %#v, want client_replaced", apiErr)
		}
	case <-time.After(100 * time.Millisecond):
		t.Fatal("runner did not return after websocket handler completed")
	}
}

func TestRunnerStopsWhenPeerClosesDuringBlockedAcknowledgement(t *testing.T) {
	var upgrader websocket.Upgrader
	handlerFinished := make(chan struct{})
	closeSent := make(chan struct{})
	releaseServer := make(chan struct{})
	deliveryID := strings.Repeat("delivery-", 512*1024)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("upgrade: %v", err)
			return
		}
		defer conn.Close()

		if err := conn.WriteJSON(map[string]any{
			"type":           "connected",
			"hook":           "assistant",
			"client_id":      "runner",
			"listen":         false,
			"server_version": "0.1.0",
		}); err != nil {
			t.Errorf("write connected: %v", err)
			return
		}
		if err := conn.WriteJSON(map[string]any{
			"type":        "messages",
			"delivery_id": deliveryID,
			"messages": []map[string]any{
				{"msgtype": "request", "req_id": "req-1", "datatype": "text", "data": "aGVsbG8="},
			},
		}); err != nil {
			t.Errorf("write messages: %v", err)
			return
		}

		<-handlerFinished

		// Read only the first byte of the acknowledgement, then stop reading.
		// The large delivery ID ensures the client write cannot fit in the socket
		// buffer and is still blocked when the close frame arrives.
		firstByte := make([]byte, 1)
		if _, err := conn.NetConn().Read(firstByte); err != nil {
			t.Errorf("read acknowledgement start: %v", err)
			return
		}

		message := websocket.FormatCloseMessage(websocket.CloseNormalClosure, "replaced")
		if err := conn.WriteControl(websocket.CloseMessage, message, time.Now().Add(time.Second)); err != nil {
			t.Errorf("write close: %v", err)
			return
		}

		close(closeSent)
		<-releaseServer
	}))
	defer func() {
		close(releaseServer)
		server.Close()
	}()

	client, err := NewClient(Config{
		BaseURL:  server.URL,
		Token:    "ai-token",
		ClientID: "runner",
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true,
		DisconnectTimeout: 5 * time.Second,
		Handler: func(context.Context, Message) error {
			close(handlerFinished)
			return nil
		},
	})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan error, 1)
	go func() {
		result <- runner.Run(ctx)
	}()

	// Start the shutdown deadline after the large test frame and acknowledgement
	// setup, whose encoding/decoding is slower under the race detector.
	select {
	case <-closeSent:
	case <-time.After(10 * time.Second):
		t.Fatal("peer did not send the close frame")
	}
	select {
	case err := <-result:
		apiErr := requireAPIError(t, err)
		if apiErr.Reason != "client_replaced" {
			t.Fatalf("Run error = %#v, want client_replaced", apiErr)
		}
	case <-time.After(time.Second):
		t.Fatal("runner deadlocked while shutting down a blocked websocket writer")
	}
}

func TestRunnerWaitsForWebSocketHandlerBeforeReconnect(t *testing.T) {
	var upgrader websocket.Upgrader
	var attempts atomic.Int32
	firstHandlerStarted := make(chan struct{})
	firstConnectionClosed := make(chan struct{})
	releaseFirstHandler := make(chan struct{}, 1)
	secondConnectionStarted := make(chan struct{})
	secondHandlerStarted := make(chan struct{})

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempt := attempts.Add(1)
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Fatalf("upgrade: %v", err)
		}
		defer conn.Close()

		if err := conn.WriteJSON(map[string]any{
			"type":           "connected",
			"hook":           "assistant",
			"client_id":      "runner",
			"listen":         false,
			"server_version": "0.1.0",
		}); err != nil {
			t.Fatalf("write connected: %v", err)
		}

		switch attempt {
		case 1:
			if err := conn.WriteJSON(map[string]any{
				"type": "messages",
				"messages": []map[string]any{
					{"msgtype": "request", "req_id": "req-1", "datatype": "text", "data": "Zmlyc3Q="},
				},
			}); err != nil {
				t.Fatalf("write first messages: %v", err)
			}
			<-firstHandlerStarted
			_ = conn.Close()
			close(firstConnectionClosed)
		case 2:
			close(secondConnectionStarted)
			if err := conn.WriteJSON(map[string]any{
				"type": "messages",
				"messages": []map[string]any{
					{"msgtype": "request", "req_id": "req-2", "datatype": "text", "data": "c2Vjb25k"},
				},
			}); err != nil {
				t.Fatalf("write second messages: %v", err)
			}
			<-secondHandlerStarted
		default:
			t.Errorf("unexpected websocket attempt: %d", attempt)
		}
	}))
	defer server.Close()
	defer close(releaseFirstHandler)

	client, err := NewClient(Config{
		BaseURL:  server.URL,
		Token:    "ai-token",
		ClientID: "runner",
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true,
		PollInterval:      time.Millisecond,
		DisconnectTimeout: 200 * time.Millisecond,
		Handler: func(_ context.Context, message Message) error {
			switch message.Text() {
			case "first":
				close(firstHandlerStarted)
				<-releaseFirstHandler
			case "second":
				close(secondHandlerStarted)
				cancel()
			default:
				t.Errorf("unexpected message: %q", message.Text())
			}
			return nil
		},
	})

	result := make(chan error, 1)
	go func() {
		result <- runner.Run(ctx)
	}()

	select {
	case <-firstConnectionClosed:
	case <-time.After(100 * time.Millisecond):
		t.Fatal("first websocket connection did not close")
	}

	select {
	case <-secondConnectionStarted:
		t.Fatal("runner reconnected while the first handler was still running")
	case <-time.After(20 * time.Millisecond):
	}

	releaseFirstHandler <- struct{}{}

	select {
	case <-secondConnectionStarted:
	case <-time.After(100 * time.Millisecond):
		t.Fatal("runner did not reconnect after the first handler completed")
	}

	select {
	case <-secondHandlerStarted:
	case <-time.After(100 * time.Millisecond):
		t.Fatal("runner did not handle a message from the replacement connection")
	}

	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Run error = %v, want context canceled", err)
		}
	case <-time.After(100 * time.Millisecond):
		t.Fatal("runner did not stop after context cancellation")
	}

	if attempts.Load() != 2 {
		t.Fatalf("attempts = %d, want 2", attempts.Load())
	}
}

func TestRunnerStopsWhenWebSocketIsReplaced(t *testing.T) {
	var upgrader websocket.Upgrader
	var attempts atomic.Int32

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts.Add(1)

		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Fatalf("upgrade: %v", err)
		}
		defer conn.Close()

		if err := conn.WriteJSON(map[string]any{
			"type":           "connected",
			"hook":           "assistant",
			"client_id":      "runner",
			"listen":         false,
			"server_version": "0.1.0",
		}); err != nil {
			t.Fatalf("write connected: %v", err)
		}

		message := websocket.FormatCloseMessage(websocket.CloseNormalClosure, "replaced")
		if err := conn.WriteControl(websocket.CloseMessage, message, time.Now().Add(time.Second)); err != nil {
			t.Fatalf("write close: %v", err)
		}
	}))
	defer server.Close()

	client, err := NewClient(Config{
		BaseURL:  server.URL,
		Token:    "ai-token",
		ClientID: "runner",
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true,
		PollInterval: time.Millisecond,
		Handler: func(context.Context, Message) error {
			return nil
		},
	})

	apiErr := requireAPIError(t, runner.Run(context.Background()))
	if apiErr.Reason != "client_replaced" {
		t.Fatalf("Run error = %#v, want client_replaced", apiErr)
	}
	if attempts.Load() != 1 {
		t.Fatalf("attempts = %d, want no reconnect after replacement", attempts.Load())
	}
}

func TestRunnerStopsWhenWebSocketHandshakeIsFatal(t *testing.T) {
	var attempts atomic.Int32

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts.Add(1)
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"invalid token"}`))
	}))
	defer server.Close()

	client, err := NewClient(Config{
		BaseURL:  server.URL,
		Token:    "wrong-token",
		ClientID: "runner",
	})
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true,
		PollInterval: time.Millisecond,
		Handler: func(context.Context, Message) error {
			return nil
		},
	})

	apiErr := requireAPIError(t, runner.Run(context.Background()))
	if apiErr.Reason != "invalid_token" {
		t.Fatalf("Run error = %#v, want invalid_token", apiErr)
	}
	if attempts.Load() != 1 {
		t.Fatalf("attempts = %d, want no retry after fatal handshake", attempts.Load())
	}
}
