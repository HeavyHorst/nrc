package protocol

import "core:encoding/endian"

ClientMessageID :: [16]byte

SendMessageV2Request :: struct {
	conv_id:           ConversationID,
	client_message_id: ClientMessageID,
	correlation_id:    u32,
	content_type:      MessageContentType,
	content:           []byte,
}

parseSendMessageV2Request :: proc(data: []byte) -> (result: SendMessageV2Request, err: ProtocolParseError) {
	if len(data) < 31 do return result, .TooShort
	content_len, _ := endian.get_u16(data[29:], .Big)
	if int(content_len) > MAX_ALLOWED_CONTENT_LENGTH do return result, .ContentLengthExceedsMax
	if len(data) != 31 + int(content_len) do return result, .ContentLengthMismatch
	if data[28] > u8(MessageContentType.Markdown) do return result, .InvalidContentType
	conv_id, _ := endian.get_u64(data, .Big)
	result.conv_id = ConversationID(conv_id)
	copy(result.client_message_id[:], data[8:24])
	result.correlation_id, _ = endian.get_u32(data[24:], .Big)
	result.content_type = MessageContentType(data[28])
	result.content = data[31:]
	return result, nil
}

getSizeSendMessageV2Request :: proc(content: []byte) -> int {return 2 + 31 + len(content)}

serializeSendMessageV2Request :: proc(req: SendMessageV2Request, buf: []byte) -> int {
	total := getSizeSendMessageV2Request(req.content)
	if len(buf) < total || len(req.content) > MAX_ALLOWED_CONTENT_LENGTH || req.content_type > .Markdown do return -1
	endian.put_u16(buf, .Big, u16(Opcode.C_SendMessageV2))
	endian.put_u64(buf[2:], .Big, u64(req.conv_id))
	for value, i in req.client_message_id do buf[10 + i] = value
	endian.put_u32(buf[26:], .Big, req.correlation_id)
	buf[30] = u8(req.content_type)
	endian.put_u16(buf[31:], .Big, u16(len(req.content)))
	copy(buf[33:], req.content)
	return total
}

SubscribeConvsV2Request :: struct {
	conv_ids:       []ConversationID,
	correlation_id: u32,
}

@(thread_local)
_subscribe_v2_ids: [MAX_SUBSCRIBE_CONVS]ConversationID

parseSubscribeConvsV2Request :: proc(data: []byte) -> (result: SubscribeConvsV2Request, err: ProtocolParseError) {
	if len(data) < 6 do return result, .TooShort
	count_raw, _ := endian.get_u16(data, .Big)
	count := int(count_raw)
	if count > MAX_SUBSCRIBE_CONVS do return result, .TooMany
	if len(data) != 2 + count * 8 + 4 do return result, .ContentLengthMismatch
	for i in 0 ..< count {
		id, _ := endian.get_u64(data[2 + i * 8:], .Big)
		_subscribe_v2_ids[i] = ConversationID(id)
	}
	result.conv_ids = _subscribe_v2_ids[:count]
	result.correlation_id, _ = endian.get_u32(data[2 + count * 8:], .Big)
	return result, nil
}

serializeSubscribeConvsV2Request :: proc(req: SubscribeConvsV2Request, buf: []byte) -> int {
	total := 2 + 2 + len(req.conv_ids) * 8 + 4
	if len(buf) < total || len(req.conv_ids) > MAX_SUBSCRIBE_CONVS do return -1
	endian.put_u16(buf, .Big, u16(Opcode.C_SubscribeConvsV2)); endian.put_u16(buf[2:], .Big, u16(len(req.conv_ids)))
	pos := 4
	for id in req.conv_ids {endian.put_u64(buf[pos:], .Big, u64(id)); pos += 8}
	endian.put_u32(buf[pos:], .Big, req.correlation_id)
	return total
}

MessageRangeRequest :: struct {
	conv_id:        ConversationID,
	cursor:         MessageSeq,
	limit:          u16,
	correlation_id: u32,
}

parseMessageRangeRequest :: proc(data: []byte) -> (result: MessageRangeRequest, err: ProtocolParseError) {
	if len(data) < 22 do return result, .TooShort
	if len(data) != 22 do return result, .ContentLengthMismatch
	conv, _ := endian.get_u64(data, .Big); cursor, _ := endian.get_u64(data[8:], .Big)
	result.limit, _ = endian.get_u16(data[16:], .Big)
	if result.limit == 0 || result.limit > MAX_MESSAGE_PAGE_COUNT do return result, .TooMany
	result.correlation_id, _ = endian.get_u32(data[18:], .Big)
	result.conv_id = ConversationID(conv); result.cursor = MessageSeq(cursor)
	return result, nil
}

