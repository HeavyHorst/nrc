package main

import "core:os"
import "core:testing"

import "btree"
import hgl "hegel"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: btree.count
	_ :: hgl.run
	_ :: os.remove
	_ :: pr.Opcode
}

when NRC_SIMULATION {
	asset_query_test_payload :: proc(t: ^testing.T, sim: ^Sim_Runtime, c: ^NRC_Connection, expected: pr.Opcode) -> (payload: []u8, ok: bool) {
		testing.expect(t, simulation_test_commit_shards(sim))
		testing.expect_value(t, nrc_sim_client_frame_count(sim, c.sock), 1)
		if nrc_sim_client_frame_count(sim, c.sock) != 1 do return
		payload, ok = nrc_sim_frame_protocol_payload(nrc_sim_client_frame(sim, c.sock, 0))
		testing.expect(t, ok, "asset response should be a complete WebSocket frame")
		if ok do testing.expect_value(t, pr.get_opcode(payload), expected)
		return
	}

	asset_query_test_install_asset :: proc(
		conv: ^Conversation_State,
		conv_id: pr.ConversationID,
		asset_id: pr.AssetID,
		asset_type: pr.AssetType,
		preview, payload: string,
		updated_at: i64,
	) -> ^pr.Asset {
		asset := alloc_asset(transmute([]byte)string("owner"), transmute([]byte)preview, transmute([]byte)payload)
		if asset == nil do return nil
		asset.asset_type = asset_type
		asset.asset_id = asset_id
		asset.conv_id = conv_id
		asset.created_at = updated_at - 1
		asset.updated_at = updated_at
		asset.payload_encoding = .Plain
		asset.payload_raw_len = u32(len(payload))
		conv.assets[asset_id] = asset
		if asset_type == .Note do index_note_asset(conv, asset)
		return asset
	}

	asset_query_test_expect_empty_page :: proc(t: ^testing.T, sim: ^Sim_Runtime, c: ^NRC_Connection, correlation_id: u32) {
		payload, ok := asset_query_test_payload(t, sim, c, .S_AssetListPage)
		if !ok do return
		msg, err := pr.parseAssetListPageMessage(payload)
		defer if len(msg.assets) > 0 do delete(msg.assets)
		testing.expect(t, err == nil, "empty asset page should decode")
		testing.expect_value(t, len(msg.assets), 0)
		testing.expect_value(t, msg.has_more, false)
		testing.expect_value(t, msg.total_count, u32(0))
		testing.expect_value(t, msg.correlation_id, correlation_id)
	}

	asset_query_test_init_writer :: proc(workspace_id: string, path_label: string = "asset_query_broadcast.log") -> (path: string, ok: bool) {
		path = test_wal_path(path_label)
		_ = os.remove(path)
		if os.write_entire_file(path, nil) != nil do return path, false
		shard := int(shard_for_workspace(transmute([]byte)workspace_id))
		td.shard_writers.worker = 0
		td.shard_writers.worker_count = 1
		for &index in td.shard_writers.writer_index do index = -1
		_, append_err := append(&td.shard_writers.writers, Shard_Transaction_Writer{})
		if append_err != nil || !init_shard_transaction_writer(&td.shard_writers.writers[0], path, shard, 0, 1) {
			shutdown_shard_writer_registry(&td.shard_writers)
			return path, false
		}
		td.shard_writers.writer_index[shard] = 0
		td.shard_writers.mode = .Active
		return path, true
	}

	ASSET_EQUIVALENCE_PAYLOAD_CAPACITY :: 2_048

	Asset_Equivalence_Result :: struct {
		response:          [ASSET_EQUIVALENCE_PAYLOAD_CAPACITY]byte,
		response_len:      int,
		asset_payload:     [ASSET_EQUIVALENCE_PAYLOAD_CAPACITY]byte,
		asset_payload_len: int,
		asset_count:       int,
		wal_records:       u64,
		wal_last_hash:     [32]byte,
		asset_floor:       u64,
		index_count:       int,
		btree_count:       int,
		index_key:         Note_Sort_Key,
		index_present:     bool,
		btree_contains:    bool,
	}

	handler_equivalence_deliver_wire :: proc(sim: ^Sim_Runtime, client: ^NRC_Connection, payload: []byte, split_selector_a, split_selector_b: int) -> bool {
		frame := make_test_ws_frame(payload, .opBinary, true)
		defer delete(frame)
		if len(frame) < 3 do return false
		first := 1 + split_selector_a % (len(frame) - 1)
		second := 1 + split_selector_b % (len(frame) - 1)
		if first == second {
			second = first == len(frame) - 1 ? first - 1 : first + 1
		}
		if first > second do first, second = second, first
		boundaries := [4]int{0, first, second, len(frame)}
		for index in 0 ..< len(boundaries) - 1 {
			start, end := boundaries[index], boundaries[index + 1]
			if start == end do continue
			if !nrc_sim_enqueue_receive(sim, client, frame[start:end]) do return false
		}
		nrc_sim_run_all_receives(sim)
		return true
	}

	asset_equivalence_capture :: proc(
		ctx: ^Sim_Test_Context,
		workspace_id: string,
		conv_id: pr.ConversationID,
		asset_id: pr.AssetID,
		expected_opcode: pr.Opcode,
		expected_correlation: u32,
	) -> (
		Asset_Equivalence_Result,
		string,
		bool,
	) {
		result: Asset_Equivalence_Result
		client := simulation_test_client(ctx, 1)
		if client == nil do return result, "asset equivalence client missing", false
		if !simulation_test_commit_shards(&ctx.sim) do return result, "commit asset mutation", false
		if nrc_sim_client_frame_count(&ctx.sim, client.sock) != 1 do return result, "unexpected asset response count", false
		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, client.sock, 0))
		if !payload_ok || len(payload) > len(result.response) do return result, "capture asset response", false
		copy(result.response[:], payload)
		result.response_len = len(payload)
		ws := get_workspace(workspace_id)
		conv := get_conversation(ws, conv_id)
		if conv == nil do return result, "asset equivalence conversation missing", false
		asset := conv.assets[asset_id]
		if asset == nil do return result, "asset equivalence live asset missing", false
		result.asset_payload_len = pr.serializeAsset(asset^, result.asset_payload[:])
		if result.asset_payload_len <= 0 do return result, "serialize asset equivalence final state", false
		result.asset_count = len(conv.assets)
		result.wal_records = td.shard_writers.writers[0].wal.record_count
		result.wal_last_hash = td.shard_writers.writers[0].wal.last_hash
		result.asset_floor = td.shard_writers.writers[0].floors.asset
		result.index_count = len(conv.note_index_keys)
		result.btree_count = btree.count(&conv.note_index)
		result.index_key, result.index_present = conv.note_index_keys[asset_id]
		if result.index_present do result.btree_contains = btree.contains(&conv.note_index, result.index_key)
		correlation_matches := false
		#partial switch expected_opcode {
		case .S_AssetCreated:
			msg, parse_err := pr.parseAssetCreatedMessage(payload)
			correlation_matches = parse_err == nil && msg.correlation_id == expected_correlation
		case .S_AssetUpdated:
			msg, parse_err := pr.parseAssetUpdatedMessage(payload)
			correlation_matches = parse_err == nil && msg.correlation_id == expected_correlation
		}
		if pr.get_opcode(payload) != expected_opcode || !correlation_matches || result.asset_count != 1 || result.wal_last_hash == ([32]byte{}) {
			return result, "asset path did not produce the expected successful mutation", false
		}
		return result, "", true
	}

	asset_equivalence_results_equal :: proc(a, b: Asset_Equivalence_Result) -> bool {
		if a.response_len != b.response_len do return false
		for index in 0 ..< a.response_len do if a.response[index] != b.response[index] do return false
		if a.asset_payload_len != b.asset_payload_len do return false
		for index in 0 ..< a.asset_payload_len do if a.asset_payload[index] != b.asset_payload[index] do return false
		return(
			a.asset_count == b.asset_count &&
			a.wal_records == b.wal_records &&
			a.wal_last_hash == b.wal_last_hash &&
			a.asset_floor == b.asset_floor &&
			a.index_count == b.index_count &&
			a.btree_count == b.btree_count &&
			a.index_key == b.index_key &&
			a.index_present == b.index_present &&
			a.btree_contains == b.btree_contains \
		)
	}

	asset_equivalence_attachments_equal :: proc(a, b: []pr.Attachment) -> bool {
		if len(a) != len(b) do return false
		for value, index in a {
			other := b[index]
			if string(value.file_id) != string(other.file_id) ||
			   string(value.filename) != string(other.filename) ||
			   value.size != other.size ||
			   string(value.mime_type) != string(other.mime_type) ||
			   value.uploaded_at != other.uploaded_at {
				return false
			}
		}
		return true
	}

	asset_create_equivalence_run :: proc(req: pr.CreateAssetRequest, through_wire: bool, split_a, split_b: int) -> (Asset_Equivalence_Result, string, bool) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, through_wire ? 137 : 136)
		defer simulation_test_end(&ctx)
		workspace_id := "asset-create-parser-direct-equivalence"
		wal_path, writer_ok := asset_query_test_init_writer(workspace_id, "asset_create_equivalence.log")
		defer os.remove(wal_path)
		if !writer_ok do return {}, "initialize create-asset WAL", false
		defer shutdown_shard_writer_registry(&td.shard_writers)
		td.asset_seq = 0

		client := simulation_test_install_client(&ctx.sim, 1, workspace_id, "equivalence-user")
		if client == nil do return {}, "install create-asset client", false
		ctx.conns[1] = client
		subscribe_to_conversation(client, req.conv_id)
		nrc_sim_clear_inboxes(&ctx.sim)
		expected_now := nrc_time_unix_nanos()
		if through_wire {
			request_buf: [1_024]byte
			request_len := pr.serializeCreateAssetRequest(req, request_buf[:])
			if request_len <= 0 do return {}, "serialize create-asset request", false
			if !handler_equivalence_deliver_wire(&ctx.sim, client, request_buf[:request_len], split_a, split_b) do return {}, "deliver split create-asset request", false
		} else {
			handle_create_asset(client, req)
		}

		result, reason, ok := asset_equivalence_capture(&ctx, workspace_id, req.conv_id, 1, .S_AssetCreated, req.correlation_id)
		if !ok do return result, reason, false
		expected_indexes := req.asset_type == .Note ? 1 : 0
		expected_asset_floor := u64(1)
		if req.parent_type == .Asset do expected_asset_floor = max(expected_asset_floor, req.parent_id)
		ws := get_workspace(workspace_id)
		conv := get_conversation(ws, req.conv_id)
		asset := conv.assets[1]
		if result.wal_records != 1 ||
		   result.asset_floor != expected_asset_floor ||
		   result.index_count != expected_indexes ||
		   result.btree_count != expected_indexes ||
		   result.index_present != (expected_indexes == 1) ||
		   result.btree_contains != (expected_indexes == 1) ||
		   (expected_indexes == 1 && result.index_key != make_note_sort_key(asset)) ||
		   asset.asset_id != 1 ||
		   asset.conv_id != req.conv_id ||
		   string(asset.owner) != "equivalence-user" ||
		   asset.created_at != expected_now ||
		   asset.updated_at != expected_now ||
		   asset.asset_type != req.asset_type ||
		   asset.parent_type != req.parent_type ||
		   asset.parent_id != req.parent_id ||
		   asset.payload_encoding != req.payload_encoding ||
		   asset.payload_raw_len != req.payload_raw_len ||
		   string(asset.preview) != string(req.preview) ||
		   string(asset.payload) != string(req.payload) ||
		   !asset_equivalence_attachments_equal(asset.attachments, req.attachments) {
			return result, "create-asset indexes or WAL state differ from the request", false
		}
		return result, "", true
	}

	asset_update_equivalence_run :: proc(req: pr.UpdateAssetRequest, through_wire: bool, split_a, split_b: int) -> (Asset_Equivalence_Result, string, bool) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, through_wire ? 139 : 138)
		defer simulation_test_end(&ctx)
		workspace_id := "asset-update-parser-direct-equivalence"
		wal_path, writer_ok := asset_query_test_init_writer(workspace_id, "asset_update_equivalence.log")
		defer os.remove(wal_path)
		if !writer_ok do return {}, "initialize update-asset WAL", false
		defer shutdown_shard_writer_registry(&td.shard_writers)
		td.asset_seq = 0

		client := simulation_test_install_client(&ctx.sim, 1, workspace_id, "equivalence-user")
		if client == nil do return {}, "install update-asset client", false
		ctx.conns[1] = client
		subscribe_to_conversation(client, req.conv_id)
		nrc_sim_clear_inboxes(&ctx.sim)
		handle_create_asset(
			client,
			pr.CreateAssetRequest {
				conv_id = req.conv_id,
				asset_type = .Note,
				parent_type = .Task,
				parent_id = 44,
				payload_encoding = .Plain,
				payload_raw_len = 13,
				preview = transmute([]byte)string(`{"project":"baseline","tags":["old"]}`),
				payload = transmute([]byte)string("baseline body"),
			},
		)
		if !simulation_test_commit_shards(&ctx.sim) do return {}, "commit update-asset baseline", false
		if nrc_sim_client_frame_count(&ctx.sim, client.sock) != 1 do return {}, "create update-asset baseline", false
		ws := get_workspace(workspace_id)
		conv := get_conversation(ws, req.conv_id)
		baseline := conv.assets[req.asset_id]
		if baseline == nil do return {}, "update-asset baseline missing", false
		baseline_created_at := baseline.created_at
		nrc_sim_clear_inboxes(&ctx.sim)
		ctx.sim.world.now += 1
		expected_updated_at := nrc_time_unix_nanos()

		if through_wire {
			request_buf: [1_024]byte
			request_len := pr.serializeUpdateAssetRequest(req, request_buf[:])
			if request_len <= 0 do return {}, "serialize update-asset request", false
			if !handler_equivalence_deliver_wire(&ctx.sim, client, request_buf[:request_len], split_a, split_b) do return {}, "deliver split update-asset request", false
		} else {
			handle_update_asset(client, req)
		}

		result, reason, ok := asset_equivalence_capture(&ctx, workspace_id, req.conv_id, req.asset_id, .S_AssetUpdated, req.correlation_id)
		if !ok do return result, reason, false
		asset := conv.assets[req.asset_id]
		expected_key := make_note_sort_key(asset)
		if result.wal_records != 2 ||
		   result.asset_floor != 1 ||
		   result.index_count != 1 ||
		   result.btree_count != 1 ||
		   !result.index_present ||
		   !result.btree_contains ||
		   result.index_key != expected_key ||
		   asset.asset_id != req.asset_id ||
		   asset.conv_id != req.conv_id ||
		   asset.asset_type != .Note ||
		   asset.parent_type != .Task ||
		   asset.parent_id != 44 ||
		   string(asset.owner) != "equivalence-user" ||
		   asset.payload_encoding != req.payload_encoding ||
		   asset.payload_raw_len != req.payload_raw_len ||
		   string(asset.preview) != string(req.preview) ||
		   string(asset.payload) != string(req.payload) ||
		   !asset_equivalence_attachments_equal(asset.attachments, req.attachments) ||
		   asset.created_at != baseline_created_at ||
		   asset.updated_at != expected_updated_at ||
		   asset.updated_at <= asset.created_at {
			return result, "update-asset immutable fields, indexes, or WAL state differ from the request", false
		}
		return result, "", true
	}

	prop_asset_create_parser_direct_equivalence :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		selector, selector_err := hgl.draw_i64(tc, 0, 4_095)
		if selector_err == .Stop_Test do return hgl.abort()
		if selector_err != nil do return hgl.interesting("create-asset selector draw failed")
		correlation, correlation_err := hgl.draw_i64(tc, 0, i64(max(u32)))
		if correlation_err == .Stop_Test do return hgl.abort()
		if correlation_err != nil do return hgl.interesting("create-asset correlation draw failed")
		split_a, split_a_err := hgl.draw_i64(tc, 0, 4_095)
		if split_a_err == .Stop_Test do return hgl.abort()
		if split_a_err != nil do return hgl.interesting("create-asset first split draw failed")
		split_b, split_b_err := hgl.draw_i64(tc, 0, 4_095)
		if split_b_err == .Stop_Test do return hgl.abort()
		if split_b_err != nil do return hgl.interesting("create-asset second split draw failed")

		previews := [?]string{"", "generated preview", `{"project":"nrc","tags":["sim","parser"]}`}
		payloads := [?]string{"x", "generated asset payload", "compressed-shaped bytes"}
		attachment_storage: [1]pr.Attachment
		attachments: []pr.Attachment
		if selector & 1 != 0 {
			attachment_storage[0] = {
				file_id     = transmute([]byte)string("asset-file"),
				filename    = transmute([]byte)string("asset.bin"),
				size        = u64(1_000 + selector),
				mime_type   = transmute([]byte)string("application/octet-stream"),
				uploaded_at = 2_000 + selector,
			}
			attachments = attachment_storage[:]
		}
		payload := payloads[(selector / 3) % i64(len(payloads))]
		encoding := pr.PayloadEncoding((selector / 7) % 2)
		parent_type := pr.ParentType((selector / 11) % 3)
		req := pr.CreateAssetRequest {
			conv_id          = pr.WORKSPACE_DATA_ID,
			asset_type       = pr.AssetType(1 + (selector / 13) % 6),
			parent_type      = parent_type,
			parent_id        = parent_type == .None ? 0 : 99,
			payload_encoding = encoding,
			payload_raw_len  = encoding == .Plain ? u32(len(payload)) : u32(len(payload) + 100),
			preview          = transmute([]byte)previews[(selector / 17) % i64(len(previews))],
			payload          = transmute([]byte)payload,
			attachments      = attachments,
			correlation_id   = u32(correlation),
		}
		direct, direct_reason, direct_ok := asset_create_equivalence_run(req, false, 0, 0)
		if !direct_ok do return hgl.interesting(direct_reason)
		wire, wire_reason, wire_ok := asset_create_equivalence_run(req, true, int(split_a), int(split_b))
		if !wire_ok do return hgl.interesting(wire_reason)
		if !asset_equivalence_results_equal(direct, wire) do return hgl.interesting("direct and split-wire create-asset semantics differ")
		return hgl.valid()
	}

	prop_asset_update_parser_direct_equivalence :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		selector, selector_err := hgl.draw_i64(tc, 0, 4_095)
		if selector_err == .Stop_Test do return hgl.abort()
		if selector_err != nil do return hgl.interesting("update-asset selector draw failed")
		correlation, correlation_err := hgl.draw_i64(tc, 0, i64(max(u32)))
		if correlation_err == .Stop_Test do return hgl.abort()
		if correlation_err != nil do return hgl.interesting("update-asset correlation draw failed")
		split_a, split_a_err := hgl.draw_i64(tc, 0, 4_095)
		if split_a_err == .Stop_Test do return hgl.abort()
		if split_a_err != nil do return hgl.interesting("update-asset first split draw failed")
		split_b, split_b_err := hgl.draw_i64(tc, 0, 4_095)
		if split_b_err == .Stop_Test do return hgl.abort()
		if split_b_err != nil do return hgl.interesting("update-asset second split draw failed")

		previews := [?]string{`{"project":"new","tags":[]}`, `{"project":"updated","tags":["one","two"]}`, "opaque preview"}
		payloads := [?]string{"u", "updated asset payload", "replacement compressed-shaped bytes"}
		attachment_storage: [1]pr.Attachment
		attachments: []pr.Attachment
		if selector & 1 != 0 {
			attachment_storage[0] = {
				file_id     = transmute([]byte)string("updated-asset-file"),
				filename    = transmute([]byte)string("updated.txt"),
				size        = u64(3_000 + selector),
				mime_type   = transmute([]byte)string("text/plain"),
				uploaded_at = 4_000 + selector,
			}
			attachments = attachment_storage[:]
		}
		payload := payloads[(selector / 3) % i64(len(payloads))]
		encoding := pr.PayloadEncoding((selector / 5) % 2)
		req := pr.UpdateAssetRequest {
			conv_id          = pr.WORKSPACE_DATA_ID,
			asset_id         = 1,
			payload_encoding = encoding,
			payload_raw_len  = encoding == .Plain ? u32(len(payload)) : u32(len(payload) + 200),
			preview          = transmute([]byte)previews[(selector / 7) % i64(len(previews))],
			payload          = transmute([]byte)payload,
			attachments      = attachments,
			correlation_id   = u32(correlation),
		}
		direct, direct_reason, direct_ok := asset_update_equivalence_run(req, false, 0, 0)
		if !direct_ok do return hgl.interesting(direct_reason)
		wire, wire_reason, wire_ok := asset_update_equivalence_run(req, true, int(split_a), int(split_b))
		if !wire_ok do return hgl.interesting(wire_reason)
		if !asset_equivalence_results_equal(direct, wire) do return hgl.interesting("direct and split-wire update-asset semantics differ")
		return hgl.valid()
	}

	asset_create_update_equivalence_mandatory_cases :: proc(t: ^testing.T) -> bool {
		create_payload := transmute([]byte)string("mandatory asset body")
		create_attachment := [1]pr.Attachment {
			{
				file_id = transmute([]byte)string("mandatory-create-file"),
				filename = transmute([]byte)string("create.bin"),
				size = 8_192,
				mime_type = transmute([]byte)string("application/octet-stream"),
				uploaded_at = 9_000,
			},
		}
		create_cases := [?]pr.CreateAssetRequest {
			{
				conv_id = pr.WORKSPACE_DATA_ID,
				asset_type = .Document,
				payload_encoding = .Plain,
				payload_raw_len = u32(len(create_payload)),
				preview = transmute([]byte)string("mandatory document"),
				payload = create_payload,
				correlation_id = 0x7300,
			},
			{
				conv_id = pr.WORKSPACE_DATA_ID,
				asset_type = .Note,
				parent_type = .Asset,
				parent_id = 99,
				payload_encoding = .Zstd,
				payload_raw_len = 200,
				preview = transmute([]byte)string(`{"project":"mandatory","tags":["asset"]}`),
				payload = create_payload,
				attachments = create_attachment[:],
				correlation_id = 0x7301,
			},
			{
				conv_id = pr.WORKSPACE_DATA_ID,
				asset_type = .Comment,
				parent_type = .Task,
				parent_id = 77,
				payload_encoding = .Plain,
				payload_raw_len = u32(len(create_payload)),
				preview = transmute([]byte)string("mandatory task parent"),
				payload = create_payload,
				correlation_id = 0x7302,
			},
		}
		for req, case_index in create_cases {
			direct, direct_reason, direct_ok := asset_create_equivalence_run(req, false, 0, 0)
			testing.expectf(t, direct_ok, "mandatory create-asset case %d direct path failed: %s", case_index, direct_reason)
			if !direct_ok do return false
			wire, wire_reason, wire_ok := asset_create_equivalence_run(req, true, 1 + case_index, 9 + case_index)
			testing.expectf(t, wire_ok, "mandatory create-asset case %d split-wire path failed: %s", case_index, wire_reason)
			if !wire_ok do return false
			equal := asset_equivalence_results_equal(direct, wire)
			testing.expectf(t, equal, "mandatory create-asset case %d direct and split-wire semantics should match", case_index)
			if !equal do return false
		}

		update_payload := transmute([]byte)string("mandatory replacement")
		update_attachment := [1]pr.Attachment {
			{
				file_id = transmute([]byte)string("mandatory-update-file"),
				filename = transmute([]byte)string("update.txt"),
				size = 16_384,
				mime_type = transmute([]byte)string("text/plain"),
				uploaded_at = 18_000,
			},
		}
		update_cases := [?]pr.UpdateAssetRequest {
			{
				conv_id = pr.WORKSPACE_DATA_ID,
				asset_id = 1,
				payload_encoding = .Plain,
				payload_raw_len = u32(len(update_payload)),
				preview = transmute([]byte)string(`{"project":"plain","tags":[]}`),
				payload = update_payload,
				correlation_id = 0x7400,
			},
			{
				conv_id = pr.WORKSPACE_DATA_ID,
				asset_id = 1,
				payload_encoding = .Zstd,
				payload_raw_len = 300,
				preview = transmute([]byte)string(`{"project":"zstd","tags":["updated"]}`),
				payload = update_payload,
				attachments = update_attachment[:],
				correlation_id = 0x7401,
			},
		}
		for req, case_index in update_cases {
			direct, direct_reason, direct_ok := asset_update_equivalence_run(req, false, 0, 0)
			testing.expectf(t, direct_ok, "mandatory update-asset case %d direct path failed: %s", case_index, direct_reason)
			if !direct_ok do return false
			wire, wire_reason, wire_ok := asset_update_equivalence_run(req, true, 2 + case_index, 11 + case_index)
			testing.expectf(t, wire_ok, "mandatory update-asset case %d split-wire path failed: %s", case_index, wire_reason)
			if !wire_ok do return false
			equal := asset_equivalence_results_equal(direct, wire)
			testing.expectf(t, equal, "mandatory update-asset case %d direct and split-wire semantics should match", case_index)
			if !equal do return false
		}
		return true
	}
}

