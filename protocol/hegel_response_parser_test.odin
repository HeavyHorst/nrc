package protocol

// Hegel properties for promoted server response parsers.
//
// These properties serialize production S_* response messages, parse them back
// through the protocol response decoders used by simulator oracles, and generate
// malformed variants that must be rejected. Keeping these parser properties in a
// focused file prevents the broader protocol request/roundtrip property file from
// becoming the dumping ground for every response decoder case.

import "core:encoding/endian"
import "core:testing"

import hgl "../hegel"

@(test)
test_hegel_promoted_response_parser_roundtrips :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_promoted_response_parser_roundtrips, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel promoted response parser property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_promoted_response_parser_roundtrips :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	conv_id_raw, draw_err := hgl.draw_i64(tc, 0, 9_000_000_000_000)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil do return hgl.interesting("draw response conv id")
	conv_id := ConversationID(conv_id_raw)

	correlation_raw: i64
	correlation_raw, draw_err = hgl.draw_i64(tc, 0, 0xFFFF_FFFF)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil do return hgl.interesting("draw response correlation id")
	correlation_id := u32(correlation_raw)

	draw_result: hgl.Body_Result
	draw_ok: bool
	task_count: int
	task_count, draw_result, draw_ok = hegel_draw_len(tc, 3, "draw task response count")
	if !draw_ok do return draw_result
	edge_count: int
	error_len: int
	edge_count, draw_result, draw_ok = hegel_draw_len(tc, 4, "draw edge response count")
	if !draw_ok do return draw_result
	error_len, draw_result, draw_ok = hegel_draw_len(tc, 8, "draw task response error length")
	if !draw_ok do return draw_result

	error_storage: [8]byte
	fill_bytes(error_storage[:], u64(correlation_id) + 5)

	tasks: [3]Task
	attachments: [6]Attachment
	title_storage: [3][8]byte
	desc_storage: [3][8]byte
	assignee_storage: [3][8]byte
	created_by_storage: [3][8]byte
	external_ref_storage: [3][8]byte
	completed_by_storage: [3][8]byte
	project_storage: [3][8]byte
	att_file_storage: [6][8]byte
	att_name_storage: [6][8]byte
	att_mime_storage: [6][8]byte
	attachment_pos := 0

	for i in 0 ..< task_count {
		status_index_raw, status_err := hgl.draw_i64(tc, 0, i64(task_status_count() - 1))
		if status_err == .Stop_Test do return hgl.abort()
		if status_err != nil do return hgl.interesting("draw task response status")
		status, status_ok := task_status_by_index(int(status_index_raw))
		if !status_ok do return hgl.interesting("select task response status")

		title_len: int
		title_len, draw_result, draw_ok = hegel_draw_len(tc, 8, "draw task response title length")
		if !draw_ok do return draw_result
		desc_len: int
		assignee_len: int
		created_by_len: int
		external_ref_len: int
		completed_by_len: int
		project_len: int
		attachment_count: int
		desc_len, draw_result, draw_ok = hegel_draw_len(tc, 8, "draw task response description length")
		if !draw_ok do return draw_result
		assignee_len, draw_result, draw_ok = hegel_draw_len(tc, 8, "draw task response assignee length")
		if !draw_ok do return draw_result
		created_by_len, draw_result, draw_ok = hegel_draw_len(tc, 8, "draw task response created-by length")
		if !draw_ok do return draw_result
		external_ref_len, draw_result, draw_ok = hegel_draw_len(tc, 8, "draw task response external-ref length")
		if !draw_ok do return draw_result
		completed_by_len, draw_result, draw_ok = hegel_draw_len(tc, 8, "draw task response completed-by length")
		if !draw_ok do return draw_result
		project_len, draw_result, draw_ok = hegel_draw_len(tc, 8, "draw task response project length")
		if !draw_ok do return draw_result
		attachment_count, draw_result, draw_ok = hegel_draw_len(tc, 2, "draw task response attachment count")
		if !draw_ok do return draw_result

		seed := u64(correlation_id) + u64(i) * 100
		fill_bytes(title_storage[i][:], seed + 1)
		fill_bytes(desc_storage[i][:], seed + 2)
		fill_bytes(assignee_storage[i][:], seed + 3)
		fill_bytes(created_by_storage[i][:], seed + 4)
		fill_bytes(external_ref_storage[i][:], seed + 5)
		fill_bytes(completed_by_storage[i][:], seed + 6)
		fill_bytes(project_storage[i][:], seed + 7)

		for j in 0 ..< attachment_count {
			file_len: int
			file_len, draw_result, draw_ok = hegel_draw_len(tc, 8, "draw task response attachment file length")
			if !draw_ok do return draw_result
			name_len: int
			mime_len: int
			name_len, draw_result, draw_ok = hegel_draw_len(tc, 8, "draw task response attachment filename length")
			if !draw_ok do return draw_result
			mime_len, draw_result, draw_ok = hegel_draw_len(tc, 8, "draw task response attachment mime length")
			if !draw_ok do return draw_result

			att_index := attachment_pos + j
			att_seed := seed + u64(j) * 10
			fill_bytes(att_file_storage[att_index][:], att_seed + 7)
			fill_bytes(att_name_storage[att_index][:], att_seed + 8)
			fill_bytes(att_mime_storage[att_index][:], att_seed + 9)
			attachments[att_index] = Attachment {
				file_id     = att_file_storage[att_index][:file_len],
				filename    = att_name_storage[att_index][:name_len],
				size        = u64(seed + u64(j) + 1000),
				mime_type   = att_mime_storage[att_index][:mime_len],
				uploaded_at = i64(seed + u64(j) + 2000),
			}
		}

		tasks[i] = Task {
			id           = TaskID(100 + i),
			conv_id      = conv_id,
			title        = title_storage[i][:title_len],
			description  = desc_storage[i][:desc_len],
			status       = status,
			order_index  = u16(i * 10 + 1),
			assignee     = assignee_storage[i][:assignee_len],
			priority     = u8(i * 50),
			color        = TaskColor(i % 4),
			created_by   = created_by_storage[i][:created_by_len],
			created_at   = i64(seed + 10),
			updated_at   = i64(seed + 11),
			external_ref = external_ref_storage[i][:external_ref_len],
			due_at       = i64(seed + 12),
			blocked_by   = TaskID(200 + i),
			completed_at = i64(seed + 13),
			completed_by = completed_by_storage[i][:completed_by_len],
			project      = project_storage[i][:project_len],
			attachments  = attachments[attachment_pos:attachment_pos + attachment_count],
		}
		attachment_pos += attachment_count
	}

	task_msg := TaskListResponse {
		conv_id        = conv_id,
		success        = (correlation_id & 1) == 0,
		tasks          = tasks[:task_count],
		error          = error_storage[:error_len],
		correlation_id = correlation_id,
	}
	task_expected_size := hegel_task_list_response_wire_size(task_msg)
	if getSizeTaskListResponse(task_msg) != task_expected_size do return hgl.interesting("task list response independent size")
	task_buf: [2048]byte
	task_written := serializeTaskListResponse(task_msg, task_buf[:])
	if task_written != task_expected_size do return hgl.interesting("serialize task list response size")
	decoded_tasks: [3]Task
	decoded_attachments: [6]Attachment
	parsed_tasks, task_err := parseTaskListResponse(task_buf[:task_written], decoded_tasks[:], decoded_attachments[:])
	if task_err != nil ||
	   parsed_tasks.conv_id != task_msg.conv_id ||
	   parsed_tasks.success != task_msg.success ||
	   !bytes_equal(parsed_tasks.error, task_msg.error) ||
	   parsed_tasks.correlation_id != task_msg.correlation_id ||
	   len(parsed_tasks.tasks) != len(task_msg.tasks) {
		return hgl.interesting("decode task list response header")
	}
	for task, i in parsed_tasks.tasks {
		if !hegel_task_equal(task, task_msg.tasks[i]) do return hgl.interesting("decode task list response task")
	}

	edges: [4]Edge
	edge_created_by_storage: [4][8]byte
	for i in 0 ..< edge_count {
		created_by_len: int
		created_by_len, draw_result, draw_ok = hegel_draw_len(tc, 8, "draw edge response created-by length")
		if !draw_ok do return draw_result
		seed := u64(correlation_id) + u64(i) * 37 + 500
		fill_bytes(edge_created_by_storage[i][:], seed)
		edges[i] = Edge {
			edge_id     = EdgeID(1000 + i),
			conv_id     = conv_id,
			source_type = (i & 1) == 0 ? TargetType.Task : TargetType.Asset,
			source_id   = u64(2000 + i),
			target_type = (i & 1) == 0 ? TargetType.Asset : TargetType.Task,
			target_id   = u64(3000 + i),
			relation    = (i & 1) == 0 ? RelationType.References : RelationType.Blocks,
			created_at  = i64(seed + 1),
			created_by  = edge_created_by_storage[i][:created_by_len],
		}
	}

	edge_msg := EdgeListMessage {
		conv_id        = conv_id,
		target_type    = .Task,
		target_id      = 4242,
		edges          = edges[:edge_count],
		correlation_id = correlation_id,
	}
	edge_expected_size := hegel_edge_list_response_wire_size(edge_msg)
	if getSizeEdgeListMessage(edge_msg) != edge_expected_size do return hgl.interesting("edge list response independent size")
	edge_buf: [1024]byte
	edge_written := serializeEdgeListMessage(edge_msg, edge_buf[:])
	if edge_written != edge_expected_size do return hgl.interesting("serialize edge list response size")
	decoded_edges: [4]Edge
	parsed_edges, edge_err := parseEdgeListMessage(edge_buf[:edge_written], decoded_edges[:])
	if edge_err != nil ||
	   parsed_edges.conv_id != edge_msg.conv_id ||
	   parsed_edges.target_type != edge_msg.target_type ||
	   parsed_edges.target_id != edge_msg.target_id ||
	   parsed_edges.correlation_id != edge_msg.correlation_id ||
	   len(parsed_edges.edges) != len(edge_msg.edges) {
		return hgl.interesting("decode edge list response header")
	}
	for edge, i in parsed_edges.edges {
		if !hegel_edge_equal(edge, edge_msg.edges[i]) do return hgl.interesting("decode edge list response edge")
	}

	all_edge_msg := AllEdgeListMessage {
		conv_id        = conv_id,
		edges          = edges[:edge_count],
		correlation_id = correlation_id,
	}
	all_edge_expected_size := hegel_all_edge_list_response_wire_size(all_edge_msg)
	if getSizeAllEdgeListMessage(all_edge_msg) != all_edge_expected_size do return hgl.interesting("all edge list response independent size")
	all_edge_buf: [1024]byte
	all_edge_written := serializeAllEdgeListMessage(all_edge_msg, all_edge_buf[:])
	if all_edge_written != all_edge_expected_size do return hgl.interesting("serialize all edge list response size")
	decoded_all_edges: [4]Edge
	parsed_all_edges, all_edge_err := parseAllEdgeListMessage(all_edge_buf[:all_edge_written], decoded_all_edges[:])
	if all_edge_err != nil ||
	   parsed_all_edges.conv_id != all_edge_msg.conv_id ||
	   parsed_all_edges.correlation_id != all_edge_msg.correlation_id ||
	   len(parsed_all_edges.edges) != len(all_edge_msg.edges) {
		return hgl.interesting("decode all edge list response header")
	}
	for edge, i in parsed_all_edges.edges {
		if !hegel_edge_equal(edge, all_edge_msg.edges[i]) do return hgl.interesting("decode all edge list response edge")
	}

	asset_count: int
	asset_count, draw_result, draw_ok = hegel_draw_len(tc, 3, "draw asset page response count")
	if !draw_ok do return draw_result
	full_content_raw: i64
	full_content_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 1, "draw asset page full-content flag")
	if !draw_ok do return draw_result
	full_content := full_content_raw != 0
	has_more_raw: i64
	has_more_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 1, "draw asset page has-more flag")
	if !draw_ok do return draw_result
	cursor_updated_at_raw: i64
	cursor_updated_at_raw, draw_result, draw_ok = draw_i64_or_result(tc, -1_000_000_000_000, 1_000_000_000_000, "draw asset page cursor timestamp")
	if !draw_ok do return draw_result
	cursor_asset_id_raw: i64
	cursor_asset_id_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 9_000_000_000_000, "draw asset page cursor id")
	if !draw_ok do return draw_result
	total_count_raw: i64
	total_count_raw, draw_result, draw_ok = draw_i64_or_result(tc, i64(asset_count), i64(asset_count + 20), "draw asset page total count")
	if !draw_ok do return draw_result

	assets: [3]Asset
	asset_owner_storage: [3][8]byte
	asset_preview_storage: [3][8]byte
	asset_payload_storage: [3][8]byte
	for i in 0 ..< asset_count {
		owner_len: int
		owner_len, draw_result, draw_ok = hegel_draw_len(tc, 8, "draw asset page owner length")
		if !draw_ok do return draw_result
		preview_len: int
		preview_len, draw_result, draw_ok = hegel_draw_len(tc, 8, "draw asset page preview length")
		if !draw_ok do return draw_result
		payload_len: int
		payload_len, draw_result, draw_ok = hegel_draw_len(tc, 8, "draw asset page payload length")
		if !draw_ok do return draw_result

		seed := u64(correlation_id) + u64(i) * 71 + 900
		fill_bytes(asset_owner_storage[i][:], seed + 1)
		fill_bytes(asset_preview_storage[i][:], seed + 2)
		fill_bytes(asset_payload_storage[i][:], seed + 3)
		assets[i] = Asset {
			asset_type       = AssetType(u64(min(AssetType)) + seed % u64(len(AssetType))),
			asset_id         = AssetID(7000 + i),
			parent_type      = (i & 1) == 0 ? ParentType.Task : ParentType.Asset,
			parent_id        = u64(8000 + i),
			owner            = asset_owner_storage[i][:owner_len],
			created_at       = i64(seed + 4),
			updated_at       = i64(seed + 5),
			conv_id          = conv_id,
			payload_encoding = .Plain,
			payload_raw_len  = u32(payload_len),
			preview          = asset_preview_storage[i][:preview_len],
			payload          = full_content ? asset_payload_storage[i][:payload_len] : nil,
		}
	}

	asset_list_msg := AssetListMessage {
		conv_id        = conv_id,
		assets         = assets[:asset_count],
		full_content   = full_content,
		correlation_id = correlation_id,
	}
	asset_list_buf: [1024]byte
	asset_list_written := serializeAssetListMessage(asset_list_msg, asset_list_buf[:])
	if asset_list_written != getSizeAssetListMessage(asset_list_msg) do return hgl.interesting("serialize asset list response size")
	parsed_asset_list, asset_list_err := parseAssetListMessage(asset_list_buf[:asset_list_written])
	if asset_list_err != nil ||
	   parsed_asset_list.conv_id != asset_list_msg.conv_id ||
	   parsed_asset_list.full_content != asset_list_msg.full_content ||
	   parsed_asset_list.correlation_id != asset_list_msg.correlation_id ||
	   len(parsed_asset_list.assets) != len(asset_list_msg.assets) {
		return hgl.interesting("decode asset list response header")
	}
	defer if len(parsed_asset_list.assets) > 0 do delete(parsed_asset_list.assets)
	for asset, i in parsed_asset_list.assets {
		if !hegel_asset_equal(asset, asset_list_msg.assets[i]) do return hgl.interesting("decode asset list response asset")
	}

	asset_page_msg := AssetListPageMessage {
		conv_id                = conv_id,
		assets                 = assets[:asset_count],
		full_content           = full_content,
		has_more               = has_more_raw != 0,
		next_cursor_updated_at = cursor_updated_at_raw,
		next_cursor_asset_id   = AssetID(cursor_asset_id_raw),
		total_count            = u32(total_count_raw),
		correlation_id         = correlation_id,
	}
	asset_page_buf: [1024]byte
	asset_page_written := serializeAssetListPageMessage(asset_page_msg, asset_page_buf[:])
	if asset_page_written != getSizeAssetListPageMessage(asset_page_msg) do return hgl.interesting("serialize asset page response size")
	parsed_asset_page, asset_page_err := parseAssetListPageMessage(asset_page_buf[:asset_page_written])
	if asset_page_err != nil ||
	   parsed_asset_page.conv_id != asset_page_msg.conv_id ||
	   parsed_asset_page.full_content != asset_page_msg.full_content ||
	   parsed_asset_page.has_more != asset_page_msg.has_more ||
	   parsed_asset_page.next_cursor_updated_at != asset_page_msg.next_cursor_updated_at ||
	   parsed_asset_page.next_cursor_asset_id != asset_page_msg.next_cursor_asset_id ||
	   parsed_asset_page.total_count != asset_page_msg.total_count ||
	   parsed_asset_page.correlation_id != asset_page_msg.correlation_id ||
	   len(parsed_asset_page.assets) != len(asset_page_msg.assets) {
		return hgl.interesting("decode asset page response header")
	}
	defer if len(parsed_asset_page.assets) > 0 do delete(parsed_asset_page.assets)
	for asset, i in parsed_asset_page.assets {
		if !hegel_asset_equal(asset, asset_page_msg.assets[i]) do return hgl.interesting("decode asset page response asset")
	}

	if asset_count > 0 {
		full_asset := assets[0]
		full_asset.payload = asset_payload_storage[0][:full_asset.payload_raw_len]
		asset_created_msg := AssetCreatedMessage {
			asset          = full_asset,
			correlation_id = correlation_id,
		}
		asset_created_buf: [512]byte
		asset_created_written := serializeAssetCreatedMessage(asset_created_msg, asset_created_buf[:])
		if asset_created_written != getSizeAssetCreatedMessage(asset_created_msg) do return hgl.interesting("serialize asset created response size")
		parsed_asset_created, asset_created_err := parseAssetCreatedMessage(asset_created_buf[:asset_created_written])
		if asset_created_err != nil ||
		   parsed_asset_created.correlation_id != asset_created_msg.correlation_id ||
		   !hegel_asset_equal(parsed_asset_created.asset, asset_created_msg.asset) {
			return hgl.interesting("decode asset created response")
		}

		asset_updated_msg := AssetUpdatedMessage {
			asset          = full_asset,
			correlation_id = correlation_id,
		}
		asset_updated_buf: [512]byte
		asset_updated_written := serializeAssetUpdatedMessage(asset_updated_msg, asset_updated_buf[:])
		if asset_updated_written != getSizeAssetUpdatedMessage(asset_updated_msg) do return hgl.interesting("serialize asset updated response size")
		parsed_asset_updated, asset_updated_err := parseAssetUpdatedMessage(asset_updated_buf[:asset_updated_written])
		if asset_updated_err != nil ||
		   parsed_asset_updated.correlation_id != asset_updated_msg.correlation_id ||
		   !hegel_asset_equal(parsed_asset_updated.asset, asset_updated_msg.asset) {
			return hgl.interesting("decode asset updated response")
		}

		asset_full_msg := AssetFullMessage {
			asset          = full_asset,
			correlation_id = correlation_id,
		}
		asset_full_buf: [512]byte
		asset_full_written := serializeAssetFullMessage(asset_full_msg, asset_full_buf[:])
		if asset_full_written != getSizeAssetFullMessage(asset_full_msg) do return hgl.interesting("serialize asset full response size")
		parsed_asset_full, asset_full_err := parseAssetFullMessage(asset_full_buf[:asset_full_written])
		if asset_full_err != nil ||
		   parsed_asset_full.correlation_id != asset_full_msg.correlation_id ||
		   !hegel_asset_equal(parsed_asset_full.asset, asset_full_msg.asset) {
			return hgl.interesting("decode asset full response")
		}
	}

	asset_deleted_msg := AssetDeletedMessage {
		conv_id        = conv_id,
		asset_id       = AssetID(cursor_asset_id_raw),
		correlation_id = correlation_id,
	}
	asset_deleted_buf: [32]byte
	asset_deleted_written := serializeAssetDeletedMessage(asset_deleted_msg, asset_deleted_buf[:])
	if asset_deleted_written != getSizeAssetDeletedMessage(asset_deleted_msg) do return hgl.interesting("serialize asset deleted response size")
	parsed_asset_deleted, asset_deleted_err := parseAssetDeletedMessage(asset_deleted_buf[:asset_deleted_written])
	if asset_deleted_err != nil ||
	   parsed_asset_deleted.conv_id != asset_deleted_msg.conv_id ||
	   parsed_asset_deleted.asset_id != asset_deleted_msg.asset_id ||
	   parsed_asset_deleted.correlation_id != asset_deleted_msg.correlation_id {
		return hgl.interesting("decode asset deleted response")
	}

	project_count: int
	project_count, draw_result, draw_ok = hegel_draw_len(tc, 3, "draw note project response count")
	if !draw_ok do return draw_result
	tag_count: int
	tag_count, draw_result, draw_ok = hegel_draw_len(tc, 3, "draw note tag response count")
	if !draw_ok do return draw_result
	projects_storage := [?]string{"", "ops", "infra"}
	tags_storage := [?]string{"", "urgent", "dst"}
	project_msg := NoteProjectListMessage {
		conv_id        = conv_id,
		projects       = projects_storage[:project_count],
		correlation_id = correlation_id,
	}
	project_buf: [128]byte
	project_written := serializeNoteProjectListMessage(project_msg, project_buf[:])
	if project_written != getSizeNoteProjectListMessage(project_msg) do return hgl.interesting("serialize note project response size")
	parsed_projects, project_err := parseNoteProjectListMessage(project_buf[:project_written])
	if project_err != nil ||
	   parsed_projects.conv_id != project_msg.conv_id ||
	   parsed_projects.correlation_id != project_msg.correlation_id ||
	   !hegel_string_slices_equal(parsed_projects.projects, project_msg.projects) {
		return hgl.interesting("decode note project response")
	}
	defer if len(parsed_projects.projects) > 0 do delete(parsed_projects.projects)

	tag_msg := NoteTagListMessage {
		conv_id        = conv_id,
		tags           = tags_storage[:tag_count],
		correlation_id = correlation_id,
	}
	tag_buf: [128]byte
	tag_written := serializeNoteTagListMessage(tag_msg, tag_buf[:])
	if tag_written != getSizeNoteTagListMessage(tag_msg) do return hgl.interesting("serialize note tag response size")
	parsed_tags, tag_err := parseNoteTagListMessage(tag_buf[:tag_written])
	if tag_err != nil ||
	   parsed_tags.conv_id != tag_msg.conv_id ||
	   parsed_tags.correlation_id != tag_msg.correlation_id ||
	   !hegel_string_slices_equal(parsed_tags.tags, tag_msg.tags) {
		return hgl.interesting("decode note tag response")
	}
	defer if len(parsed_tags.tags) > 0 do delete(parsed_tags.tags)

	return hgl.valid()
}

