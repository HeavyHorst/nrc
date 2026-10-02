package main

import "core:testing"
import pr "protocol"

@(test)
test_asset_page_exact_byte_boundary :: proc(t: ^testing.T) {
	// Empty header-only assets serialize to 55 bytes each. A 38-byte page
	// header plus two records with these previews is exactly 131072 bytes.
	preview := make([]byte, 65462)
	defer delete(preview)
	assets := [?]pr.Asset{{asset_id = 91, updated_at = 7, preview = preview}, {asset_id = 72, updated_at = 6, preview = preview}}
	msg := pr.AssetListPageMessage {
		assets                 = assets[:],
		next_cursor_asset_id   = 72,
		next_cursor_updated_at = 6,
		total_count            = 2,
	}
	bound_asset_list_page(&msg)
	testing.expect_value(t, len(msg.assets), 2)
	testing.expect_value(t, pr.getSizeAssetListPageMessage(msg), 131072)
	testing.expect(t, !msg.has_more)
	// One additional byte must cut at the first asset, not leave the cursor
	// pointing at the omitted second asset or report an exhausted result.
	assets[1].owner = []byte{'x'}
	msg.assets = assets[:]
	bound_asset_list_page(&msg)
	testing.expect_value(t, len(msg.assets), 1)
	testing.expect(t, msg.has_more)
	testing.expect_value(t, msg.next_cursor_asset_id, pr.AssetID(91))
	testing.expect_value(t, msg.next_cursor_updated_at, i64(7))
	testing.expect_value(t, msg.total_count, u32(2))
}

@(test)
test_edge_page_byte_and_cursor_boundary :: proc(t: ^testing.T) {
	conv: Conversation_State
	conv.edges = make(map[pr.EdgeID]^pr.Edge)
	defer delete(conv.edges)
	creator := make([]byte, 65473)
	defer delete(creator)
	items := [?]pr.Edge{{edge_id = 17, created_by = creator}, {edge_id = 39, created_by = creator}}
	for &edge in items do conv.edges[edge.edge_id] = &edge
	edges := make([dynamic]pr.Edge)
	defer delete(edges)
	// 29 + 2*(48+65473) = 131071; one more creator byte fits, two do not.
	msg := collect_edge_page(&conv, {conv_id = 21, limit = 1000}, &edges)
	testing.expect_value(t, len(msg.edges), 2)
	testing.expect_value(t, pr.getSizeAllEdgeListPageMessage(msg), 131071)
	testing.expect(t, !msg.has_more)
	large_creator := make([]byte, 65475)
	defer delete(large_creator)
	items[1].created_by = large_creator
	clear(&edges)
	msg = collect_edge_page(&conv, {conv_id = 21, limit = 1000}, &edges)
	testing.expect_value(t, len(msg.edges), 1)
	testing.expect(t, msg.has_more)
	testing.expect_value(t, msg.next_edge_id, pr.EdgeID(17))
	clear(&edges)
	msg = collect_edge_page(&conv, {conv_id = 21, after_edge_id = 17}, &edges)
	testing.expect_value(t, len(msg.edges), 1)
	testing.expect_value(t, msg.edges[0].edge_id, pr.EdgeID(39))
	testing.expect_value(t, msg.total_count, u32(2))
	testing.expect(t, !msg.has_more)
	clear(&edges)
	msg = collect_edge_page(&conv, {conv_id = 21, after_edge_id = 39}, &edges)
	testing.expect_value(t, len(msg.edges), 0)
	testing.expect(t, !msg.has_more)
}