when NRC_SIMULATION {
	Asset_Delete_Equivalence_Kind :: enum {
		Simple,
		Cascade,
	}

	Asset_Delete_Equivalence_Result :: struct {
		responses:              [5][64]byte,
		response_lens:          [5]int,
		response_count:         int,
		survivor_assets:        [2][ASSET_EQUIVALENCE_PAYLOAD_CAPACITY]byte,
		survivor_asset_lens:    [2]int,
		retained_edge:          [256]byte,
		retained_edge_len:      int,
		asset_count:            int,
		edge_count:             int,
		adjacency_count:        int,
		note_index_count:       int,
		note_key_count:         int,
		note_project_count:     int,
		note_tag_count:         int,
		wal_records:            u64,
		wal_last_hash:          [32]byte,
		asset_floor:            u64,
		edge_floor:             u64,
		removed_assets_absent:  bool,
		removed_edges_absent:   bool,
		retained_adjacency:     bool,
		edge_notifications_ok:  bool,
		asset_notifications_ok: bool,
	}

	asset_delete_equivalence_create_asset :: proc(
		client: ^NRC_Connection,
		conv_id: pr.ConversationID,
		asset_type: pr.AssetType,
		parent_type: pr.ParentType,
		parent_id: u64,
		preview, payload: string,
	) {
		handle_create_asset(
			client,
			pr.CreateAssetRequest {
				conv_id = conv_id,
				asset_type = asset_type,
				parent_type = parent_type,
				parent_id = parent_id,
				payload_encoding = .Plain,
				payload_raw_len = u32(len(payload)),
				preview = transmute([]byte)preview,
				payload = transmute([]byte)payload,
			},
		)
	}

	asset_delete_equivalence_run :: proc(
		kind: Asset_Delete_Equivalence_Kind,
		correlation_id: u32,
		through_wire: bool,
		split_a, split_b: int,
	) -> (
		Asset_Delete_Equivalence_Result,
		string,
		bool,
	) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, through_wire ? 141 : 140)
		defer simulation_test_end(&ctx)
		workspace_id := "asset-delete-parser-direct-equivalence"
		wal_path, writer_ok := asset_query_test_init_writer(workspace_id, "asset_delete_equivalence.log")
		defer os.remove(wal_path)
		if !writer_ok do return {}, "initialize delete-asset WAL", false
		defer shutdown_shard_writer_registry(&td.shard_writers)
		td.asset_seq = 0
		td.edge_seq = 0

		client := simulation_test_install_client(&ctx.sim, 1, workspace_id, "equivalence-user")
		if client == nil do return {}, "install delete-asset client", false
		ctx.conns[1] = client
		conv_id := pr.WORKSPACE_DATA_ID
		subscribe_to_conversation(client, conv_id)
		nrc_sim_clear_inboxes(&ctx.sim)

		if kind == .Simple {
			asset_delete_equivalence_create_asset(client, conv_id, .Note, .None, 0, `{"project":"removed","tags":["delete"]}`, "root")
			asset_delete_equivalence_create_asset(client, conv_id, .Document, .None, 0, "survivor", "survivor")
		} else {
			asset_delete_equivalence_create_asset(client, conv_id, .Note, .None, 0, `{"project":"root","tags":["tree"]}`, "root")
			asset_delete_equivalence_create_asset(client, conv_id, .Note, .Asset, 1, `{"project":"child","tags":["tree"]}`, "child")
			asset_delete_equivalence_create_asset(client, conv_id, .Document, .Asset, 2, "grandchild", "grandchild")
			asset_delete_equivalence_create_asset(client, conv_id, .Document, .None, 0, "outside-a", "outside-a")
			asset_delete_equivalence_create_asset(client, conv_id, .File, .None, 0, "outside-b", "outside-b")
			edge_requests := [?]pr.CreateEdgeRequest {
				{conv_id = conv_id, source_type = .Asset, source_id = 1, target_type = .Asset, target_id = 2, relation = .References},
				{conv_id = conv_id, source_type = .Asset, source_id = 2, target_type = .Asset, target_id = 3, relation = .RelatedTo},
				{conv_id = conv_id, source_type = .Asset, source_id = 1, target_type = .Asset, target_id = 4, relation = .DependsOn},
				{conv_id = conv_id, source_type = .Asset, source_id = 4, target_type = .Asset, target_id = 5, relation = .References},
			}
			for req in edge_requests do handle_create_edge(client, req)
		}

		ws := get_workspace(workspace_id)
		conv := get_conversation(ws, conv_id)
		if conv == nil do return {}, "delete-asset fixture conversation missing", false
		expected_setup_assets := kind == .Simple ? 2 : 5
		expected_setup_edges := kind == .Simple ? 0 : 4
		if len(conv.assets) != expected_setup_assets || len(conv.edges) != expected_setup_edges {
			return {}, "create delete-asset fixture", false
		}
		if kind == .Simple {
			key, key_ok := conv.note_index_keys[1]
			project_assets := conv.note_project_assets["removed"]
			tag_assets := conv.note_tag_assets["delete"]
			if btree.count(&conv.note_index) != 1 ||
			   len(conv.note_index_keys) != 1 ||
			   !key_ok ||
			   !btree.contains(&conv.note_index, key) ||
			   len(conv.note_project_assets) != 1 ||
			   note_secondary_index_count(project_assets) != 1 ||
			   !note_secondary_index_contains_asset(project_assets, 1) ||
			   len(conv.note_tag_assets) != 1 ||
			   note_secondary_index_count(tag_assets) != 1 ||
			   !note_secondary_index_contains_asset(tag_assets, 1) {
				return {}, "simple delete-asset Note indexes missing before delete", false
			}
		} else {
			root_key, root_key_ok := conv.note_index_keys[1]
			child_key, child_key_ok := conv.note_index_keys[2]
			root_project := conv.note_project_assets["root"]
			child_project := conv.note_project_assets["child"]
			tree_tag := conv.note_tag_assets["tree"]
			if btree.count(&conv.note_index) != 2 ||
			   len(conv.note_index_keys) != 2 ||
			   !root_key_ok ||
			   !child_key_ok ||
			   !btree.contains(&conv.note_index, root_key) ||
			   !btree.contains(&conv.note_index, child_key) ||
			   len(conv.note_project_assets) != 2 ||
			   note_secondary_index_count(root_project) != 1 ||
			   !note_secondary_index_contains_asset(root_project, 1) ||
			   note_secondary_index_count(child_project) != 1 ||
			   !note_secondary_index_contains_asset(child_project, 2) ||
			   len(conv.note_tag_assets) != 1 ||
			   note_secondary_index_count(tree_tag) != 2 ||
			   !note_secondary_index_contains_asset(tree_tag, 1) ||
			   !note_secondary_index_contains_asset(tree_tag, 2) {
				return {}, "cascade delete-asset Note indexes missing before delete", false
			}
		}
		if !simulation_test_commit_shards(&ctx.sim) do return {}, "commit delete-asset baseline", false
		nrc_sim_clear_inboxes(&ctx.sim)

		req := pr.DeleteAssetRequest {
			conv_id        = conv_id,
			asset_id       = 1,
			correlation_id = correlation_id,
		}
		if through_wire {
			request_buf: [32]byte
			request_len := pr.serializeDeleteAssetRequest(req.conv_id, req.asset_id, request_buf[:], req.correlation_id)
			if request_len <= 0 do return {}, "serialize delete-asset request", false
			if !handler_equivalence_deliver_wire(&ctx.sim, client, request_buf[:request_len], split_a, split_b) do return {}, "deliver split delete-asset request", false
		} else {
			handle_delete_asset(client, req)
		}
		if !simulation_test_commit_shards(&ctx.sim) do return {}, "commit delete-asset", false

		result: Asset_Delete_Equivalence_Result
		result.response_count = nrc_sim_client_frame_count(&ctx.sim, client.sock)
		expected_response_count := kind == .Simple ? 1 : 5
		if result.response_count != expected_response_count do return result, "unexpected delete-asset response count", false
		asset_deleted_seen: [4]bool
		edge_deleted_seen: [5]bool
		for frame_index in 0 ..< result.response_count {
			response, response_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, client.sock, frame_index))
			if !response_ok || len(response) > len(result.responses[frame_index]) do return result, "capture delete-asset response", false
			copy(result.responses[frame_index][:], response)
			result.response_lens[frame_index] = len(response)
			#partial switch pr.get_opcode(response) {
			case .S_AssetDeleted:
				deleted, parse_err := pr.parseAssetDeletedMessage(response)
				expected_message_correlation := deleted.asset_id == 1 ? correlation_id : u32(0)
				if parse_err != nil ||
				   deleted.conv_id != conv_id ||
				   deleted.asset_id < 1 ||
				   deleted.asset_id > 3 ||
				   deleted.correlation_id != expected_message_correlation ||
				   asset_deleted_seen[deleted.asset_id] {
					return result, "delete-asset response semantics differ from request", false
				}
				asset_deleted_seen[deleted.asset_id] = true
			case .S_EdgeDeleted:
				deleted, parse_err := pr.parseEdgeDeletedMessage(response)
				if parse_err != nil || deleted.conv_id != conv_id || deleted.edge_id < 1 || deleted.edge_id > 4 || deleted.correlation_id != 0 {
					return result, "cascade edge-delete notification semantics differ", false
				}
				edge_deleted_seen[deleted.edge_id] = true
			}
		}
		if !asset_deleted_seen[1] do return result, "delete-asset acknowledgment missing", false
		result.edge_notifications_ok =
			kind == .Simple ? (!edge_deleted_seen[1] && !edge_deleted_seen[2]) : (edge_deleted_seen[1] && edge_deleted_seen[2] && !edge_deleted_seen[3] && !edge_deleted_seen[4])
		result.asset_notifications_ok = kind == .Simple ? (!asset_deleted_seen[2] && !asset_deleted_seen[3]) : (asset_deleted_seen[2] && asset_deleted_seen[3])

		result.asset_count = len(conv.assets)
		result.edge_count = len(conv.edges)
		result.adjacency_count = len(conv.edges_by_entity)
		result.note_index_count = btree.count(&conv.note_index)
		result.note_key_count = len(conv.note_index_keys)
		result.note_project_count = len(conv.note_project_assets)
		result.note_tag_count = len(conv.note_tag_assets)
		result.wal_records = td.shard_writers.writers[0].wal.record_count
		result.wal_last_hash = td.shard_writers.writers[0].wal.last_hash
		result.asset_floor = td.shard_writers.writers[0].floors.asset
		result.edge_floor = td.shard_writers.writers[0].floors.edge

		if kind == .Simple {
			result.removed_assets_absent = conv.assets[1] == nil
			if survivor := conv.assets[2]; survivor != nil {
				result.survivor_asset_lens[0] = pr.serializeAsset(survivor^, result.survivor_assets[0][:])
			}
			if result.asset_count != 1 ||
			   result.edge_count != 0 ||
			   result.adjacency_count != 0 ||
			   result.note_index_count != 0 ||
			   result.note_key_count != 0 ||
			   result.note_project_count != 0 ||
			   result.note_tag_count != 0 ||
			   result.wal_records != 3 ||
			   result.wal_last_hash == ([32]byte{}) ||
			   result.asset_floor != 2 ||
			   result.edge_floor != 0 ||
			   !result.edge_notifications_ok ||
			   !result.asset_notifications_ok ||
			   !result.removed_assets_absent ||
			   result.survivor_asset_lens[0] <= 0 {
				return result, "simple delete-asset state differs from expected semantics", false
			}
		} else {
			result.removed_assets_absent = conv.assets[1] == nil && conv.assets[2] == nil && conv.assets[3] == nil
			result.removed_edges_absent = conv.edges[1] == nil && conv.edges[2] == nil && conv.edges[3] == nil
			if survivor := conv.assets[4]; survivor != nil {
				result.survivor_asset_lens[0] = pr.serializeAsset(survivor^, result.survivor_assets[0][:])
			}
			if survivor := conv.assets[5]; survivor != nil {
				result.survivor_asset_lens[1] = pr.serializeAsset(survivor^, result.survivor_assets[1][:])
			}
			if retained := conv.edges[4]; retained != nil {
				result.retained_edge_len = pr.serializeEdge(retained^, result.retained_edge[:])
			}
			adjacency_a := conv.edges_by_entity[Edge_Entity_Key{target_type = .Asset, target_id = 4}]
			adjacency_b := conv.edges_by_entity[Edge_Entity_Key{target_type = .Asset, target_id = 5}]
			result.retained_adjacency = len(adjacency_a) == 1 && adjacency_a[0] == 4 && len(adjacency_b) == 1 && adjacency_b[0] == 4
			if result.asset_count != 2 ||
			   result.edge_count != 1 ||
			   result.adjacency_count != 2 ||
			   result.note_index_count != 0 ||
			   result.note_key_count != 0 ||
			   result.note_project_count != 0 ||
			   result.note_tag_count != 0 ||
			   result.wal_records != 10 ||
			   result.wal_last_hash == ([32]byte{}) ||
			   result.asset_floor != 5 ||
			   result.edge_floor != 4 ||
			   !result.removed_assets_absent ||
			   !result.removed_edges_absent ||
			   !result.retained_adjacency ||
			   !result.edge_notifications_ok ||
			   !result.asset_notifications_ok ||
			   result.survivor_asset_lens[0] <= 0 ||
			   result.survivor_asset_lens[1] <= 0 ||
			   result.retained_edge_len <= 0 {
				return result, "cascade delete-asset state differs from expected semantics", false
			}
		}
		return result, "", true
	}

	asset_delete_equivalence_results_equal :: proc(a, b: Asset_Delete_Equivalence_Result) -> bool {
		if a.response_count != b.response_count do return false
		for response_index in 0 ..< a.response_count {
			if a.response_lens[response_index] != b.response_lens[response_index] do return false
			for index in 0 ..< a.response_lens[response_index] do if a.responses[response_index][index] != b.responses[response_index][index] do return false
		}
		for survivor_index in 0 ..< len(a.survivor_asset_lens) {
			if a.survivor_asset_lens[survivor_index] != b.survivor_asset_lens[survivor_index] do return false
			for index in 0 ..< a.survivor_asset_lens[survivor_index] do if a.survivor_assets[survivor_index][index] != b.survivor_assets[survivor_index][index] do return false
		}
		if a.retained_edge_len != b.retained_edge_len do return false
		for index in 0 ..< a.retained_edge_len do if a.retained_edge[index] != b.retained_edge[index] do return false
		return(
			a.asset_count == b.asset_count &&
			a.edge_count == b.edge_count &&
			a.adjacency_count == b.adjacency_count &&
			a.note_index_count == b.note_index_count &&
			a.note_key_count == b.note_key_count &&
			a.note_project_count == b.note_project_count &&
			a.note_tag_count == b.note_tag_count &&
			a.wal_records == b.wal_records &&
			a.wal_last_hash == b.wal_last_hash &&
			a.asset_floor == b.asset_floor &&
			a.edge_floor == b.edge_floor &&
			a.response_count == b.response_count &&
			a.removed_assets_absent == b.removed_assets_absent &&
			a.removed_edges_absent == b.removed_edges_absent &&
			a.retained_adjacency == b.retained_adjacency &&
			a.edge_notifications_ok == b.edge_notifications_ok &&
			a.asset_notifications_ok == b.asset_notifications_ok \
		)
	}

	prop_asset_delete_parser_direct_equivalence :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		kind_value, kind_err := hgl.draw_i64(tc, 0, 1)
		if kind_err == .Stop_Test do return hgl.abort()
		if kind_err != nil do return hgl.interesting("delete-asset kind draw failed")
		correlation, correlation_err := hgl.draw_i64(tc, 0, i64(max(u32)))
		if correlation_err == .Stop_Test do return hgl.abort()
		if correlation_err != nil do return hgl.interesting("delete-asset correlation draw failed")
		split_a, split_a_err := hgl.draw_i64(tc, 0, 4_095)
		if split_a_err == .Stop_Test do return hgl.abort()
		if split_a_err != nil do return hgl.interesting("delete-asset first split draw failed")
		split_b, split_b_err := hgl.draw_i64(tc, 0, 4_095)
		if split_b_err == .Stop_Test do return hgl.abort()
		if split_b_err != nil do return hgl.interesting("delete-asset second split draw failed")
		kind := Asset_Delete_Equivalence_Kind(kind_value)
		direct, direct_reason, direct_ok := asset_delete_equivalence_run(kind, u32(correlation), false, 0, 0)
		if !direct_ok do return hgl.interesting(direct_reason)
		wire, wire_reason, wire_ok := asset_delete_equivalence_run(kind, u32(correlation), true, int(split_a), int(split_b))
		if !wire_ok do return hgl.interesting(wire_reason)
		if !asset_delete_equivalence_results_equal(direct, wire) do return hgl.interesting("direct and split-wire delete-asset semantics differ")
		return hgl.valid()
	}

	asset_delete_equivalence_mandatory_cases :: proc(t: ^testing.T) -> bool {
		cases := [?]Asset_Delete_Equivalence_Kind{.Simple, .Cascade}
		for kind, case_index in cases {
			direct, direct_reason, direct_ok := asset_delete_equivalence_run(kind, u32(0x7500 + case_index), false, 0, 0)
			testing.expectf(t, direct_ok, "mandatory delete-asset case %d direct path failed: %s", case_index, direct_reason)
			if !direct_ok do return false
			wire, wire_reason, wire_ok := asset_delete_equivalence_run(kind, u32(0x7500 + case_index), true, 3 + case_index, 13 + case_index)
			testing.expectf(t, wire_ok, "mandatory delete-asset case %d split-wire path failed: %s", case_index, wire_reason)
			if !wire_ok do return false
			equal := asset_delete_equivalence_results_equal(direct, wire)
			testing.expectf(t, equal, "mandatory delete-asset case %d direct and split-wire semantics should match", case_index)
			if !equal do return false
		}
		return true
	}
}

