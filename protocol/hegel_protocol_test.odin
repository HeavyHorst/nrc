package protocol

// Hegel properties for protocol opcode, client request, and general message
// serialization/parsing behavior.
//
// This file owns the broad protocol properties that are not specifically about
// promoted server response decoders: opcode inventory/ranges, request roundtrips,
// malformed client request rejection, and shared generators/helpers. Server S_*
// response parser roundtrip/malformed coverage lives in
// hegel_response_parser_test.odin to keep response decoder work isolated.

import "base:runtime"

import "core:encoding/endian"
import "core:testing"

import hgl "../hegel"

DECLARED_PROTOCOL_OPCODES :: [?]Opcode {
	.C_SendMessage,
	.C_SubscribeConvs,
	.C_UnsubscribeConvs,
	.C_Stats,
	.C_StartDM,
	.C_ListDMs,
	.C_LeaveDM,
	.C_Ping,
	.C_CreateTask,
	.C_UpdateTask,
	.C_DeleteTask,
	.C_MoveTask,
	.C_GetTasks,
	.C_CreateAsset,
	.C_UpdateAsset,
	.C_DeleteAsset,
	.C_GetAsset,
	.C_ListAssets,
	.C_ListAssetsPaged,
	.C_ListAssetsPagedByProject,
	.C_ListNoteProjects,
	.C_ListAssetsPagedByTag,
	.C_ListNoteTags,
	.C_CreateEdge,
	.C_DeleteEdge,
	.C_ListEdges,
	.C_ListAllEdges,
	.C_ListAllEdgesPaged,
	.C_ListEdgesPaged,
	.C_SearchCustomers,
	.C_GraphQuery,
	.C_GraphShortestPath,
	.C_GraphDegree,
	.C_GraphCommonNeighbors,
	.C_GraphRank,
	.S_ServerReady,
	.S_NewMessage,
	.S_AckSendMessage,
	.S_ErrorResponse,
	.S_RoomPresenceUpdate,
	.S_StatsResponse,
	.S_AuthResponse,
	.S_DMStarted,
	.S_DMList,
	.S_DMError,
	.S_DMLeft,
	.S_DMPartnerStatus,
	.S_Pong,
	.S_AckUnsubscribeConvs,
	.S_TaskCreated,
	.S_TaskUpdated,
	.S_TaskDeleted,
	.S_TaskMoved,
	.S_TaskListResponse,
	.S_AssetCreated,
	.S_AssetUpdated,
	.S_AssetDeleted,
	.S_AssetFull,
	.S_AssetList,
	.S_AssetListPage,
	.S_NoteProjectList,
	.S_NoteTagList,
	.S_EdgeCreated,
	.S_EdgeDeleted,
	.S_EdgeList,
	.S_AllEdgeList,
	.S_AllEdgeListPage,
	.S_EdgeListPage,
	.S_CustomerSearchPage,
	.S_GraphQueryResult,
	.S_GraphShortestPathResult,
	.S_GraphDegreeResult,
	.S_GraphCommonNeighborsResult,
	.S_GraphRankResult,
}

task_status_by_index :: proc(index: int) -> (TaskStatus, bool) {
	type_info := runtime.type_info_base(type_info_of(TaskStatus))
	#partial switch info in type_info.variant {
	case runtime.Type_Info_Enum:
		if index >= 0 && index < len(info.values) {
			return TaskStatus(info.values[index]), true
		}
	}
	return {}, false
}

task_status_count :: proc() -> int {
	type_info := runtime.type_info_base(type_info_of(TaskStatus))
	#partial switch info in type_info.variant {
	case runtime.Type_Info_Enum:
		return len(info.values)
	}
	return 0
}

draw_i64_or_result :: proc(tc: ^hgl.Test_Case, min_value, max_value: i64, label: string) -> (i64, hgl.Body_Result, bool) {
	value, draw_err := hgl.draw_i64(tc, min_value, max_value)
	if draw_err == .Stop_Test {
		return 0, hgl.abort(), false
	}
	if draw_err != nil {
		return 0, hgl.interesting(label), false
	}
	return value, hgl.valid(), true
}

fill_bytes :: proc(buf: []byte, seed: u64) {
	for i in 0 ..< len(buf) {
		buf[i] = byte((seed + u64(i) * 31) & 0xFF)
	}
}

bytes_equal :: proc(a, b: []byte) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

expect_project_parser_rejects_truncations :: proc(buf: []byte) -> bool {
	for truncate_len in 0 ..< len(buf) {
		_, err := parseListAssetsPagedByProjectRequest(buf[:truncate_len])
		if err != .TooShort {
			return false
		}
	}
	return true
}

expect_tag_parser_rejects_truncations :: proc(buf: []byte) -> bool {
	for truncate_len in 0 ..< len(buf) {
		_, err := parseListAssetsPagedByTagRequest(buf[:truncate_len])
		if err != .TooShort {
			return false
		}
	}
	return true
}

expect_note_projects_parser_rejects_truncations :: proc(buf: []byte) -> bool {
	for truncate_len in 0 ..< len(buf) {
		_, err := parseListNoteProjectsRequest(buf[:truncate_len])
		if err != .TooShort {
			return false
		}
	}
	return true
}

expect_note_tags_parser_rejects_truncations :: proc(buf: []byte) -> bool {
	for truncate_len in 0 ..< len(buf) {
		_, err := parseListNoteTagsRequest(buf[:truncate_len])
		if err != .TooShort {
			return false
		}
	}
	return true
}

expect_delete_asset_parser_rejects_truncations :: proc(buf: []byte) -> bool {
	for truncate_len in 0 ..< len(buf) {
		_, err := parseDeleteAssetRequest(buf[:truncate_len])
		if err != .TooShort {
			return false
		}
	}
	return true
}

expect_get_asset_parser_rejects_truncations :: proc(buf: []byte) -> bool {
	for truncate_len in 0 ..< len(buf) {
		_, err := parseGetAssetRequest(buf[:truncate_len])
		if err != .TooShort {
			return false
		}
	}
	return true
}

stats_response_base_equal :: proc(a, b: StatsResponse) -> bool {
	if a.timestamp != b.timestamp || a.server_timestamp != b.server_timestamp {
		return false
	}
	if a.thread_id != b.thread_id || a.total_threads != b.total_threads || a.connections != b.connections {
		return false
	}
	if a.memory_total_mb != b.memory_total_mb || a.buffer_pool_percent != b.buffer_pool_percent || a.io_pending != b.io_pending {
		return false
	}
	if a.io_ring_depth != b.io_ring_depth || a.io_ring_available != b.io_ring_available || a.io_sq_overflow != b.io_sq_overflow {
		return false
	}
	if a.io_total_completions != b.io_total_completions || a.io_total_latency_ns != b.io_total_latency_ns || a.io_latency_count != b.io_latency_count {
		return false
	}
	if a.send_queue_depth != b.send_queue_depth ||
	   a.send_queue_limit != b.send_queue_limit ||
	   a.send_backpressure != b.send_backpressure ||
	   a.send_dropped != b.send_dropped {
		return false
	}
	if a.wal_file_size != b.wal_file_size || a.wal_pending_bytes != b.wal_pending_bytes || a.wal_record_count != b.wal_record_count {
		return false
	}
	if a.wal_fsync_count != b.wal_fsync_count ||
	   a.wal_total_fsync_ns != b.wal_total_fsync_ns ||
	   a.wal_total_write_ns != b.wal_total_write_ns ||
	   a.wal_write_count != b.wal_write_count {
		return false
	}
	return true
}

@(test)
test_get_opcode_declared_opcodes :: proc(t: ^testing.T) {
	buf: [2]byte
	for opcode in DECLARED_PROTOCOL_OPCODES {
		endian.put_u16(buf[:], .Big, u16(opcode))
		testing.expect_value(t, get_opcode(buf[:]), opcode)
	}
}

@(test)
test_hegel_ping_request_roundtrip :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_ping_request_roundtrip, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel ping property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_ping_request_roundtrip :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	timestamp, draw_err := hgl.draw_i64(tc, -1_000_000_000_000, 1_000_000_000_000)
	if draw_err == .Stop_Test {
		return hgl.abort()
	}
	if draw_err != nil {
		return hgl.interesting("draw timestamp")
	}

	buf: [16]byte
	written := serializePingRequest(timestamp, buf[:])
	if written != getSizePingRequest() {
		return hgl.interesting("serializePingRequest size")
	}

	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	if Opcode(opcode_val) != .C_Ping {
		return hgl.interesting("serializePingRequest opcode")
	}

	parsed, parse_err := parsePingRequest(buf[2:written])
	if parse_err != nil {
		return hgl.interesting("parsePingRequest rejected serialized payload")
	}
	if parsed.timestamp != timestamp {
		return hgl.interesting("parsePingRequest timestamp mismatch")
	}
	return hgl.valid()
}

@(test)
test_hegel_send_message_request_parse_valid_payloads :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_send_message_request_parse_valid_payloads, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel send-message property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_send_message_request_parse_valid_payloads :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	conv_id_raw, draw_err := hgl.draw_i64(tc, 0, 9_000_000_000_000)
	if draw_err == .Stop_Test {
		return hgl.abort()
	}
	if draw_err != nil {
		return hgl.interesting("draw conversation id")
	}

	client_req_id_raw: i64
	client_req_id_raw, draw_err = hgl.draw_i64(tc, 0, 0xFFFF_FFFF)
	if draw_err == .Stop_Test {
		return hgl.abort()
	}
	if draw_err != nil {
		return hgl.interesting("draw client request id")
	}

	content_type_raw: i64
	content_type_raw, draw_err = hgl.draw_i64(tc, 0, 1)
	if draw_err == .Stop_Test {
		return hgl.abort()
	}
	if draw_err != nil {
		return hgl.interesting("draw content type")
	}

	content_len_raw: i64
	content_len_raw, draw_err = hgl.draw_i64(tc, 0, 512)
	if draw_err == .Stop_Test {
		return hgl.abort()
	}
	if draw_err != nil {
		return hgl.interesting("draw content length")
	}

	conv_id := ConversationID(u64(conv_id_raw))
	client_req_id := u32(client_req_id_raw)
	content_type := MessageContentType(u8(content_type_raw))
	content_len := int(content_len_raw)

	content: [512]byte
	seed := u64(conv_id) ~ u64(client_req_id)
	for i in 0 ..< content_len {
		content[i] = byte((seed + u64(i * 31)) & 0xFF)
	}

	buf: [1024]byte
	written := serializeSendMessageRequest(conv_id, client_req_id, content_type, content[:content_len], buf[:])
	if written != getSizeSendMessageRequest(content[:content_len]) {
		return hgl.interesting("serializeSendMessageRequest size")
	}
	if get_opcode(buf[:written]) != .C_SendMessage {
		return hgl.interesting("serializeSendMessageRequest opcode")
	}

	parsed, parse_err := parseSendMessageRequest(buf[2:written])
	if parse_err != nil {
		return hgl.interesting("parseSendMessageRequest rejected valid payload")
	}
	if parsed.conv_id != conv_id {
		return hgl.interesting("send message conv_id mismatch")
	}
	if parsed.client_req_id != client_req_id {
		return hgl.interesting("send message client_req_id mismatch")
	}
	if parsed.content_type != content_type {
		return hgl.interesting("send message content type mismatch")
	}
	if len(parsed.content) != content_len {
		return hgl.interesting("send message content length mismatch")
	}
	for i in 0 ..< content_len {
		if parsed.content[i] != content[i] {
			return hgl.interesting("send message content byte mismatch")
		}
	}

	return hgl.valid()
}

