package main

import "core:testing"

import "btree"
import hgl "hegel"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: btree.count
	_ :: hgl.run
	_ :: pr.Opcode
}

when NRC_SIMULATION {
	NOTE_PAGING_EQ_CONV :: pr.WORKSPACE_DATA_ID
	NOTE_PAGING_EQ_COUNT :: 7
	NOTE_PAGING_LIMIT_BOUNDARY_COUNT :: 251

	Note_Paging_Equivalence_Scope :: enum {
		Global,
		Project,
		Tag,
	}

	Note_Paging_Equivalence_Request :: struct {
		scope:             Note_Paging_Equivalence_Scope,
		filter:            string,
		asset_type:        pr.AssetType,
		full_content:      bool,
		limit:             u16,
		has_cursor:        bool,
		cursor_updated_at: i64,
		cursor_asset_id:   pr.AssetID,
		correlation_id:    u32,
	}

	Note_Paging_Equivalence_State :: struct {
		asset_bytes:      [NOTE_PAGING_EQ_COUNT][512]byte,
		asset_lens:       [NOTE_PAGING_EQ_COUNT]int,
		keys:             [NOTE_PAGING_EQ_COUNT]Note_Sort_Key,
		key_present:      [NOTE_PAGING_EQ_COUNT]bool,
		btree_keys:       [NOTE_PAGING_EQ_COUNT]Note_Sort_Key,
		btree_key_count:  int,
		alpha_projects:   [NOTE_PAGING_EQ_COUNT]pr.AssetID,
		alpha_count:      int,
		beta_projects:    [NOTE_PAGING_EQ_COUNT]pr.AssetID,
		beta_count:       int,
		shared_tags:      [NOTE_PAGING_EQ_COUNT]pr.AssetID,
		shared_count:     int,
		graph_tags:       [NOTE_PAGING_EQ_COUNT]pr.AssetID,
		graph_count:      int,
		odin_tags:        [NOTE_PAGING_EQ_COUNT]pr.AssetID,
		odin_count:       int,
		project_count:    int,
		tag_count:        int,
		asset_count:      int,
		note_index_count: int,
		note_btree_count: int,
		asset_seq:        u64,
	}

	Note_Paging_Equivalence_Result :: struct {
		response:     [32_768]byte,
		response_len: int,
	}

	Note_Paging_Limit_Boundary_State :: struct {
		keys:        [NOTE_PAGING_LIMIT_BOUNDARY_COUNT]Note_Sort_Key,
		key_count:   int,
		asset_count: int,
		index_count: int,
		asset_seq:   u64,
	}

	note_paging_equivalence_setup :: proc(conv: ^Conversation_State) -> bool {
		fixtures := [?]struct {
			id:             pr.AssetID,
			kind:           pr.AssetType,
			updated:        i64,
			metadata, body: string,
		} {
			{1, .Note, 100, `{"project":"alpha","tags":["odin","shared"]}`, "one"},
			{2, .Note, 300, `{"project":"alpha","tags":["shared"]}`, "two"},
			{3, .Note, 300, `{"project":"beta","tags":["shared","graph"]}`, "three"},
			{4, .Note, 250, `{"project":"beta","tags":["graph"]}`, "four"},
			{5, .Note, 200, `{"tags":["shared"]}`, "five"},
			{6, .Note, 150, `{"project":"alpha"}`, "six"},
			{7, .Document, 999, `{"project":"alpha","tags":["shared"]}`, "not-note"},
		}
		for fixture in fixtures {
			asset := asset_query_test_install_asset(conv, NOTE_PAGING_EQ_CONV, fixture.id, fixture.kind, fixture.metadata, fixture.body, fixture.updated)
			if asset == nil do return false
			asset.created_at = fixture.updated - 7
		}
		return true
	}

	note_paging_equivalence_capture_state :: proc(conv: ^Conversation_State) -> (Note_Paging_Equivalence_State, bool) {
		state: Note_Paging_Equivalence_State
		if conv == nil do return state, false
		for id in 1 ..= NOTE_PAGING_EQ_COUNT {
			asset := conv.assets[pr.AssetID(id)]
			if asset == nil do return state, false
			state.asset_lens[id - 1] = pr.serializeAsset(asset^, state.asset_bytes[id - 1][:])
			if state.asset_lens[id - 1] <= 0 do return state, false
			state.keys[id - 1], state.key_present[id - 1] = conv.note_index_keys[pr.AssetID(id)]
		}
		it := btree.iter(&conv.note_index)
		defer btree.iter_destroy(&it)
		for has_item := btree.iter_first(&it); has_item; has_item = btree.iter_next(&it) {
			if state.btree_key_count >= len(state.btree_keys) do return state, false
			state.btree_keys[state.btree_key_count] = btree.item(&it)
			state.btree_key_count += 1
		}
		alpha, beta := note_secondary_index_asset_ids(conv.note_project_assets["alpha"]), note_secondary_index_asset_ids(conv.note_project_assets["beta"])
		shared, graph, odin :=
			note_secondary_index_asset_ids(conv.note_tag_assets["shared"]),
			note_secondary_index_asset_ids(conv.note_tag_assets["graph"]),
			note_secondary_index_asset_ids(conv.note_tag_assets["odin"])
		defer delete(alpha)
		defer delete(beta)
		defer delete(shared)
		defer delete(graph)
		defer delete(odin)
		if len(alpha) > NOTE_PAGING_EQ_COUNT ||
		   len(beta) > NOTE_PAGING_EQ_COUNT ||
		   len(shared) > NOTE_PAGING_EQ_COUNT ||
		   len(graph) > NOTE_PAGING_EQ_COUNT ||
		   len(odin) > NOTE_PAGING_EQ_COUNT {
			return state, false
		}
		state.alpha_count, state.beta_count = len(alpha), len(beta)
		state.shared_count, state.graph_count, state.odin_count = len(shared), len(graph), len(odin)
		copy(state.alpha_projects[:], alpha[:])
		copy(state.beta_projects[:], beta[:])
		copy(state.shared_tags[:], shared[:])
		copy(state.graph_tags[:], graph[:])
		copy(state.odin_tags[:], odin[:])
		state.project_count = len(conv.note_project_assets)
		state.tag_count = len(conv.note_tag_assets)
		state.asset_count = len(conv.assets)
		state.note_index_count = len(conv.note_index_keys)
		state.note_btree_count = btree.count(&conv.note_index)
		state.asset_seq = td.asset_seq
		return state, true
	}

	note_paging_equivalence_states_equal :: proc(a, b: Note_Paging_Equivalence_State) -> bool {
		if a.asset_lens != b.asset_lens ||
		   a.keys != b.keys ||
		   a.key_present != b.key_present ||
		   a.btree_keys != b.btree_keys ||
		   a.alpha_projects != b.alpha_projects ||
		   a.beta_projects != b.beta_projects ||
		   a.shared_tags != b.shared_tags ||
		   a.graph_tags != b.graph_tags ||
		   a.odin_tags != b.odin_tags {
			return false
		}
		for i in 0 ..< NOTE_PAGING_EQ_COUNT do for j in 0 ..< a.asset_lens[i] do if a.asset_bytes[i][j] != b.asset_bytes[i][j] do return false
		return(
			a.alpha_count == b.alpha_count &&
			a.btree_key_count == b.btree_key_count &&
			a.beta_count == b.beta_count &&
			a.shared_count == b.shared_count &&
			a.graph_count == b.graph_count &&
			a.odin_count == b.odin_count &&
			a.project_count == b.project_count &&
			a.tag_count == b.tag_count &&
			a.asset_count == b.asset_count &&
			a.note_index_count == b.note_index_count &&
			a.note_btree_count == b.note_btree_count &&
			a.asset_seq == b.asset_seq \
		)
	}

	note_paging_equivalence_matches_scope :: proc(id: pr.AssetID, scope: Note_Paging_Equivalence_Scope, filter: string) -> bool {
		if id == 7 do return false
		switch scope {
		case .Global:
			return true
		case .Project:
			switch filter {case "alpha":
				return id == 1 || id == 2 || id == 6; case "beta":
				return id == 3 || id == 4}
		case .Tag:
			switch filter {case "shared":
				return id == 1 || id == 2 || id == 3 || id == 5; case "graph":
				return id == 3 || id == 4}
		}
		return false
	}

	note_paging_equivalence_model :: proc(conv: ^Conversation_State, req: Note_Paging_Equivalence_Request, out: []byte) -> int {
		storage: [NOTE_PAGING_EQ_COUNT]pr.Asset
		if req.asset_type != .Note && req.scope != .Global {
			return pr.serializeAssetListPageMessage(
				pr.AssetListPageMessage{conv_id = NOTE_PAGING_EQ_CONV, full_content = req.full_content, correlation_id = req.correlation_id},
				out,
			)
		}
		ordered := [7]pr.AssetID{7, 3, 2, 4, 5, 6, 1} // descending (updated_at, asset_id), including Document
		matching: [NOTE_PAGING_EQ_COUNT]pr.AssetID
		matching_count := 0
		for id in ordered {
			if conv.assets[id].asset_type != req.asset_type do continue
			if req.scope == .Global || note_paging_equivalence_matches_scope(id, req.scope, req.filter) {
				matching[matching_count] = id
				matching_count += 1
			}
		}
		start := 0
		if req.has_cursor {
			for start < matching_count {
				a := conv.assets[matching[start]]
				if a.updated_at < req.cursor_updated_at || (a.updated_at == req.cursor_updated_at && a.asset_id < req.cursor_asset_id) do break
				start += 1
			}
		}
		limit := int(req.limit)
		if limit == 0 do limit = int(DEFAULT_ASSET_PAGE_LIMIT)
		if limit > int(MAX_ASSET_PAGE_LIMIT) do limit = int(MAX_ASSET_PAGE_LIMIT)
		count := min(limit, matching_count - start)
		for i in 0 ..< count do storage[i] = conv.assets[matching[start + i]]^
		message := pr.AssetListPageMessage {
			conv_id        = NOTE_PAGING_EQ_CONV,
			assets         = storage[:count],
			full_content   = req.full_content,
			has_more       = matching_count - start > count,
			total_count    = u32(matching_count),
			correlation_id = req.correlation_id,
		}
		if count > 0 {
			message.next_cursor_updated_at = storage[count - 1].updated_at
			message.next_cursor_asset_id = storage[count - 1].asset_id
		}
		return pr.serializeAssetListPageMessage(message, out)
	}

	note_paging_equivalence_serialize_and_validate :: proc(req: Note_Paging_Equivalence_Request, buf: []byte) -> (int, bool) {
		switch req.scope {
		case .Global:
			n := pr.serializeListAssetsPagedRequest(
				NOTE_PAGING_EQ_CONV,
				req.asset_type,
				req.full_content,
				req.limit,
				req.has_cursor,
				req.cursor_updated_at,
				req.cursor_asset_id,
				buf,
				req.correlation_id,
			)
			if n <= 0 do return n, false
			p, e := pr.parseListAssetsPagedRequest(buf[2:n])
			return n,
				e == nil &&
				p.conv_id == NOTE_PAGING_EQ_CONV &&
				p.asset_type == req.asset_type &&
				p.full_content == req.full_content &&
				p.limit == req.limit &&
				p.has_cursor == req.has_cursor &&
				p.cursor_updated_at == req.cursor_updated_at &&
				p.cursor_asset_id == req.cursor_asset_id &&
				p.correlation_id == req.correlation_id
		case .Project:
			n := pr.serializeListAssetsPagedByProjectRequest(
				NOTE_PAGING_EQ_CONV,
				req.asset_type,
				req.full_content,
				req.limit,
				req.has_cursor,
				req.cursor_updated_at,
				req.cursor_asset_id,
				req.filter,
				buf,
				req.correlation_id,
			)
			if n <= 0 do return n, false
			p, e := pr.parseListAssetsPagedByProjectRequest(buf[2:n])
			return n,
				e == nil &&
				p.conv_id == NOTE_PAGING_EQ_CONV &&
				p.asset_type == req.asset_type &&
				p.full_content == req.full_content &&
				p.limit == req.limit &&
				p.has_cursor == req.has_cursor &&
				p.cursor_updated_at == req.cursor_updated_at &&
				p.cursor_asset_id == req.cursor_asset_id &&
				p.project == req.filter &&
				p.correlation_id == req.correlation_id
		case .Tag:
			n := pr.serializeListAssetsPagedByTagRequest(
				NOTE_PAGING_EQ_CONV,
				req.asset_type,
				req.full_content,
				req.limit,
				req.has_cursor,
				req.cursor_updated_at,
				req.cursor_asset_id,
				req.filter,
				buf,
				req.correlation_id,
			)
			if n <= 0 do return n, false
			p, e := pr.parseListAssetsPagedByTagRequest(buf[2:n])
			return n,
				e == nil &&
				p.conv_id == NOTE_PAGING_EQ_CONV &&
				p.asset_type == req.asset_type &&
				p.full_content == req.full_content &&
				p.limit == req.limit &&
				p.has_cursor == req.has_cursor &&
				p.cursor_updated_at == req.cursor_updated_at &&
				p.cursor_asset_id == req.cursor_asset_id &&
				p.tag == req.filter &&
				p.correlation_id == req.correlation_id
		}
		return -1, false
	}

	note_paging_equivalence_run :: proc(
		req: Note_Paging_Equivalence_Request,
		wire: bool,
		split_a, split_b: int,
	) -> (
		Note_Paging_Equivalence_Result,
		string,
		bool,
	) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, wire ? 181 : 180)
		defer simulation_test_end(&ctx)
		c := simulation_test_install_client(&ctx.sim, 1, "note-paging-equivalence", "reader")
		if c == nil do return {}, "install client", false
		ctx.conns[1] = c
		subscribe_to_conversation(c, NOTE_PAGING_EQ_CONV)
		conv := get_conversation(get_connection_workspace(c), NOTE_PAGING_EQ_CONV)
		if conv == nil || !note_paging_equivalence_setup(conv) do return {}, "install fixture", false
		td.asset_seq = 707
		before, ok := note_paging_equivalence_capture_state(conv)
		if !ok do return {}, "capture baseline", false
		nrc_sim_clear_inboxes(&ctx.sim)
		if wire {
			buf: [128]byte
			n, parser_ok := note_paging_equivalence_serialize_and_validate(req, buf[:])
			if !parser_ok do return {}, "production parser did not preserve request", false
			if !handler_equivalence_deliver_wire(&ctx.sim, c, buf[:n], split_a, split_b) do return {}, "deliver three wire chunks", false
		} else {
			switch req.scope {
			case .Global:
				handle_list_assets_paged(
					c,
					{
						conv_id = NOTE_PAGING_EQ_CONV,
						asset_type = req.asset_type,
						full_content = req.full_content,
						limit = req.limit,
						has_cursor = req.has_cursor,
						cursor_updated_at = req.cursor_updated_at,
						cursor_asset_id = req.cursor_asset_id,
						correlation_id = req.correlation_id,
					},
				)
			case .Project:
				handle_list_assets_paged_by_project(
					c,
					{
						conv_id = NOTE_PAGING_EQ_CONV,
						asset_type = req.asset_type,
						full_content = req.full_content,
						limit = req.limit,
						has_cursor = req.has_cursor,
						cursor_updated_at = req.cursor_updated_at,
						cursor_asset_id = req.cursor_asset_id,
						project = req.filter,
						correlation_id = req.correlation_id,
					},
				)
			case .Tag:
				handle_list_assets_paged_by_tag(
					c,
					{
						conv_id = NOTE_PAGING_EQ_CONV,
						asset_type = req.asset_type,
						full_content = req.full_content,
						limit = req.limit,
						has_cursor = req.has_cursor,
						cursor_updated_at = req.cursor_updated_at,
						cursor_asset_id = req.cursor_asset_id,
						tag = req.filter,
						correlation_id = req.correlation_id,
					},
				)
			}
		}
		result: Note_Paging_Equivalence_Result
		if nrc_sim_client_frame_count(&ctx.sim, c.sock) != 1 do return result, "response count", false
		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, c.sock, 0))
		if !payload_ok || len(payload) > len(result.response) do return result, "capture response", false
		copy(result.response[:], payload); result.response_len = len(payload)
		parsed, parse_err := pr.parseAssetListPageMessage(payload)
		defer if len(parsed.assets) > 0 do delete(parsed.assets)
		if parse_err != nil do return result, "parse response", false
		expected_buf: [4_096]byte
		expected_len := note_paging_equivalence_model(conv, req, expected_buf[:])
		if expected_len != len(payload) do return result, "model response length", false
		for value, i in payload do if value != expected_buf[i] do return result, "model response bytes", false
		after, after_ok := note_paging_equivalence_capture_state(conv)
		if !after_ok || !note_paging_equivalence_states_equal(before, after) do return result, "query mutated state/index/ID sequence", false
		return result, "", true
	}

	note_paging_equivalence_results_equal :: proc(a, b: Note_Paging_Equivalence_Result) -> bool {
		if a.response_len != b.response_len do return false
		for i in 0 ..< a.response_len do if a.response[i] != b.response[i] do return false
		return true
	}

	note_paging_limit_boundary_capture_state :: proc(conv: ^Conversation_State) -> (Note_Paging_Limit_Boundary_State, bool) {
		state: Note_Paging_Limit_Boundary_State
		if conv == nil do return state, false
		it := btree.iter(&conv.note_index)
		defer btree.iter_destroy(&it)
		for has_item := btree.iter_first(&it); has_item; has_item = btree.iter_next(&it) {
			if state.key_count >= len(state.keys) do return state, false
			state.keys[state.key_count] = btree.item(&it)
			state.key_count += 1
		}
		state.asset_count = len(conv.assets)
		state.index_count = len(conv.note_index_keys)
		state.asset_seq = td.asset_seq
		return state, true
	}

	note_paging_limit_boundary_run :: proc(limit: u16, wire: bool, split_a, split_b: int) -> (Note_Paging_Equivalence_Result, string, bool) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, wire ? 185 : 184)
		defer simulation_test_end(&ctx)
		c := simulation_test_install_client(&ctx.sim, 1, "note-paging-limit-boundary", "reader")
		if c == nil do return {}, "install Note limit-boundary client", false
		ctx.conns[1] = c
		conv := get_or_create_conversation(get_connection_workspace(c), NOTE_PAGING_EQ_CONV)
		for id in 1 ..= NOTE_PAGING_LIMIT_BOUNDARY_COUNT {
			asset := alloc_asset(nil, nil, nil)
			if asset == nil do return {}, "allocate Note limit-boundary fixture", false
			asset.asset_type = .Note
			asset.asset_id = pr.AssetID(id)
			asset.conv_id = NOTE_PAGING_EQ_CONV
			asset.created_at = i64(id)
			asset.updated_at = i64(id)
			conv.assets[asset.asset_id] = asset
			index_note_asset(conv, asset)
		}
		td.asset_seq = 808
		before, before_ok := note_paging_limit_boundary_capture_state(conv)
		if !before_ok do return {}, "capture Note limit-boundary baseline", false
		req := Note_Paging_Equivalence_Request {
			scope          = .Global,
			asset_type     = .Note,
			limit          = limit,
			correlation_id = limit == 0 ? 0x8300 : 0x8301,
		}
		nrc_sim_clear_inboxes(&ctx.sim)
		if wire {
			request_buf: [64]byte
			request_len, parser_ok := note_paging_equivalence_serialize_and_validate(req, request_buf[:])
			if !parser_ok do return {}, "validate Note limit-boundary request parser", false
			if !handler_equivalence_deliver_wire(&ctx.sim, c, request_buf[:request_len], split_a, split_b) {
				return {}, "deliver split Note limit-boundary request", false
			}
		} else {
			handle_list_assets_paged(c, {conv_id = NOTE_PAGING_EQ_CONV, asset_type = .Note, limit = limit, correlation_id = req.correlation_id})
		}
		result: Note_Paging_Equivalence_Result
		if nrc_sim_client_frame_count(&ctx.sim, c.sock) != 1 do return result, "Note limit-boundary response count", false
		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, c.sock, 0))
		if !payload_ok || len(payload) > len(result.response) do return result, "capture Note limit-boundary response", false
		copy(result.response[:], payload)
		result.response_len = len(payload)
		parsed, parse_err := pr.parseAssetListPageMessage(payload)
		defer if len(parsed.assets) > 0 do delete(parsed.assets)
		expected_count := limit == 0 ? int(DEFAULT_ASSET_PAGE_LIMIT) : int(MAX_ASSET_PAGE_LIMIT)
		expected_cursor_id := pr.AssetID(NOTE_PAGING_LIMIT_BOUNDARY_COUNT - expected_count + 1)
		if parse_err != nil ||
		   len(parsed.assets) != expected_count ||
		   !parsed.has_more ||
		   parsed.total_count != NOTE_PAGING_LIMIT_BOUNDARY_COUNT ||
		   parsed.next_cursor_updated_at != i64(expected_cursor_id) ||
		   parsed.next_cursor_asset_id != expected_cursor_id {
			return result, "Note default/clamped page boundary differs from model", false
		}
		expected_assets: [MAX_ASSET_PAGE_LIMIT]pr.Asset
		for i in 0 ..< expected_count {
			expected_assets[i] = conv.assets[pr.AssetID(NOTE_PAGING_LIMIT_BOUNDARY_COUNT - i)]^
		}
		expected_message := pr.AssetListPageMessage {
			conv_id                = NOTE_PAGING_EQ_CONV,
			assets                 = expected_assets[:expected_count],
			full_content           = false,
			has_more               = true,
			next_cursor_updated_at = i64(expected_cursor_id),
			next_cursor_asset_id   = expected_cursor_id,
			total_count            = NOTE_PAGING_LIMIT_BOUNDARY_COUNT,
			correlation_id         = req.correlation_id,
		}
		expected: [32_768]byte
		expected_len := pr.serializeAssetListPageMessage(expected_message, expected[:])
		if expected_len != len(payload) do return result, "Note limit-boundary model response length", false
		for value, i in payload do if value != expected[i] do return result, "Note limit-boundary model response bytes", false
		after, after_ok := note_paging_limit_boundary_capture_state(conv)
		if !after_ok || before != after do return result, "Note limit-boundary query mutated index or sequence", false
		return result, "", true
	}

	prop_note_paging_parser_direct_equivalence :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		scope, scope_err := hgl.draw_i64(
			tc,
			0,
			2,
		); if scope_err == .Stop_Test do return hgl.abort(); if scope_err != nil do return hgl.interesting("scope draw")
		flags, flags_err := hgl.draw_i64(
			tc,
			0,
			255,
		); if flags_err == .Stop_Test do return hgl.abort(); if flags_err != nil do return hgl.interesting("flags draw")
		limit_selector, limit_err := hgl.draw_i64(
			tc,
			0,
			2,
		); if limit_err == .Stop_Test do return hgl.abort(); if limit_err != nil do return hgl.interesting("limit draw")
		correlation, correlation_err := hgl.draw_i64(
			tc,
			0,
			i64(max(u32)),
		); if correlation_err == .Stop_Test do return hgl.abort(); if correlation_err != nil do return hgl.interesting("correlation draw")
		split_a, split_a_err := hgl.draw_i64(
			tc,
			0,
			4095,
		); if split_a_err == .Stop_Test do return hgl.abort(); if split_a_err != nil do return hgl.interesting("split draw")
		split_b, split_b_err := hgl.draw_i64(
			tc,
			0,
			4095,
		); if split_b_err == .Stop_Test do return hgl.abort(); if split_b_err != nil do return hgl.interesting("split draw")
		s := Note_Paging_Equivalence_Scope(scope)
		has_cursor := flags & 2 != 0
		filter :=
			s == .Project ? (flags & 4 == 0 ? "alpha" : (flags & 8 == 0 ? "beta" : "missing")) : (s == .Tag ? (flags & 4 == 0 ? "shared" : (flags & 8 == 0 ? "graph" : "")) : "")
		limits := [3]u16{0, 2, 400}
		req := Note_Paging_Equivalence_Request {
			scope             = s,
			filter            = filter,
			asset_type        = flags & 16 != 0 ? .Document : .Note,
			full_content      = flags & 1 != 0,
			limit             = limits[limit_selector],
			has_cursor        = has_cursor,
			cursor_updated_at = has_cursor ? 300 : 0,
			cursor_asset_id   = has_cursor ? 2 : 0,
			correlation_id    = u32(correlation),
		}
		d, direct_reason, direct_ok := note_paging_equivalence_run(req, false, 0, 0); if !direct_ok do return hgl.interesting(direct_reason)
		w, wire_reason, wire_ok := note_paging_equivalence_run(req, true, int(split_a), int(split_b)); if !wire_ok do return hgl.interesting(wire_reason)
		if !note_paging_equivalence_results_equal(d, w) do return hgl.interesting("direct/wire differ")
		return hgl.valid()
	}

	note_paging_equivalence_mandatory :: proc(t: ^testing.T) -> bool {
		cases := [?]Note_Paging_Equivalence_Request {
			{scope = .Global, asset_type = .Note, limit = 0, full_content = false, correlation_id = 8101},
			{
				scope = .Global,
				asset_type = .Note,
				limit = 2,
				full_content = true,
				has_cursor = true,
				cursor_updated_at = 300,
				cursor_asset_id = 3,
				correlation_id = 8102,
			},
			{scope = .Project, filter = "alpha", asset_type = .Note, limit = 400, full_content = true, correlation_id = 8103},
			{scope = .Project, filter = "missing", asset_type = .Note, limit = 2, correlation_id = 8104},
			{
				scope = .Tag,
				filter = "shared",
				asset_type = .Note,
				limit = 2,
				has_cursor = true,
				cursor_updated_at = 300,
				cursor_asset_id = 2,
				correlation_id = 8105,
			},
			{scope = .Tag, filter = "", asset_type = .Note, limit = 2, full_content = true, correlation_id = 8106},
			{scope = .Global, asset_type = .Document, limit = 2, full_content = true, correlation_id = 8107},
		}
		for req, i in cases {
			d, direct_reason, direct_ok := note_paging_equivalence_run(
				req,
				false,
				0,
				0,
			); testing.expectf(t, direct_ok, "mandatory direct %d: %s", i, direct_reason); if !direct_ok do return false
			w, wire_reason, wire_ok := note_paging_equivalence_run(
				req,
				true,
				i + 1,
				i + 19,
			); testing.expectf(t, wire_ok, "mandatory wire %d: %s", i, wire_reason); if !wire_ok do return false
			equal := note_paging_equivalence_results_equal(d, w); testing.expectf(t, equal, "mandatory direct/wire %d", i); if !equal do return false
		}
		boundary_limits := [2]u16{0, 400}
		for limit, i in boundary_limits {
			direct, direct_reason, direct_ok := note_paging_limit_boundary_run(limit, false, 0, 0)
			testing.expectf(t, direct_ok, "mandatory Note limit boundary direct case=%d failed: %s", i, direct_reason)
			if !direct_ok do return false
			wire, wire_reason, wire_ok := note_paging_limit_boundary_run(limit, true, i + 5, i + 31)
			testing.expectf(t, wire_ok, "mandatory Note limit boundary wire case=%d failed: %s", i, wire_reason)
			if !wire_ok do return false
			equal := note_paging_equivalence_results_equal(direct, wire)
			testing.expectf(t, equal, "mandatory Note limit boundary case=%d semantics should match", i)
			if !equal do return false
		}
		return true
	}
}

@(test)
test_hegel_note_paging_parser_direct_semantic_equivalence :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !note_paging_equivalence_mandatory(t) do return
		if !hgl.can_run() do return
		result, err := hgl.run(prop_note_paging_parser_direct_equivalence, nil, {test_cases = 48})
		testing.expectf(t, err == nil, "generated Note paging parser/direct equivalence failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}