@(test)
test_hegel_asset_create_update_parser_direct_semantic_equivalence :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !asset_create_update_equivalence_mandatory_cases(t) do return
		if !hgl.can_run() do return
		create_result, create_err := hgl.run(
			prop_asset_create_parser_direct_equivalence,
			nil,
			{test_cases = 48, database_key = "asset-create-parser-direct-equivalence"},
		)
		testing.expectf(
			t,
			create_err == nil,
			"generated create-asset parser/direct equivalence failed: err=%v interesting=%v",
			create_err,
			create_result.interesting_test_cases,
		)
		if create_err != nil do return
		update_result, update_err := hgl.run(
			prop_asset_update_parser_direct_equivalence,
			nil,
			{test_cases = 48, database_key = "asset-update-parser-direct-equivalence"},
		)
		testing.expectf(
			t,
			update_err == nil,
			"generated update-asset parser/direct equivalence failed: err=%v interesting=%v",
			update_err,
			update_result.interesting_test_cases,
		)
	}
}

@(test)
test_hegel_asset_delete_cascade_parser_direct_semantic_equivalence :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !asset_delete_equivalence_mandatory_cases(t) do return
		if !hgl.can_run() do return
		result, err := hgl.run(prop_asset_delete_parser_direct_equivalence, nil, {test_cases = 48})
		testing.expectf(t, err == nil, "generated delete-asset parser/direct equivalence failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_simulation_asset_get_list_and_note_metadata_responses :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 126)
		defer simulation_test_end(&ctx)

		ops := [?]Sim_Op {
			{kind = .Connect, client_id = 1, workspace_id = "asset-query-responses", username = "alice"},
			{kind = .Subscribe, client_id = 1, conv_id = 81},
			{kind = .Clear_Inboxes},
		}
		testing.expect(t, simulation_test_apply_ops(&ctx, ops[:]), "asset query client should initialize")
		c := simulation_test_client(&ctx, 1)
		if c == nil do return
		conv := get_conversation(get_connection_workspace(c), 81)
		testing.expect(t, conv != nil, "asset query conversation should exist")
		if conv == nil do return

		note_a := asset_query_test_install_asset(conv, 81, 11, .Note, `{"project":"zeta","tags":["yellow","alpha"]}`, "note body", 300)
		note_b := asset_query_test_install_asset(conv, 81, 12, .Note, `{"project":"alpha","tags":["beta"]}`, "second body", 200)
		document := asset_query_test_install_asset(conv, 81, 13, .Document, "document preview", "document body", 100)
		testing.expect(t, note_a != nil && note_b != nil && document != nil, "asset query fixtures should allocate")
		if note_a == nil || note_b == nil || document == nil do return
		conv.assets[99] = nil // A stale map slot must not crash or appear on the wire.

		handle_get_asset(c, pr.GetAssetRequest{conv_id = 81, asset_id = 11, correlation_id = 1001})
		payload, ok := asset_query_test_payload(t, &ctx.sim, c, .S_AssetFull)
		if ok {
			msg, err := pr.parseAssetFullMessage(payload)
			testing.expect(t, err == nil, "full asset response should decode")
			testing.expect_value(t, msg.asset.asset_id, pr.AssetID(11))
			testing.expect(t, string(msg.asset.preview) == string(note_a.preview), "get should include preview")
			testing.expect(t, string(msg.asset.payload) == "note body", "get should include the full payload")
			testing.expect_value(t, msg.correlation_id, u32(1001))
		}

		nrc_sim_clear_inboxes(&ctx.sim)
		handle_list_assets(c, pr.ListAssetsRequest{conv_id = 81, filter_by_type = true, asset_type = .Note, full_content = false, correlation_id = 1002})
		payload, ok = asset_query_test_payload(t, &ctx.sim, c, .S_AssetList)
		if ok {
			msg, err := pr.parseAssetListMessage(payload)
			defer if len(msg.assets) > 0 do delete(msg.assets)
			testing.expect(t, err == nil, "filtered preview list should decode")
			testing.expect_value(t, msg.full_content, false)
			testing.expect_value(t, len(msg.assets), 2)
			testing.expect_value(t, msg.correlation_id, u32(1002))
			seen_note_a, seen_note_b := false, false
			for asset in msg.assets {
				testing.expect_value(t, asset.asset_type, pr.AssetType.Note)
				testing.expect_value(t, len(asset.payload), 0)
				switch asset.asset_id {
				case 11:
					seen_note_a = string(asset.preview) == string(note_a.preview)
				case 12:
					seen_note_b = string(asset.preview) == string(note_b.preview)
				}
			}
			testing.expect(t, seen_note_a && seen_note_b, "preview list should include each note preview")
		}

		nrc_sim_clear_inboxes(&ctx.sim)
		handle_list_assets(c, pr.ListAssetsRequest{conv_id = 81, full_content = true, correlation_id = 1003})
		payload, ok = asset_query_test_payload(t, &ctx.sim, c, .S_AssetList)
		if ok {
			msg, err := pr.parseAssetListMessage(payload)
			defer if len(msg.assets) > 0 do delete(msg.assets)
			testing.expect(t, err == nil, "full-content list should decode")
			testing.expect_value(t, msg.full_content, true)
			testing.expect_value(t, len(msg.assets), 3)
			testing.expect_value(t, msg.correlation_id, u32(1003))
			payloads_present := 0
			for asset in msg.assets {
				if len(asset.payload) > 0 do payloads_present += 1
			}
			testing.expect_value(t, payloads_present, 3)
		}

		nrc_sim_clear_inboxes(&ctx.sim)
		handle_list_note_projects(c, pr.ListNoteProjectsRequest{conv_id = 81, correlation_id = 1004})
		payload, ok = asset_query_test_payload(t, &ctx.sim, c, .S_NoteProjectList)
		if ok {
			msg, err := pr.parseNoteProjectListMessage(payload)
			defer if len(msg.projects) > 0 do delete(msg.projects)
			testing.expect(t, err == nil, "note project list should decode")
			testing.expect_value(t, len(msg.projects), 2)
			if len(msg.projects) == 2 {
				testing.expect(t, msg.projects[0] == "alpha" && msg.projects[1] == "zeta", "projects should be sorted")
			}
			testing.expect_value(t, msg.correlation_id, u32(1004))
		}

		nrc_sim_clear_inboxes(&ctx.sim)
		handle_list_note_tags(c, pr.ListNoteTagsRequest{conv_id = 81, correlation_id = 1005})
		payload, ok = asset_query_test_payload(t, &ctx.sim, c, .S_NoteTagList)
		if ok {
			msg, err := pr.parseNoteTagListMessage(payload)
			defer if len(msg.tags) > 0 do delete(msg.tags)
			testing.expect(t, err == nil, "note tag list should decode")
			testing.expect_value(t, len(msg.tags), 3)
			if len(msg.tags) == 3 {
				testing.expect(t, msg.tags[0] == "alpha" && msg.tags[1] == "beta" && msg.tags[2] == "yellow", "tags should be sorted")
			}
			testing.expect_value(t, msg.correlation_id, u32(1005))
		}
	}
}