@(test)
test_hegel_client_request_roundtrips :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_client_request_roundtrips, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel client-request property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_client_request_roundtrips :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	seed_raw, draw_result, ok := draw_i64_or_result(tc, 0, 9_000_000_000_000, "draw client request seed")
	if !ok {
		return draw_result
	}
	seed := u64(seed_raw)

	conv_count_raw: i64
	conv_count_raw, draw_result, ok = draw_i64_or_result(tc, 0, MAX_SUBSCRIBE_CONVS, "draw subscription count")
	if !ok {
		return draw_result
	}
	conv_count := int(conv_count_raw)
	conv_ids: [MAX_SUBSCRIBE_CONVS]ConversationID
	for i in 0 ..< conv_count {
		conv_ids[i] = ConversationID(seed + u64(i) * 17)
	}

	subscribe_buf: [2 + 2 + MAX_SUBSCRIBE_CONVS * size_of(ConversationID)]byte
	written := serializeSubscribeConvsRequest(conv_ids[:conv_count], subscribe_buf[:])
	if written != getSizeSubscribeConvsRequest(conv_count) {
		return hgl.interesting("serializeSubscribeConvsRequest size")
	}
	if get_opcode(subscribe_buf[:written]) != .C_SubscribeConvs {
		return hgl.interesting("serializeSubscribeConvsRequest opcode")
	}
	parsed_subscribe, subscribe_err := parseSubscribeConvsRequest(subscribe_buf[2:written])
	if subscribe_err != nil || len(parsed_subscribe.conv_ids) != conv_count {
		return hgl.interesting("subscribe convs parse mismatch")
	}
	for i in 0 ..< conv_count {
		if parsed_subscribe.conv_ids[i] != conv_ids[i] {
			return hgl.interesting("subscribe conv id mismatch")
		}
	}

	unsubscribe_buf: [2 + 2 + MAX_SUBSCRIBE_CONVS * size_of(ConversationID) + size_of(u32)]byte
	unsubscribe_correlation_id := u32(seed)
	written = serializeUnsubscribeConvsRequest(conv_ids[:conv_count], unsubscribe_buf[:], unsubscribe_correlation_id)
	if written != getSizeUnsubscribeConvsRequest(conv_count) {
		return hgl.interesting("serializeUnsubscribeConvsRequest size")
	}
	if get_opcode(unsubscribe_buf[:written]) != .C_UnsubscribeConvs {
		return hgl.interesting("serializeUnsubscribeConvsRequest opcode")
	}
	parsed_unsubscribe, unsubscribe_err := parseUnsubscribeConvsRequest(unsubscribe_buf[2:written])
	if unsubscribe_err != nil || len(parsed_unsubscribe.conv_ids) != conv_count || parsed_unsubscribe.correlation_id != unsubscribe_correlation_id {
		return hgl.interesting("unsubscribe convs parse mismatch")
	}
	for i in 0 ..< conv_count {
		if parsed_unsubscribe.conv_ids[i] != conv_ids[i] {
			return hgl.interesting("unsubscribe conv id mismatch")
		}
	}

	timestamp_raw: i64
	timestamp_raw, draw_result, ok = draw_i64_or_result(tc, -1_000_000_000_000, 1_000_000_000_000, "draw stats timestamp")
	if !ok {
		return draw_result
	}
	stats_buf: [16]byte
	written = serializeStatsRequest(timestamp_raw, stats_buf[:])
	if written != getSizeStatsRequest() {
		return hgl.interesting("serializeStatsRequest size")
	}
	if get_opcode(stats_buf[:written]) != .C_Stats {
		return hgl.interesting("serializeStatsRequest opcode")
	}
	parsed_stats, stats_err := parseStatsRequest(stats_buf[2:written])
	if stats_err != nil || parsed_stats.timestamp != timestamp_raw {
		return hgl.interesting("stats request roundtrip mismatch")
	}

	asset_type_raw: i64
	asset_type_raw, draw_result, ok = draw_i64_or_result(tc, i64(min(AssetType)), i64(max(AssetType)), "draw asset type")
	if !ok {
		return draw_result
	}
	filter_raw: i64
	filter_raw, draw_result, ok = draw_i64_or_result(tc, 0, 1, "draw asset filter flag")
	if !ok {
		return draw_result
	}
	full_raw: i64
	full_raw, draw_result, ok = draw_i64_or_result(tc, 0, 1, "draw full-content flag")
	if !ok {
		return draw_result
	}
	correlation_raw: i64
	correlation_raw, draw_result, ok = draw_i64_or_result(tc, 0, 0xFFFF_FFFF, "draw list assets correlation id")
	if !ok {
		return draw_result
	}
	list_assets_buf: [32]byte
	asset_conv_id := ConversationID(seed)
	asset_type := AssetType(u16(asset_type_raw))
	filter_by_type := filter_raw == 1
	full_content := full_raw == 1
	correlation_id := u32(correlation_raw)
	written = serializeListAssetsRequest(asset_conv_id, filter_by_type, asset_type, full_content, list_assets_buf[:], correlation_id)
	if written != getSizeListAssetsRequest() {
		return hgl.interesting("serializeListAssetsRequest size")
	}
	if get_opcode(list_assets_buf[:written]) != .C_ListAssets {
		return hgl.interesting("serializeListAssetsRequest opcode")
	}
	parsed_list_assets, list_assets_err := parseListAssetsRequest(list_assets_buf[2:written])
	if list_assets_err != nil {
		return hgl.interesting("parseListAssetsRequest rejected serialized payload")
	}
	if parsed_list_assets.conv_id != asset_conv_id ||
	   parsed_list_assets.filter_by_type != filter_by_type ||
	   parsed_list_assets.asset_type != asset_type ||
	   parsed_list_assets.full_content != full_content ||
	   parsed_list_assets.correlation_id != correlation_id {
		return hgl.interesting("list assets request roundtrip mismatch")
	}

	limit_raw: i64
	limit_raw, draw_result, ok = draw_i64_or_result(tc, 0, 500, "draw paged note asset limit")
	if !ok {
		return draw_result
	}
	has_cursor_raw: i64
	has_cursor_raw, draw_result, ok = draw_i64_or_result(tc, 0, 1, "draw paged note asset cursor flag")
	if !ok {
		return draw_result
	}
	project_len_raw: i64
	project_len_raw, draw_result, ok = draw_i64_or_result(tc, 0, 64, "draw project length")
	if !ok {
		return draw_result
	}
	tag_len_raw: i64
	tag_len_raw, draw_result, ok = draw_i64_or_result(tc, 0, 64, "draw tag length")
	if !ok {
		return draw_result
	}
	cursor_updated_at_raw: i64
	cursor_updated_at_raw, draw_result, ok = draw_i64_or_result(tc, -1_000_000_000_000, 1_000_000_000_000, "draw paged note asset cursor timestamp")
	if !ok {
		return draw_result
	}
	cursor_asset_id_raw: i64
	cursor_asset_id_raw, draw_result, ok = draw_i64_or_result(tc, 0, 9_000_000_000_000, "draw paged note asset cursor id")
	if !ok {
		return draw_result
	}

	limit := u16(limit_raw)
	has_cursor := has_cursor_raw == 1
	cursor_updated_at := cursor_updated_at_raw
	cursor_asset_id := AssetID(cursor_asset_id_raw)
	project_len := int(project_len_raw)
	tag_len := int(tag_len_raw)
	project_bytes: [64]byte
	tag_bytes: [64]byte
	for i in 0 ..< project_len {
		project_bytes[i] = byte('a' + ((seed + u64(i)) % 26))
	}
	for i in 0 ..< tag_len {
		tag_bytes[i] = byte('a' + ((seed + u64(i) * 3) % 26))
	}
	project := string(project_bytes[:project_len])
	tag := string(tag_bytes[:tag_len])

	project_buf: [256]byte
	written = serializeListAssetsPagedByProjectRequest(
		asset_conv_id,
		asset_type,
		full_content,
		limit,
		has_cursor,
		cursor_updated_at,
		cursor_asset_id,
		project,
		project_buf[:],
		correlation_id,
	)
	if written != getSizeListAssetsPagedByProjectRequest(has_cursor, len(project)) {
		return hgl.interesting("serializeListAssetsPagedByProjectRequest size")
	}
	if get_opcode(project_buf[:written]) != .C_ListAssetsPagedByProject {
		return hgl.interesting("serializeListAssetsPagedByProjectRequest opcode")
	}

	parsed_project, project_err := parseListAssetsPagedByProjectRequest(project_buf[2:written])
	if project_err != nil {
		return hgl.interesting("parseListAssetsPagedByProjectRequest rejected serialized payload")
	}
	if parsed_project.conv_id != asset_conv_id ||
	   parsed_project.asset_type != asset_type ||
	   parsed_project.full_content != full_content ||
	   parsed_project.limit != limit ||
	   parsed_project.has_cursor != has_cursor ||
	   parsed_project.project != project ||
	   parsed_project.correlation_id != correlation_id {
		return hgl.interesting("list assets paged by project roundtrip mismatch")
	}
	if has_cursor && (parsed_project.cursor_updated_at != cursor_updated_at || parsed_project.cursor_asset_id != cursor_asset_id) {
		return hgl.interesting("list assets paged by project cursor mismatch")
	}
	if !expect_project_parser_rejects_truncations(project_buf[2:written]) {
		return hgl.interesting("list assets paged by project accepted truncated payload")
	}

	tag_buf: [256]byte
	written = serializeListAssetsPagedByTagRequest(
		asset_conv_id,
		asset_type,
		full_content,
		limit,
		has_cursor,
		cursor_updated_at,
		cursor_asset_id,
		tag,
		tag_buf[:],
		correlation_id,
	)
	if written != getSizeListAssetsPagedByTagRequest(has_cursor, len(tag)) {
		return hgl.interesting("serializeListAssetsPagedByTagRequest size")
	}
	if get_opcode(tag_buf[:written]) != .C_ListAssetsPagedByTag {
		return hgl.interesting("serializeListAssetsPagedByTagRequest opcode")
	}

	parsed_tag, tag_err := parseListAssetsPagedByTagRequest(tag_buf[2:written])
	if tag_err != nil {
		return hgl.interesting("parseListAssetsPagedByTagRequest rejected serialized payload")
	}
	if parsed_tag.conv_id != asset_conv_id ||
	   parsed_tag.asset_type != asset_type ||
	   parsed_tag.full_content != full_content ||
	   parsed_tag.limit != limit ||
	   parsed_tag.has_cursor != has_cursor ||
	   parsed_tag.tag != tag ||
	   parsed_tag.correlation_id != correlation_id {
		return hgl.interesting("list assets paged by tag roundtrip mismatch")
	}
	if has_cursor && (parsed_tag.cursor_updated_at != cursor_updated_at || parsed_tag.cursor_asset_id != cursor_asset_id) {
		return hgl.interesting("list assets paged by tag cursor mismatch")
	}
	if !expect_tag_parser_rejects_truncations(tag_buf[2:written]) {
		return hgl.interesting("list assets paged by tag accepted truncated payload")
	}

	note_lists_buf: [32]byte
	written = serializeListNoteProjectsRequest(asset_conv_id, note_lists_buf[:], correlation_id)
	if written != getSizeListNoteProjectsRequest() {
		return hgl.interesting("serializeListNoteProjectsRequest size")
	}
	if get_opcode(note_lists_buf[:written]) != .C_ListNoteProjects {
		return hgl.interesting("serializeListNoteProjectsRequest opcode")
	}
	parsed_projects, projects_err := parseListNoteProjectsRequest(note_lists_buf[2:written])
	if projects_err != nil || parsed_projects.conv_id != asset_conv_id || parsed_projects.correlation_id != correlation_id {
		return hgl.interesting("list note projects request roundtrip mismatch")
	}
	if !expect_note_projects_parser_rejects_truncations(note_lists_buf[2:written]) {
		return hgl.interesting("list note projects accepted truncated payload")
	}

	written = serializeListNoteTagsRequest(asset_conv_id, note_lists_buf[:], correlation_id)
	if written != getSizeListNoteTagsRequest() {
		return hgl.interesting("serializeListNoteTagsRequest size")
	}
	if get_opcode(note_lists_buf[:written]) != .C_ListNoteTags {
		return hgl.interesting("serializeListNoteTagsRequest opcode")
	}
	parsed_tags, tags_err := parseListNoteTagsRequest(note_lists_buf[2:written])
	if tags_err != nil || parsed_tags.conv_id != asset_conv_id || parsed_tags.correlation_id != correlation_id {
		return hgl.interesting("list note tags request roundtrip mismatch")
	}
	if !expect_note_tags_parser_rejects_truncations(note_lists_buf[2:written]) {
		return hgl.interesting("list note tags accepted truncated payload")
	}

	return hgl.valid()
}

