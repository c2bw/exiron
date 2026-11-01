package exiron

import (
	"context"
	"errors"
	"fmt"
	"testing"
)

func TestErrorClassificationPreservesControlBoundaries(t *testing.T) {
	cases := []struct {
		err  error
		kind string
	}{
		{nil, "none"},
		{transportError(context.DeadlineExceeded), "transport_timeout"},
		{ErrHandlerDeadlineExceeded, "handler_deadline_exceeded"},
		{ErrClientLeaseLost, "client_lease_lost"},
		{ErrRequestCancelled, "request_cancelled"},
		{ErrRequestExpired, "request_expired"},
		{&Error{Reason: "request_cancelled"}, "request_cancelled"},
		{&Error{Reason: "telegram_delivery_timeout", StatusCode: 504}, "client_error"},
		{transportError(errors.New("timeout in arbitrary message")), "transport_error"},
	}
	for _, tc := range cases {
		if got := ClassifyError(tc.err); got != tc.kind {
			t.Errorf("classification %s, want %s", got, tc.kind)
		}
		if tc.err != nil {
			if got := ClassifyError(fmt.Errorf("wrapped: %w", tc.err)); got != tc.kind {
				t.Errorf("wrapped category %s, want %s", got, tc.kind)
			}
		}
		if IsTransportTimeout(tc.err) != (tc.kind == "transport_timeout") {
			t.Errorf("transport timeout boundary %s", tc.kind)
		}
		if IsHandlerDeadlineExceeded(tc.err) != (tc.kind == "handler_deadline_exceeded") {
			t.Errorf("handler deadline boundary %s", tc.kind)
		}
	}
}