@(test)
test_simulation_asset_query_missing_and_invalid_pagination_responses :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 127)
		defer simulation_test_end(&ctx)

		c := simulation_test_install_client(&ctx.sim, 1, "asset-query-missing-workspace", "alice")
		ctx.conns[1] = c
		if c == nil do return
		workspace := c.workspace
		c.workspace = nil
		delete_key(&td.workspaces, c.workspace_id)

		handle_get_asset(c, pr.GetAssetRequest{conv_id = 82, asset_id = 20, correlation_id = 1101})
		payload, ok := asset_query_test_payload(t, &ctx.sim, c, .S_ErrorResponse)
		if ok {
			msg, err := pr.parseErrorResponseMessage(payload)
			testing.expect(t, err == nil, "missing workspace error should decode")
			testing.expect_value(t, msg.origin_opcode, pr.Opcode.C_GetAsset)
			testing.expect(t, string(msg.error_msg) == "Workspace not found", "missing workspace error should be explicit")
			testing.expect_value(t, msg.correlation_id, u32(1101))
		}

		td.workspaces[c.workspace_id] = workspace
		c.workspace = workspace
		nrc_sim_clear_inboxes(&ctx.sim)
		handle_get_asset(c, pr.GetAssetRequest{conv_id = 82, asset_id = 20, correlation_id = 1102})
		payload, ok = asset_query_test_payload(t, &ctx.sim, c, .S_ErrorResponse)
		if ok {
			msg, err := pr.parseErrorResponseMessage(payload)
			testing.expect(t, err == nil, "missing conversation error should decode")
			testing.expect(t, string(msg.error_msg) == "Conversation not found", "missing conversation error should be explicit")
			testing.expect_value(t, msg.correlation_id, u32(1102))
		}

		_ = get_or_create_conversation(c.workspace, 82)
		nrc_sim_clear_inboxes(&ctx.sim)
		handle_get_asset(c, pr.GetAssetRequest{conv_id = 82, asset_id = 20, correlation_id = 1103})
		payload, ok = asset_query_test_payload(t, &ctx.sim, c, .S_ErrorResponse)
		if ok {
			msg, err := pr.parseErrorResponseMessage(payload)
			testing.expect(t, err == nil, "missing asset error should decode")
			testing.expect(t, string(msg.error_msg) == "Asset not found", "missing asset error should be explicit")
			testing.expect_value(t, msg.correlation_id, u32(1103))
		}

		nrc_sim_clear_inboxes(&ctx.sim)
		handle_list_assets(c, pr.ListAssetsRequest{conv_id = 999, full_content = true, correlation_id = 1104})
		payload, ok = asset_query_test_payload(t, &ctx.sim, c, .S_AssetList)
		if ok {
			msg, err := pr.parseAssetListMessage(payload)
			defer if len(msg.assets) > 0 do delete(msg.assets)
			testing.expect(t, err == nil, "missing conversation list should decode")
			testing.expect_value(t, len(msg.assets), 0)
			testing.expect_value(t, msg.full_content, true)
			testing.expect_value(t, msg.correlation_id, u32(1104))
		}

		nrc_sim_clear_inboxes(&ctx.sim)
		handle_list_assets_paged(c, pr.ListAssetsPagedRequest{conv_id = 82, asset_type = .Document, full_content = true, correlation_id = 1111})
		asset_query_test_expect_empty_page(t, &ctx.sim, c, 1111)
		nrc_sim_clear_inboxes(&ctx.sim)
		handle_list_assets_paged_by_project(c, pr.ListAssetsPagedByProjectRequest{conv_id = 82, asset_type = .Document, project = "x", correlation_id = 1112})
		asset_query_test_expect_empty_page(t, &ctx.sim, c, 1112)
		nrc_sim_clear_inboxes(&ctx.sim)
		handle_list_assets_paged_by_tag(c, pr.ListAssetsPagedByTagRequest{conv_id = 82, asset_type = .Document, tag = "x", correlation_id = 1113})
		asset_query_test_expect_empty_page(t, &ctx.sim, c, 1113)
	}
}

