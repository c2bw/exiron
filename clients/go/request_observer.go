package exiron

import (
	"net/url"
	"strings"
)

// RequestEvent contains only bounded metadata. Duration includes retry waits;
// attempts counts actual HTTP attempts, not handler retries or socket frames.
type RequestEvent struct {
	Method     string `json:"method"`
	Route      string `json:"route"`
	DurationMS int64  `json:"duration_ms"`
	Attempts   int    `json:"attempts"`
	HTTPStatus int    `json:"http_status"`
	ErrorKind  string `json:"error_kind"`
}

func requestRoute(path string) string {
	parsed, err := url.Parse(path)
	if err != nil {
		return "other"
	}
	if strings.HasPrefix(parsed.Path, "/api/deliveries/") {
		return "/api/deliveries/:id"
	}
	switch parsed.Path {
	case "/api/auth", "/api/status", "/api/capabilities", "/api/requests", "/api/responses", "/api/push", "/api/edits", "/api/actions", "/api/cancellations", "/api/request-state", "/api/client-lease", "/api/client-retire", "/api/client-runtime", "/api/handler-reports", "/api/idempotent/responses", "/api/idempotent/push":
		return parsed.Path
	default:
		return "other"
	}
}
func requestMethod(method string) string {
	switch method {
	case "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS":
		return method
	default:
		return "OTHER"
	}
}
func (c *Client) observeRequest(event RequestEvent) {
	defer func() { _ = recover() }()
	c.onRequest(event)
}
