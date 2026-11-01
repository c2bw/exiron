package exiron

func (w wireAuthResponse) toAuthResponse() AuthResponse {
	return AuthResponse{
		AuthResponse:    w.AuthResponse,
		Hook:            w.Hook,
		Msgtype:         w.Msgtype,
		ServerVersion:   w.ServerVersion,
		ProtocolVersion: w.ProtocolVersion,
		Capabilities:    w.Capabilities,
	}
}

func (w wireOKResponse) toOKResponse() OkResponse {
	return OkResponse{OK: w.OK, Final: w.Final, MessageID: w.MessageID, MessageIDs: w.MessageIDs}
}

func (w wirePushResponse) toPushResponse() PushResponse {
	return PushResponse{OK: w.OK, Sent: w.Sent}
}

func (w wireTelegramUser) toTelegramUser() TelegramUser {
	return TelegramUser{
		ID:           w.ID,
		IsBot:        w.IsBot,
		FirstName:    w.FirstName,
		LastName:     w.LastName,
		Username:     w.Username,
		LanguageCode: w.LanguageCode,
	}
}

func (w wireStatus) toStatus() Status {
	return Status{
		Enabled:              w.Enabled,
		TelegramPolling:      w.TelegramPolling,
		TelegramLastPolledAt: w.TelegramLastPolledAt,
		Version:              w.Version,
		Requested:            w.Requested,
		Chats:                convertSlice(w.Chats, func(value wireChatStatus) ChatStatus { return value.toChatStatus() }),
		Hooks:                convertSlice(w.Hooks, func(value wireHookStatus) HookStatus { return value.toHookStatus() }),
		Routes:               convertSlice(w.Routes, func(value wireRoute) Route { return value.toRoute() }),
		Events:               convertSlice(w.Events, func(value wireEvent) Event { return value.toEvent() }),
		SendFailures:         convertSlice(w.SendFailures, func(value wireSendFailure) SendFailure { return value.toSendFailure() }),
		OverloadEvents:       convertSlice(w.OverloadEvents, func(value wireOverloadEvent) OverloadEvent { return value.toOverloadEvent() }),
		MembershipEvents:     convertSlice(w.MembershipEvents, func(value wireMembershipEvent) MembershipEvent { return value.toMembershipEvent() }),
		BotMemberships:       convertSlice(w.BotMemberships, func(value wireBotMembership) BotMembership { return value.toBotMembership() }),
		ClientEvents:         convertSlice(w.ClientEvents, func(value wireClientEvent) ClientEvent { return value.toClientEvent() }),
	}
}

func (w wireChatStatus) toChatStatus() ChatStatus {
	return ChatStatus{
		ID:             w.ID,
		Aliases:        w.Aliases,
		DefaultBot:     w.DefaultBot,
		CurrentBot:     w.CurrentBot,
		BotMemberships: convertSlice(w.BotMemberships, func(value wireBotMembership) BotMembership { return value.toBotMembership() }),
		Polling:        w.Polling,
		LastPolledAt:   w.LastPolledAt,
	}
}

func (w wireHookStatus) toHookStatus() HookStatus {
	return HookStatus{
		Client:    w.Client,
		Health:    w.Health,
		Name:      w.Name,
		Connected: w.Connected,
		Listening: w.Listening,
		Queued:    w.Queued,
	}
}

func (w wireRoute) toRoute() Route {
	return Route{
		ID:         w.ID,
		To:         w.To,
		ServiceID:  w.ServiceID,
		ChatID:     w.ChatID,
		ChatAlias:  w.ChatAlias,
		Messages:   w.Messages,
		Push:       w.Push,
		DefaultBot: w.DefaultBot,
	}
}

func (w wireSendFailure) toSendFailure() SendFailure {
	return SendFailure{
		Delivery:  w.Delivery,
		ID:        w.ID,
		At:        w.At,
		Operation: w.Operation,
		Hook:      w.Hook,
		ChatID:    w.ChatID,
		BotName:   w.BotName,
		Datatype:  Datatype(w.Datatype),
		Preview:   w.Preview,
		Reason:    w.Reason,
	}
}

func (w wireMembershipEvent) toMembershipEvent() MembershipEvent {
	return MembershipEvent{
		ID:        w.ID,
		At:        w.At,
		Action:    w.Action,
		ChatID:    w.ChatID,
		ChatTitle: w.ChatTitle,
		BotName:   w.BotName,
		BotUserID: w.BotUserID,
		OldStatus: w.OldStatus,
		NewStatus: w.NewStatus,
	}
}

func (w wireBotMembership) toBotMembership() BotMembership {
	return BotMembership{
		ChatID:    w.ChatID,
		BotName:   w.BotName,
		BotUserID: w.BotUserID,
		Status:    w.Status,
		Present:   w.Present,
		Error:     w.Error,
	}
}

func (w wireOverloadEvent) toOverloadEvent() OverloadEvent {
	return OverloadEvent{
		ID:           w.ID,
		At:           w.At,
		Hook:         w.Hook,
		Reason:       w.Reason,
		ServiceID:    w.ServiceID,
		ChatID:       w.ChatID,
		Datatype:     w.Datatype,
		PayloadBytes: w.PayloadBytes,
	}
}

func (w wireEvent) toEvent() Event {
	return Event{
		ID:               w.ID,
		At:               w.At,
		Direction:        w.Direction,
		Target:           w.Target,
		Kind:             w.Kind,
		ServiceID:        w.ServiceID,
		ChatID:           w.ChatID,
		BotName:          w.BotName,
		Datatype:         Datatype(w.Datatype),
		Preview:          w.Preview,
		Hook:             w.Hook,
		ImageSrc:         w.ImageSrc,
		StickerID:        w.StickerID,
		StickerEmoji:     w.StickerEmoji,
		EmojiList:        w.EmojiList,
		MessageID:        w.MessageID,
		ReplyToMessageID: w.ReplyToMessageID,
	}
}

func (w wireClientEvent) toClientEvent() ClientEvent {
	return ClientEvent{
		ID:        w.ID,
		At:        w.At,
		Action:    w.Action,
		Hook:      w.Hook,
		ClientID:  w.ClientID,
		Listening: w.Listening,
	}
}

func convertSlice[From any, To any](values []From, convert func(From) To) []To {
	if values == nil {
		return nil
	}
	converted := make([]To, len(values))
	for index, value := range values {
		converted[index] = convert(value)
	}
	return converted
}