serializeMessageRangeRequest :: proc(opcode: Opcode, req: MessageRangeRequest, buf: []byte) -> int {
	if opcode != .C_ListMessagesBefore && opcode != .C_ReplayMessagesAfter do return -1
	if len(buf) < 24 || req.limit == 0 || req.limit > MAX_MESSAGE_PAGE_COUNT do return -1
	endian.put_u16(buf, .Big, u16(opcode)); endian.put_u64(buf[2:], .Big, u64(req.conv_id))
	endian.put_u64(buf[10:], .Big, u64(req.cursor)); endian.put_u16(buf[18:], .Big, req.limit)
	endian.put_u32(buf[20:], .Big, req.correlation_id)
	return 24
}

SubscriptionReadyEntry :: struct {
	conv_id:              ConversationID,
	high_water_seq:       MessageSeq,
	retention_cutoff_seq: MessageSeq,
}
SubscriptionReady :: struct {
	correlation_id: u32,
	entries:        []SubscriptionReadyEntry,
}

@(thread_local)
_subscription_ready_entries: [MAX_SUBSCRIBE_CONVS]SubscriptionReadyEntry

parseSubscriptionReady :: proc(data: []byte) -> (result: SubscriptionReady, err: ProtocolParseError) {
	if len(data) < 6 do return result, .TooShort
	result.correlation_id, _ = endian.get_u32(data, .Big)
	count_raw, _ := endian.get_u16(data[4:], .Big); count := int(count_raw)
	if count > MAX_SUBSCRIBE_CONVS do return result, .TooMany
	if len(data) != 6 + count * 24 do return result, .ContentLengthMismatch
	for i in 0 ..< count {
		pos := 6 + i * 24
		conv, _ := endian.get_u64(data[pos:], .Big); high, _ := endian.get_u64(data[pos + 8:], .Big); cutoff, _ := endian.get_u64(data[pos + 16:], .Big)
		_subscription_ready_entries[i] = {ConversationID(conv), MessageSeq(high), MessageSeq(cutoff)}
	}
	result.entries = _subscription_ready_entries[:count]
	return result, nil
}

getSizeSubscriptionReady :: proc(ready: SubscriptionReady) -> int {
	return 2 + 6 + len(ready.entries) * 24
}

serializeSubscriptionReady :: proc(ready: SubscriptionReady, buf: []byte) -> int {
	total := getSizeSubscriptionReady(ready)
	if len(buf) < total || len(ready.entries) > MAX_SUBSCRIBE_CONVS do return -1
	endian.put_u16(buf, .Big, u16(Opcode.S_SubscriptionReady)); endian.put_u32(buf[2:], .Big, ready.correlation_id)
	endian.put_u16(buf[6:], .Big, u16(len(ready.entries))); pos := 8
	for entry in ready.entries {
		endian.put_u64(buf[pos:], .Big, u64(entry.conv_id)); endian.put_u64(buf[pos + 8:], .Big, u64(entry.high_water_seq))
		endian.put_u64(buf[pos + 16:], .Big, u64(entry.retention_cutoff_seq)); pos += 24
	}
	return total
}

MessageRecord :: struct {
	conv_id:           ConversationID,
	seq:               MessageSeq,
	client_message_id: ClientMessageID,
	author_username:   []byte,
	timestamp:         i64,
	content_type:      MessageContentType,
	content:           []byte,
}

MessagePage :: struct {
	conv_id:              ConversationID,
	ascending:            bool,
	has_more:             bool,
	truncated:            bool,
	high_water_seq:       MessageSeq,
	retention_cutoff_seq: MessageSeq,
	continuation_cursor:  MessageSeq,
	correlation_id:       u32,
	messages:             []MessageRecord,
}

@(thread_local)
_message_page_records: [MAX_MESSAGE_PAGE_COUNT]MessageRecord

getSizeMessagePage :: proc(page: MessagePage) -> int {
	total := 2 + 41
	for m in page.messages do total += 45 + len(m.author_username) + len(m.content)
	return total
}