@(test)
test_hegel_promoted_response_parsers_reject_malformed :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_promoted_response_parsers_reject_malformed, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel promoted malformed response parser property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

@(test)
test_hegel_graph_response_parsers_reject_malformed :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_graph_response_parsers_reject_malformed, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel graph malformed response parser property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

@(test)
test_hegel_asset_note_response_parsers_reject_malformed :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_asset_note_response_parsers_reject_malformed, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel asset/note malformed response parser property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

@(test)
test_hegel_asset_write_response_parsers_reject_malformed :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_asset_write_response_parsers_reject_malformed, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel asset write malformed response parser property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

@(test)
test_hegel_task_write_response_parsers_roundtrip_and_reject_malformed :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_task_write_response_parsers_roundtrip_and_reject_malformed, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel task write response parser property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

@(test)
test_hegel_edge_write_response_parsers_roundtrip_and_reject_malformed :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_edge_write_response_parsers_roundtrip_and_reject_malformed, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel edge write response parser property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

@(test)
test_hegel_message_response_parsers_reject_malformed :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_message_response_parsers_reject_malformed, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel message response parser property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

@(test)
test_hegel_system_response_parsers_reject_malformed :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_system_response_parsers_reject_malformed, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel system response parser property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

@(test)
test_hegel_handshake_auth_response_parsers_reject_malformed :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_handshake_auth_response_parsers_reject_malformed, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel handshake/auth response parser property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

