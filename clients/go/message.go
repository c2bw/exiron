package exiron

import (
	"encoding/base64"
	"encoding/json"
)

// Text returns Data as a string for text messages, otherwise the empty string.
func (m Message) Text() string {
	if m.Datatype != DatatypeText {
		return ""
	}
	return string(m.Data)
}

func decodeMessage(message wireMessage) (Message, error) {
	if message.Data == nil {
		return Message{}, invalidResponse("message data is missing", nil)
	}

	data, err := base64.StdEncoding.DecodeString(*message.Data)
	if err != nil {
		return Message{}, invalidResponse("message data is not valid base64", err)
	}

	msgtype := message.Msgtype
	if msgtype == "" {
		msgtype = "request"
	}

	var items []MediaItem
	if message.Datatype == "album" {
		if err := json.Unmarshal(data, &items); err != nil || len(items) < 1 || len(items) > 10 {
			return Message{}, invalidResponse("invalid media album", err)
		}
		for _, item := range items {
			if !albumDatatype(item.Datatype) {
				return Message{}, invalidResponse("invalid album member datatype", nil)
			}
		}
	}
	return Message{
		MediaItems:       items,
		MessageThreadID:  message.MessageThreadID,
		MediaGroupID:     message.MediaGroupID,
		Caption:          message.Caption,
		Entities:         message.Entities,
		CaptionEntities:  message.CaptionEntities,
		FileName:         message.FileName,
		MIMEType:         message.MIMEType,
		CallbackQuery:    message.CallbackQuery,
		FollowupReqID:    message.FollowupReqID,
		Msgtype:          msgtype,
		ReqID:            message.ReqID,
		From:             wireUser(message.From),
		ServiceID:        message.ServiceID,
		ChatID:           message.ChatID,
		Instance:         message.Instance,
		Datatype:         Datatype(message.Datatype),
		Data:             data,
		StickerID:        message.StickerID,
		StickerEmoji:     message.StickerEmoji,
		EmojiList:        message.EmojiList,
		MessageID:        message.MessageID,
		ReplyToMessageID: message.ReplyToMessageID,
	}, nil
}

func wireUser(user *wireTelegramUser) *TelegramUser {
	if user == nil {
		return nil
	}
	converted := user.toTelegramUser()
	return &converted
}

func decodeMessages(wireMessages []wireMessage) ([]Message, error) {
	messages := make([]Message, 0, len(wireMessages))
	for _, wireMessage := range wireMessages {
		message, err := decodeMessage(wireMessage)
		if err != nil {
			return nil, err
		}
		messages = append(messages, message)
	}
	return messages, nil
}