serializeMessagePage :: proc(page: MessagePage, buf: []byte) -> int {
	total := getSizeMessagePage(page)
	if len(buf) < total || len(page.messages) > MAX_MESSAGE_PAGE_COUNT do return -1
	endian.put_u16(buf, .Big, u16(Opcode.S_MessagePage)); endian.put_u64(buf[2:], .Big, u64(page.conv_id))
	buf[10] = page.ascending ? 1 : 0; buf[11] = page.has_more ? 1 : 0; buf[12] = page.truncated ? 1 : 0
	endian.put_u64(buf[13:], .Big, u64(page.high_water_seq)); endian.put_u64(buf[21:], .Big, u64(page.retention_cutoff_seq))
	endian.put_u64(buf[29:], .Big, u64(page.continuation_cursor)); endian.put_u32(buf[37:], .Big, page.correlation_id)
	endian.put_u16(buf[41:], .Big, u16(len(page.messages))); pos := 43
	for m in page.messages {
		if len(m.author_username) > MAX_USERNAME_LENGTH || len(m.content) > MAX_ALLOWED_CONTENT_LENGTH || m.content_type > .Markdown do return -1
		endian.put_u64(buf[pos:], .Big, u64(m.conv_id)); endian.put_u64(buf[pos + 8:], .Big, u64(m.seq))
		for value, i in m.client_message_id do buf[pos + 16 + i] = value
		pos += 32
		endian.put_u16(buf[pos:], .Big, u16(len(m.author_username))); pos += 2; copy(buf[pos:], m.author_username); pos += len(m.author_username)
		endian.put_u64(buf[pos:], .Big, u64(m.timestamp)); pos += 8; buf[pos] = u8(m.content_type); pos += 1
		endian.put_u16(buf[pos:], .Big, u16(len(m.content))); pos += 2; copy(buf[pos:], m.content); pos += len(m.content)
	}
	return total
}

parseMessagePage :: proc(data: []byte) -> (result: MessagePage, err: ProtocolParseError) {
	if len(data) < 41 do return result, .TooShort
	if data[8] > 1 || data[9] > 1 || data[10] > 1 do return result, .InvalidContentType
	conv, _ := endian.get_u64(data, .Big); result.conv_id = ConversationID(conv)
	result.ascending = data[8] == 1; result.has_more = data[9] == 1; result.truncated = data[10] == 1
	high, _ := endian.get_u64(data[11:], .Big); cutoff, _ := endian.get_u64(data[19:], .Big); cursor, _ := endian.get_u64(data[27:], .Big)
	result.high_water_seq = MessageSeq(high); result.retention_cutoff_seq = MessageSeq(cutoff); result.continuation_cursor = MessageSeq(cursor)
	result.correlation_id, _ = endian.get_u32(data[35:], .Big)
	count_raw, _ := endian.get_u16(data[39:], .Big); count := int(count_raw)
	if count > MAX_MESSAGE_PAGE_COUNT do return result, .TooMany
	pos := 41
	for i in 0 ..< count {
		if len(data) < pos + 45 do return result, .TooShort
		m := &_message_page_records[i]
		cid, _ := endian.get_u64(data[pos:], .Big); seq, _ := endian.get_u64(data[pos + 8:], .Big)
		m.conv_id = ConversationID(cid); m.seq = MessageSeq(seq); copy(m.client_message_id[:], data[pos + 16:pos + 32]); pos += 32
		username_len, _ := endian.get_u16(data[pos:], .Big); pos += 2
		if username_len > MAX_USERNAME_LENGTH || len(data) < pos + int(username_len) + 11 do return result, .ContentLengthMismatch
		m.author_username = data[pos:pos + int(username_len)]; pos += int(username_len)
		ts, _ := endian.get_u64(data[pos:], .Big); m.timestamp = i64(ts); pos += 8
		if data[pos] > u8(MessageContentType.Markdown) do return result, .InvalidContentType
		m.content_type = MessageContentType(data[pos]); pos += 1
		content_len, _ := endian.get_u16(data[pos:], .Big); pos += 2
		if int(content_len) > MAX_ALLOWED_CONTENT_LENGTH do return result, .ContentLengthExceedsMax
		if len(data) < pos + int(content_len) do return result, .ContentLengthMismatch
		m.content = data[pos:pos + int(content_len)]; pos += int(content_len)
	}
	if pos != len(data) do return result, .ContentLengthMismatch
	result.messages = _message_page_records[:count]
	return result, nil
}
