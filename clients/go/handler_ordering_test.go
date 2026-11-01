package exiron

import (
	"context"
	"errors"
	"net/http"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestConversationLanesUseServiceChatAndTopicValues(t *testing.T) {
	topicA, topicB, otherTopic := int64(10), int64(10), int64(20)
	botA, botB := "bot-a", "bot-b"
	messages := []Message{
		{ReqID: "main-one", ServiceID: 222, ChatID: 123, Instance: &botA},
		{ReqID: "topic-one", ServiceID: 222, ChatID: 123, MessageThreadID: &topicA},
		{ReqID: "main-two", ServiceID: 222, ChatID: 123, Instance: &botB},
		{ReqID: "topic-two", ServiceID: 222, ChatID: 123, MessageThreadID: &topicB},
		{ReqID: "other-topic", ServiceID: 222, ChatID: 123, MessageThreadID: &otherTopic},
		{ReqID: "other-chat", ServiceID: 222, ChatID: 456},
		{ReqID: "other-service", ServiceID: 333, ChatID: 123},
		{ReqID: "missing-chat", ServiceID: 222},
		{ReqID: "missing-service", ChatID: 123},
	}
	var actual [][]string
	for _, lane := range conversationLanes(messages) {
		var ids []string
		for _, m := range lane {
			ids = append(ids, m.ReqID)
		}
		actual = append(actual, ids)
	}
	expected := [][]string{{"main-one", "main-two"}, {"topic-one", "topic-two"}, {"other-topic"}, {"other-chat"}, {"other-service"}, {"missing-chat", "missing-service"}}
	if !reflect.DeepEqual(actual, expected) {
		t.Fatalf("lanes=%v", actual)
	}
}

func TestOrderedHandlersBypassBusyConversationAndKeepRetriesInOrder(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	type start struct {
		id      string
		attempt int
	}
	started := make(chan start, 10)
	releases := map[string]chan struct{}{}
	for _, id := range []string{"a1", "a2", "a3", "b1", "c1"} {
		releases[id] = make(chan struct{})
	}
	attempts := map[string]int{}
	var mu sync.Mutex
	var active, peak atomic.Int32
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerConcurrency: 2, HandlerOrderByChat: true, HandlerMaxAttempts: 2,
		Handler: func(_ context.Context, m Message) error {
			n := active.Add(1)
			for p := peak.Load(); n > p; p = peak.Load() {
				if peak.CompareAndSwap(p, n) {
					break
				}
			}
			defer active.Add(-1)
			mu.Lock()
			attempts[m.ReqID]++
			attempt := attempts[m.ReqID]
			mu.Unlock()
			started <- start{m.ReqID, attempt}
			<-releases[m.ReqID]
			if m.ReqID == "a2" && attempt == 1 {
				return errors.New("retry")
			}
			return nil
		}})
	runner.handlerWait = func(context.Context, time.Duration) error { return nil }
	messages := []Message{}
	for _, id := range []string{"a1", "a2", "a3", "b1", "c1"} {
		chat := int64(1)
		if id == "b1" {
			chat = 2
		}
		if id == "c1" {
			chat = 3
		}
		messages = append(messages, Message{ReqID: id, ServiceID: 222, ChatID: chat})
	}
	result := make(chan error, 1)
	go func() { result <- runner.handleBatch(context.Background(), messages) }()
	read := func() start {
		t.Helper()
		select {
		case s := <-started:
			return s
		case <-time.After(2 * time.Second):
			t.Fatal("handler did not start")
			return start{}
		}
	}
	first, second := read(), read()
	if first.id == second.id || (first.id != "a1" && first.id != "b1") || (second.id != "a1" && second.id != "b1") {
		t.Fatalf("started %v %v", first, second)
	}
	close(releases["b1"])
	if s := read(); s.id != "c1" {
		t.Fatalf("busy chat blocked independent conversation: %v", s)
	}
	close(releases["c1"])
	select {
	case s := <-started:
		t.Fatalf("same-chat handler started early: %v", s)
	default:
	}
	close(releases["a1"])
	if s := read(); s.id != "a2" || s.attempt != 1 {
		t.Fatal(s)
	}
	close(releases["a2"])
	if s := read(); s.id != "a2" || s.attempt != 2 {
		t.Fatal(s)
	}
	if s := read(); s.id != "a3" {
		t.Fatal(s)
	}
	close(releases["a3"])
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("batch did not finish")
	}
	if peak.Load() > 2 {
		t.Fatal("concurrency cap exceeded")
	}
}

