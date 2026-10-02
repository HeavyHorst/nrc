package protocol

// Hegel properties for sampled client request parser rejection behavior.
// Broad valid request roundtrips still live in hegel_protocol_test.odin; this
// file focuses on malformed opcode-stripped request payloads that production
// parsers should not accept silently.
//
// Selector coverage mirrors production-dispatched C_* parsers in
// websocket_handler.odin. C_ListAssetsPaged is represented twice to cover both
// cursor and no-cursor wire shapes. The only request parser intentionally
// omitted is legacy parseAuthenticateRequest for reserved opcode 9, which is not
// dispatched by the server.
//
// Parser success is ProtocolParseError.None/nil. Payloads invalid under every
// supported wire shape must return a non-nil error. C_UnsubscribeConvs accepts
// a legacy shape without its trailing correlation ID. Some C_CreateTask and
// C_UpdateTask prefixes are also valid older request shapes because of optional
// backward-compatible tail fields, so those truncation cases may succeed.
// Trailing-suffix checks here cover the generated exact wire shape plus one
// extra byte; do not read this as exhaustive proof over every longer suffix.

import "core:encoding/endian"
import "core:fmt"
import "core:testing"

import hgl "../hegel"

@(test)
test_hegel_fixed_size_request_parsers_reject_truncation_and_trailing_bytes :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_fixed_size_request_parsers_reject_truncation_and_trailing_bytes, nil, {test_cases = 250})
	testing.expectf(t, err == nil, "hegel fixed-size request parser malformed property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

@(test)
test_hegel_variable_size_request_parsers_reject_truncation_and_trailing_bytes :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_variable_size_request_parsers_reject_truncation_and_trailing_bytes, nil, {test_cases = 500})
	testing.expectf(t, err == nil, "hegel variable-size request parser malformed property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_fixed_size_request_parsers_reject_truncation_and_trailing_bytes :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	parser_raw, draw_result, draw_ok := draw_i64_or_result(tc, 0, 14, "draw fixed-size request parser selector")
	if !draw_ok do return draw_result

	truncate_raw: i64
	truncate_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 1, "draw fixed-size request malformed variant")
	if !draw_ok do return draw_result

	seed_raw: i64
	seed_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 9_000_000_000_000, "draw fixed-size request seed")
	if !draw_ok do return draw_result
	seed := u64(seed_raw)

	payload: [40]byte
	valid_len := fixed_request_valid_payload(int(parser_raw), seed, payload[:])
	if valid_len <= 0 {
		return hgl.interesting("build fixed-size request payload")
	}
	valid_err := fixed_request_parse(int(parser_raw), payload[:valid_len])
	if valid_err != nil {
		return hgl.interesting(
			fmt.tprintf("fixed-size request parser rejected valid generated payload selector=%d valid_len=%d err=%v", parser_raw, valid_len, valid_err),
		)
	}

	parse_err: ProtocolParseError
	if truncate_raw == 0 {
		truncate_len_raw, truncate_result, truncate_ok := draw_i64_or_result(tc, 0, i64(valid_len - 1), "draw fixed-size request truncation")
		if !truncate_ok do return truncate_result
		parse_err = fixed_request_parse(int(parser_raw), payload[:int(truncate_len_raw)])
		if parse_err != .TooShort {
			return hgl.interesting(
				fmt.tprintf(
					"fixed-size request parser did not reject truncation as TooShort selector=%d len=%d valid_len=%d err=%v",
					parser_raw,
					truncate_len_raw,
					valid_len,
					parse_err,
				),
			)
		}
		return hgl.valid()
	}

	payload[valid_len] = 0xA5
	parse_err = fixed_request_parse(int(parser_raw), payload[:valid_len + 1])
	if parse_err != .ContentLengthMismatch {
		return hgl.interesting(
			fmt.tprintf(
				"fixed-size request parser did not reject trailing byte as ContentLengthMismatch selector=%d valid_len=%d err=%v",
				parser_raw,
				valid_len,
				parse_err,
			),
		)
	}
	return hgl.valid()
}