@(test)
test_hegel_dm_response_parsers_roundtrip_and_reject_malformed :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_dm_response_parsers_roundtrip_and_reject_malformed, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel dm response parser property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

@(test)
test_hegel_error_presence_response_parsers_reject_malformed :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}
	result, err := hgl.run(prop_error_presence_response_parsers_reject_malformed, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel error/presence response parser property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_handshake_auth_response_parsers_reject_malformed :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	parser_raw, draw_result, draw_ok := draw_i64_or_result(tc, 0, 1, "draw malformed handshake/auth parser selector")
	if !draw_ok do return draw_result
	variant_raw: i64
	variant_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 4, "draw malformed handshake/auth variant")
	if !draw_ok do return draw_result

	build := [?]byte{'d', 'e', 'v'}
	cpu := [?]byte{'c', 'p', 'u'}
	username := [?]byte{'r', 'e', 'n', 'e'}
	valid: [128]byte
	valid_len := 0
	if parser_raw == 0 {
		ready := ServerReady {
			build_version    = build[:],
			protocol_version = 1,
			cpu_model        = cpu[:],
			username         = username[:],
			is_authenticated = true,
		}
		valid_len = serializeServerReady(ready, valid[:])
	} else {
		auth := AuthenticateResponse {
			success   = true,
			user_id   = username[:],
			nickname  = username[:],
			error_msg = cpu[:],
		}
		valid_len = serializeAuthenticateResponse(auth, valid[:])
	}
	if valid_len <= 0 do return hgl.interesting("build valid handshake/auth response")

	malformed: [129]byte
	copy(malformed[:], valid[:valid_len])
	malformed_len := valid_len
	switch variant_raw {
	case 0:
		truncate_raw, truncate_result, truncate_ok := draw_i64_or_result(tc, 0, i64(valid_len - 1), "draw handshake/auth response truncation")
		if !truncate_ok do return truncate_result
		malformed_len = int(truncate_raw)
	case 1:
		endian.put_u16(malformed[:], .Big, u16(Opcode.C_Ping))
	case 2:
		malformed[valid_len] = 0xA5
		malformed_len = valid_len + 1
	case 3:
		malformed_len = valid_len - 1
	case:
		if parser_raw == 0 {
			endian.put_u16(malformed[2 + 2 + len(build) + 4 + 2 + len(cpu):], .Big, 255)
		} else {
			endian.put_u16(malformed[2 + 1 + 2 + len(username) + 2 + len(username):], .Big, 255)
		}
	}

	parse_err: ProtocolParseError
	accepted := false
	if parser_raw == 0 {
		parsed: ServerReady
		parsed, parse_err = parseServerReadyMessage(malformed[:malformed_len])
		accepted =
			parse_err == nil &&
			parsed.protocol_version == 1 &&
			parsed.is_authenticated &&
			bytes_equal(parsed.build_version, build[:]) &&
			bytes_equal(parsed.cpu_model, cpu[:]) &&
			bytes_equal(parsed.username, username[:])
	} else {
		parsed: AuthenticateResponse
		parsed, parse_err = parseAuthenticateResponseMessage(malformed[:malformed_len])
		accepted =
			parse_err == nil &&
			parsed.success &&
			bytes_equal(parsed.user_id, username[:]) &&
			bytes_equal(parsed.nickname, username[:]) &&
			bytes_equal(parsed.error_msg, cpu[:])
	}
	if variant_raw == 1 && parse_err != .InvalidOpcode do return hgl.interesting("handshake/auth parser wrong opcode was not InvalidOpcode")
	if accepted do return hgl.interesting("handshake/auth parser accepted malformed payload")

	return hgl.valid()
}

