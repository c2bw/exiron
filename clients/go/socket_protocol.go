package exiron

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"

	"github.com/gorilla/websocket"
)

func (c *Client) socketURL() (string, error) {
	parsed, err := url.Parse(c.baseURL)
	if err != nil {
		return "", invalidResponse("invalid base URL", err)
	}
	switch parsed.Scheme {
	case "http":
		parsed.Scheme = "ws"
	case "https":
		parsed.Scheme = "wss"
	default:
		return "", invalidResponse("base URL must use http or https", nil)
	}
	parsed.Path = joinURLPath(parsed.Path, "/api/socket")
	parsed.RawQuery = url.Values{
		"client_id": {c.clientID},
		"listen":    {c.listen},
	}.Encode()
	return parsed.String(), nil
}

func joinURLPath(basePath, childPath string) string {
	basePath = strings.TrimRight(basePath, "/")
	childPath = strings.TrimLeft(childPath, "/")
	if basePath == "" {
		return "/" + childPath
	}
	return basePath + "/" + childPath
}

type socketDelivery struct {
	id       string
	messages []Message
}

func socketFrameError(frame wireSocketFrame) error {
	if frame.Error == "" {
		return invalidResponse("websocket error frame missing error", nil)
	}
	body, _ := json.Marshal(map[string]any{
		"error":          frame.Error,
		"code":           frame.Code,
		"retry_after_ms": frame.RetryAfterMS,
	})
	return apiError(http.StatusConflict, body)
}

func replacedError(err error) *Error {
	return &Error{
		Reason:  "client_replaced",
		Message: "websocket client replaced",
		Err:     err,
	}
}

func isReplacedWebSocketClose(err error) bool {
	var closeErr *websocket.CloseError
	if !errors.As(err, &closeErr) {
		return false
	}
	return closeErr.Code == websocket.CloseNormalClosure && closeErr.Text == "replaced"
}
