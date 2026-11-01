package exiron

import (
	"context"
	"errors"
	"net/http"
)

// Capabilities discovers protocol support without consuming work or renewing a
// lease. Only a missing/unsupported route falls back to legacy authentication.
func (c *Client) Capabilities(ctx context.Context) (*ProtocolInfo, error) {
	var response struct {
		Version      string    `json:"protocol_version"`
		Capabilities *[]string `json:"capabilities"`
	}
	err := c.request(ctx, http.MethodGet, "/api/capabilities", c.token, nil, &response)
	if err == nil {
		if response.Version == "" || response.Capabilities == nil {
			return nil, invalidResponse("invalid capability discovery response", nil)
		}
		for _, capability := range *response.Capabilities {
			if capability == "" {
				return nil, invalidResponse("invalid capability discovery response", nil)
			}
		}
		return &ProtocolInfo{Version: response.Version, Capabilities: *response.Capabilities}, nil
	}
	var apiErr *Error
	if !errors.As(err, &apiErr) || (apiErr.StatusCode != http.StatusNotFound && apiErr.StatusCode != http.StatusMethodNotAllowed) {
		return nil, err
	}
	auth, err := c.Auth(ctx)
	if err != nil {
		return nil, err
	}
	return &ProtocolInfo{Version: auth.ProtocolVersion, Capabilities: auth.Capabilities}, nil
}