prop_dm_response_parsers_roundtrip_and_reject_malformed :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	parser_raw, draw_result, draw_ok := draw_i64_or_result(tc, 0, 4, "draw dm parser selector")
	if !draw_ok do return draw_result
	variant_raw: i64
	variant_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 4, "draw dm malformed variant")
	if !draw_ok do return draw_result
	correlation_raw: i64
	correlation_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 0xFFFF_FFFF, "draw dm correlation")
	if !draw_ok do return draw_result
	correlation_id := u32(correlation_raw)

	username := "alice"
	message := "bad dm"
	conv_id := ConversationID(DM_CONV_FLAG | 77)
	valid: [128]byte
	valid_len := 0
	switch parser_raw {
	case 0:
		valid_len = dm_started_size(username)
		write_dm_started(valid[:valid_len], conv_id, username, true, false, true, correlation_id)
		parsed, parse_err := parseDMStartedMessage(valid[:valid_len])
		if parse_err != nil || parsed.conv_id != conv_id || parsed.username != username || !parsed.authenticated || parsed.online || !parsed.is_initiator || parsed.correlation_id != correlation_id do return hgl.interesting("dm started roundtrip")
	case 1:
		entry := DMEntry {
			conv_id       = conv_id,
			username      = username,
			authenticated = true,
			online        = false,
			last_seen     = 123,
		}
		valid_len = dm_list_header_size() + dm_entry_size(username)
		write_dm_list_header(valid[:valid_len], 1, correlation_id)
		_ = write_dm_entry(valid[dm_list_header_size():valid_len], entry)
		entries: [1]DMEntry
		parsed, parse_err := parseDMListMessage(valid[:valid_len], entries[:])
		if parse_err != nil || parsed.correlation_id != correlation_id || len(parsed.entries) != 1 || parsed.entries[0].conv_id != conv_id || parsed.entries[0].username != username || !parsed.entries[0].authenticated || parsed.entries[0].online || parsed.entries[0].last_seen != 123 do return hgl.interesting("dm list roundtrip")
	case 2:
		valid_len = dm_error_size(username, message)
		write_dm_error(valid[:valid_len], .User_Not_Found, username, message, correlation_id)
		parsed, parse_err := parseDMErrorMessage(valid[:valid_len])
		if parse_err != nil || parsed.code != .User_Not_Found || parsed.target_username != username || parsed.message != message || parsed.correlation_id != correlation_id do return hgl.interesting("dm error roundtrip")
	case 3:
		valid_len = dm_left_size()
		write_dm_left(valid[:valid_len], conv_id, correlation_id)
		parsed, parse_err := parseDMLeftMessage(valid[:valid_len])
		if parse_err != nil || parsed.conv_id != conv_id || parsed.correlation_id != correlation_id do return hgl.interesting("dm left roundtrip")
	case:
		valid_len = dm_partner_status_size(username)
		write_dm_partner_status(valid[:valid_len], conv_id, true, username, 456)
		parsed, parse_err := parseDMPartnerStatusMessage(valid[:valid_len])
		if parse_err != nil || parsed.conv_id != conv_id || !parsed.online || parsed.username != username || parsed.last_seen != 456 do return hgl.interesting("dm partner status roundtrip")
	}
	if valid_len <= 0 do return hgl.interesting("build valid dm response")

	malformed: [129]byte
	copy(malformed[:], valid[:valid_len])
	malformed_len := valid_len
	switch variant_raw {
	case 0:
		truncate_raw, truncate_result, truncate_ok := draw_i64_or_result(tc, 0, i64(valid_len - 1), "draw dm response truncation")
		if !truncate_ok do return truncate_result
		malformed_len = int(truncate_raw)
	case 1:
		endian.put_u16(malformed[:], .Big, u16(Opcode.C_Ping))
	case 2:
		malformed[valid_len] = 0xA5
		malformed_len = valid_len + 1
	case 3:
		if parser_raw == 1 {
			entries: [0]DMEntry
			_, parse_err := parseDMListMessage(malformed[:malformed_len], entries[:])
			if parse_err != .TooMany do return hgl.interesting("dm list count exceeding caller buffer was not TooMany")
			return hgl.valid()
		}
		malformed_len = valid_len - 1
	case:
		if parser_raw == 0 {
			endian.put_u16(malformed[10:], .Big, 255)
		} else if parser_raw == 1 {
			endian.put_u16(malformed[dm_list_header_size() + 8:], .Big, 255)
		} else if parser_raw == 2 {
			endian.put_u16(malformed[3:], .Big, 255)
		} else if parser_raw == 4 {
			endian.put_u16(malformed[11:], .Big, 255)
		} else {
			malformed_len = valid_len - 1
		}
	}

	parse_err: ProtocolParseError
	accepted := false
	switch parser_raw {
	case 0:
		parsed: DMStartedMessage
		parsed, parse_err = parseDMStartedMessage(malformed[:malformed_len])
		accepted = parse_err == nil && parsed.conv_id == conv_id && parsed.username == username && parsed.correlation_id == correlation_id
	case 1:
		entries: [1]DMEntry
		parsed: DMListMessage
		parsed, parse_err = parseDMListMessage(malformed[:malformed_len], entries[:])
		accepted = parse_err == nil && parsed.correlation_id == correlation_id && len(parsed.entries) == 1 && parsed.entries[0].username == username
	case 2:
		parsed: DMErrorMessage
		parsed, parse_err = parseDMErrorMessage(malformed[:malformed_len])
		accepted = parse_err == nil && parsed.target_username == username && parsed.message == message && parsed.correlation_id == correlation_id
	case 3:
		parsed: DMLeftMessage
		parsed, parse_err = parseDMLeftMessage(malformed[:malformed_len])
		accepted = parse_err == nil && parsed.conv_id == conv_id && parsed.correlation_id == correlation_id
	case:
		parsed: DMPartnerStatusMessage
		parsed, parse_err = parseDMPartnerStatusMessage(malformed[:malformed_len])
		accepted = parse_err == nil && parsed.conv_id == conv_id && parsed.username == username && parsed.last_seen == 456
	}
	if variant_raw == 1 && parse_err != .InvalidOpcode do return hgl.interesting("dm parser wrong opcode was not InvalidOpcode")
	if accepted do return hgl.interesting("dm parser accepted malformed payload")

	return hgl.valid()
}

prop_error_presence_response_parsers_reject_malformed :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	parser_raw, draw_result, draw_ok := draw_i64_or_result(tc, 0, 1, "draw malformed error/presence parser selector")
	if !draw_ok do return draw_result
	variant_raw: i64
	variant_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 5, "draw malformed error/presence variant")
	if !draw_ok do return draw_result

	error_text := [?]byte{'b', 'a', 'd'}
	username := [?]byte{'a', 'l', 'i', 'c', 'e'}
	old_username := [?]byte{'o', 'l', 'd'}
	listed_user := [?]byte{'b', 'o', 'b'}
	user_list := [?][]byte{listed_user[:]}
	user_auth_flags := [?]bool{true}
	user_types := [?]User_Type{.User}

	valid: [256]byte
	valid_len := 0
	if parser_raw == 0 {
		msg := ErrorResponse {
			origin_opcode  = .C_SendMessage,
			error_msg      = error_text[:],
			correlation_id = 0xAABBCCDD,
		}
		valid_len = serializeErrorResponse(msg, valid[:])
		parsed, parse_err := parseErrorResponseMessage(valid[:valid_len])
		if parse_err != nil ||
		   parsed.origin_opcode != msg.origin_opcode ||
		   parsed.correlation_id != msg.correlation_id ||
		   !bytes_equal(parsed.error_msg, msg.error_msg) {
			return hgl.interesting("error response full parser roundtrip")
		}
	} else {
		msg := RoomPresenceUpdate {
			conv_id          = 77,
			event_type       = .UserRenamed,
			sequence         = 88,
			username         = username[:],
			is_authenticated = true,
			user_type        = .User,
			old_username     = old_username[:],
			user_list        = user_list[:],
			user_auth_flags  = user_auth_flags[:],
			user_types       = user_types[:],
		}
		valid_len = serializeRoomPresenceUpdate(msg, valid[:])
		parsed, parse_err := parseRoomPresenceUpdateMessage(valid[:valid_len])
		defer if len(parsed.user_list) > 0 {
			delete(parsed.user_list)
			delete(parsed.user_auth_flags)
			delete(parsed.user_types)
		}
		if parse_err != nil ||
		   parsed.conv_id != msg.conv_id ||
		   parsed.event_type != msg.event_type ||
		   parsed.sequence != msg.sequence ||
		   !bytes_equal(parsed.username, msg.username) ||
		   !bytes_equal(parsed.old_username, msg.old_username) ||
		   len(parsed.user_list) != 1 ||
		   !bytes_equal(parsed.user_list[0], listed_user[:]) {
			return hgl.interesting("presence response full parser roundtrip")
		}
	}
	if valid_len <= 0 do return hgl.interesting("build valid error/presence response")

	malformed: [257]byte
	copy(malformed[:], valid[:valid_len])
	malformed_len := valid_len
	switch variant_raw {
	case 0:
		truncate_raw, truncate_result, truncate_ok := draw_i64_or_result(tc, 0, i64(valid_len - 1), "draw error/presence truncation")
		if !truncate_ok do return truncate_result
		malformed_len = int(truncate_raw)
	case 1:
		endian.put_u16(malformed[:], .Big, u16(Opcode.C_Ping))
	case 2:
		malformed[valid_len] = 0xA5
		malformed_len = valid_len + 1
	case 3:
		malformed_len = valid_len - 1
	case 4:
		if parser_raw == 0 {
			// Error message length after opcode + origin opcode.
			endian.put_u16(malformed[4:], .Big, 255)
		} else {
			// Username length after opcode + conv_id + event_type + sequence.
			endian.put_u16(malformed[2 + 8 + 1 + 8:], .Big, 255)
		}
	case:
		if parser_raw == 0 {
			malformed_len = 2 + _ERR_FIXED_HEADER_SIZE
		} else {
			// User-list entry length after fixed payload, username, auth/type, old_username, and count.
			endian.put_u16(malformed[2 + 19 + len(username) + 1 + 1 + 2 + len(old_username) + 2:], .Big, 255)
		}
	}

	parse_err: ProtocolParseError
	accepted := false
	if parser_raw == 0 {
		parsed: ErrorResponse
		parsed, parse_err = parseErrorResponseMessage(malformed[:malformed_len])
		accepted =
			parse_err == nil && parsed.origin_opcode == .C_SendMessage && parsed.correlation_id == 0xAABBCCDD && bytes_equal(parsed.error_msg, error_text[:])
	} else {
		parsed: RoomPresenceUpdate
		parsed, parse_err = parseRoomPresenceUpdateMessage(malformed[:malformed_len])
		defer if len(parsed.user_list) > 0 {
			delete(parsed.user_list)
			delete(parsed.user_auth_flags)
			delete(parsed.user_types)
		}
		accepted =
			parse_err == nil &&
			parsed.conv_id == 77 &&
			parsed.event_type == .UserRenamed &&
			parsed.sequence == 88 &&
			bytes_equal(parsed.username, username[:]) &&
			bytes_equal(parsed.old_username, old_username[:]) &&
			len(parsed.user_list) == 1 &&
			bytes_equal(parsed.user_list[0], listed_user[:])
	}
	if variant_raw == 1 && parse_err != .InvalidOpcode do return hgl.interesting("error/presence parser wrong opcode was not InvalidOpcode")
	if accepted do return hgl.interesting("error/presence parser accepted malformed payload")

	return hgl.valid()
}