fixed_request_valid_payload :: proc(selector: int, seed: u64, payload: []byte) -> int {
	conv_id := seed + 100
	entity_id := seed + 200
	correlation_id := u32(seed & 0xFFFF_FFFF)

	switch selector {
	case 0:
		// C_Stats
		endian.put_u64(payload[0:], .Big, seed)
		return 8
	case 1:
		// C_Ping
		endian.put_u64(payload[0:], .Big, seed + 1)
		return 8
	case 2:
		// C_DeleteTask
		endian.put_u64(payload[0:], .Big, conv_id)
		endian.put_u64(payload[8:], .Big, entity_id)
		endian.put_u32(payload[16:], .Big, correlation_id)
		return 20
	case 3:
		// C_MoveTask: conv_id(8) + task_id(8) + status(1) + flags(1) + order_index(2)
		// + correlation_id(4). The flag asks for the end of the target column, so
		// the position it carries is not the position that is stored.
		endian.put_u64(payload[0:], .Big, conv_id)
		endian.put_u64(payload[8:], .Big, entity_id)
		payload[16] = u8(TaskStatus.Todo)
		payload[17] = transmute(u8)MoveTaskFlag_APPEND
		endian.put_u16(payload[18:], .Big, u16(seed & 0xFFFF))
		endian.put_u32(payload[20:], .Big, correlation_id)
		return 24
	case 4:
		// C_GetTasks
		endian.put_u64(payload[0:], .Big, conv_id)
		endian.put_u32(payload[8:], .Big, correlation_id)
		return 12
	case 5:
		// C_DeleteAsset
		endian.put_u64(payload[0:], .Big, conv_id)
		endian.put_u64(payload[8:], .Big, entity_id)
		endian.put_u32(payload[16:], .Big, correlation_id)
		return 20
	case 6:
		// C_GetAsset
		endian.put_u64(payload[0:], .Big, conv_id)
		endian.put_u64(payload[8:], .Big, entity_id)
		endian.put_u32(payload[16:], .Big, correlation_id)
		return 20
	case 7:
		// C_ListNoteProjects
		endian.put_u64(payload[0:], .Big, conv_id)
		endian.put_u32(payload[8:], .Big, correlation_id)
		return 12
	case 8:
		// C_ListNoteTags
		endian.put_u64(payload[0:], .Big, conv_id)
		endian.put_u32(payload[8:], .Big, correlation_id)
		return 12
	case 9:
		// C_DeleteEdge
		endian.put_u64(payload[0:], .Big, conv_id)
		endian.put_u64(payload[8:], .Big, entity_id)
		endian.put_u32(payload[16:], .Big, correlation_id)
		return 20
	case 10:
		// C_ListEdges
		endian.put_u64(payload[0:], .Big, conv_id)
		endian.put_u16(payload[8:], .Big, u16(TargetType.Task))
		endian.put_u64(payload[10:], .Big, entity_id)
		endian.put_u32(payload[18:], .Big, correlation_id)
		return 22
	case 11:
		// C_ListAllEdges
		endian.put_u64(payload[0:], .Big, conv_id)
		endian.put_u32(payload[8:], .Big, correlation_id)
		return 12
	case 12:
		// C_ListDMs
		endian.put_u32(payload[0:], .Big, correlation_id)
		return 4
	case 13:
		// C_LeaveDM
		endian.put_u64(payload[0:], .Big, conv_id)
		endian.put_u32(payload[8:], .Big, correlation_id)
		return 12
	case 14:
		// C_CreateEdge
		endian.put_u64(payload[0:], .Big, conv_id)
		endian.put_u16(payload[8:], .Big, u16(TargetType.Task))
		endian.put_u64(payload[10:], .Big, entity_id)
		endian.put_u16(payload[18:], .Big, u16(TargetType.Asset))
		endian.put_u64(payload[20:], .Big, entity_id + 1)
		endian.put_u16(payload[28:], .Big, u16(RelationType.References))
		endian.put_u32(payload[30:], .Big, correlation_id)
		return 34
	}

	return 0
}

fixed_request_parse :: proc(selector: int, payload: []byte) -> ProtocolParseError {
	switch selector {
	case 0:
		_, err := parseStatsRequest(payload)
		return err
	case 1:
		_, err := parsePingRequest(payload)
		return err
	case 2:
		_, err := parseDeleteTaskRequest(payload)
		return err
	case 3:
		_, err := parseMoveTaskRequest(payload)
		return err
	case 4:
		_, err := parseGetTasksRequest(payload)
		return err
	case 5:
		_, err := parseDeleteAssetRequest(payload)
		return err
	case 6:
		_, err := parseGetAssetRequest(payload)
		return err
	case 7:
		_, err := parseListNoteProjectsRequest(payload)
		return err
	case 8:
		_, err := parseListNoteTagsRequest(payload)
		return err
	case 9:
		_, err := parseDeleteEdgeRequest(payload)
		return err
	case 10:
		_, err := parseListEdgesRequest(payload)
		return err
	case 11:
		_, err := parseListAllEdgesRequest(payload)
		return err
	case 12:
		_, err := parseListDMsRequest(payload)
		return err
	case 13:
		_, err := parseLeaveDMRequest(payload)
		return err
	case 14:
		_, err := parseCreateEdgeRequest(payload)
		return err
	}

	return .InvalidOpcode
}