@(test)
test_simulation_asset_mutation_broadcast_routing_and_correlations :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 128)
		defer simulation_test_end(&ctx)
		workspace_id := "asset-broadcast-routing"
		wal_path, writer_ok := asset_query_test_init_writer(workspace_id)
		defer os.remove(wal_path)
		testing.expect(t, writer_ok, "asset broadcast writer should initialize")
		if !writer_ok do return
		defer shutdown_shard_writer_registry(&td.shard_writers)
		td.asset_seq = 0

		ops := [?]Sim_Op {
			{kind = .Connect, client_id = 1, workspace_id = workspace_id, username = "alice"},
			{kind = .Connect, client_id = 2, workspace_id = workspace_id, username = "bob"},
			{kind = .Connect, client_id = 3, workspace_id = workspace_id, username = "carol"},
			{kind = .Connect, client_id = 4, workspace_id = "asset-broadcast-other-workspace", username = "dana"},
			{kind = .Subscribe, client_id = 1, conv_id = 83},
			{kind = .Subscribe, client_id = 2, conv_id = 83},
			{kind = .Subscribe, client_id = 4, conv_id = 83},
			{kind = .Clear_Inboxes},
		}
		testing.expect(t, simulation_test_apply_ops(&ctx, ops[:]), "asset broadcast clients should initialize")
		sender := simulation_test_client(&ctx, 1)
		peer := simulation_test_client(&ctx, 2)
		unsubscribed := simulation_test_client(&ctx, 3)
		other_workspace := simulation_test_client(&ctx, 4)
		if sender == nil || peer == nil || unsubscribed == nil || other_workspace == nil do return

		conv := get_conversation(get_connection_workspace(sender), 83)
		if conv == nil do return
		stale_sock := connection_test_fake_socket(90)
		append(&conv.subscriber_entries, Subscriber_Entry{sock = stale_sock})
		conv.subscriber_index[stale_sock] = len(conv.subscriber_entries) - 1

		handle_create_asset(
			sender,
			pr.CreateAssetRequest {
				conv_id = 83,
				asset_type = .Document,
				payload_encoding = .Plain,
				payload_raw_len = 11,
				preview = transmute([]byte)string("preview-one"),
				payload = transmute([]byte)string("payload-one"),
				correlation_id = 1201,
			},
		)
		testing.expect(t, simulation_test_commit_shards(&ctx.sim))
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, sender.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, peer.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, unsubscribed.sock), 0)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, other_workspace.sock), 0)
		recipients := [?]^NRC_Connection{sender, peer}
		created_correlations := [?]u32{1201, 0}
		for c, i in recipients {
			payload, ok := asset_query_test_payload(t, &ctx.sim, c, .S_AssetCreated)
			if ok {
				msg, err := pr.parseAssetCreatedMessage(payload)
				testing.expect(t, err == nil, "asset created response should decode")
				testing.expect_value(t, msg.asset.asset_id, pr.AssetID(1))
				testing.expect_value(t, msg.correlation_id, created_correlations[i])
			}
		}

		nrc_sim_clear_inboxes(&ctx.sim)
		handle_update_asset(
			sender,
			pr.UpdateAssetRequest {
				conv_id = 83,
				asset_id = 1,
				payload_encoding = .Plain,
				payload_raw_len = 11,
				preview = transmute([]byte)string("preview-two"),
				payload = transmute([]byte)string("payload-two"),
				correlation_id = 1202,
			},
		)
		updated_correlations := [?]u32{1202, 0}
		for c, i in recipients {
			payload, ok := asset_query_test_payload(t, &ctx.sim, c, .S_AssetUpdated)
			if ok {
				msg, err := pr.parseAssetUpdatedMessage(payload)
				testing.expect(t, err == nil, "asset updated response should decode")
				testing.expect(t, string(msg.asset.payload) == "payload-two", "update payload should reach requester and subscriber")
				testing.expect_value(t, msg.correlation_id, updated_correlations[i])
			}
		}
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, unsubscribed.sock), 0)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, other_workspace.sock), 0)

		nrc_sim_clear_inboxes(&ctx.sim)
		handle_delete_asset(sender, pr.DeleteAssetRequest{conv_id = 83, asset_id = 1, correlation_id = 1203})
		deleted_correlations := [?]u32{1203, 0}
		for c, i in recipients {
			payload, ok := asset_query_test_payload(t, &ctx.sim, c, .S_AssetDeleted)
			if ok {
				msg, err := pr.parseAssetDeletedMessage(payload)
				testing.expect(t, err == nil, "asset deleted response should decode")
				testing.expect_value(t, msg.conv_id, pr.ConversationID(83))
				testing.expect_value(t, msg.asset_id, pr.AssetID(1))
				testing.expect_value(t, msg.correlation_id, deleted_correlations[i])
			}
		}
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, unsubscribed.sock), 0)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, other_workspace.sock), 0)
	}
}