prop_system_response_parsers_reject_malformed :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	parser_raw, draw_result, draw_ok := draw_i64_or_result(tc, 0, 1, "draw malformed system response parser selector")
	if !draw_ok do return draw_result
	variant_raw: i64
	variant_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 4, "draw malformed system response variant")
	if !draw_ok do return draw_result

	valid: [256]byte
	valid_len := 0
	if parser_raw == 0 {
		pong := PongResponse {
			timestamp        = 101,
			server_timestamp = 202,
		}
		valid_len = serializePongResponse(pong, valid[:])
	} else {
		stats := StatsResponse {
			timestamp            = 101,
			server_timestamp     = 202,
			thread_id            = 1,
			total_threads        = 2,
			connections          = 3,
			memory_total_mb      = 4,
			buffer_pool_percent  = 5,
			io_pending           = 6,
			io_ring_depth        = 7,
			io_ring_available    = 8,
			io_sq_overflow       = 9,
			io_total_completions = 10,
			io_total_latency_ns  = 11,
			io_latency_count     = 12,
			send_queue_depth     = 13,
			send_queue_limit     = 14,
			send_backpressure    = true,
			send_dropped         = 15,
			wal_file_size        = 16,
			wal_pending_bytes    = 17,
			wal_record_count     = 18,
			wal_fsync_count      = 19,
			wal_total_fsync_ns   = 20,
			wal_total_write_ns   = 21,
			wal_write_count      = 22,
		}
		valid_len = serializeStatsResponse(stats, valid[:])
	}
	if valid_len <= 0 do return hgl.interesting("build valid system response")

	malformed: [257]byte
	copy(malformed[:], valid[:valid_len])
	malformed_len := valid_len
	switch variant_raw {
	case 0:
		truncate_raw, truncate_result, truncate_ok := draw_i64_or_result(tc, 0, i64(valid_len - 1), "draw system response truncation")
		if !truncate_ok do return truncate_result
		malformed_len = int(truncate_raw)
	case 1:
		endian.put_u16(malformed[:], .Big, u16(Opcode.C_Ping))
	case 2:
		malformed[valid_len] = 0xA5
		malformed_len = valid_len + 1
	case 3:
		malformed_len = valid_len - 1
	case:
		if parser_raw == 0 {
			malformed_len = 2 + 8
		} else {
			// Pretend the optional WAL detail header is present but incomplete.
			malformed[valid_len] = PONG_WAL_DETAIL_VERSION
			malformed_len = valid_len + 1
		}
	}

	parse_err: ProtocolParseError
	accepted := false
	if parser_raw == 0 {
		parsed: PongResponse
		parsed, parse_err = parsePongResponseMessage(malformed[:malformed_len])
		accepted = parse_err == nil && parsed.timestamp == 101 && parsed.server_timestamp == 202
	} else {
		parsed: StatsResponse
		parsed, parse_err = parseStatsResponseMessage(malformed[:malformed_len])
		accepted = parse_err == nil && parsed.timestamp == 101 && parsed.server_timestamp == 202 && parsed.thread_id == 1 && parsed.wal_write_count == 22
	}
	if variant_raw == 1 && parse_err != .InvalidOpcode do return hgl.interesting("system response parser wrong opcode was not InvalidOpcode")
	if accepted do return hgl.interesting("system response parser accepted malformed payload")

	return hgl.valid()
}

prop_message_response_parsers_reject_malformed :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	parser_raw, draw_result, draw_ok := draw_i64_or_result(tc, 0, 1, "draw malformed message response parser selector")
	if !draw_ok do return draw_result
	variant_raw: i64
	variant_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 4, "draw malformed message response variant")
	if !draw_ok do return draw_result

	username := [?]byte{'a', 'l', 'i', 'c', 'e'}
	content := [?]byte{'h', 'e', 'l', 'l', 'o'}
	valid: [128]byte
	valid_len := 0
	if parser_raw == 0 {
		msg := NewMessageEvent {
			conv_id         = 77,
			seq             = 123,
			author_username = username[:],
			timestamp       = 456,
			content_type    = .PlainText,
			content         = content[:],
		}
		valid_len = serializeNewMessageEvent(msg, valid[:])
	} else {
		ack := AckSendMessage {
			client_req_id = 99,
			assigned_seq  = 123,
			timestamp     = 456,
		}
		valid_len = serializeAckSendMessage(ack, valid[:])
	}
	if valid_len <= 0 do return hgl.interesting("build valid message response")

	malformed: [129]byte
	copy(malformed[:], valid[:valid_len])
	malformed_len := valid_len
	switch variant_raw {
	case 0:
		truncate_raw, truncate_result, truncate_ok := draw_i64_or_result(tc, 0, i64(valid_len - 1), "draw message response truncation")
		if !truncate_ok do return truncate_result
		malformed_len = int(truncate_raw)
	case 1:
		endian.put_u16(malformed[:], .Big, u16(Opcode.C_Ping))
	case 2:
		malformed[valid_len] = 0xA5
		malformed_len = valid_len + 1
	case 3:
		malformed_len = valid_len - 1
	case:
		if parser_raw == 0 {
			// Corrupt content length after opcode + conv_id + seq + username_len + username + timestamp + content_type.
			endian.put_u16(malformed[2 + 8 + 8 + 2 + len(username) + 8 + 1:], .Big, 255)
		} else {
			// Ack has no nested payload; use a too-short fixed field variant.
			malformed_len = 2 + 4 + 8
		}
	}

	parse_err: ProtocolParseError
	accepted := false
	if parser_raw == 0 {
		parsed: NewMessageEvent
		parsed, parse_err = parseNewMessageEventMessage(malformed[:malformed_len])
		accepted =
			parse_err == nil &&
			parsed.conv_id == 77 &&
			parsed.seq == 123 &&
			parsed.timestamp == 456 &&
			parsed.content_type == .PlainText &&
			bytes_equal(parsed.author_username, username[:]) &&
			bytes_equal(parsed.content, content[:])
	} else {
		parsed: AckSendMessage
		parsed, parse_err = parseAckSendMessageMessage(malformed[:malformed_len])
		accepted = parse_err == nil && parsed.client_req_id == 99 && parsed.assigned_seq == 123 && parsed.timestamp == 456
	}
	if variant_raw == 1 && parse_err != .InvalidOpcode do return hgl.interesting("message response parser wrong opcode was not InvalidOpcode")
	if accepted do return hgl.interesting("message response parser accepted malformed payload")

	return hgl.valid()
}

prop_edge_write_response_parsers_roundtrip_and_reject_malformed :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	parser_raw, draw_result, draw_ok := draw_i64_or_result(tc, 0, 1, "draw edge write response parser selector")
	if !draw_ok do return draw_result
	variant_raw: i64
	variant_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 4, "draw edge write response malformed variant")
	if !draw_ok do return draw_result
	correlation_raw: i64
	correlation_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 0xFFFF_FFFF, "draw edge write response correlation")
	if !draw_ok do return draw_result
	correlation_id := u32(correlation_raw)

	created_by := [?]byte{'a'}
	edge := Edge {
		edge_id     = 1,
		conv_id     = 77,
		source_type = .Task,
		source_id   = 2,
		target_type = .Asset,
		target_id   = 3,
		relation    = .References,
		created_at  = 4,
		created_by  = created_by[:],
	}

	valid: [128]byte
	valid_len := 0
	if parser_raw == 0 {
		valid_len = serializeEdgeCreatedMessage({edge = edge, correlation_id = correlation_id}, valid[:])
	} else {
		valid_len = serializeEdgeDeletedMessage({conv_id = edge.conv_id, edge_id = edge.edge_id, correlation_id = correlation_id}, valid[:])
	}
	if valid_len <= 0 do return hgl.interesting("build valid edge write response")

	if parser_raw == 0 {
		parsed, parse_err := parseEdgeCreatedMessage(valid[:valid_len])
		if parse_err != nil || parsed.correlation_id != correlation_id || !hegel_edge_equal(parsed.edge, edge) do return hgl.interesting("roundtrip edge created response")
	} else {
		parsed, parse_err := parseEdgeDeletedMessage(valid[:valid_len])
		if parse_err != nil || parsed.correlation_id != correlation_id || parsed.conv_id != edge.conv_id || parsed.edge_id != edge.edge_id do return hgl.interesting("roundtrip edge deleted response")
	}

	malformed: [129]byte
	copy(malformed[:], valid[:valid_len])
	malformed_len := valid_len
	switch variant_raw {
	case 0:
		truncate_raw, truncate_result, truncate_ok := draw_i64_or_result(tc, 0, i64(valid_len - 1), "draw edge write response truncation")
		if !truncate_ok do return truncate_result
		malformed_len = int(truncate_raw)
	case 1:
		endian.put_u16(malformed[:], .Big, u16(Opcode.C_Ping))
	case 2:
		malformed[valid_len] = 0x5A
		malformed_len = valid_len + 1
	case 3:
		malformed_len = valid_len - 1
	case:
		if parser_raw == 0 {
			// Edge created_by length is after opcode + fixed edge fields.
			endian.put_u16(malformed[48:], .Big, 255)
		} else {
			malformed[valid_len] = 0x5A
			malformed_len = valid_len + 1
		}
	}

	parse_err: ProtocolParseError
	accepted_coherent_valid := false
	if parser_raw == 0 {
		parsed: EdgeCreatedMessage
		parsed, parse_err = parseEdgeCreatedMessage(malformed[:malformed_len])
		accepted_coherent_valid = parse_err == nil && parsed.correlation_id == correlation_id && hegel_edge_equal(parsed.edge, edge)
	} else {
		parsed: EdgeDeletedMessage
		parsed, parse_err = parseEdgeDeletedMessage(malformed[:malformed_len])
		accepted_coherent_valid =
			parse_err == nil && parsed.correlation_id == correlation_id && parsed.conv_id == edge.conv_id && parsed.edge_id == edge.edge_id
	}
	if variant_raw == 1 && parse_err != .InvalidOpcode do return hgl.interesting("edge write response parser wrong opcode was not InvalidOpcode")
	if accepted_coherent_valid {
		switch variant_raw {
		case 0:
			return hgl.interesting("edge write response parser accepted truncation")
		case 1:
			return hgl.interesting("edge write response parser accepted wrong opcode")
		case 2:
			return hgl.interesting("edge write response parser accepted trailing byte")
		case 3:
			return hgl.interesting("edge write response parser accepted missing correlation id")
		case:
			return hgl.interesting("edge write response parser accepted malformed nested payload")
		}
	}

	return hgl.valid()
}

