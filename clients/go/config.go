package exiron

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	defaultInitialDelay     = 250 * time.Millisecond
	defaultMaxDelay         = 30 * time.Second
	defaultMaxElapsed       = 30 * time.Second
	defaultMaxRequestBytes  = int64(51 * 1024 * 1024)
	defaultMaxResponseBytes = int64(128 * 1024 * 1024)
)

// Config configures a Client.
type Config struct {
	// OnRequest observes completed logical HTTP API calls. It must return promptly.
	OnRequest  func(RequestEvent)
	BaseURL    string
	Token      string
	HTTPClient *http.Client
	Retry      RetryPolicy
	ClientID   string
	// ListenMode selects ambient message delivery. Empty and unknown values are off.
	ListenMode       ListenMode
	Transport        Transport
	MaxResponseBytes int64
	// MaxRequestBytes limits the complete encoded JSON body; zero selects 51 MiB.
	MaxRequestBytes int64
}

// ListenMode controls which listen-style messages the client asks for.
type ListenMode string

const (
	ListenOff ListenMode = "false"
	ListenOn  ListenMode = "true"
	ListenAll ListenMode = "all"
)

// Transport selects the managed runner connection strategy.
type Transport int

const (
	TransportWebSocket Transport = iota
	TransportHTTP
)

// RetryPolicy controls transport-error and HTTP 429 retries on safe requests.
//
// Delivery requests such as responses and pushes are never retried because
// their result may be unknown after a transport error. HTTP responses are not
// retried except for HTTP 429 and managed-client conflicts with a retry_after_ms hint.
// Ordinary delays use equal jitter unless DisableJitter is set. Server hints
// are minimum waits, even when longer than MaxDelay; MaxElapsed still applies.
type RetryPolicy struct {
	// DisableJitter restores deterministic exponential retry delays.
	DisableJitter bool
	InitialDelay  time.Duration
	MaxDelay      time.Duration
	MaxElapsed    time.Duration
	Sleep         func(context.Context, time.Duration) error
}

// Option configures a Client.
type Option func(*Config)

// WithToken configures the bearer token used for authenticated calls.
func WithToken(token string) Option {
	return func(config *Config) {
		config.Token = token
	}
}

// WithListen includes listen-style Telegram messages while polling.
func WithListen() Option {
	return func(config *Config) {
		config.ListenMode = ListenOn
	}
}

// WithListenAll includes listen-style messages even when they also route as requests.
func WithListenAll() Option {
	return func(config *Config) {
		config.ListenMode = ListenAll
	}
}

// WithClientID configures a stable identifier for this client instance.
func WithClientID(clientID string) Option {
	return func(config *Config) {
		config.ClientID = clientID
	}
}

// WithHTTPClient configures the HTTP client used for requests.
func WithHTTPClient(httpClient *http.Client) Option {
	return func(config *Config) {
		config.HTTPClient = httpClient
	}
}

// WithMaxResponseBytes limits HTTP response bodies and WebSocket frames.
// The default is 128 MiB.
func WithMaxResponseBytes(maxBytes int64) Option {
	return func(config *Config) {
		config.MaxResponseBytes = maxBytes
	}
}

// WithMaxRequestBytes limits outgoing JSON bodies, including base64 and metadata.
func WithMaxRequestBytes(maxBytes int64) Option {
	return func(config *Config) { config.MaxRequestBytes = maxBytes }
}

// WithRetryPolicy configures retries for safe requests and WebSocket reconnects.
func WithRetryPolicy(policy RetryPolicy) Option {
	return func(config *Config) {
		config.Retry = policy
	}
}

// WithTransport configures the managed runner transport.
func WithTransport(transport Transport) Option {
	return func(config *Config) {
		config.Transport = transport
	}
}

// New builds a client for baseURL.
func New(baseURL string, opts ...Option) (*Client, error) {
	config := Config{BaseURL: baseURL}
	for _, opt := range opts {
		opt(&config)
	}
	return NewClient(config)
}

// NewClient builds a client from config.
func NewClient(config Config) (*Client, error) {
	baseURL, err := normalizeBaseURL(config.BaseURL)
	if err != nil {
		return nil, err
	}
	if err := validateTransport(config.Transport); err != nil {
		return nil, err
	}
	if err := validateRetryPolicy(config.Retry); err != nil {
		return nil, err
	}

	if config.MaxRequestBytes < 0 {
		return nil, invalidResponse("max request bytes must not be negative", nil)
	}
	maxRequestBytes := config.MaxRequestBytes
	if maxRequestBytes == 0 {
		maxRequestBytes = defaultMaxRequestBytes
	}

	httpClient := config.HTTPClient
	if httpClient == nil {
		httpClient = http.DefaultClient
	}

	clientID := config.ClientID
	if clientID == "" {
		clientID, err = newClientID()
		if err != nil {
			return nil, err
		}
	}

	maxResponseBytes := config.MaxResponseBytes
	if maxResponseBytes <= 0 {
		maxResponseBytes = defaultMaxResponseBytes
	}

	return &Client{
		onRequest:        config.OnRequest,
		baseURL:          baseURL,
		token:            config.Token,
		httpClient:       httpClient,
		retry:            normalizeRetry(config.Retry),
		clientID:         clientID,
		listen:           normalizeListenMode(config),
		transport:        config.Transport,
		maxResponseBytes: maxResponseBytes,
		maxRequestBytes:  maxRequestBytes,
	}, nil
}

func normalizeListenMode(config Config) string {
	switch config.ListenMode {
	case ListenAll:
		return string(ListenAll)
	case ListenOn:
		return string(ListenOn)
	case ListenOff:
		return string(ListenOff)
	}
	return string(ListenOff)
}

func newClientID() (string, error) {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return "", fmt.Errorf("exiron: generate client ID: %w", err)
	}
	return hex.EncodeToString(id[:]), nil
}

func normalizeBaseURL(raw string) (string, error) {
	raw = strings.TrimRight(raw, "/")
	if raw == "" {
		return "", fmt.Errorf("exiron: base URL is required")
	}

	parsed, err := url.Parse(raw)
	if err != nil {
		return "", fmt.Errorf("exiron: invalid base URL: %w", err)
	}
	if parsed.Scheme == "" || parsed.Host == "" {
		return "", fmt.Errorf("exiron: base URL must include a scheme and host")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", fmt.Errorf("exiron: base URL must use http or https")
	}
	if parsed.RawQuery != "" || parsed.ForceQuery || strings.Contains(raw, "#") {
		return "", fmt.Errorf("exiron: base URL must not include a query or fragment")
	}
	return parsed.String(), nil
}

func validateTransport(transport Transport) error {
	switch transport {
	case TransportWebSocket, TransportHTTP:
		return nil
	default:
		return fmt.Errorf("exiron: invalid transport %d", transport)
	}
}

func validateRetryPolicy(policy RetryPolicy) error {
	if policy.MaxDelay < 0 {
		return fmt.Errorf("exiron: retry max delay must not be negative")
	}
	return nil
}

func normalizeRetry(policy RetryPolicy) RetryPolicy {
	if policy.InitialDelay == 0 {
		policy.InitialDelay = defaultInitialDelay
	}
	if policy.MaxDelay == 0 {
		policy.MaxDelay = defaultMaxDelay
	}
	if policy.MaxElapsed == 0 {
		policy.MaxElapsed = defaultMaxElapsed
	}
	if policy.Sleep == nil {
		policy.Sleep = sleepContext
	}
	return policy
}

func sleepContext(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