@(test)
test_hegel_create_task_and_asset_request_roundtrips :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_create_task_and_asset_request_roundtrips, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel create task/asset property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_create_task_and_asset_request_roundtrips :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	seed_raw, draw_result, ok := draw_i64_or_result(tc, 0, 9_000_000_000_000, "draw create request seed")
	if !ok {
		return draw_result
	}
	seed := u64(seed_raw)

	title_len_raw: i64
	title_len_raw, draw_result, ok = draw_i64_or_result(tc, 0, 64, "draw task title length")
	if !ok {
		return draw_result
	}
	desc_len_raw: i64
	desc_len_raw, draw_result, ok = draw_i64_or_result(tc, 0, 128, "draw task description length")
	if !ok {
		return draw_result
	}
	external_ref_len_raw: i64
	external_ref_len_raw, draw_result, ok = draw_i64_or_result(tc, 0, 64, "draw task external ref length")
	if !ok {
		return draw_result
	}
	priority_raw: i64
	priority_raw, draw_result, ok = draw_i64_or_result(tc, 0, 255, "draw task priority")
	if !ok {
		return draw_result
	}
	color_raw: i64
	color_raw, draw_result, ok = draw_i64_or_result(tc, 0, 5, "draw task color")
	if !ok {
		return draw_result
	}
	status_raw: i64
	status_raw, draw_result, ok = draw_i64_or_result(tc, 0, i64(task_status_count() - 1), "draw task status")
	if !ok {
		return draw_result
	}
	status, status_ok := task_status_by_index(int(status_raw))
	if !status_ok {
		return hgl.interesting("draw task status index")
	}
	due_at: i64
	due_at, draw_result, ok = draw_i64_or_result(tc, -1_000_000_000_000, 1_000_000_000_000, "draw task due_at")
	if !ok {
		return draw_result
	}

	title_len := int(title_len_raw)
	desc_len := int(desc_len_raw)
	external_ref_len := int(external_ref_len_raw)
	title: [64]byte
	description: [128]byte
	external_ref: [64]byte
	fill_bytes(title[:title_len], seed)
	fill_bytes(description[:desc_len], seed + 1)
	fill_bytes(external_ref[:external_ref_len], seed + 2)

	task_req := CreateTaskRequest {
		conv_id        = ConversationID(seed),
		title          = title[:title_len],
		description    = description[:desc_len],
		priority       = u8(priority_raw),
		color          = TaskColor(color_raw),
		external_ref   = external_ref[:external_ref_len],
		due_at         = due_at,
		status         = status,
		correlation_id = u32((seed >> 32) & 0xFFFF_FFFF),
	}
	task_buf: [512]byte
	written := serializeCreateTaskRequest(task_req, task_buf[:])
	if written != getSizeCreateTaskRequest(task_req) {
		return hgl.interesting("serializeCreateTaskRequest size")
	}
	if get_opcode(task_buf[:written]) != .C_CreateTask {
		return hgl.interesting("serializeCreateTaskRequest opcode")
	}
	parsed_task, task_err := parseCreateTaskRequest(task_buf[2:written])
	if task_err != nil {
		return hgl.interesting("parseCreateTaskRequest rejected serialized payload")
	}
	if parsed_task.conv_id != task_req.conv_id ||
	   parsed_task.priority != task_req.priority ||
	   parsed_task.color != task_req.color ||
	   parsed_task.due_at != task_req.due_at ||
	   parsed_task.status != task_req.status ||
	   parsed_task.correlation_id != task_req.correlation_id ||
	   len(parsed_task.attachments) != 0 {
		return hgl.interesting("create task fixed-field roundtrip mismatch")
	}
	if !bytes_equal(parsed_task.title, task_req.title) ||
	   !bytes_equal(parsed_task.description, task_req.description) ||
	   !bytes_equal(parsed_task.external_ref, task_req.external_ref) {
		return hgl.interesting("create task byte-field roundtrip mismatch")
	}

	assignee_len_raw: i64
	assignee_len_raw, draw_result, ok = draw_i64_or_result(tc, 0, 32, "draw task update assignee length")
	if !ok {
		return draw_result
	}
	update_priority_raw: i64
	update_priority_raw, draw_result, ok = draw_i64_or_result(tc, 0, 254, "draw task update priority")
	if !ok {
		return draw_result
	}
	update_status_raw: i64
	update_status_raw, draw_result, ok = draw_i64_or_result(tc, 0, i64(task_status_count() - 1), "draw task update status")
	if !ok {
		return draw_result
	}
	update_status, update_status_ok := task_status_by_index(int(update_status_raw))
	if !update_status_ok {
		return hgl.interesting("draw task update status index")
	}
	update_color_raw: i64
	update_color_raw, draw_result, ok = draw_i64_or_result(tc, 0, 5, "draw task update color")
	if !ok {
		return draw_result
	}
	preserve_attachments_raw: i64
	preserve_attachments_raw, draw_result, ok = draw_i64_or_result(tc, 0, 1, "draw task update preserve attachments")
	if !ok {
		return draw_result
	}
	assignee_len := int(assignee_len_raw)
	assignee: [32]byte
	fill_bytes(assignee[:assignee_len], seed + 10)
	update_req := UpdateTaskRequest {
		conv_id              = task_req.conv_id,
		task_id              = TaskID(seed + 11),
		title                = title[:title_len],
		description          = description[:desc_len],
		status               = update_status,
		assignee             = assignee[:assignee_len],
		priority             = u8(update_priority_raw),
		color                = TaskColor(update_color_raw),
		external_ref         = external_ref[:external_ref_len],
		due_at               = 0,
		blocked_by           = TaskID(seed + 12),
		preserve_attachments = preserve_attachments_raw == 1,
		correlation_id       = u32((seed + 13) & 0xFFFF_FFFF),
	}
	update_task_buf: [768]byte
	written = serializeUpdateTaskRequest(update_req, update_task_buf[:])
	if written != getSizeUpdateTaskRequest(update_req) {
		return hgl.interesting("serializeUpdateTaskRequest size")
	}
	if get_opcode(update_task_buf[:written]) != .C_UpdateTask {
		return hgl.interesting("serializeUpdateTaskRequest opcode")
	}
	parsed_update_task, update_task_err := parseUpdateTaskRequest(update_task_buf[2:written])
	if update_task_err != nil {
		return hgl.interesting("parseUpdateTaskRequest rejected serialized payload")
	}
	if parsed_update_task.conv_id != update_req.conv_id ||
	   parsed_update_task.task_id != update_req.task_id ||
	   parsed_update_task.status != update_req.status ||
	   parsed_update_task.priority != update_req.priority ||
	   parsed_update_task.color != update_req.color ||
	   parsed_update_task.due_at != update_req.due_at ||
	   parsed_update_task.blocked_by != update_req.blocked_by ||
	   parsed_update_task.preserve_attachments != update_req.preserve_attachments ||
	   parsed_update_task.correlation_id != update_req.correlation_id ||
	   len(parsed_update_task.attachments) != 0 {
		return hgl.interesting("update task fixed-field roundtrip mismatch")
	}
	if !bytes_equal(parsed_update_task.title, update_req.title) ||
	   !bytes_equal(parsed_update_task.description, update_req.description) ||
	   !bytes_equal(parsed_update_task.assignee, update_req.assignee) ||
	   !bytes_equal(parsed_update_task.external_ref, update_req.external_ref) {
		return hgl.interesting("update task byte-field roundtrip mismatch")
	}

	preview_len_raw: i64
	preview_len_raw, draw_result, ok = draw_i64_or_result(tc, 0, 96, "draw asset preview length")
	if !ok {
		return draw_result
	}
	payload_len_raw: i64
	payload_len_raw, draw_result, ok = draw_i64_or_result(tc, 0, 160, "draw asset payload length")
	if !ok {
		return draw_result
	}
	asset_type_raw: i64
	asset_type_raw, draw_result, ok = draw_i64_or_result(tc, i64(min(AssetType)), i64(max(AssetType)), "draw asset type")
	if !ok {
		return draw_result
	}
	parent_type_raw: i64
	parent_type_raw, draw_result, ok = draw_i64_or_result(tc, 0, 2, "draw asset parent type")
	if !ok {
		return draw_result
	}
	encoding_raw: i64
	encoding_raw, draw_result, ok = draw_i64_or_result(tc, 0, 1, "draw asset payload encoding")
	if !ok {
		return draw_result
	}

	preview_len := int(preview_len_raw)
	payload_len := int(payload_len_raw)
	preview: [96]byte
	payload: [160]byte
	asset_file_id: [16]byte
	asset_filename: [16]byte
	asset_mime_type: [16]byte
	fill_bytes(preview[:preview_len], seed + 3)
	fill_bytes(payload[:payload_len], seed + 4)
	fill_bytes(asset_file_id[:], seed + 5)
	fill_bytes(asset_filename[:], seed + 6)
	fill_bytes(asset_mime_type[:], seed + 7)
	asset_attachments := []Attachment {
		{file_id = asset_file_id[:8], filename = asset_filename[:10], size = seed + 8, mime_type = asset_mime_type[:9], uploaded_at = i64(seed + 9)},
	}
	asset_encoding := PayloadEncoding(encoding_raw)
	asset_raw_len := u32(payload_len)
	if asset_encoding == .Zstd {
		asset_raw_len = u32((seed + 17) % 160)
	}
	asset_req := CreateAssetRequest {
		conv_id          = ConversationID(seed + 1),
		asset_type       = AssetType(asset_type_raw),
		parent_type      = ParentType(parent_type_raw),
		parent_id        = seed + 2,
		payload_encoding = asset_encoding,
		payload_raw_len  = asset_raw_len,
		preview          = preview[:preview_len],
		payload          = payload[:payload_len],
		attachments      = asset_attachments,
		correlation_id   = u32(seed & 0xFFFF_FFFF),
	}
	asset_buf: [512]byte
	written = serializeCreateAssetRequest(asset_req, asset_buf[:])
	if written != getSizeCreateAssetRequest(asset_req) {
		return hgl.interesting("serializeCreateAssetRequest size")
	}
	if get_opcode(asset_buf[:written]) != .C_CreateAsset {
		return hgl.interesting("serializeCreateAssetRequest opcode")
	}
	parsed_asset, asset_err := parseCreateAssetRequest(asset_buf[2:written])
	if asset_err != nil {
		return hgl.interesting("parseCreateAssetRequest rejected serialized payload")
	}
	if parsed_asset.conv_id != asset_req.conv_id ||
	   parsed_asset.asset_type != asset_req.asset_type ||
	   parsed_asset.parent_type != asset_req.parent_type ||
	   parsed_asset.parent_id != asset_req.parent_id ||
	   parsed_asset.payload_encoding != asset_req.payload_encoding ||
	   parsed_asset.payload_raw_len != asset_req.payload_raw_len ||
	   parsed_asset.correlation_id != asset_req.correlation_id ||
	   len(parsed_asset.attachments) != len(asset_req.attachments) {
		return hgl.interesting("create asset fixed-field roundtrip mismatch")
	}
	for att, i in parsed_asset.attachments {
		if !hegel_attachment_equal(att, asset_req.attachments[i]) do return hgl.interesting("create asset attachment roundtrip mismatch")
	}
	if !bytes_equal(parsed_asset.preview, asset_req.preview) || !bytes_equal(parsed_asset.payload, asset_req.payload) {
		return hgl.interesting("create asset byte-field roundtrip mismatch")
	}

	update_asset_req := UpdateAssetRequest {
		conv_id          = asset_req.conv_id,
		asset_id         = AssetID(seed + 13),
		payload_encoding = asset_req.payload_encoding,
		payload_raw_len  = asset_req.payload_raw_len,
		preview          = asset_req.preview,
		payload          = asset_req.payload,
		attachments      = asset_req.attachments,
		correlation_id   = u32((seed + 14) & 0xFFFF_FFFF),
	}
	update_asset_buf: [512]byte
	written = serializeUpdateAssetRequest(update_asset_req, update_asset_buf[:])
	if written != getSizeUpdateAssetRequest(update_asset_req) {
		return hgl.interesting("serializeUpdateAssetRequest size")
	}
	if get_opcode(update_asset_buf[:written]) != .C_UpdateAsset {
		return hgl.interesting("serializeUpdateAssetRequest opcode")
	}
	parsed_update_asset, update_asset_err := parseUpdateAssetRequest(update_asset_buf[2:written])
	if update_asset_err != nil {
		return hgl.interesting("parseUpdateAssetRequest rejected serialized payload")
	}
	if parsed_update_asset.conv_id != update_asset_req.conv_id ||
	   parsed_update_asset.asset_id != update_asset_req.asset_id ||
	   parsed_update_asset.payload_encoding != update_asset_req.payload_encoding ||
	   parsed_update_asset.payload_raw_len != update_asset_req.payload_raw_len ||
	   parsed_update_asset.correlation_id != update_asset_req.correlation_id ||
	   len(parsed_update_asset.attachments) != len(update_asset_req.attachments) {
		return hgl.interesting("update asset fixed-field roundtrip mismatch")
	}
	for att, i in parsed_update_asset.attachments {
		if !hegel_attachment_equal(att, update_asset_req.attachments[i]) do return hgl.interesting("update asset attachment roundtrip mismatch")
	}
	if !bytes_equal(parsed_update_asset.preview, update_asset_req.preview) || !bytes_equal(parsed_update_asset.payload, update_asset_req.payload) {
		return hgl.interesting("update asset byte-field roundtrip mismatch")
	}

	delete_task_buf: [32]byte
	written = serializeDeleteTaskRequest(task_req.conv_id, TaskID(seed + 5), delete_task_buf[:], task_req.correlation_id)
	if written != getSizeDeleteTaskRequest() {
		return hgl.interesting("serializeDeleteTaskRequest size")
	}
	if get_opcode(delete_task_buf[:written]) != .C_DeleteTask {
		return hgl.interesting("serializeDeleteTaskRequest opcode")
	}
	parsed_delete_task, delete_task_err := parseDeleteTaskRequest(delete_task_buf[2:written])
	if delete_task_err != nil {
		return hgl.interesting("parseDeleteTaskRequest rejected serialized payload")
	}
	if parsed_delete_task.conv_id != task_req.conv_id ||
	   parsed_delete_task.task_id != TaskID(seed + 5) ||
	   parsed_delete_task.correlation_id != task_req.correlation_id {
		return hgl.interesting("delete task request roundtrip mismatch")
	}

	move_status_raw: i64
	move_status_raw, draw_result, ok = draw_i64_or_result(tc, 0, i64(task_status_count() - 1), "draw move task status")
	if !ok {
		return draw_result
	}
	move_status, move_status_ok := task_status_by_index(int(move_status_raw))
	if !move_status_ok {
		return hgl.interesting("draw move task status index")
	}
	move_order_raw: i64
	move_order_raw, draw_result, ok = draw_i64_or_result(tc, 0, 1024, "draw move task order index")
	if !ok {
		return draw_result
	}
	move_flags_raw: i64
	move_flags_raw, draw_result, ok = draw_i64_or_result(tc, 0, 1, "draw move task flags")
	if !ok {
		return draw_result
	}
	move_req := MoveTaskRequest {
		conv_id        = task_req.conv_id,
		task_id        = TaskID(seed + 14),
		status         = move_status,
		flags          = move_flags_raw == 1 ? MoveTaskFlag_APPEND : MoveTaskFlags{},
		order_index    = u16(move_order_raw),
		correlation_id = u32((seed + 15) & 0xFFFF_FFFF),
	}
	move_task_buf: [32]byte
	written = serializeMoveTaskRequest(move_req, move_task_buf[:])
	if written != getSizeMoveTaskRequest() {
		return hgl.interesting("serializeMoveTaskRequest size")
	}
	if get_opcode(move_task_buf[:written]) != .C_MoveTask {
		return hgl.interesting("serializeMoveTaskRequest opcode")
	}
	parsed_move_task, move_task_err := parseMoveTaskRequest(move_task_buf[2:written])
	if move_task_err != nil {
		return hgl.interesting("parseMoveTaskRequest rejected serialized payload")
	}
	if parsed_move_task.conv_id != move_req.conv_id ||
	   parsed_move_task.task_id != move_req.task_id ||
	   parsed_move_task.status != move_req.status ||
	   parsed_move_task.flags != move_req.flags ||
	   parsed_move_task.order_index != move_req.order_index ||
	   parsed_move_task.correlation_id != move_req.correlation_id {
		return hgl.interesting("move task request roundtrip mismatch")
	}

	relation_raw: i64
	relation_raw, draw_result, ok = draw_i64_or_result(tc, i64(min(RelationType)), i64(max(RelationType)), "draw edge relation")
	if !ok {
		return draw_result
	}
	edge_req := CreateEdgeRequest {
		conv_id        = ConversationID(seed + 6),
		source_type    = .Task,
		source_id      = seed + 7,
		target_type    = .Asset,
		target_id      = seed + 8,
		relation       = RelationType(relation_raw),
		correlation_id = u32((seed + 9) & 0xFFFF_FFFF),
	}
	edge_buf: [40]byte
	written = serializeCreateEdgeRequest(edge_req, edge_buf[:])
	if written != getSizeCreateEdgeRequest() {
		return hgl.interesting("serializeCreateEdgeRequest size")
	}
	if get_opcode(edge_buf[:written]) != .C_CreateEdge {
		return hgl.interesting("serializeCreateEdgeRequest opcode")
	}
	parsed_edge, edge_err := parseCreateEdgeRequest(edge_buf[2:written])
	if edge_err != nil {
		return hgl.interesting("parseCreateEdgeRequest rejected serialized payload")
	}
	if parsed_edge.conv_id != edge_req.conv_id ||
	   parsed_edge.source_type != edge_req.source_type ||
	   parsed_edge.source_id != edge_req.source_id ||
	   parsed_edge.target_type != edge_req.target_type ||
	   parsed_edge.target_id != edge_req.target_id ||
	   parsed_edge.relation != edge_req.relation ||
	   parsed_edge.correlation_id != edge_req.correlation_id {
		return hgl.interesting("create edge request roundtrip mismatch")
	}

	delete_edge_buf: [32]byte
	written = serializeDeleteEdgeRequest(edge_req.conv_id, EdgeID(seed + 10), delete_edge_buf[:], edge_req.correlation_id)
	if written != getSizeDeleteEdgeRequest() {
		return hgl.interesting("serializeDeleteEdgeRequest size")
	}
	if get_opcode(delete_edge_buf[:written]) != .C_DeleteEdge {
		return hgl.interesting("serializeDeleteEdgeRequest opcode")
	}
	parsed_delete_edge, delete_edge_err := parseDeleteEdgeRequest(delete_edge_buf[2:written])
	if delete_edge_err != nil {
		return hgl.interesting("parseDeleteEdgeRequest rejected serialized payload")
	}
	if parsed_delete_edge.conv_id != edge_req.conv_id ||
	   parsed_delete_edge.edge_id != EdgeID(seed + 10) ||
	   parsed_delete_edge.correlation_id != edge_req.correlation_id {
		return hgl.interesting("delete edge request roundtrip mismatch")
	}

	list_edge_req := ListEdgesRequest {
		conv_id        = edge_req.conv_id,
		target_type    = edge_req.target_type,
		target_id      = edge_req.target_id,
		correlation_id = u32((seed + 11) & 0xFFFF_FFFF),
	}
	list_edge_buf: [32]byte
	written = serializeListEdgesRequest(list_edge_req, list_edge_buf[:])
	if written != getSizeListEdgesRequest() {
		return hgl.interesting("serializeListEdgesRequest size")
	}
	if get_opcode(list_edge_buf[:written]) != .C_ListEdges {
		return hgl.interesting("serializeListEdgesRequest opcode")
	}
	parsed_list_edge, list_edge_err := parseListEdgesRequest(list_edge_buf[2:written])
	if list_edge_err != nil {
		return hgl.interesting("parseListEdgesRequest rejected serialized payload")
	}
	if parsed_list_edge.conv_id != list_edge_req.conv_id ||
	   parsed_list_edge.target_type != list_edge_req.target_type ||
	   parsed_list_edge.target_id != list_edge_req.target_id ||
	   parsed_list_edge.correlation_id != list_edge_req.correlation_id {
		return hgl.interesting("list edge request roundtrip mismatch")
	}

	list_all_edges_req := ListAllEdgesRequest {
		conv_id        = edge_req.conv_id,
		correlation_id = u32((seed + 12) & 0xFFFF_FFFF),
	}
	list_all_edges_buf: [24]byte
	written = serializeListAllEdgesRequest(list_all_edges_req, list_all_edges_buf[:])
	if written != getSizeListAllEdgesRequest() {
		return hgl.interesting("serializeListAllEdgesRequest size")
	}
	if get_opcode(list_all_edges_buf[:written]) != .C_ListAllEdges {
		return hgl.interesting("serializeListAllEdgesRequest opcode")
	}
	parsed_list_all_edges, list_all_edges_err := parseListAllEdgesRequest(list_all_edges_buf[2:written])
	if list_all_edges_err != nil {
		return hgl.interesting("parseListAllEdgesRequest rejected serialized payload")
	}
	if parsed_list_all_edges.conv_id != list_all_edges_req.conv_id || parsed_list_all_edges.correlation_id != list_all_edges_req.correlation_id {
		return hgl.interesting("list all edges request roundtrip mismatch")
	}

	return hgl.valid()
}