prop_task_write_response_parsers_roundtrip_and_reject_malformed :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	parser_raw, draw_result, draw_ok := draw_i64_or_result(tc, 0, 3, "draw task write response parser selector")
	if !draw_ok do return draw_result
	variant_raw: i64
	variant_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 5, "draw task write response malformed variant")
	if !draw_ok do return draw_result
	correlation_raw: i64
	correlation_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 0xFFFF_FFFF, "draw task write response correlation")
	if !draw_ok do return draw_result
	correlation_id := u32(correlation_raw)

	title := [?]byte{'t'}
	description := [?]byte{'d'}
	created_by := [?]byte{'a'}
	completed_by := [?]byte{'a'}
	task := Task {
		id           = 1,
		conv_id      = 77,
		title        = title[:],
		description  = description[:],
		status       = .Done,
		order_index  = 2,
		priority     = 3,
		color        = .Cyan,
		created_by   = created_by[:],
		created_at   = 4,
		updated_at   = 5,
		completed_at = 6,
		completed_by = completed_by[:],
	}

	valid: [512]byte
	valid_len := 0
	switch parser_raw {
	case 0:
		valid_len = serializeTaskCreated({task = task, correlation_id = correlation_id}, valid[:])
	case 1:
		valid_len = serializeTaskUpdated({task = task, correlation_id = correlation_id}, valid[:])
	case 2:
		valid_len = serializeTaskDeleted({task_id = task.id, conv_id = task.conv_id, correlation_id = correlation_id}, valid[:])
	case:
		valid_len = serializeTaskMoved(
			{
				task_id = task.id,
				conv_id = task.conv_id,
				status = task.status,
				order_index = task.order_index,
				completed_at = task.completed_at,
				completed_by = task.completed_by,
				correlation_id = correlation_id,
			},
			valid[:],
		)
	}
	if valid_len <= 0 do return hgl.interesting("build valid task write response")

	attachments: [MAX_ATTACHMENTS_PER_TASK]Attachment
	switch parser_raw {
	case 0:
		parsed, parse_err := parseTaskCreated(valid[:valid_len], attachments[:])
		if parse_err != nil || parsed.correlation_id != correlation_id || !hegel_task_equal(parsed.task, task) do return hgl.interesting("roundtrip task created response")
	case 1:
		parsed, parse_err := parseTaskUpdated(valid[:valid_len], attachments[:])
		if parse_err != nil || parsed.correlation_id != correlation_id || !hegel_task_equal(parsed.task, task) do return hgl.interesting("roundtrip task updated response")
	case 2:
		parsed, parse_err := parseTaskDeleted(valid[:valid_len])
		if parse_err != nil || parsed.correlation_id != correlation_id || parsed.task_id != task.id || parsed.conv_id != task.conv_id do return hgl.interesting("roundtrip task deleted response")
	case:
		parsed, parse_err := parseTaskMoved(valid[:valid_len])
		if parse_err != nil || parsed.correlation_id != correlation_id || parsed.task_id != task.id || parsed.conv_id != task.conv_id || parsed.status != task.status || parsed.order_index != task.order_index || parsed.completed_at != task.completed_at || !bytes_equal(parsed.completed_by, task.completed_by) do return hgl.interesting("roundtrip task moved response")
	}

	malformed: [513]byte
	copy(malformed[:], valid[:valid_len])
	malformed_len := valid_len
	switch variant_raw {
	case 0:
		truncate_raw, truncate_result, truncate_ok := draw_i64_or_result(tc, 0, i64(valid_len - 1), "draw task write response truncation")
		if !truncate_ok do return truncate_result
		malformed_len = int(truncate_raw)
	case 1:
		endian.put_u16(malformed[:], .Big, u16(Opcode.C_Ping))
	case 2:
		malformed[valid_len] = 0x5A
		malformed_len = valid_len + 1
	case 3:
		malformed_len = valid_len - 1
	case:
		if parser_raw == 0 || parser_raw == 1 {
			// Task title length is after opcode + task_id + conv_id.
			endian.put_u16(malformed[18:], .Big, 255)
		} else if parser_raw == 3 {
			// TaskMoved completed_by length is after opcode + ids/status/order/completed_at.
			endian.put_u16(malformed[31:], .Big, 255)
		} else {
			malformed[valid_len] = 0x5A
			malformed_len = valid_len + 1
		}
	}

	parse_err: ProtocolParseError
	accepted_coherent_valid := false
	if parser_raw == 0 {
		parsed: TaskCreated
		parsed, parse_err = parseTaskCreated(malformed[:malformed_len], attachments[:])
		accepted_coherent_valid = parse_err == nil && parsed.correlation_id == correlation_id && hegel_task_equal(parsed.task, task)
	} else if parser_raw == 1 {
		parsed: TaskUpdated
		parsed, parse_err = parseTaskUpdated(malformed[:malformed_len], attachments[:])
		accepted_coherent_valid = parse_err == nil && parsed.correlation_id == correlation_id && hegel_task_equal(parsed.task, task)
	} else if parser_raw == 2 {
		parsed: TaskDeleted
		parsed, parse_err = parseTaskDeleted(malformed[:malformed_len])
		accepted_coherent_valid = parse_err == nil && parsed.correlation_id == correlation_id && parsed.task_id == task.id && parsed.conv_id == task.conv_id
	} else {
		parsed: TaskMoved
		parsed, parse_err = parseTaskMoved(malformed[:malformed_len])
		accepted_coherent_valid =
			parse_err == nil &&
			parsed.correlation_id == correlation_id &&
			parsed.task_id == task.id &&
			parsed.conv_id == task.conv_id &&
			parsed.status == task.status &&
			parsed.order_index == task.order_index &&
			parsed.completed_at == task.completed_at &&
			bytes_equal(parsed.completed_by, task.completed_by)
	}
	if variant_raw == 1 && parse_err != .InvalidOpcode do return hgl.interesting("task write response parser wrong opcode was not InvalidOpcode")
	if accepted_coherent_valid {
		switch variant_raw {
		case 0:
			return hgl.interesting("task write response parser accepted truncation")
		case 1:
			return hgl.interesting("task write response parser accepted wrong opcode")
		case 2:
			return hgl.interesting("task write response parser accepted trailing byte")
		case 3:
			return hgl.interesting("task write response parser accepted missing correlation id")
		case:
			return hgl.interesting("task write response parser accepted malformed nested payload")
		}
	}

	return hgl.valid()
}

prop_asset_write_response_parsers_reject_malformed :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	parser_raw, draw_result, draw_ok := draw_i64_or_result(tc, 0, 3, "draw malformed asset write response parser selector")
	if !draw_ok do return draw_result
	variant_raw: i64
	variant_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 4, "draw malformed asset write response variant")
	if !draw_ok do return draw_result

	owner := [?]byte{'o'}
	preview := [?]byte{'p'}
	payload := [?]byte{'x'}
	asset := Asset {
		asset_type       = .Note,
		asset_id         = 1,
		parent_type      = .Task,
		parent_id        = 2,
		owner            = owner[:],
		created_at       = 3,
		updated_at       = 4,
		conv_id          = 77,
		payload_encoding = .Plain,
		payload_raw_len  = u32(len(payload)),
		preview          = preview[:],
		payload          = payload[:],
	}

	valid: [256]byte
	valid_len := 0
	switch parser_raw {
	case 0:
		valid_len = serializeAssetCreatedMessage({asset = asset, correlation_id = 0xB001}, valid[:])
	case 1:
		valid_len = serializeAssetUpdatedMessage({asset = asset, correlation_id = 0xB002}, valid[:])
	case 2:
		valid_len = serializeAssetDeletedMessage({conv_id = 77, asset_id = 1, correlation_id = 0xB003}, valid[:])
	case:
		valid_len = serializeAssetFullMessage({asset = asset, correlation_id = 0xB004}, valid[:])
	}
	if valid_len <= 0 do return hgl.interesting("build valid asset write response")

	malformed: [257]byte
	copy(malformed[:], valid[:valid_len])
	malformed_len := valid_len

	switch variant_raw {
	case 0:
		truncate_raw, truncate_result, truncate_ok := draw_i64_or_result(tc, 0, i64(valid_len - 1), "draw asset write response truncation")
		if !truncate_ok do return truncate_result
		malformed_len = int(truncate_raw)
	case 1:
		endian.put_u16(malformed[:], .Big, u16(Opcode.C_Ping))
	case 2:
		malformed[valid_len] = 0x5A
		malformed_len = valid_len + 1
	case 3:
		malformed_len = valid_len - 1
	case:
		if parser_raw == 2 {
			malformed[valid_len] = 0x5A
			malformed_len = valid_len + 1
		} else {
			// Asset owner length is after opcode + asset_type/id/parent_type/parent_id.
			endian.put_u16(malformed[2 + 20:], .Big, 255)
		}
	}

	parse_err: ProtocolParseError
	accepted_coherent_valid := false
	if parser_raw == 0 {
		parsed: AssetCreatedMessage
		parsed, parse_err = parseAssetCreatedMessage(malformed[:malformed_len])
		accepted_coherent_valid = parse_err == nil && parsed.correlation_id == 0xB001 && hegel_asset_equal(parsed.asset, asset)
	} else if parser_raw == 1 {
		parsed: AssetUpdatedMessage
		parsed, parse_err = parseAssetUpdatedMessage(malformed[:malformed_len])
		accepted_coherent_valid = parse_err == nil && parsed.correlation_id == 0xB002 && hegel_asset_equal(parsed.asset, asset)
	} else if parser_raw == 2 {
		parsed: AssetDeletedMessage
		parsed, parse_err = parseAssetDeletedMessage(malformed[:malformed_len])
		accepted_coherent_valid = parse_err == nil && parsed.conv_id == 77 && parsed.asset_id == 1 && parsed.correlation_id == 0xB003
	} else {
		parsed: AssetFullMessage
		parsed, parse_err = parseAssetFullMessage(malformed[:malformed_len])
		accepted_coherent_valid = parse_err == nil && parsed.correlation_id == 0xB004 && hegel_asset_equal(parsed.asset, asset)
	}
	if variant_raw == 1 && parse_err != .InvalidOpcode do return hgl.interesting("asset write response parser wrong opcode was not InvalidOpcode")
	if accepted_coherent_valid {
		switch variant_raw {
		case 0:
			return hgl.interesting("asset write response parser accepted truncation")
		case 1:
			return hgl.interesting("asset write response parser accepted wrong opcode")
		case 2:
			return hgl.interesting("asset write response parser accepted trailing byte")
		case 3:
			return hgl.interesting("asset write response parser accepted missing correlation id")
		case:
			return hgl.interesting("asset write response parser accepted malformed nested payload")
		}
	}

	return hgl.valid()
}

