package exiron

import (
	"context"
	"errors"
	"net/http"
	"reflect"
	"testing"
	"time"
)

func TestHandlerRetriesOnlyFailingMessageBeforeBatchAck(t *testing.T) {
	polls := 0
	client, err := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", Transport: TransportHTTP,
		HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			polls++
			if polls == 1 {
				return jsonResponse(200, `{"delivery_id":"batch","requests":[{"req_id":"one","datatype":"text","data":""},{"req_id":"two","datatype":"text","data":""},{"req_id":"three","datatype":"text","data":""}]}`), nil
			}
			if req.URL.Query().Get("delivery_ack") != "batch" {
				t.Fatal("batch acknowledged incorrectly")
			}
			return jsonResponse(409, `{"error":"stop"}`), nil
		})}, Retry: RetryPolicy{MaxElapsed: -1}})
	if err != nil {
		t.Fatal(err)
	}
	counts := map[string]int{}
	var failures []*HandlerFailure
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, PollInterval: time.Millisecond, HandlerMaxAttempts: 3,
		Handler: func(_ context.Context, message Message) error {
			counts[message.ReqID]++
			if message.ReqID == "two" && counts["two"] < 3 {
				return errors.New("transient")
			}
			return nil
		},
		OnHandlerError: func(_ context.Context, failure *HandlerFailure) { failures = append(failures, failure) }})
	runner.handlerWait = func(context.Context, time.Duration) error { return nil }
	if err := runner.Run(context.Background()); err == nil {
		t.Fatal("expected stop")
	}
	if !reflect.DeepEqual(counts, map[string]int{"one": 1, "two": 3, "three": 1}) {
		t.Fatalf("calls=%v", counts)
	}
	if len(failures) != 2 || failures[1].RequestID != "two" || failures[1].Attempt != 2 || !failures[1].WillRetry {
		t.Fatalf("failures=%#v", failures)
	}
}

func TestHandlerFailureIsFatalEvenWhenCauseLooksLikeTransportFailure(t *testing.T) {
	calls := 0
	client, err := NewClient(Config{BaseURL: "http://exiron.test", Transport: TransportHTTP,
		HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			calls++
			if req.URL.Query().Get("delivery_ack") != "" {
				t.Fatal("failed batch acknowledged")
			}
			return jsonResponse(200, `{"delivery_id":"batch","requests":[{"req_id":"poison","datatype":"text","data":""}]}`), nil
		})}, Retry: RetryPolicy{MaxElapsed: -1}})
	if err != nil {
		t.Fatal(err)
	}
	cause := transportError(errors.New("handler's own dependency failed"))
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerMaxAttempts: 2, Handler: func(context.Context, Message) error { return cause }})
	runner.handlerWait = func(context.Context, time.Duration) error { return nil }
	err = runner.Run(context.Background())
	var failure *HandlerFailure
	if !errors.As(err, &failure) || !errors.Is(err, cause) {
		t.Fatalf("error=%v", err)
	}
	if failure.Attempt != 2 || failure.WillRetry || calls != 1 {
		t.Fatalf("failure=%#v polls=%d", failure, calls)
	}
}

func TestHandlerRetryCancellationStopsFurtherAttempts(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := 0
	runner := &Runner{handlerMaxAttempts: 3, handlerRetryDelay: time.Second,
		handler:        func(context.Context, Message) error { calls++; return errors.New("failure") },
		onHandlerError: func(context.Context, *HandlerFailure) { cancel() }}
	if !errors.Is(runner.handleMessage(ctx, Message{ReqID: "request"}), context.Canceled) || calls != 1 {
		t.Fatalf("calls=%d", calls)
	}
}