prop_variable_size_request_parsers_reject_truncation_and_trailing_bytes :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	parser_raw, draw_result, draw_ok := draw_i64_or_result(tc, 0, 16, "draw variable-size request parser selector")
	if !draw_ok do return draw_result

	truncate_raw: i64
	truncate_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 1, "draw variable-size request malformed variant")
	if !draw_ok do return draw_result

	seed_raw: i64
	seed_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 9_000_000_000_000, "draw variable-size request seed")
	if !draw_ok do return draw_result
	seed := u64(seed_raw)

	valid: [512]byte
	valid_len := variable_request_valid_message(int(parser_raw), seed, valid[:])
	if valid_len <= 2 {
		return hgl.interesting("build variable-size request payload")
	}
	payload := valid[2:valid_len]

	valid_err := variable_request_parse(int(parser_raw), payload)
	if valid_err != nil {
		return hgl.interesting(
			fmt.tprintf("variable-size request parser rejected valid generated payload selector=%d valid_len=%d err=%v", parser_raw, valid_len, valid_err),
		)
	}

	if truncate_raw == 0 {
		truncate_len_raw, truncate_result, truncate_ok := draw_i64_or_result(tc, 0, i64(len(payload) - 1), "draw variable-size request truncation")
		if !truncate_ok do return truncate_result
		parse_err := variable_request_parse(int(parser_raw), payload[:int(truncate_len_raw)])
		if parse_err == nil {
			// C_UnsubscribeConvs accepts exactly one legacy prefix: the current
			// request without its trailing u32 correlation ID.
			if parser_raw == 2 && int(truncate_len_raw) == len(payload) - size_of(u32) {
				return hgl.valid()
			}
			// C_CreateTask and C_UpdateTask retain backward-compatible optional tail
			// fields. Some prefixes of the current serialized form are therefore
			// valid older request shapes rather than malformed truncations.
			if parser_raw == 3 || parser_raw == 4 {
				return hgl.valid()
			}
			return hgl.interesting(
				fmt.tprintf(
					"variable-size request parser accepted truncation selector=%d len=%d valid_payload_len=%d",
					parser_raw,
					truncate_len_raw,
					len(payload),
				),
			)
		}
		return hgl.valid()
	}

	valid[valid_len] = 0xA5
	parse_err := variable_request_parse(int(parser_raw), valid[2:valid_len + 1])
	if parse_err != .ContentLengthMismatch {
		return hgl.interesting(
			fmt.tprintf(
				"variable-size request parser did not reject trailing byte as ContentLengthMismatch selector=%d valid_payload_len=%d err=%v",
				parser_raw,
				len(payload),
				parse_err,
			),
		)
	}
	return hgl.valid()
}