prop_asset_note_response_parsers_reject_malformed :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	parser_raw, draw_result, draw_ok := draw_i64_or_result(tc, 0, 3, "draw malformed asset/note response parser selector")
	if !draw_ok do return draw_result
	variant_raw: i64
	variant_raw, draw_result, draw_ok = draw_i64_or_result(tc, 0, 5, "draw malformed asset/note response variant")
	if !draw_ok do return draw_result

	owner := [?]byte{'o'}
	preview := [?]byte{'p'}
	payload := [?]byte{'x'}
	asset := Asset {
		asset_type       = .Note,
		asset_id         = 1,
		parent_type      = .Task,
		parent_id        = 2,
		owner            = owner[:],
		created_at       = 3,
		updated_at       = 4,
		conv_id          = 77,
		payload_encoding = .Plain,
		payload_raw_len  = u32(len(payload)),
		preview          = preview[:],
		payload          = payload[:],
	}
	asset_list := [?]Asset{asset}
	projects := [?]string{"ops"}
	tags := [?]string{"dst"}

	valid: [256]byte
	valid_len := 0
	switch parser_raw {
	case 0:
		msg := AssetListMessage {
			conv_id        = 77,
			assets         = asset_list[:],
			full_content   = true,
			correlation_id = 0xA000,
		}
		valid_len = serializeAssetListMessage(msg, valid[:])
	case 1:
		msg := AssetListPageMessage {
			conv_id                = 77,
			assets                 = asset_list[:],
			full_content           = true,
			has_more               = false,
			next_cursor_updated_at = 4,
			next_cursor_asset_id   = 1,
			total_count            = 1,
			correlation_id         = 0xA001,
		}
		valid_len = serializeAssetListPageMessage(msg, valid[:])
	case 2:
		msg := NoteProjectListMessage {
			conv_id        = 77,
			projects       = projects[:],
			correlation_id = 0xA002,
		}
		valid_len = serializeNoteProjectListMessage(msg, valid[:])
	case:
		msg := NoteTagListMessage {
			conv_id        = 77,
			tags           = tags[:],
			correlation_id = 0xA003,
		}
		valid_len = serializeNoteTagListMessage(msg, valid[:])
	}
	if valid_len <= 0 do return hgl.interesting("build valid asset/note response")

	malformed: [257]byte
	copy(malformed[:], valid[:valid_len])
	malformed_len := valid_len

	switch variant_raw {
	case 0:
		truncate_raw, truncate_result, truncate_ok := draw_i64_or_result(tc, 0, i64(valid_len - 1), "draw asset/note response truncation")
		if !truncate_ok do return truncate_result
		malformed_len = int(truncate_raw)
	case 1:
		endian.put_u16(malformed[:], .Big, u16(Opcode.C_Ping))
	case 2:
		// Count exceeds a practical caller/parse buffer.
		if parser_raw == 0 {
			endian.put_u16(malformed[11:], .Big, 2)
		} else if parser_raw == 1 {
			endian.put_u16(malformed[32:], .Big, 2)
		} else {
			endian.put_u16(malformed[10:], .Big, 2)
		}
	case 3:
		malformed[valid_len] = 0x5A
		malformed_len = valid_len + 1
	case 4:
		malformed_len = valid_len - 1
	case:
		// Malformed nested payload/string length.
		if parser_raw == 0 {
			// asset owner length is after header + asset_type/id/parent_type/parent_id
			endian.put_u16(malformed[17 + 20:], .Big, 255)
		} else if parser_raw == 1 {
			// asset owner length is after header + asset_type/id/parent_type/parent_id
			endian.put_u16(malformed[38 + 20:], .Big, 255)
		} else {
			endian.put_u16(malformed[16:], .Big, 255)
		}
	}

	parse_err: ProtocolParseError
	accepted_coherent_valid := false
	if parser_raw == 0 {
		parsed: AssetListMessage
		parsed, parse_err = parseAssetListMessage(malformed[:malformed_len])
		accepted_coherent_valid =
			parse_err == nil &&
			parsed.conv_id == 77 &&
			parsed.full_content == true &&
			parsed.correlation_id == 0xA000 &&
			len(parsed.assets) == 1 &&
			hegel_asset_equal(parsed.assets[0], asset)
		defer if len(parsed.assets) > 0 do delete(parsed.assets)
	} else if parser_raw == 1 {
		parsed: AssetListPageMessage
		parsed, parse_err = parseAssetListPageMessage(malformed[:malformed_len])
		accepted_coherent_valid =
			parse_err == nil &&
			parsed.conv_id == 77 &&
			parsed.full_content == true &&
			parsed.has_more == false &&
			parsed.next_cursor_updated_at == 4 &&
			parsed.next_cursor_asset_id == 1 &&
			parsed.total_count == 1 &&
			parsed.correlation_id == 0xA001 &&
			len(parsed.assets) == 1 &&
			hegel_asset_equal(parsed.assets[0], asset)
		defer if len(parsed.assets) > 0 do delete(parsed.assets)
	} else if parser_raw == 2 {
		parsed: NoteProjectListMessage
		parsed, parse_err = parseNoteProjectListMessage(malformed[:malformed_len])
		accepted_coherent_valid =
			parse_err == nil && parsed.conv_id == 77 && parsed.correlation_id == 0xA002 && hegel_string_slices_equal(parsed.projects, projects[:])
		defer if len(parsed.projects) > 0 do delete(parsed.projects)
	} else {
		parsed: NoteTagListMessage
		parsed, parse_err = parseNoteTagListMessage(malformed[:malformed_len])
		accepted_coherent_valid =
			parse_err == nil && parsed.conv_id == 77 && parsed.correlation_id == 0xA003 && hegel_string_slices_equal(parsed.tags, tags[:])
		defer if len(parsed.tags) > 0 do delete(parsed.tags)
	}
	if variant_raw == 1 && parse_err != .InvalidOpcode do return hgl.interesting("asset/note response parser wrong opcode was not InvalidOpcode")
	if accepted_coherent_valid {
		switch variant_raw {
		case 0:
			return hgl.interesting("asset/note response parser accepted truncation")
		case 1:
			return hgl.interesting("asset/note response parser accepted wrong opcode")
		case 2:
			return hgl.interesting("asset/note response parser accepted excessive count")
		case 3:
			return hgl.interesting("asset/note response parser accepted trailing byte")
		case 4:
			return hgl.interesting("asset/note response parser accepted missing correlation id")
		case:
			return hgl.interesting("asset/note response parser accepted malformed nested payload")
		}
	}

	return hgl.valid()
}

prop_promoted_response_parsers_reject_malformed :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	parser_raw, draw_err := hgl.draw_i64(tc, 0, 2)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil do return hgl.interesting("draw malformed response parser selector")

	variant_raw: i64
	variant_raw, draw_err = hgl.draw_i64(tc, 0, 4)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil do return hgl.interesting("draw malformed response variant")

	valid: [256]byte
	valid_len := 0
	switch parser_raw {
	case 0:
		msg := TaskListResponse {
			conv_id        = 77,
			success        = true,
			correlation_id = 0xABCDEF01,
		}
		valid_len = serializeTaskListResponse(msg, valid[:])
		if valid_len <= 0 do return hgl.interesting("build valid task-list response")
	case 1:
		msg := EdgeListMessage {
			conv_id        = 77,
			target_type    = .Task,
			target_id      = 123,
			correlation_id = 0xABCDEF02,
		}
		valid_len = serializeEdgeListMessage(msg, valid[:])
		if valid_len <= 0 do return hgl.interesting("build valid edge-list response")
	case:
		msg := AllEdgeListMessage {
			conv_id        = 77,
			correlation_id = 0xABCDEF03,
		}
		valid_len = serializeAllEdgeListMessage(msg, valid[:])
		if valid_len <= 0 do return hgl.interesting("build valid all-edge-list response")
	}

	malformed: [257]byte
	copy(malformed[:], valid[:valid_len])
	malformed_len := valid_len
	tasks: [1]Task
	attachments: [1]Attachment
	edges: [1]Edge
	use_empty_task_buffer := false
	use_empty_edge_buffer := false

	switch variant_raw {
	case 0:
		// truncation at arbitrary byte offset
		truncate_raw, truncate_err := hgl.draw_i64(tc, 0, i64(valid_len - 1))
		if truncate_err == .Stop_Test do return hgl.abort()
		if truncate_err != nil do return hgl.interesting("draw malformed response truncation")
		malformed_len = int(truncate_raw)

	case 1:
		// wrong opcode
		endian.put_u16(malformed[:], .Big, u16(Opcode.C_Ping))

	case 2:
		// declared count exceeds caller buffer
		if parser_raw == 0 {
			endian.put_u16(malformed[11:], .Big, 1)
			use_empty_task_buffer = true
		} else if parser_raw == 1 {
			endian.put_u16(malformed[20:], .Big, 1)
			use_empty_edge_buffer = true
		} else {
			endian.put_u32(malformed[10:], .Big, 1)
			use_empty_edge_buffer = true
		}

	case 3:
		// content-length mismatch via trailing byte
		malformed[valid_len] = 0xA5
		malformed_len = valid_len + 1

	case:
		// missing correlation ID byte
		malformed_len = valid_len - 1
	}

	parse_err: ProtocolParseError
	accepted := false
	if parser_raw == 0 {
		parsed: TaskListResponse
		if use_empty_task_buffer {
			parsed, parse_err = parseTaskListResponse(malformed[:malformed_len], tasks[:0], attachments[:0])
		} else {
			parsed, parse_err = parseTaskListResponse(malformed[:malformed_len], tasks[:], attachments[:])
		}
		accepted = parse_err == nil && parsed.conv_id == 77 && parsed.correlation_id == 0xABCDEF01
	} else if parser_raw == 1 {
		parsed: EdgeListMessage
		if use_empty_edge_buffer {
			parsed, parse_err = parseEdgeListMessage(malformed[:malformed_len], edges[:0])
		} else {
			parsed, parse_err = parseEdgeListMessage(malformed[:malformed_len], edges[:])
		}
		accepted = parse_err == nil && parsed.conv_id == 77 && parsed.target_type == .Task && parsed.target_id == 123 && parsed.correlation_id == 0xABCDEF02
	} else {
		parsed: AllEdgeListMessage
		if use_empty_edge_buffer {
			parsed, parse_err = parseAllEdgeListMessage(malformed[:malformed_len], edges[:0])
		} else {
			parsed, parse_err = parseAllEdgeListMessage(malformed[:malformed_len], edges[:])
		}
		accepted = parse_err == nil && parsed.conv_id == 77 && parsed.correlation_id == 0xABCDEF03
	}
	if accepted {
		switch variant_raw {
		case 0:
			return hgl.interesting("promoted response parser accepted truncation")
		case 1:
			return hgl.interesting("promoted response parser accepted wrong opcode")
		case 2:
			return hgl.interesting("promoted response parser accepted excessive count")
		case 3:
			return hgl.interesting("promoted response parser accepted trailing byte")
		case:
			return hgl.interesting("promoted response parser accepted missing correlation id")
		}
	}

	return hgl.valid()
}

