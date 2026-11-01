package exiron

import (
	"context"
	"sync/atomic"
)

type conversationKey struct {
	serviceID int64
	chatID    int64
	topicID   int64
	hasTopic  bool
	unknown   bool
}

func messageConversation(message Message) conversationKey {
	// Legacy/malformed messages without an address share one conservative lane.
	if message.ServiceID == 0 || message.ChatID == 0 {
		return conversationKey{unknown: true}
	}
	key := conversationKey{serviceID: message.ServiceID, chatID: message.ChatID}
	if message.MessageThreadID != nil {
		key.hasTopic = true
		key.topicID = *message.MessageThreadID
	}
	return key
}

func conversationLanes(messages []Message) [][]Message {
	lanes := [][]Message{}
	indices := map[conversationKey]int{}
	for _, message := range messages {
		key := messageConversation(message)
		index, ok := indices[key]
		if !ok {
			index = len(lanes)
			indices[key] = index
			lanes = append(lanes, nil)
		}
		lanes[index] = append(lanes[index], message)
	}
	return lanes
}

func (r *Runner) handleOrderedBatch(ctx context.Context, messages []Message) error {
	lanes := conversationLanes(messages)
	limit := min(r.handlerConcurrency, len(lanes))
	results := make(chan error, limit)
	var stopped atomic.Bool
	next, active := 0, 0
	var failure error
	for next < len(lanes) || active > 0 {
		for !stopped.Load() && ctx.Err() == nil && !handlerBatchExpired(ctx) && active < limit && next < len(lanes) {
			lane := lanes[next]
			next++
			active++
			go func() {
				for _, message := range lane {
					if stopped.Load() || ctx.Err() != nil || handlerBatchExpired(ctx) {
						break
					}
					if err := r.handleMessage(ctx, message); err != nil {
						stopped.Store(true)
						results <- err
						return
					}
				}
				results <- nil
			}()
		}
		if active == 0 {
			break
		}
		err := <-results
		active--
		if failure == nil && err != nil {
			failure = err
		}
	}
	if failure != nil {
		return failure
	}
	if handlerBatchExpired(ctx) {
		return handlerTimeoutError
	}
	return ctx.Err()
}