@(test)
test_hegel_server_message_roundtrips :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_server_message_roundtrips, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel server-message property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_server_message_roundtrips :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	seed_raw, draw_result, ok := draw_i64_or_result(tc, 0, 9_000_000_000_000, "draw server message seed")
	if !ok {
		return draw_result
	}
	seed := u64(seed_raw)

	timestamp: i64
	timestamp, draw_result, ok = draw_i64_or_result(tc, -1_000_000_000_000, 1_000_000_000_000, "draw server message timestamp")
	if !ok {
		return draw_result
	}

	build_len_raw: i64
	build_len_raw, draw_result, ok = draw_i64_or_result(tc, 0, 32, "draw build version length")
	if !ok {
		return draw_result
	}
	cpu_len_raw: i64
	cpu_len_raw, draw_result, ok = draw_i64_or_result(tc, 0, 64, "draw cpu model length")
	if !ok {
		return draw_result
	}
	username_len_raw: i64
	username_len_raw, draw_result, ok = draw_i64_or_result(tc, 0, 32, "draw server username length")
	if !ok {
		return draw_result
	}
	auth_raw: i64
	auth_raw, draw_result, ok = draw_i64_or_result(tc, 0, 1, "draw auth flag")
	if !ok {
		return draw_result
	}

	build_len := int(build_len_raw)
	cpu_len := int(cpu_len_raw)
	username_len := int(username_len_raw)
	build_version: [32]byte
	cpu_model: [64]byte
	username: [32]byte
	fill_bytes(build_version[:build_len], seed)
	fill_bytes(cpu_model[:cpu_len], seed + 1)
	fill_bytes(username[:username_len], seed + 2)
	server_ready := ServerReady {
		build_version    = build_version[:build_len],
		protocol_version = u32(seed & 0xFFFF_FFFF),
		cpu_model        = cpu_model[:cpu_len],
		username         = username[:username_len],
		is_authenticated = auth_raw == 1,
	}
	server_ready_buf: [160]byte
	written := serializeServerReady(server_ready, server_ready_buf[:])
	if written != getSizeServerReady(server_ready) || get_opcode(server_ready_buf[:written]) != .S_ServerReady {
		return hgl.interesting("serializeServerReady metadata")
	}
	parsed_server_ready, server_ready_err := parseServerReady(server_ready_buf[2:written])
	if server_ready_err != nil ||
	   parsed_server_ready.protocol_version != server_ready.protocol_version ||
	   parsed_server_ready.is_authenticated != server_ready.is_authenticated ||
	   !bytes_equal(parsed_server_ready.build_version, server_ready.build_version) ||
	   !bytes_equal(parsed_server_ready.cpu_model, server_ready.cpu_model) ||
	   !bytes_equal(parsed_server_ready.username, server_ready.username) {
		return hgl.interesting("server ready roundtrip mismatch")
	}
	parsed_server_ready_full, server_ready_full_err := parseServerReadyMessage(server_ready_buf[:written])
	if server_ready_full_err != nil ||
	   parsed_server_ready_full.protocol_version != server_ready.protocol_version ||
	   parsed_server_ready_full.is_authenticated != server_ready.is_authenticated ||
	   !bytes_equal(parsed_server_ready_full.build_version, server_ready.build_version) ||
	   !bytes_equal(parsed_server_ready_full.cpu_model, server_ready.cpu_model) ||
	   !bytes_equal(parsed_server_ready_full.username, server_ready.username) {
		return hgl.interesting("server ready full parser roundtrip mismatch")
	}

	auth_response := AuthenticateResponse {
		success   = auth_raw == 1,
		user_id   = username[:username_len],
		nickname  = build_version[:min(build_len, MAX_NICKNAME_LENGTH)],
		error_msg = cpu_model[:cpu_len],
	}
	auth_response_buf: [160]byte
	written = serializeAuthenticateResponse(auth_response, auth_response_buf[:])
	if written != getSizeAuthenticateResponse(auth_response) || get_opcode(auth_response_buf[:written]) != .S_AuthResponse {
		return hgl.interesting("serializeAuthenticateResponse metadata")
	}
	parsed_auth_response, auth_response_err := parseAuthenticateResponseMessage(auth_response_buf[:written])
	if auth_response_err != nil ||
	   parsed_auth_response.success != auth_response.success ||
	   !bytes_equal(parsed_auth_response.user_id, auth_response.user_id) ||
	   !bytes_equal(parsed_auth_response.nickname, auth_response.nickname) ||
	   !bytes_equal(parsed_auth_response.error_msg, auth_response.error_msg) {
		return hgl.interesting("auth response full parser roundtrip mismatch")
	}

	content_len_raw: i64
	content_len_raw, draw_result, ok = draw_i64_or_result(tc, 0, 512, "draw new message content length")
	if !ok {
		return draw_result
	}
	content_type_raw: i64
	content_type_raw, draw_result, ok = draw_i64_or_result(tc, 0, 1, "draw new message content type")
	if !ok {
		return draw_result
	}
	content_len := int(content_len_raw)
	content: [512]byte
	fill_bytes(content[:content_len], seed + 5)
	new_message := NewMessageEvent {
		conv_id         = ConversationID(seed),
		seq             = MessageSeq(seed + 1),
		author_username = username[:username_len],
		timestamp       = timestamp,
		content_type    = MessageContentType(u8(content_type_raw)),
		content         = content[:content_len],
	}
	new_message_buf: [640]byte
	written = serializeNewMessageEvent(new_message, new_message_buf[:])
	if written != getSizeNewMessageEvent(new_message) || get_opcode(new_message_buf[:written]) != .S_NewMessage {
		return hgl.interesting("serializeNewMessageEvent metadata")
	}
	parsed_new_message, new_message_err := parseNewMessageEvent(new_message_buf[2:written])
	if new_message_err != nil ||
	   parsed_new_message.conv_id != new_message.conv_id ||
	   parsed_new_message.seq != new_message.seq ||
	   parsed_new_message.timestamp != new_message.timestamp ||
	   parsed_new_message.content_type != new_message.content_type ||
	   !bytes_equal(parsed_new_message.author_username, new_message.author_username) ||
	   !bytes_equal(parsed_new_message.content, new_message.content) {
		return hgl.interesting("new message event roundtrip mismatch")
	}
	parsed_new_message_full, new_message_full_err := parseNewMessageEventMessage(new_message_buf[:written])
	if new_message_full_err != nil ||
	   parsed_new_message_full.conv_id != new_message.conv_id ||
	   parsed_new_message_full.seq != new_message.seq ||
	   parsed_new_message_full.timestamp != new_message.timestamp ||
	   parsed_new_message_full.content_type != new_message.content_type ||
	   !bytes_equal(parsed_new_message_full.author_username, new_message.author_username) ||
	   !bytes_equal(parsed_new_message_full.content, new_message.content) {
		return hgl.interesting("new message full parser roundtrip mismatch")
	}

	ack := AckSendMessage {
		client_req_id = u32(seed & 0xFFFF_FFFF),
		assigned_seq  = MessageSeq(seed + 2),
		timestamp     = timestamp,
	}
	ack_buf: [32]byte
	written = serializeAckSendMessage(ack, ack_buf[:])
	if written != getSizeAckSendMessage(ack) || get_opcode(ack_buf[:written]) != .S_AckSendMessage {
		return hgl.interesting("serializeAckSendMessage metadata")
	}
	parsed_ack, ack_err := parseAckSendMessage(ack_buf[2:written])
	if ack_err != nil ||
	   parsed_ack.client_req_id != ack.client_req_id ||
	   parsed_ack.assigned_seq != ack.assigned_seq ||
	   parsed_ack.timestamp != ack.timestamp {
		return hgl.interesting("ack send message roundtrip mismatch")
	}
	parsed_ack_full, ack_full_err := parseAckSendMessageMessage(ack_buf[:written])
	if ack_full_err != nil ||
	   parsed_ack_full.client_req_id != ack.client_req_id ||
	   parsed_ack_full.assigned_seq != ack.assigned_seq ||
	   parsed_ack_full.timestamp != ack.timestamp {
		return hgl.interesting("ack send message full parser roundtrip mismatch")
	}

	unsubscribe_ack := AckUnsubscribeConvs {
		correlation_id = u32(timestamp),
	}
	unsubscribe_ack_buf: [6]byte
	written = serializeAckUnsubscribeConvs(unsubscribe_ack, unsubscribe_ack_buf[:])
	if written != getSizeAckUnsubscribeConvs(unsubscribe_ack) || get_opcode(unsubscribe_ack_buf[:written]) != .S_AckUnsubscribeConvs {
		return hgl.interesting("serializeAckUnsubscribeConvs metadata")
	}
	parsed_unsubscribe_ack, unsubscribe_ack_err := parseAckUnsubscribeConvsMessage(unsubscribe_ack_buf[:written])
	if unsubscribe_ack_err != nil || parsed_unsubscribe_ack.correlation_id != unsubscribe_ack.correlation_id {
		return hgl.interesting("ack unsubscribe convs roundtrip mismatch")
	}

	pong := PongResponse {
		timestamp        = timestamp,
		server_timestamp = timestamp + 1,
	}
	pong_buf: [24]byte
	written = serializePongResponse(pong, pong_buf[:])
	if written != getSizePongResponse(pong) || get_opcode(pong_buf[:written]) != .S_Pong {
		return hgl.interesting("serializePongResponse metadata")
	}
	parsed_pong, pong_err := parsePongResponse(pong_buf[2:written])
	if pong_err != nil || parsed_pong.timestamp != pong.timestamp || parsed_pong.server_timestamp != pong.server_timestamp {
		return hgl.interesting("pong response roundtrip mismatch")
	}
	parsed_pong_full, pong_full_err := parsePongResponseMessage(pong_buf[:written])
	if pong_full_err != nil || parsed_pong_full.timestamp != pong.timestamp || parsed_pong_full.server_timestamp != pong.server_timestamp {
		return hgl.interesting("pong response full parser roundtrip mismatch")
	}

	stats := StatsResponse {
		timestamp            = timestamp,
		server_timestamp     = timestamp + 1,
		thread_id            = u32(seed & 0xFFFF_FFFF),
		total_threads        = u32((seed >> 1) & 0xFFFF_FFFF),
		connections          = u32((seed >> 2) & 0xFFFF_FFFF),
		memory_total_mb      = u32((seed >> 3) & 0xFFFF_FFFF),
		buffer_pool_percent  = u32(seed % 101),
		io_pending           = u32((seed >> 4) & 0xFFFF_FFFF),
		io_ring_depth        = u32((seed >> 5) & 0xFFFF_FFFF),
		io_ring_available    = u32((seed >> 6) & 0xFFFF_FFFF),
		io_sq_overflow       = u32((seed >> 7) & 0xFFFF_FFFF),
		io_total_completions = seed + 3,
		io_total_latency_ns  = seed + 4,
		io_latency_count     = seed + 5,
		send_queue_depth     = u32((seed >> 8) & 0xFFFF_FFFF),
		send_queue_limit     = u32((seed >> 9) & 0xFFFF_FFFF),
		send_backpressure    = auth_raw == 1,
		send_dropped         = u32((seed >> 10) & 0xFFFF_FFFF),
		wal_file_size        = seed + 6,
		wal_pending_bytes    = seed + 7,
		wal_record_count     = seed + 8,
		wal_fsync_count      = seed + 9,
		wal_total_fsync_ns   = seed + 10,
		wal_total_write_ns   = seed + 11,
		wal_write_count      = seed + 12,
	}
	stats_buf: [160]byte
	written = serializeStatsResponse(stats, stats_buf[:])
	if written != getSizeStatsResponse(stats) || get_opcode(stats_buf[:written]) != .S_StatsResponse {
		return hgl.interesting("serializeStatsResponse metadata")
	}
	parsed_stats, stats_err := parseStatsResponse(stats_buf[2:written])
	if stats_err != nil || !stats_response_base_equal(parsed_stats, stats) {
		return hgl.interesting("stats response roundtrip mismatch")
	}
	parsed_stats_full, stats_full_err := parseStatsResponseMessage(stats_buf[:written])
	if stats_full_err != nil || !stats_response_base_equal(parsed_stats_full, stats) {
		return hgl.interesting("stats response full parser roundtrip mismatch")
	}

	return hgl.valid()
}

