package exiron

import (
	"reflect"
	"testing"
)

func TestFeedbackKeyboardPreservesAndCopiesButtons(t *testing.T) {
	existing := InlineKeyboard{{{Text: "Next", CallbackData: "next"}}}
	keyboard, err := WithFeedback(existing)
	if err != nil || len(keyboard) != 2 || len(keyboard[1]) != 2 || !reflect.DeepEqual(keyboard[0], existing[0]) {
		t.Fatalf("keyboard=%v err=%v", keyboard, err)
	}
	keyboard[0][0].Text = "Changed"
	if existing[0][0].Text != "Next" {
		t.Fatal("input keyboard mutated")
	}
	if _, err := WithFeedback(keyboard); err == nil {
		t.Fatal("duplicate feedback row accepted")
	}
	full := make(InlineKeyboard, 20)
	for i := range full {
		full[i] = []InlineKeyboardButton{{Text: "Next", CallbackData: "next"}}
	}
	if _, err := WithFeedback(full); err == nil {
		t.Fatal("full keyboard accepted")
	}
	crowded := make(InlineKeyboard, 13)
	for i := 0; i < 12; i++ {
		crowded[i] = make([]InlineKeyboardButton, 8)
	}
	crowded[12] = make([]InlineKeyboardButton, 2)
	if _, err := WithFeedback(crowded); err != nil {
		t.Fatal(err)
	}
	crowded[12] = append(crowded[12], InlineKeyboardButton{})
	if _, err := WithFeedback(crowded); err == nil {
		t.Fatal("100-button limit exceeded")
	}
}

func TestFeedbackRecognizesBoundCallbacksAndRejectsOrdinaryMessages(t *testing.T) {
	origin := "rated-request"
	message := Message{Msgtype: "request", Datatype: DatatypeCallback, ReqID: "vote-request", Data: []byte(feedbackPositiveData), From: &TelegramUser{ID: 42}, CallbackQuery: &CallbackQuery{ID: "click", OriginReqID: &origin}}
	feedback, ok := ParseFeedback(message)
	if !ok || feedback.Vote != FeedbackPositive || feedback.OriginReqID != origin || feedback.RequestID != "vote-request" || feedback.UserID != 42 {
		t.Fatalf("feedback=%v ok=%v", feedback, ok)
	}
	message.Data = []byte(feedbackNegativeData)
	if feedback, ok := ParseFeedback(message); !ok || feedback.Vote != FeedbackNegative {
		t.Fatal(feedback, ok)
	}
	mutations := []func(*Message){
		func(m *Message) { m.Msgtype = "listen" }, func(m *Message) { m.Datatype = DatatypeText },
		func(m *Message) { m.From = nil }, func(m *Message) { m.CallbackQuery = nil },
		func(m *Message) { m.CallbackQuery = &CallbackQuery{ID: "click"} }, func(m *Message) { m.Data = []byte("next") },
	}
	for _, mutate := range mutations {
		copy := message
		mutate(&copy)
		if _, ok := ParseFeedback(copy); ok {
			t.Fatal("invalid feedback accepted")
		}
	}
}
