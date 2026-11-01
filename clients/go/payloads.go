package exiron

import "encoding/base64"

func encodedPayload(datatype Datatype, data []byte, opts PushOptions) wireDataPayload {
	return wireDataPayload{
		IdempotencyKey:  opts.IdempotencyKey,
		Datatype:        string(datatype),
		Data:            base64.StdEncoding.EncodeToString(data),
		StickerEmoji:    optionalString(opts.StickerEmoji),
		MessageThreadID: opts.MessageThreadID,
		Caption:         optionalString(opts.Caption),
		CaptionOverflow: opts.CaptionOverflow,
		Entities:        opts.Entities,
		CaptionEntities: opts.CaptionEntities,
		FileName:        optionalString(opts.FileName),
		MIMEType:        optionalString(opts.MIMEType),
		InlineKeyboard:  opts.InlineKeyboard,
		ParseMode:       optionalString(opts.ParseMode),
		Bot:             optionalString(opts.Bot),
	}
}

func encodedPayloadWithChatID(chatID int64, datatype Datatype, data []byte, opts PushOptions) wireDataPayloadWithChatID {
	return wireDataPayloadWithChatID{
		IdempotencyKey:  opts.IdempotencyKey,
		ChatID:          chatID,
		Datatype:        string(datatype),
		Data:            base64.StdEncoding.EncodeToString(data),
		StickerEmoji:    optionalString(opts.StickerEmoji),
		MessageThreadID: opts.MessageThreadID,
		Caption:         optionalString(opts.Caption),
		CaptionOverflow: opts.CaptionOverflow,
		Entities:        opts.Entities,
		CaptionEntities: opts.CaptionEntities,
		FileName:        optionalString(opts.FileName),
		MIMEType:        optionalString(opts.MIMEType),
		InlineKeyboard:  opts.InlineKeyboard,
		ParseMode:       optionalString(opts.ParseMode),
		Bot:             optionalString(opts.Bot),
	}
}

func encodedResponse(reqID string, datatype Datatype, data []byte, stickerEmoji *string) wireResponsePayload {
	return wireResponsePayload{
		ReqID:        reqID,
		Datatype:     string(datatype),
		Data:         base64.StdEncoding.EncodeToString(data),
		StickerEmoji: stickerEmoji,
	}
}

func encodedResponseWithOptions(reqID string, datatype Datatype, data []byte, opts ResponseOptions) wireResponsePayload {
	payload := encodedResponse(reqID, datatype, data, optionalString(opts.StickerEmoji))
	payload.IdempotencyKey = opts.IdempotencyKey
	payload.Final = opts.Final
	payload.Caption = optionalString(opts.Caption)
	payload.CaptionOverflow = opts.CaptionOverflow
	payload.Entities = opts.Entities
	payload.CaptionEntities = opts.CaptionEntities
	payload.FileName = optionalString(opts.FileName)
	payload.MIMEType = optionalString(opts.MIMEType)
	payload.ParseMode = optionalString(opts.ParseMode)
	payload.InlineKeyboard = opts.InlineKeyboard
	payload.EditOrigin = opts.EditOrigin
	payload.ReplyToOriginal = opts.ReplyToOriginal
	return payload
}