@(test)
test_hegel_room_presence_update_roundtrip :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_room_presence_update_roundtrip, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel room-presence property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_room_presence_update_roundtrip :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	seed_raw, draw_result, ok := draw_i64_or_result(tc, 0, 9_000_000_000_000, "draw presence seed")
	if !ok {
		return draw_result
	}
	seed := u64(seed_raw)

	username_len_raw: i64
	username_len_raw, draw_result, ok = draw_i64_or_result(tc, 0, 32, "draw presence username length")
	if !ok {
		return draw_result
	}
	old_username_len_raw: i64
	old_username_len_raw, draw_result, ok = draw_i64_or_result(tc, 0, 32, "draw old presence username length")
	if !ok {
		return draw_result
	}
	user_count_raw: i64
	user_count_raw, draw_result, ok = draw_i64_or_result(tc, 0, 4, "draw presence user count")
	if !ok {
		return draw_result
	}
	event_type_raw: i64
	event_type_raw, draw_result, ok = draw_i64_or_result(tc, 0, 3, "draw presence event type")
	if !ok {
		return draw_result
	}
	user_type_raw: i64
	user_type_raw, draw_result, ok = draw_i64_or_result(tc, 0, 3, "draw presence user type")
	if !ok {
		return draw_result
	}
	auth_raw: i64
	auth_raw, draw_result, ok = draw_i64_or_result(tc, 0, 1, "draw presence auth flag")
	if !ok {
		return draw_result
	}

	username_len := int(username_len_raw)
	old_username_len := int(old_username_len_raw)
	user_count := int(user_count_raw)
	username: [32]byte
	old_username: [32]byte
	fill_bytes(username[:username_len], seed)
	fill_bytes(old_username[:old_username_len], seed + 1)

	user_bytes: [4][32]byte
	user_list: [4][]byte
	user_auth_flags: [4]bool
	user_types: [4]User_Type
	for i in 0 ..< user_count {
		user_len := int((seed + u64(i) * 11) % 33)
		fill_bytes(user_bytes[i][:user_len], seed + u64(i) + 2)
		user_list[i] = user_bytes[i][:user_len]
		user_auth_flags[i] = ((seed >> u64(i)) & 1) == 1
		user_types[i] = User_Type(u8((seed + u64(i)) % 4))
	}

	msg := RoomPresenceUpdate {
		conv_id          = ConversationID(seed),
		event_type       = PresenceEventType(u8(event_type_raw)),
		sequence         = seed + 1,
		username         = username[:username_len],
		is_authenticated = auth_raw == 1,
		user_type        = User_Type(u8(user_type_raw)),
		old_username     = old_username[:old_username_len],
		user_list        = user_list[:user_count],
		user_auth_flags  = user_auth_flags[:user_count],
		user_types       = user_types[:user_count],
	}

	buf: [1024]byte
	written := serializeRoomPresenceUpdate(msg, buf[:])
	if written != getSizeRoomPresenceUpdate(msg) {
		return hgl.interesting("serializeRoomPresenceUpdate size")
	}
	if get_opcode(buf[:written]) != .S_RoomPresenceUpdate {
		return hgl.interesting("serializeRoomPresenceUpdate opcode")
	}

	parsed, parse_err := parseRoomPresenceUpdate(buf[2:written])
	if parse_err != nil {
		return hgl.interesting("parseRoomPresenceUpdate rejected serialized payload")
	}
	if len(parsed.user_list) > 0 {
		defer delete(parsed.user_list)
		defer delete(parsed.user_auth_flags)
		defer delete(parsed.user_types)
	}

	if parsed.conv_id != msg.conv_id ||
	   parsed.event_type != msg.event_type ||
	   parsed.sequence != msg.sequence ||
	   parsed.is_authenticated != msg.is_authenticated ||
	   parsed.user_type != msg.user_type {
		return hgl.interesting("room presence fixed-field mismatch")
	}
	if !bytes_equal(parsed.username, msg.username) || !bytes_equal(parsed.old_username, msg.old_username) {
		return hgl.interesting("room presence username mismatch")
	}
	if len(parsed.user_list) != user_count || len(parsed.user_auth_flags) != user_count || len(parsed.user_types) != user_count {
		return hgl.interesting("room presence user count mismatch")
	}
	for i in 0 ..< user_count {
		if !bytes_equal(parsed.user_list[i], msg.user_list[i]) ||
		   parsed.user_auth_flags[i] != msg.user_auth_flags[i] ||
		   parsed.user_types[i] != msg.user_types[i] {
			return hgl.interesting("room presence listed user mismatch")
		}
	}

	parsed_full, parse_full_err := parseRoomPresenceUpdateMessage(buf[:written])
	if parse_full_err != nil {
		return hgl.interesting("parseRoomPresenceUpdateMessage rejected serialized payload")
	}
	if len(parsed_full.user_list) > 0 {
		defer delete(parsed_full.user_list)
		defer delete(parsed_full.user_auth_flags)
		defer delete(parsed_full.user_types)
	}
	if parsed_full.conv_id != msg.conv_id ||
	   parsed_full.event_type != msg.event_type ||
	   parsed_full.sequence != msg.sequence ||
	   parsed_full.is_authenticated != msg.is_authenticated ||
	   parsed_full.user_type != msg.user_type ||
	   !bytes_equal(parsed_full.username, msg.username) ||
	   !bytes_equal(parsed_full.old_username, msg.old_username) ||
	   len(parsed_full.user_list) != user_count ||
	   len(parsed_full.user_auth_flags) != user_count ||
	   len(parsed_full.user_types) != user_count {
		return hgl.interesting("room presence full parser mismatch")
	}
	for i in 0 ..< user_count {
		if !bytes_equal(parsed_full.user_list[i], msg.user_list[i]) ||
		   parsed_full.user_auth_flags[i] != msg.user_auth_flags[i] ||
		   parsed_full.user_types[i] != msg.user_types[i] {
			return hgl.interesting("room presence full parser listed user mismatch")
		}
	}

	return hgl.valid()
}