variable_request_valid_message :: proc(selector: int, seed: u64, buf: []byte) -> int {
	conv_id := ConversationID(seed + 700)
	correlation_id := u32(seed & 0xFFFF_FFFF)
	title := []byte{'t', 'a', 's', 'k'}
	desc := []byte{'d', 'e', 's', 'c'}
	project := []byte{'p', 'r', 'o', 'j'}
	preview := []byte{'p', 'r', 'e', 'v'}
	payload := []byte{'p', 'a', 'y', 'l', 'o', 'a', 'd'}

	switch selector {
	case 0:
		return serializeSendMessageRequest(conv_id, correlation_id, .PlainText, []byte{'h', 'e', 'l', 'l', 'o'}, buf)
	case 1:
		conv_ids := []ConversationID{conv_id, conv_id + 1}
		return serializeSubscribeConvsRequest(conv_ids, buf)
	case 2:
		conv_ids := []ConversationID{conv_id, conv_id + 1}
		return serializeUnsubscribeConvsRequest(conv_ids, buf)
	case 3:
		req := CreateTaskRequest {
			conv_id        = conv_id,
			title          = title,
			description    = desc,
			priority       = 2,
			color          = .Cyan,
			external_ref   = []byte{'N', 'R', 'C', '-', '1'},
			due_at         = i64(seed),
			status         = .Todo,
			project        = project,
			correlation_id = correlation_id,
		}
		return serializeCreateTaskRequest(req, buf)
	case 4:
		req := UpdateTaskRequest {
			conv_id              = conv_id,
			task_id              = TaskID(seed + 701),
			title                = title,
			description          = desc,
			status               = .InProgress,
			assignee             = []byte{'a', 'l', 'i', 'c', 'e'},
			priority             = 3,
			color                = .Gold,
			external_ref         = []byte{'N', 'R', 'C', '-', '2'},
			due_at               = i64(seed + 1),
			blocked_by           = TaskID(seed + 702),
			preserve_attachments = (seed & 1) == 1,
			project              = project,
			correlation_id       = correlation_id,
		}
		return serializeUpdateTaskRequest(req, buf)
	case 5:
		req := CreateAssetRequest {
			conv_id          = conv_id,
			asset_type       = .Note,
			parent_type      = .Task,
			parent_id        = seed + 703,
			payload_encoding = .Plain,
			payload_raw_len  = u32(len(payload)),
			preview          = preview,
			payload          = payload,
			correlation_id   = correlation_id,
		}
		return serializeCreateAssetRequest(req, buf)
	case 6:
		req := UpdateAssetRequest {
			conv_id          = conv_id,
			asset_id         = AssetID(seed + 704),
			payload_encoding = .Plain,
			payload_raw_len  = u32(len(payload)),
			preview          = preview,
			payload          = payload,
			correlation_id   = correlation_id,
		}
		return serializeUpdateAssetRequest(req, buf)
	case 7:
		return serializeListAssetsRequest(conv_id, true, .Note, false, buf, correlation_id)
	case 8:
		return serializeListAssetsPagedRequest(conv_id, .Note, true, 7, true, i64(seed + 705), AssetID(seed + 706), buf, correlation_id)
	case 9:
		return serializeListAssetsPagedByProjectRequest(conv_id, .Note, false, 3, true, i64(seed + 707), AssetID(seed + 708), "proj", buf, correlation_id)
	case 10:
		return serializeListAssetsPagedByTagRequest(conv_id, .Note, false, 3, true, i64(seed + 709), AssetID(seed + 710), "tag", buf, correlation_id)
	case 11:
		username := "bob"
		total_size := 2 + 2 + len(username) + 4
		if len(buf) < total_size do return -1
		endian.put_u16(buf[0:], .Big, u16(Opcode.C_StartDM))
		endian.put_u16(buf[2:], .Big, u16(len(username)))
		copy(buf[4:], username)
		endian.put_u32(buf[4 + len(username):], .Big, correlation_id)
		return total_size
	case 12:
		req := GraphQueryRequest {
			conv_id        = conv_id,
			start_type     = .Task,
			start_id       = seed + 711,
			max_depth      = 2,
			relation_mask  = 0x3,
			direction      = .Both,
			flags          = 1,
			correlation_id = correlation_id,
		}
		return serializeGraphQueryRequest(req, buf)
	case 13:
		req := GraphShortestPathRequest {
			conv_id        = conv_id,
			from_type      = .Task,
			from_id        = seed + 712,
			to_type        = .Asset,
			to_id          = seed + 713,
			relation_mask  = 0x7,
			direction      = .Outgoing,
			max_depth      = 4,
			flags          = 0,
			correlation_id = correlation_id,
		}
		return serializeGraphShortestPathRequest(req, buf)
	case 14:
		req := GraphDegreeRequest {
			conv_id        = conv_id,
			top_n          = 5,
			type_filter    = u16(TargetType.Task),
			relation_mask  = 0,
			correlation_id = correlation_id,
		}
		return serializeGraphDegreeRequest(req, buf)
	case 15:
		req := GraphCommonNeighborsRequest {
			conv_id        = conv_id,
			a_type         = .Task,
			a_id           = seed + 714,
			b_type         = .Asset,
			b_id           = seed + 715,
			relation_mask  = 0x1,
			direction      = .Incoming,
			correlation_id = correlation_id,
		}
		return serializeGraphCommonNeighborsRequest(req, buf)
	case 16:
		return serializeListAssetsPagedRequest(conv_id, .Note, true, 7, false, 0, 0, buf, correlation_id)
	}

	return -1
}

variable_request_parse :: proc(selector: int, payload: []byte) -> ProtocolParseError {
	switch selector {
	case 0:
		_, err := parseSendMessageRequest(payload)
		return err
	case 1:
		_, err := parseSubscribeConvsRequest(payload)
		return err
	case 2:
		_, err := parseUnsubscribeConvsRequest(payload)
		return err
	case 3:
		_, err := parseCreateTaskRequest(payload)
		return err
	case 4:
		_, err := parseUpdateTaskRequest(payload)
		return err
	case 5:
		_, err := parseCreateAssetRequest(payload)
		return err
	case 6:
		_, err := parseUpdateAssetRequest(payload)
		return err
	case 7:
		_, err := parseListAssetsRequest(payload)
		return err
	case 8:
		_, err := parseListAssetsPagedRequest(payload)
		return err
	case 9:
		_, err := parseListAssetsPagedByProjectRequest(payload)
		return err
	case 10:
		_, err := parseListAssetsPagedByTagRequest(payload)
		return err
	case 11:
		_, err := parseStartDMRequest(payload)
		return err
	case 12:
		_, err := parseGraphQueryRequest(payload)
		return err
	case 13:
		_, err := parseGraphShortestPathRequest(payload)
		return err
	case 14:
		_, err := parseGraphDegreeRequest(payload)
		return err
	case 15:
		_, err := parseGraphCommonNeighborsRequest(payload)
		return err
	case 16:
		_, err := parseListAssetsPagedRequest(payload)
		return err
	}

	return .InvalidOpcode
}