prop_graph_response_parsers_reject_malformed :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	parser_raw, draw_err := hgl.draw_i64(tc, 0, 3)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil do return hgl.interesting("draw malformed graph response parser selector")

	variant_raw: i64
	variant_raw, draw_err = hgl.draw_i64(tc, 0, 5)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil do return hgl.interesting("draw malformed graph response variant")

	created_by := [?]byte{'g', 'r', 'a', 'p', 'h'}
	edge := Edge {
		edge_id     = 90,
		conv_id     = 77,
		source_type = .Task,
		source_id   = 1001,
		target_type = .Asset,
		target_id   = 2002,
		relation    = .References,
		created_at  = 12345,
		created_by  = created_by[:],
	}
	query_node := GraphQueryNode {
		target_type = .Task,
		target_id   = 55,
		depth       = 1,
	}
	path_node := GraphPathNode {
		target_type = .Asset,
		target_id   = 66,
	}
	degree_entry := GraphDegreeEntry {
		target_type = .Task,
		target_id   = 77,
		degree      = 3,
	}
	query_node_list := [?]GraphQueryNode{query_node}
	path_node_list := [?]GraphPathNode{path_node}
	degree_entry_list := [?]GraphDegreeEntry{degree_entry}
	edge_list := [?]Edge{edge}

	valid: [512]byte
	valid_len := 0
	switch parser_raw {
	case 0:
		msg := GraphQueryResultMessage {
			conv_id        = 77,
			start_type     = .Task,
			start_id       = 111,
			truncated      = false,
			nodes          = query_node_list[:],
			edges          = edge_list[:],
			correlation_id = 0xABCDEF10,
		}
		valid_len = serializeGraphQueryResult(msg, valid[:])
	case 1:
		msg := GraphShortestPathResultMessage {
			conv_id        = 77,
			from_type      = .Task,
			from_id        = 111,
			to_type        = .Asset,
			to_id          = 222,
			found          = true,
			path_length    = 1,
			nodes          = path_node_list[:],
			edges          = edge_list[:],
			correlation_id = 0xABCDEF11,
		}
		valid_len = serializeGraphShortestPathResult(msg, valid[:])
	case 2:
		msg := GraphDegreeResultMessage {
			conv_id        = 77,
			entries        = degree_entry_list[:],
			correlation_id = 0xABCDEF12,
		}
		valid_len = serializeGraphDegreeResult(msg, valid[:])
	case:
		msg := GraphCommonNeighborsResultMessage {
			conv_id        = 77,
			a_type         = .Task,
			a_id           = 111,
			b_type         = .Asset,
			b_id           = 222,
			nodes          = path_node_list[:],
			edges          = edge_list[:],
			correlation_id = 0xABCDEF13,
		}
		valid_len = serializeGraphCommonNeighborsResult(msg, valid[:])
	}
	if valid_len <= 0 do return hgl.interesting("build valid graph response")

	malformed: [513]byte
	copy(malformed[:], valid[:valid_len])
	malformed_len := valid_len
	query_nodes: [1]GraphQueryNode
	path_nodes: [1]GraphPathNode
	edges: [1]Edge
	degree_entries: [1]GraphDegreeEntry
	use_empty_node_buffer := false
	use_empty_edge_buffer := false
	use_empty_degree_buffer := false

	switch variant_raw {
	case 0:
		truncate_raw, truncate_err := hgl.draw_i64(tc, 0, i64(valid_len - 1))
		if truncate_err == .Stop_Test do return hgl.abort()
		if truncate_err != nil do return hgl.interesting("draw graph response truncation")
		malformed_len = int(truncate_raw)

	case 1:
		endian.put_u16(malformed[:], .Big, u16(Opcode.C_Ping))

	case 2:
		// declared item count exceeds the caller-provided backing buffer
		if parser_raw == 0 {
			endian.put_u16(malformed[21:], .Big, 1)
			use_empty_node_buffer = true
		} else if parser_raw == 1 {
			endian.put_u16(malformed[32:], .Big, 1)
			use_empty_node_buffer = true
		} else if parser_raw == 2 {
			endian.put_u16(malformed[10:], .Big, 1)
			use_empty_degree_buffer = true
		} else {
			endian.put_u16(malformed[30:], .Big, 1)
			use_empty_node_buffer = true
		}

	case 3:
		malformed[valid_len] = 0x5A
		malformed_len = valid_len + 1

	case 4:
		malformed_len = valid_len - 1

	case:
		// malformed nested edge payload: inflate created_by length beyond remaining bytes
		if parser_raw == 2 {
			// Degree responses have no nested edge payload, so corrupt the first entry by truncating inside it.
			malformed_len = 14
		} else {
			created_by_len_offset := valid_len - 4 - len(created_by) - 2
			endian.put_u16(malformed[created_by_len_offset:], .Big, 255)
		}
	}

	accepted := false
	if parser_raw == 0 {
		parsed: GraphQueryResultMessage
		parse_err: ProtocolParseError
		if use_empty_node_buffer || use_empty_edge_buffer {
			parsed, parse_err = parseGraphQueryResult(malformed[:malformed_len], query_nodes[:0], edges[:0])
		} else {
			parsed, parse_err = parseGraphQueryResult(malformed[:malformed_len], query_nodes[:], edges[:])
		}
		accepted = parse_err == nil && parsed.conv_id == 77 && parsed.start_type == .Task && parsed.start_id == 111 && parsed.correlation_id == 0xABCDEF10
	} else if parser_raw == 1 {
		parsed: GraphShortestPathResultMessage
		parse_err: ProtocolParseError
		if use_empty_node_buffer || use_empty_edge_buffer {
			parsed, parse_err = parseGraphShortestPathResult(malformed[:malformed_len], path_nodes[:0], edges[:0])
		} else {
			parsed, parse_err = parseGraphShortestPathResult(malformed[:malformed_len], path_nodes[:], edges[:])
		}
		accepted =
			parse_err == nil &&
			parsed.conv_id == 77 &&
			parsed.from_type == .Task &&
			parsed.from_id == 111 &&
			parsed.to_type == .Asset &&
			parsed.to_id == 222 &&
			parsed.correlation_id == 0xABCDEF11
	} else if parser_raw == 2 {
		parsed: GraphDegreeResultMessage
		parse_err: ProtocolParseError
		if use_empty_degree_buffer {
			parsed, parse_err = parseGraphDegreeResult(malformed[:malformed_len], degree_entries[:0])
		} else {
			parsed, parse_err = parseGraphDegreeResult(malformed[:malformed_len], degree_entries[:])
		}
		accepted = parse_err == nil && parsed.conv_id == 77 && parsed.correlation_id == 0xABCDEF12
	} else {
		parsed: GraphCommonNeighborsResultMessage
		parse_err: ProtocolParseError
		if use_empty_node_buffer || use_empty_edge_buffer {
			parsed, parse_err = parseGraphCommonNeighborsResult(malformed[:malformed_len], path_nodes[:0], edges[:0])
		} else {
			parsed, parse_err = parseGraphCommonNeighborsResult(malformed[:malformed_len], path_nodes[:], edges[:])
		}
		accepted =
			parse_err == nil &&
			parsed.conv_id == 77 &&
			parsed.a_type == .Task &&
			parsed.a_id == 111 &&
			parsed.b_type == .Asset &&
			parsed.b_id == 222 &&
			parsed.correlation_id == 0xABCDEF13
	}
	if accepted {
		switch variant_raw {
		case 0:
			return hgl.interesting("graph response parser accepted truncation")
		case 1:
			return hgl.interesting("graph response parser accepted wrong opcode")
		case 2:
			return hgl.interesting("graph response parser accepted excessive count")
		case 3:
			return hgl.interesting("graph response parser accepted trailing byte")
		case 4:
			return hgl.interesting("graph response parser accepted missing correlation id")
		case:
			return hgl.interesting("graph response parser accepted malformed nested payload")
		}
	}

	return hgl.valid()
}