@(test)
test_hegel_delete_asset_request_roundtrip :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_delete_asset_request_roundtrip, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel delete-asset property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_delete_asset_request_roundtrip :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	seed_raw, draw_result, ok := draw_i64_or_result(tc, 0, 9_000_000_000_000, "draw delete asset seed")
	if !ok {
		return draw_result
	}
	seed := u64(seed_raw)
	conv_id := ConversationID(seed)
	asset_id := AssetID(seed + 1)
	correlation_id := u32((seed >> 32) & 0xFFFF_FFFF)

	buf: [32]byte
	written := serializeDeleteAssetRequest(conv_id, asset_id, buf[:], correlation_id)
	if written != getSizeDeleteAssetRequest() {
		return hgl.interesting("serializeDeleteAssetRequest size")
	}
	if get_opcode(buf[:written]) != .C_DeleteAsset {
		return hgl.interesting("serializeDeleteAssetRequest opcode")
	}

	parsed, parse_err := parseDeleteAssetRequest(buf[2:written])
	if parse_err != nil {
		return hgl.interesting("parseDeleteAssetRequest rejected serialized payload")
	}
	if parsed.conv_id != conv_id || parsed.asset_id != asset_id || parsed.correlation_id != correlation_id {
		return hgl.interesting("delete asset request roundtrip mismatch")
	}
	if !expect_delete_asset_parser_rejects_truncations(buf[2:written]) {
		return hgl.interesting("delete asset request accepted truncated payload")
	}
	return hgl.valid()
}

@(test)
test_hegel_get_asset_request_roundtrip :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_get_asset_request_roundtrip, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel get-asset property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_get_asset_request_roundtrip :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	seed_raw, draw_result, ok := draw_i64_or_result(tc, 0, 9_000_000_000_000, "draw get asset seed")
	if !ok {
		return draw_result
	}
	seed := u64(seed_raw)
	conv_id := ConversationID(seed)
	asset_id := AssetID(seed + 1)
	correlation_id := u32((seed >> 32) & 0xFFFF_FFFF)

	buf: [32]byte
	written := serializeGetAssetRequest(conv_id, asset_id, buf[:], correlation_id)
	if written != getSizeGetAssetRequest() {
		return hgl.interesting("serializeGetAssetRequest size")
	}
	if get_opcode(buf[:written]) != .C_GetAsset {
		return hgl.interesting("serializeGetAssetRequest opcode")
	}

	parsed, parse_err := parseGetAssetRequest(buf[2:written])
	if parse_err != nil {
		return hgl.interesting("parseGetAssetRequest rejected serialized payload")
	}
	if parsed.conv_id != conv_id || parsed.asset_id != asset_id || parsed.correlation_id != correlation_id {
		return hgl.interesting("get asset request roundtrip mismatch")
	}
	if !expect_get_asset_parser_rejects_truncations(buf[2:written]) {
		return hgl.interesting("get asset request accepted truncated payload")
	}
	return hgl.valid()
}

@(test)
test_hegel_asset_deleted_message_roundtrip :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_asset_deleted_message_roundtrip, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel asset-deleted property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_asset_deleted_message_roundtrip :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	seed_raw, draw_result, ok := draw_i64_or_result(tc, 0, 9_000_000_000_000, "draw asset deleted seed")
	if !ok {
		return draw_result
	}
	seed := u64(seed_raw)
	msg := AssetDeletedMessage {
		conv_id        = ConversationID(seed),
		asset_id       = AssetID(seed + 1),
		correlation_id = u32((seed >> 32) & 0xFFFF_FFFF),
	}

	buf: [32]byte
	written := serializeAssetDeletedMessage(msg, buf[:])
	if written != getSizeAssetDeletedMessage(msg) {
		return hgl.interesting("serializeAssetDeletedMessage size")
	}
	if get_opcode(buf[:written]) != .S_AssetDeleted {
		return hgl.interesting("serializeAssetDeletedMessage opcode")
	}

	parsed_event, parse_err := parseAssetDeletedEvent(buf[2:written])
	if parse_err != nil {
		return hgl.interesting("parseAssetDeletedEvent rejected serialized payload")
	}
	if parsed_event.conv_id != msg.conv_id || parsed_event.asset_id != msg.asset_id {
		return hgl.interesting("asset deleted message roundtrip mismatch")
	}
	return hgl.valid()
}

@(test)
test_hegel_get_tasks_request_roundtrip :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_get_tasks_request_roundtrip, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel get-tasks property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_get_tasks_request_roundtrip :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	conv_id_raw, draw_err := hgl.draw_i64(tc, 0, 9_000_000_000_000)
	if draw_err == .Stop_Test {
		return hgl.abort()
	}
	if draw_err != nil {
		return hgl.interesting("draw conversation id")
	}

	corr_id_raw: i64
	corr_id_raw, draw_err = hgl.draw_i64(tc, 0, 0xFFFF_FFFF)
	if draw_err == .Stop_Test {
		return hgl.abort()
	}
	if draw_err != nil {
		return hgl.interesting("draw correlation id")
	}

	req := GetTasksRequest {
		conv_id        = ConversationID(u64(conv_id_raw)),
		correlation_id = u32(corr_id_raw),
	}
	size := getSizeGetTasksRequest()
	buf: [32]byte
	written := serializeGetTasksRequest(req, buf[:])
	if written != size {
		return hgl.interesting("serializeGetTasksRequest size")
	}
	if get_opcode(buf[:written]) != .C_GetTasks {
		return hgl.interesting("serializeGetTasksRequest opcode")
	}

	parsed, parse_err := parseGetTasksRequest(buf[2:written])
	if parse_err != nil {
		return hgl.interesting("parseGetTasksRequest rejected serialized payload")
	}
	if parsed.conv_id != req.conv_id || parsed.correlation_id != req.correlation_id {
		return hgl.interesting("get tasks request roundtrip mismatch")
	}
	return hgl.valid()
}

// ============================================================================
// Parse Robustness Tests: Invalid Data Rejection
// ============================================================================
// These tests generate data known to be invalid (oversized fields, out-of-range
// enums, length mismatches) and verify the parser rejects it with the correct
// error code — without panicking.