func TestOrderedFailureStopsFollowingMessagesAndQueuedConversations(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	failure := errors.New("poison")
	var calls atomic.Int32
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerConcurrency: 2, HandlerOrderByChat: true, Handler: func(context.Context, Message) error { calls.Add(1); return failure }})
	messages := []Message{{ServiceID: 222, ChatID: 1}, {ServiceID: 222, ChatID: 1}, {ServiceID: 222, ChatID: 2}, {ServiceID: 222, ChatID: 2}, {ServiceID: 222, ChatID: 3}}
	if err := runner.handleBatch(context.Background(), messages); !errors.Is(err, failure) {
		t.Fatal(err)
	}
	if calls.Load() > 2 {
		t.Fatalf("started %d handlers after failure", calls.Load())
	}
}

func TestOrderedContextCancellationDoesNotStartNextSameChatMessage(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	started := make(chan string, 3)
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerConcurrency: 2, HandlerOrderByChat: true, Handler: func(ctx context.Context, m Message) error { started <- m.ReqID; <-ctx.Done(); return ctx.Err() }})
	messages := []Message{{ReqID: "one", ServiceID: 222, ChatID: 1}, {ReqID: "queued", ServiceID: 222, ChatID: 1}, {ReqID: "other", ServiceID: 222, ChatID: 2}}
	result := make(chan error, 1)
	go func() { result <- runner.handleBatch(ctx, messages) }()
	_ = awaitStarted(t, started)
	_ = awaitStarted(t, started)
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("active handlers not joined")
	}
	select {
	case id := <-started:
		t.Fatalf("queued handler started after cancellation: %s", id)
	default:
	}
}

func TestConversationOrderingDefaultsOff(t *testing.T) {
	client, _ := NewClient(Config{BaseURL: "http://exiron.test"})
	if client.NewRunner(RunnerOptions{DisableRuntimeReporting: true}).handlerOrderByChat {
		t.Fatal("ordering must be opt-in")
	}
}

func TestOrderedCancellationReleasesTheConversationForItsNextMessage(t *testing.T) {
	var cancelNow atomic.Bool
	client, _ := NewClient(Config{BaseURL: "http://exiron.test", Token: "token", HTTPClient: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		state := "active"
		id := req.URL.Query().Get("req_id")
		if id == "first" && cancelNow.Load() {
			state = "cancelled"
		}
		return jsonResponse(200, `{"req_id":"`+id+`","state":"`+state+`","expires_in_ms":null}`), nil
	})}})
	started := make(chan string, 2)
	runner := client.NewRunner(RunnerOptions{DisableRuntimeReporting: true, HandlerConcurrency: 2, HandlerOrderByChat: true, CooperativeCancellation: true, CancellationInterval: 100 * time.Millisecond,
		Handler: func(ctx context.Context, m Message) error {
			started <- m.ReqID
			if m.ReqID == "first" {
				cancelNow.Store(true)
				<-ctx.Done()
				if !errors.Is(context.Cause(ctx), ErrRequestCancelled) {
					t.Error(context.Cause(ctx))
				}
				return ctx.Err()
			}
			if ctx.Err() != nil {
				t.Error("cancellation leaked to next same-chat handler")
			}
			return nil
		}})
	result := make(chan error, 1)
	go func() {
		result <- runner.handleBatch(context.Background(), []Message{{ReqID: "first", Msgtype: "request", ServiceID: 222, ChatID: 1}, {ReqID: "second", Msgtype: "request", ServiceID: 222, ChatID: 1}})
	}()
	if id := awaitStarted(t, started); id != "first" {
		t.Fatal(id)
	}
	if id := awaitStarted(t, started); id != "second" {
		t.Fatal(id)
	}
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("conversation did not finish")
	}
}