@(test)
test_simulation_customer_asset_paging_and_legacy_error :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 197)
		defer simulation_test_end(&ctx)
		c := simulation_test_install_client(&ctx.sim, 1, "customer-page", "alice")
		ctx.conns[1] = c
		if c == nil do return
		conv := get_or_create_conversation(c.workspace, 73)
		preview := make([]byte, 4096)
		defer delete(preview)
		body := make([]byte, 65535)
		defer delete(body)
		types := [?]pr.AssetType{.CustomerCompany, .CustomerContact, .CustomerActivity}
		for asset_type, type_index in types {
			for i in 1 ..< 36 {
				id := pr.AssetID(type_index * 100 + i)
				asset := asset_query_test_install_asset(conv, 73, id, asset_type, string(preview), string(body), i64(i % 2))
				testing.expect(t, asset != nil)
			}
		}
		// Both header and full-content requests must traverse every typed record.
		content_modes := [?]bool{false, true}
		for asset_type, type_index in types {
			for full_content in content_modes {
				req := pr.ListAssetsPagedRequest {
					conv_id        = 73,
					asset_type     = asset_type,
					limit          = 250,
					full_content   = full_content,
					correlation_id = 719,
				}
				seen := 0
				for page in 0 ..< 36 {
					nrc_sim_clear_inboxes(&ctx.sim)
					handle_list_assets_paged(c, req)
					wire, ok := asset_query_test_payload(t, &ctx.sim, c, .S_AssetListPage)
					if !ok do return
					testing.expect(t, len(wire) <= 131072)
					msg, err := pr.parseAssetListPageMessage(wire)
					testing.expect(t, err == nil)
					if err != nil do return
					if page == 0 do testing.expect_value(t, len(msg.assets), 1 if full_content else 31)
					testing.expect_value(t, msg.total_count, u32(35))
					testing.expect_value(t, msg.correlation_id, u32(719))
					for asset in msg.assets {
						expected_id := 35 - 2 * seen if seen < 18 else 34 - 2 * (seen - 18)
						testing.expect_value(t, asset.asset_id, pr.AssetID(type_index * 100 + expected_id))
						testing.expect_value(t, asset.asset_type, asset_type)
						testing.expect_value(t, len(asset.preview), 4096)
						testing.expect_value(t, len(asset.payload), 65535 if full_content else 0)
						seen += 1
					}
					req.has_cursor = true
					req.cursor_asset_id = msg.next_cursor_asset_id
					req.cursor_updated_at = msg.next_cursor_updated_at
					delete(msg.assets)
					if !msg.has_more do break
				}
				testing.expect_value(t, seen, 35)
			}
		}
		nrc_sim_clear_inboxes(&ctx.sim)
		handle_list_assets(c, {conv_id = 73, filter_by_type = true, asset_type = .CustomerCompany, correlation_id = 823})
		wire, ok := asset_query_test_payload(t, &ctx.sim, c, .S_ErrorResponse)
		if !ok do return
		msg, err := pr.parseErrorResponseMessage(wire)
		testing.expect(t, err == nil)
		testing.expect_value(t, msg.origin_opcode, pr.Opcode.C_ListAssets)
		testing.expect_value(t, msg.correlation_id, u32(823))
	}
}

@(test)
test_simulation_edge_paging_dispatch_and_legacy_errors :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 199)
		defer simulation_test_end(&ctx)
		c := simulation_test_install_client(&ctx.sim, 1, "edge-page", "alice")
		ctx.conns[1] = c
		if c == nil do return
		conv := get_or_create_conversation(c.workspace, pr.WORKSPACE_DATA_ID)
		for i in 1 ..< 2001 {
			edge := alloc_edge(transmute([]byte)string("01234567890123456789012345678901"))
			edge.edge_id = pr.EdgeID(i * 3)
			edge.conv_id = pr.WORKSPACE_DATA_ID
			edge.source_type = .Asset
			edge.source_id = 1
			edge.target_type = .Task
			edge.target_id = u64(i)
			edge.relation = .References
			conv.edges[edge.edge_id] = edge
			add_edge_to_adjacency(conv, .Asset, 1, edge.edge_id)
		}
		req := pr.ListAllEdgesPagedRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			limit          = 65535,
			correlation_id = 911,
		}
		seen := 0
		for page in 0 ..< 3 {
			nrc_sim_clear_inboxes(&ctx.sim)
			request: [24]byte
			written := pr.serializeListAllEdgesPagedRequest(req, request[:])
			testing.expect(t, handler_equivalence_deliver_wire(&ctx.sim, c, request[:written], 1, 9))
			wire, ok := asset_query_test_payload(t, &ctx.sim, c, .S_AllEdgeListPage)
			if !ok do return
			testing.expect(t, len(wire) <= 131072)
			storage: [1000]pr.Edge
			msg, err := pr.parseAllEdgeListPageMessage(wire, storage[:])
			testing.expect(t, err == nil)
			if err != nil do return
			testing.expect_value(t, len(msg.edges), 1000)
			testing.expect_value(t, msg.total_count, u32(2000))
			testing.expect_value(t, msg.correlation_id, u32(911))
			for edge in msg.edges {
				seen += 1
				testing.expect_value(t, edge.edge_id, pr.EdgeID(seen * 3))
			}
			req.after_edge_id = msg.next_edge_id
			if !msg.has_more do break
		}
		testing.expect_value(t, seen, 2000)
		legacy_opcodes := [?]pr.Opcode{.C_ListAllEdges, .C_ListEdges}
		for opcode in legacy_opcodes {
			nrc_sim_clear_inboxes(&ctx.sim)
			if opcode == .C_ListAllEdges do handle_list_all_edges(c, {conv_id = pr.WORKSPACE_DATA_ID, correlation_id = 977})
			else do handle_list_edges(c, {conv_id = pr.WORKSPACE_DATA_ID, target_type = .Asset, target_id = 1, correlation_id = 977})
			wire, ok := asset_query_test_payload(t, &ctx.sim, c, .S_ErrorResponse)
			if !ok do return
			msg, err := pr.parseErrorResponseMessage(wire)
			testing.expect(t, err == nil)
			testing.expect_value(t, msg.origin_opcode, opcode)
			testing.expect_value(t, msg.correlation_id, u32(977))
		}
	}
}