build_send_message_payload :: proc(conv_id: ConversationID, client_req_id: u32, content_type: MessageContentType, content_len: u16, buf: []byte) -> int {
	if len(buf) < 15 {
		return -1
	}
	offset := 0
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8
	endian.put_u32(buf[offset:], .Big, client_req_id)
	offset += 4
	buf[offset] = u8(content_type)
	offset += 1
	endian.put_u16(buf[offset:], .Big, content_len)
	offset += 2
	// fill content with zeros if there's room
	fill_len := min(int(content_len), len(buf) - offset)
	if fill_len > 0 {
		fill_bytes(buf[offset:offset + fill_len], u64(content_len) * 31)
	}
	return offset + fill_len
}

@(test)
test_hegel_send_message_rejects_oversized_content :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_send_message_rejects_oversized_content, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel send-message oversized-content property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_send_message_rejects_oversized_content :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	// Cap draw max at max_u16 (65535) — values above overflow u16 and wrap to small values that pass the check
	max_content_in_u16 :: u16(65535)
	content_len_raw, draw_err := hgl.draw_i64(tc, i64(MAX_ALLOWED_CONTENT_LENGTH) + 1, i64(max_content_in_u16))
	if draw_err == .Stop_Test {return hgl.abort()}
	if draw_err != nil {return hgl.interesting("draw oversized content length")}
	content_len := u16(content_len_raw)

	buf: [1024]byte
	total := build_send_message_payload(0, 0, .PlainText, content_len, buf[:])
	if total < 0 {return hgl.interesting("build payload failed")}

	_, parse_err := parseSendMessageRequest(buf[:total])
	if parse_err != .ContentLengthExceedsMax {
		return hgl.interesting("expected ContentLengthExceedsMax")
	}
	return hgl.valid()
}

@(test)
test_hegel_send_message_rejects_length_mismatch :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_send_message_rejects_length_mismatch, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel send-message length-mismatch property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_send_message_rejects_length_mismatch :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	// Declared content_len > actual remaining data in buffer
	actual_raw, draw_err := hgl.draw_i64(tc, 0, 100)
	if draw_err == .Stop_Test {return hgl.abort()}
	if draw_err != nil {return hgl.interesting("draw actual content length")}
	actual := int(actual_raw)

	declared := u16(actual + 1)

	buf: [128]byte
	offset := 0
	endian.put_u64(buf[offset:], .Big, 0)
	offset += 8
	endian.put_u32(buf[offset:], .Big, u32(0))
	offset += 4
	buf[offset] = 0
	offset += 1
	endian.put_u16(buf[offset:], .Big, declared)
	offset += 2
	// fill fewer bytes than declared
	fill_bytes(buf[offset:offset + actual], u64(declared))
	offset += actual

	_, parse_err := parseSendMessageRequest(buf[:offset])
	if parse_err != .ContentLengthMismatch {
		return hgl.interesting("expected ContentLengthMismatch")
	}
	return hgl.valid()
}

build_create_asset_header :: proc(
	conv_id: ConversationID,
	asset_type: u16,
	parent_type: u16,
	parent_id: u64,
	encoding: u8,
	payload_raw_len: u32,
	preview_len: u16,
	payload_len: u16,
	buf: []byte,
) -> int {
	// Minimum: conv_id(8) + asset_type(2) + parent_type(2) + parent_id(8)
	//        + encoding(1) + payload_raw_len(4) + preview_len(2) + payload_len(2) = 29
	if len(buf) < 29 {return -1}
	offset := 0
	endian.put_u64(buf[offset:], .Big, u64(conv_id)); offset += 8
	endian.put_u16(buf[offset:], .Big, asset_type); offset += 2
	endian.put_u16(buf[offset:], .Big, parent_type); offset += 2
	endian.put_u64(buf[offset:], .Big, parent_id); offset += 8
	buf[offset] = encoding; offset += 1
	endian.put_u32(buf[offset:], .Big, payload_raw_len); offset += 4
	endian.put_u16(buf[offset:], .Big, preview_len); offset += 2
	endian.put_u16(buf[offset:], .Big, payload_len); offset += 2
	return offset
}

build_create_asset_probe :: proc(
	encoding: u8,
	payload_raw_len: u32,
	preview_len: u16,
	payload_len: u16,
	preview_fill: []byte,
	payload_fill: []byte,
	buf: []byte,
) -> int {
	offset := build_create_asset_header(0, u16(AssetType.Note), u16(ParentType.None), 0, encoding, payload_raw_len, preview_len, payload_len, buf[:])
	if offset < 0 {return -1}
	offset = append_asset_probe_data(offset, preview_len, payload_len, preview_fill, payload_fill, buf)
	if offset < 0 {return -1}
	// Append correlation_id
	if offset + 4 <= len(buf) {
		endian.put_u32(buf[offset:], .Big, 0)
		offset += 4
	}
	return offset
}

append_asset_probe_data :: proc(offset: int, preview_len: u16, payload_len: u16, preview_fill: []byte, payload_fill: []byte, buf: []byte) -> int {
	pos := offset
	// Append preview bytes
	plen := min(int(preview_len), len(preview_fill))
	if plen > 0 && pos + plen <= len(buf) {
		copy(buf[pos:], preview_fill[:plen])
		pos += plen
	}
	// Append payload bytes
	pylen := min(int(payload_len), len(payload_fill))
	if pylen > 0 && pos + pylen <= len(buf) {
		copy(buf[pos:], payload_fill[:pylen])
		pos += pylen
	}
	return pos
}

@(test)
test_hegel_create_asset_rejects_invalid_data :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_create_asset_rejects_invalid_data, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel create-asset invalid-data property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_create_asset_rejects_invalid_data :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	return prop_asset_rejects_invalid_data(tc, false)
}

prop_asset_rejects_invalid_data :: proc(tc: ^hgl.Test_Case, update: bool) -> hgl.Body_Result {
	// Randomly choose which invalid case to exercise
	case_selector_raw, draw_err := hgl.draw_i64(tc, 0, 3)
	if draw_err == .Stop_Test {return hgl.abort()}
	if draw_err != nil {return hgl.interesting("draw case selector")}
	case_selector := int(case_selector_raw)

	buf: [132]byte

	switch case_selector {
	case 0:
		// Invalid PayloadEncoding value (anything other than 0 or 1)
		encoding_raw, derr := hgl.draw_i64(tc, 2, 255)
		if derr == .Stop_Test {return hgl.abort()}
		if derr != nil {return hgl.interesting("draw invalid encoding")}
		offset := build_asset_invalid_probe(update, u8(encoding_raw), 0, 0, 0, nil, nil, buf[:])
		if offset < 0 {return hgl.interesting("build probe failed")}
		parse_err := parse_asset_invalid_probe(update, buf[:offset])
		if parse_err != .InvalidContentType {
			return hgl.interesting("expected InvalidContentType for encoding")
		}

	case 1:
		// Oversized payload_raw_len (u32 — no overflow risk)
		raw_len_raw, derr := hgl.draw_i64(tc, i64(MAX_PAYLOAD_LENGTH) + 1, i64(MAX_PAYLOAD_LENGTH) * 2)
		if derr == .Stop_Test {return hgl.abort()}
		if derr != nil {return hgl.interesting("draw oversized raw_len")}
		offset := build_asset_invalid_probe(update, u8(PayloadEncoding.Plain), u32(raw_len_raw), 0, 0, nil, nil, buf[:])
		if offset < 0 {return hgl.interesting("build probe failed")}
		parse_err := parse_asset_invalid_probe(update, buf[:offset])
		if parse_err != .ContentLengthExceedsMax {
			return hgl.interesting("expected ContentLengthExceedsMax for raw_len")
		}

	case 2:
		// Oversized preview — parser checks preview_len > MAX_PREVIEW_LENGTH before reading data
		prev_len_raw, derr := hgl.draw_i64(tc, i64(MAX_PREVIEW_LENGTH) + 1, 65535)
		if derr == .Stop_Test {return hgl.abort()}
		if derr != nil {return hgl.interesting("draw oversized preview length")}
		prev_len := u16(prev_len_raw)
		offset := build_asset_invalid_probe(update, u8(PayloadEncoding.Plain), 0, prev_len, 0, nil, nil, buf[:])
		if offset < 0 {return hgl.interesting("build probe failed")}
		parse_err := parse_asset_invalid_probe(update, buf[:offset])
		if parse_err != .ContentLengthExceedsMax {
			return hgl.interesting("expected ContentLengthExceedsMax for preview")
		}

	case 3:
		// Plain encoding but payload_raw_len != actual payload length
		plen_raw, derr := hgl.draw_i64(tc, 1, 64)
		if derr == .Stop_Test {return hgl.abort()}
		if derr != nil {return hgl.interesting("draw payload length")}
		plen := u16(plen_raw)
		// Declare raw_len as plen + 1 so it mismatches
		payload_fill: [64]byte
		offset := build_asset_invalid_probe(update, u8(PayloadEncoding.Plain), u32(plen) + 1, 0, plen, nil, payload_fill[:plen], buf[:])
		if offset < 0 {return hgl.interesting("build probe failed")}
		parse_err := parse_asset_invalid_probe(update, buf[:offset])
		if parse_err != .ContentLengthMismatch {
			return hgl.interesting("expected ContentLengthMismatch for plain encoding mismatch")
		}
	}

	return hgl.valid()
}

build_asset_invalid_probe :: proc(
	update: bool,
	encoding: u8,
	payload_raw_len: u32,
	preview_len: u16,
	payload_len: u16,
	preview_fill: []byte,
	payload_fill: []byte,
	buf: []byte,
) -> int {
	if update {
		return build_update_asset_probe(encoding, payload_raw_len, preview_len, payload_len, preview_fill, payload_fill, buf)
	}
	return build_create_asset_probe(encoding, payload_raw_len, preview_len, payload_len, preview_fill, payload_fill, buf)
}

parse_asset_invalid_probe :: proc(update: bool, data: []byte) -> ProtocolParseError {
	if update {
		_, parse_err := parseUpdateAssetRequest(data)
		return parse_err
	}
	_, parse_err := parseCreateAssetRequest(data)
	return parse_err
}

@(test)
test_hegel_update_asset_rejects_invalid_data :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_update_asset_rejects_invalid_data, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel update-asset invalid-data property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

build_update_asset_header :: proc(
	conv_id: ConversationID,
	asset_id: AssetID,
	encoding: u8,
	payload_raw_len: u32,
	preview_len: u16,
	payload_len: u16,
	buf: []byte,
) -> int {
	// Minimum: conv_id(8) + asset_id(8) + encoding(1) + payload_raw_len(4) + preview_len(2) + payload_len(2) = 25
	if len(buf) < 25 {return -1}
	offset := 0
	endian.put_u64(buf[offset:], .Big, u64(conv_id)); offset += 8
	endian.put_u64(buf[offset:], .Big, u64(asset_id)); offset += 8
	buf[offset] = encoding; offset += 1
	endian.put_u32(buf[offset:], .Big, payload_raw_len); offset += 4
	endian.put_u16(buf[offset:], .Big, preview_len); offset += 2
	endian.put_u16(buf[offset:], .Big, payload_len); offset += 2
	return offset
}

build_update_asset_probe :: proc(
	encoding: u8,
	payload_raw_len: u32,
	preview_len: u16,
	payload_len: u16,
	preview_fill: []byte,
	payload_fill: []byte,
	buf: []byte,
) -> int {
	offset := build_update_asset_header(0, 0, encoding, payload_raw_len, preview_len, payload_len, buf[:])
	if offset < 0 {return -1}
	offset = append_asset_probe_data(offset, preview_len, payload_len, preview_fill, payload_fill, buf)
	if offset < 0 {return -1}
	return offset
}

prop_update_asset_rejects_invalid_data :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	return prop_asset_rejects_invalid_data(tc, true)
}

