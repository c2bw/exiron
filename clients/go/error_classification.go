package exiron

import (
	"context"
	"errors"
	"net"
)

// IsTransportTimeout identifies a timed-out API transport, excluding the local
// managed handler budget. It does not prove a mutation was never accepted.
func IsTransportTimeout(err error) bool {
	if IsHandlerDeadlineExceeded(err) {
		return false
	}
	var api *Error
	if !errors.As(err, &api) || api.Reason != "transport_error" {
		return false
	}
	var timeout net.Error
	return errors.Is(api.Err, context.DeadlineExceeded) || errors.As(api.Err, &timeout) && timeout.Timeout()
}
func IsHandlerDeadlineExceeded(err error) bool { return errors.Is(err, ErrHandlerDeadlineExceeded) }
func IsRequestExpired(err error) bool {
	var api *Error
	return errors.Is(err, ErrRequestExpired) || errors.As(err, &api) && api.Reason == "request_expired"
}

// ClassifyError returns a closed category, without parsing message text. Existing
// errors, fields and wrapping are retained. Classification is not retry policy.
func ClassifyError(err error) string {
	switch {
	case err == nil:
		return "none"
	case IsHandlerDeadlineExceeded(err):
		return "handler_deadline_exceeded"
	case IsClientLeaseLost(err):
		return "client_lease_lost"
	case errors.Is(err, ErrRequestCancelled) || IsRequestCancelled(err):
		return "request_cancelled"
	case IsRequestExpired(err):
		return "request_expired"
	case IsTransportTimeout(err):
		return "transport_timeout"
	}
	return runtimeError(err).Kind
}