@(test)
test_hegel_create_task_rejects_oversized_fields :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_create_task_rejects_oversized_fields, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel create-task oversized-fields property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_create_task_rejects_oversized_fields :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	field_selector_raw, draw_err := hgl.draw_i64(tc, 0, 2)
	if draw_err == .Stop_Test {return hgl.abort()}
	if draw_err != nil {return hgl.interesting("draw field selector")}

	buf: [4096]byte
	offset := 0
	endian.put_u64(buf[offset:], .Big, 0)
	offset += 8

	field_selector := int(field_selector_raw)

	if field_selector == 0 {
		// Oversized title
		title_len_raw, derr := hgl.draw_i64(tc, i64(MAX_TASK_TITLE_LENGTH) + 1, i64(MAX_TASK_TITLE_LENGTH) * 2)
		if derr == .Stop_Test {return hgl.abort()}
		if derr != nil {return hgl.interesting("draw oversized title length")}
		endian.put_u16(buf[offset:], .Big, u16(title_len_raw))
		offset += 2
		_, parse_err := parseCreateTaskRequest(buf[:offset])
		if parse_err != .ContentLengthExceedsMax {
			return hgl.interesting("title")
		}
	} else if field_selector == 1 {
		// Oversized description (need valid title + padding for desc check to trigger first)
		title_len := u16(8)
		endian.put_u16(buf[offset:], .Big, title_len)
		offset += 2
		fill_bytes(buf[offset:offset + 8], 42)
		offset += 8

		desc_len_raw, derr := hgl.draw_i64(tc, i64(MAX_TASK_DESCRIPTION_LENGTH) + 1, i64(MAX_TASK_DESCRIPTION_LENGTH) * 2)
		if derr == .Stop_Test {return hgl.abort()}
		if derr != nil {return hgl.interesting("draw oversized description length")}
		endian.put_u16(buf[offset:], .Big, u16(desc_len_raw))
		offset += 2
		// Add priority byte so parser doesn't bail with ContentLengthMismatch before the desc check
		buf[offset] = 0
		offset += 1
		_, parse_err := parseCreateTaskRequest(buf[:offset])
		if parse_err != .ContentLengthExceedsMax {
			return hgl.interesting("desc")
		}
	} else {
		// Oversized external_ref (need valid title + desc + priority + color first)
		title := "title"
		endian.put_u16(buf[offset:], .Big, u16(len(title)))
		offset += 2
		copy(buf[offset:], title)
		offset += len(title)

		endian.put_u16(buf[offset:], .Big, 0) // empty description
		offset += 2

		buf[offset] = 0 // priority
		offset += 1
		buf[offset] = u8(TaskColor.None) // color
		offset += 1

		ext_ref_len_raw, derr := hgl.draw_i64(tc, i64(MAX_EXTERNAL_REF_LENGTH) + 1, i64(MAX_EXTERNAL_REF_LENGTH) * 2)
		if derr == .Stop_Test {return hgl.abort()}
		if derr != nil {return hgl.interesting("draw oversized external ref length")}
		endian.put_u16(buf[offset:], .Big, u16(ext_ref_len_raw))
		offset += 2
		_, parse_err := parseCreateTaskRequest(buf[:offset])
		if parse_err != .ContentLengthExceedsMax {
			return hgl.interesting("extref")
		}
	}
	return hgl.valid()
}

@(test)
test_hegel_create_task_rejects_too_many_attachments :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_create_task_rejects_too_many_attachments, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel create-task too-many-attachments property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_create_task_rejects_too_many_attachments :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	att_count_raw, draw_err := hgl.draw_i64(tc, i64(MAX_ATTACHMENTS_PER_TASK) + 1, i64(MAX_ATTACHMENTS_PER_TASK) + 50)
	if draw_err == .Stop_Test {return hgl.abort()}
	if draw_err != nil {return hgl.interesting("draw excessive attachment count")}

	buf: [4096]byte
	offset := 0
	endian.put_u64(buf[offset:], .Big, 0)
	offset += 8

	// Valid title
	title := "task"
	endian.put_u16(buf[offset:], .Big, u16(len(title)))
	offset += 2
	copy(buf[offset:], title)
	offset += len(title)

	// Empty description
	endian.put_u16(buf[offset:], .Big, 0)
	offset += 2

	buf[offset] = 0 // priority
	offset += 1
	buf[offset] = u8(TaskColor.None) // color
	offset += 1

	// Empty external_ref
	endian.put_u16(buf[offset:], .Big, 0)
	offset += 2

	// due_at = 0
	endian.put_u64(buf[offset:], .Big, 0)
	offset += 8

	// Excessive attachment count
	endian.put_u16(buf[offset:], .Big, u16(att_count_raw))
	offset += 2

	_, parse_err := parseCreateTaskRequest(buf[:offset])
	if parse_err != .TooMany {
		return hgl.interesting("expected TooMany for attachments")
	}
	return hgl.valid()
}

@(test)
test_hegel_subscribe_unsubscribe_too_many_convs :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_subscribe_unsubscribe_too_many_convs, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel subscribe/unsubscribe too-many-convs property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_subscribe_unsubscribe_too_many_convs :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	which_raw, draw_err := hgl.draw_i64(tc, 0, 1)
	if draw_err == .Stop_Test {return hgl.abort()}
	if draw_err != nil {return hgl.interesting("draw subscribe/unsubscribe selector")}

	count_raw, count_err2 := hgl.draw_i64(tc, i64(MAX_SUBSCRIBE_CONVS) + 1, i64(MAX_SUBSCRIBE_CONVS) * 2)
	if count_err2 == .Stop_Test {return hgl.abort()}
	if count_err2 != nil {return hgl.interesting("draw excessive conv count")}

	buf: [2048]byte
	endian.put_u16(buf[0:], .Big, u16(count_raw))

	if which_raw == 0 {
		_, parse_err := parseSubscribeConvsRequest(buf[:])
		if parse_err != .TooMany {
			return hgl.interesting("expected TooMany for subscribe convs")
		}
	} else {
		_, parse_err := parseUnsubscribeConvsRequest(buf[:])
		if parse_err != .TooMany {
			return hgl.interesting("expected TooMany for unsubscribe convs")
		}
	}
	return hgl.valid()
}

@(test)
test_hegel_authenticate_rejects_oversized_token :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_authenticate_rejects_oversized_token, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel authenticate oversized-token property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_authenticate_rejects_oversized_token :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	token_len_raw, draw_err := hgl.draw_i64(tc, i64(MAX_TOKEN_LENGTH) + 1, i64(MAX_TOKEN_LENGTH) * 2)
	if draw_err == .Stop_Test {return hgl.abort()}
	if draw_err != nil {return hgl.interesting("draw oversized token length")}

	buf: [8192]byte
	endian.put_u16(buf[0:], .Big, u16(token_len_raw))

	_, parse_err := parseAuthenticateRequest(buf[:2])
	if parse_err != .ContentLengthExceedsMax {
		return hgl.interesting("expected ContentLengthExceedsMax for token")
	}
	return hgl.valid()
}

hegel_attachment_wire_size :: proc(att: Attachment) -> int {
	return 2 + len(att.file_id) + 2 + len(att.filename) + 8 + 2 + len(att.mime_type) + 8
}

hegel_task_wire_size :: proc(task: Task) -> int {
	size :=
		8 +
		8 +
		2 +
		len(task.title) +
		2 +
		len(task.description) +
		1 +
		2 +
		2 +
		len(task.assignee) +
		1 +
		1 +
		2 +
		len(task.created_by) +
		8 +
		8 +
		2 +
		len(task.external_ref) +
		8 +
		8 +
		8 +
		2 +
		len(task.completed_by) +
		2 +
		len(task.project) +
		2
	for att in task.attachments {
		size += hegel_attachment_wire_size(att)
	}
	return size
}

hegel_task_list_response_wire_size :: proc(msg: TaskListResponse) -> int {
	size := 2 + 8 + 1 + 2 + 2 + len(msg.error) + 4
	for task in msg.tasks {
		size += hegel_task_wire_size(task)
	}
	return size
}

hegel_edge_wire_size :: proc(edge: Edge) -> int {
	return 8 + 8 + 2 + 8 + 2 + 8 + 2 + 8 + 2 + len(edge.created_by)
}

hegel_edge_list_response_wire_size :: proc(msg: EdgeListMessage) -> int {
	size := 2 + 8 + 2 + 8 + 2 + 4
	for edge in msg.edges {
		size += hegel_edge_wire_size(edge)
	}
	return size
}

hegel_all_edge_list_response_wire_size :: proc(msg: AllEdgeListMessage) -> int {
	size := 2 + 8 + 4 + 4
	for edge in msg.edges {
		size += hegel_edge_wire_size(edge)
	}
	return size
}

hegel_attachment_equal :: proc(a, b: Attachment) -> bool {
	return(
		bytes_equal(a.file_id, b.file_id) &&
		bytes_equal(a.filename, b.filename) &&
		a.size == b.size &&
		bytes_equal(a.mime_type, b.mime_type) &&
		a.uploaded_at == b.uploaded_at \
	)
}

hegel_task_equal :: proc(a, b: Task) -> bool {
	if a.id != b.id ||
	   a.conv_id != b.conv_id ||
	   !bytes_equal(a.title, b.title) ||
	   !bytes_equal(a.description, b.description) ||
	   a.status != b.status ||
	   a.order_index != b.order_index ||
	   !bytes_equal(a.assignee, b.assignee) ||
	   a.priority != b.priority ||
	   a.color != b.color ||
	   !bytes_equal(a.created_by, b.created_by) ||
	   a.created_at != b.created_at ||
	   a.updated_at != b.updated_at ||
	   !bytes_equal(a.external_ref, b.external_ref) ||
	   a.due_at != b.due_at ||
	   a.blocked_by != b.blocked_by ||
	   a.completed_at != b.completed_at ||
	   !bytes_equal(a.completed_by, b.completed_by) ||
	   !bytes_equal(a.project, b.project) ||
	   len(a.attachments) != len(b.attachments) {
		return false
	}
	for att, i in a.attachments {
		if !hegel_attachment_equal(att, b.attachments[i]) do return false
	}
	return true
}

hegel_edge_equal :: proc(a, b: Edge) -> bool {
	return(
		a.edge_id == b.edge_id &&
		a.conv_id == b.conv_id &&
		a.source_type == b.source_type &&
		a.source_id == b.source_id &&
		a.target_type == b.target_type &&
		a.target_id == b.target_id &&
		a.relation == b.relation &&
		a.created_at == b.created_at &&
		bytes_equal(a.created_by, b.created_by) \
	)
}

hegel_asset_equal :: proc(a, b: Asset) -> bool {
	if !(a.asset_type == b.asset_type &&
		   a.asset_id == b.asset_id &&
		   a.parent_type == b.parent_type &&
		   a.parent_id == b.parent_id &&
		   bytes_equal(a.owner, b.owner) &&
		   a.created_at == b.created_at &&
		   a.updated_at == b.updated_at &&
		   a.conv_id == b.conv_id &&
		   a.payload_encoding == b.payload_encoding &&
		   a.payload_raw_len == b.payload_raw_len &&
		   bytes_equal(a.preview, b.preview) &&
		   bytes_equal(a.payload, b.payload) &&
		   len(a.attachments) == len(b.attachments)) {
		return false
	}
	for att, i in a.attachments {
		if !hegel_attachment_equal(att, b.attachments[i]) do return false
	}
	return true
}

hegel_string_slices_equal :: proc(a, b: []string) -> bool {
	if len(a) != len(b) do return false
	for item, i in a {
		if item != b[i] do return false
	}
	return true
}

hegel_draw_len :: proc(tc: ^hgl.Test_Case, max_value: i64, label: string) -> (int, hgl.Body_Result, bool) {
	raw, err := hgl.draw_i64(tc, 0, max_value)
	if err == .Stop_Test do return 0, hgl.abort(), false
	if err != nil do return 0, hgl.interesting(label), false
	return int(raw), hgl.valid(), true
}
