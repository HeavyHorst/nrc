package main

import "core:encoding/endian"
import "core:fmt"
import "core:testing"

import hgl "hegel"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: endian.get_u16
	_ :: fmt.aprint
	_ :: hgl.run
	_ :: pr.Opcode
}

when NRC_SIMULATION {
	customer_read_test_payload :: proc(t: ^testing.T, ctx: ^Sim_Test_Context, c: ^NRC_Connection, opcode: pr.Opcode) -> ([]byte, bool) {
		testing.expect(t, simulation_test_commit_shards(&ctx.sim))
		if !testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, c.sock), 1) do return nil, false
		payload, ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, c.sock, 0))
		testing.expect(t, ok)
		if ok do testing.expect_value(t, pr.get_opcode(payload), opcode)
		return payload, ok
	}

	customer_read_test_asset :: proc(conv: ^Conversation_State, conv_id: pr.ConversationID, id: pr.AssetID, kind: pr.AssetType, preview: string) {
		asset := asset_query_test_install_asset(conv, conv_id, id, kind, preview, "", 1)
		assert(asset != nil)
	}

	customer_read_test_edge :: proc(
		conv: ^Conversation_State,
		conv_id: pr.ConversationID,
		id: pr.EdgeID,
		source, target: u64,
		relation := pr.RelationType.MemberOf,
	) {
		edge := alloc_edge(transmute([]byte)string("reader")); assert(edge != nil)
		edge^ = {
			edge_id     = id,
			conv_id     = conv_id,
			source_type = .Asset,
			source_id   = source,
			target_type = .Asset,
			target_id   = target,
			relation    = relation,
			created_by  = edge.created_by,
		}
		conv.edges[id] = edge
		add_edge_to_adjacency(conv, .Asset, source, id); add_edge_to_adjacency(conv, .Asset, target, id)
	}

	customer_read_test_company_ids :: proc(t: ^testing.T, payload: []byte) -> (ids: [dynamic]pr.AssetID, more: bool, next: pr.AssetID, total: u32) {
		if len(payload) < 29 do return
		more = payload[10] == 1
		v64, _ := endian.get_u64(payload[11:], .Big); next = pr.AssetID(v64)
		total, _ = endian.get_u32(payload[19:], .Big)
		count, _ := endian.get_u16(payload[23:], .Big)
		offset := 29
		for _ in 0 ..< int(count) {
			asset, next_offset, err := pr.parseAssetHeaderFromPayload(payload, offset, false)
			testing.expect(t, err == nil)
			if err != nil do return
			// Asset headers retain the zero attachment_count field even though the
			// header parser intentionally leaves attachment decoding to its caller.
			append(&ids, asset.asset_id); offset = next_offset + 2
		}
		testing.expect_value(t, offset, len(payload))
		return
	}

	prop_customer_membership_search :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 214)
		defer simulation_test_end(&ctx)
		c := simulation_test_install_client(&ctx.sim, 1, "generated-customer-search", "reader")
		if c == nil do return hgl.interesting("customer client installation failed")
		ctx.conns[1] = c
		conv := get_or_create_conversation(c.workspace, pr.WORKSPACE_DATA_ID)
		// These reads are exercised through the shared stores, including edge
		// replacement/removal. WAL recovery is covered by the shard model and E2E.
		for index in 0 ..< 6 {
			id := pr.AssetID((index + 1) * 10)
			kind := pr.AssetType.CustomerCompany
			preview := `{"version":1,"title":"Company"}`
			if index == 3 do preview = `{"version":1,"title":"Company","archived":true}`
			if index >= 4 {
				kind = .CustomerContact
				preview = `{"version":1,"title":"Person","email":"person@example.test"}`
			}
			asset := alloc_asset(nil, transmute([]byte)preview, nil)
			if asset == nil do return hgl.interesting("customer asset allocation failed")
			asset.asset_id = id
			asset.conv_id = pr.WORKSPACE_DATA_ID
			asset.asset_type = kind
			asset_store_put(c.workspace, "generated-customer-search", conv, asset)
		}
		// Two contacts per company. 0 = absent, 1 = membership, 2 = unrelated.
		// The expected company set is calculated from this array, never adjacency.
		states: [8]u8
		prefix := [?][2]u8{{0, 1}, {1, 1}, {2, 1}, {6, 1}, {0, 0}, {1, 2}, {2, 0}}
		for step in 0 ..< len(prefix) + 16 {
			slot, state, reverse: u64
			if step < len(prefix) {
				slot, state, reverse = u64(prefix[step][0]), u64(prefix[step][1]), u64(step % 2)
			} else {
				choice, err := hgl.draw_u64(tc, 0, 47)
				if err == .Stop_Test do return hgl.abort()
				if err != nil do return hgl.interesting("customer membership choice failed")
				slot, state, reverse = choice % 8, (choice / 8) % 3, choice / 24
			}
			edge_id := pr.EdgeID(slot + 1)
			if state == 0 {
				edge_store_remove(conv, edge_id)
			} else {
				edge := alloc_edge(nil)
				if edge == nil do return hgl.interesting("customer edge allocation failed")
				edge.edge_id = edge_id
				edge.conv_id = pr.WORKSPACE_DATA_ID
				edge.source_type, edge.target_type = .Asset, .Asset
				edge.source_id = 50 + (slot % 2) * 10
				edge.target_id = (slot / 2 + 1) * 10
				if reverse != 0 do edge.source_id, edge.target_id = edge.target_id, edge.source_id
				edge.relation = state == 1 ? .MemberOf : .RelatedTo
				edge_store_put(conv, edge)
			}
			states[slot] = u8(state)
			for archived in 0 ..< 2 {
				expected: [4]pr.AssetID
				count := 0
				for company in 0 ..< 4 {
					if company == 3 && archived == 0 do continue
					if states[company * 2] == 1 || states[company * 2 + 1] == 1 {
						expected[count] = pr.AssetID((company + 1) * 10)
						count += 1
					}
				}
				req := pr.SearchCustomersRequest {
					conv_id          = pr.WORKSPACE_DATA_ID,
					limit            = u16(1 + step % 2),
					include_archived = archived == 1,
					query            = transmute([]byte)string("PERSON@EXAMPLE.TEST"),
					correlation_id   = 700 + u32(step),
				}
				consumed := 0
				for page_index in 0 ..< 5 {
					nrc_sim_clear_inboxes(&ctx.sim)
					handle_search_customers(c, req)
					if !simulation_test_commit_shards(&ctx.sim) || nrc_sim_client_frame_count(&ctx.sim, c.sock) != 1 {
						return hgl.interesting("customer page delivery failed")
					}
					wire, ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, c.sock, 0))
					if !ok || len(wire) < 29 || pr.get_opcode(wire) != .S_CustomerSearchPage do return hgl.interesting("invalid customer page frame")
					next, _ := endian.get_u64(wire[11:], .Big)
					total, _ := endian.get_u32(wire[19:], .Big)
					rows, _ := endian.get_u16(wire[23:], .Big)
					correlation, _ := endian.get_u32(wire[25:], .Big)
					page_count := min(count - consumed, int(req.limit))
					if int(rows) != page_count ||
					   total != u32(count) ||
					   (wire[10] == 1) != (consumed + page_count < count) ||
					   correlation != req.correlation_id {
						return hgl.interesting("customer paging counters differ from membership model")
					}
					offset := 29
					for row in 0 ..< page_count {
						asset, end, err := pr.parseAssetHeaderFromPayload(wire, offset, false)
						if err != nil || asset.asset_id != expected[consumed + row] || asset.asset_type != .CustomerCompany {
							return hgl.interesting("customer result differs from membership model")
						}
						offset = end + 2 // zero attachment count in an asset header
					}
					if offset != len(wire) do return hgl.interesting("unexpected customer page bytes")
					if page_count == 0 {
						if next != 0 do return hgl.interesting("empty customer page cursor")
						break
					}
					consumed += page_count
					if next != u64(expected[consumed - 1]) do return hgl.interesting("customer page cursor differs from model")
					req.after_company_id = pr.AssetID(next)
				}
				if consumed != count do return hgl.interesting("customer page walk did not finish")
			}
		}
		return hgl.valid()
	}
}

@(test)
test_hegel_customer_membership_search_matches_model :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		if !hgl.can_run() do return
		result, err := hgl.run(prop_customer_membership_search, nil, {test_cases = 32})
		testing.expectf(t, err == nil, "customer membership property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_simulation_customer_search_decodes_filters_deduplicates_and_pages :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		ctx: Sim_Test_Context; simulation_test_begin(&ctx, 211); defer simulation_test_end(&ctx)
		c := simulation_test_install_client(&ctx.sim, 1, "customer-reader", "alice"); ctx.conns[1] = c; if c == nil do return
		conv := get_or_create_conversation(c.workspace, 91)
		customer_read_test_asset(conv, 91, 10, .CustomerCompany, "{\"version\":1,\"title\":\"Alpha\",\"padding\":\"accepted\"}")
		customer_read_test_asset(conv, 91, 20, .CustomerCompany, "{\"version\":1,\"title\":\"Archived\",\"archived\":true}")
		customer_read_test_asset(conv, 91, 30, .CustomerCompany, "{\"version\":1,\"title\":\"Gamma\"}")
		customer_read_test_asset(conv, 91, 40, .CustomerCompany, "{\"version\":1,\"title\":\"Unrelated\"}")
		customer_read_test_asset(conv, 91, 60, .CustomerCompany, "{\"version\":1,\"title\":\"Quote \\\"Works\\\"\"}")
		customer_read_test_asset(conv, 91, 70, .CustomerCompany, "{\"version\":1,\"title\":\"partial")
		customer_read_test_asset(conv, 91, 100, .CustomerContact, "{\"version\":1,\"title\":\"Person\",\"email\":\"SALES\\u0040EXAMPLE.COM\"}")
		// Matching contacts can legitimately have no adjacency entry, including
		// after their final company relationship has been deleted.
		customer_read_test_asset(conv, 91, 101, .CustomerContact, "{\"version\":1,\"title\":\"Unlinked\",\"email\":\"sales@example.com\"}")
		customer_read_test_edge(conv, 91, 1, 10, 100)
		customer_read_test_edge(conv, 91, 2, 100, 30)
		customer_read_test_edge(conv, 91, 3, 30, 100)
		customer_read_test_edge(conv, 91, 4, 100, 40, .References)
		other_conv := get_or_create_conversation(c.workspace, 190)
		customer_read_test_edge(other_conv, 190, 5, 100, 40)

		req := pr.SearchCustomersRequest {
			conv_id        = 91,
			limit          = 1,
			query          = transmute([]byte)string("sales@example.com"),
			correlation_id = 71,
		}
		handle_search_customers(c, req)
		wire, ok := customer_read_test_payload(t, &ctx, c, .S_CustomerSearchPage); if !ok do return
		ids, more, next, total := customer_read_test_company_ids(t, wire); defer delete(ids)
		testing.expect(
			t,
			more,
		); testing.expect_value(t, total, u32(2)); testing.expect_value(t, len(ids), 1); if len(ids) == 1 do testing.expect_value(t, ids[0], pr.AssetID(10)); testing.expect_value(t, next, pr.AssetID(10))

		nrc_sim_clear_inboxes(&ctx.sim); req.after_company_id = next; handle_search_customers(c, req)
		wire, ok = customer_read_test_payload(t, &ctx, c, .S_CustomerSearchPage); if !ok do return
		ids2, more2, next2, total2 := customer_read_test_company_ids(t, wire); defer delete(ids2)
		testing.expect(
			t,
			!more2,
		); testing.expect_value(t, total2, u32(2)); testing.expect_value(t, len(ids2), 1); if len(ids2) == 1 do testing.expect_value(t, ids2[0], pr.AssetID(30)); testing.expect_value(t, next2, pr.AssetID(30))

		nrc_sim_clear_inboxes(&ctx.sim); req = {
			conv_id = 91,
			query   = transmute([]byte)string("quote \"works\""),
		}; handle_search_customers(c, req)
		wire, ok = customer_read_test_payload(t, &ctx, c, .S_CustomerSearchPage); if !ok do return
		quoted, _, _, quoted_total := customer_read_test_company_ids(t, wire); defer delete(quoted)
		testing.expect_value(
			t,
			quoted_total,
			u32(1),
		); testing.expect_value(t, len(quoted), 1); if len(quoted) == 1 do testing.expect_value(t, quoted[0], pr.AssetID(60))
	}
}

@(test)
test_simulation_customer_search_byte_bound_accepts_large_unknown_padding :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		ctx: Sim_Test_Context; simulation_test_begin(&ctx, 212); defer simulation_test_end(&ctx)
		c := simulation_test_install_client(&ctx.sim, 1, "customer-padding", "alice"); ctx.conns[1] = c; if c == nil do return
		conv := get_or_create_conversation(c.workspace, 92)
		padding := make([]byte, 3800); defer delete(padding); for &b in padding do b = 'x'
		for i in 1 ..= 40 {
			preview := fmt.aprint("{\"version\":1,\"title\":\"Company ", i, "\",\"padding\":\"", string(padding), "\"}"); defer delete(preview)
			customer_read_test_asset(conv, 92, pr.AssetID(i * 7), .CustomerCompany, preview)
		}
		handle_search_customers(c, {conv_id = 92, limit = 250})
		wire, ok := customer_read_test_payload(t, &ctx, c, .S_CustomerSearchPage); if !ok do return
		ids, more, next, total := customer_read_test_company_ids(t, wire); defer delete(ids)
		testing.expect(t, len(wire) <= MAX_PROTOCOL_PAYLOAD_SIZE && more && len(ids) > 0 && len(ids) < 40)
		testing.expect_value(t, total, u32(40)); testing.expect_value(t, next, ids[len(ids) - 1])
	}
}

@(test)
test_simulation_incident_edge_pages_preserve_limits_and_directions :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		ctx: Sim_Test_Context; simulation_test_begin(&ctx, 213); defer simulation_test_end(&ctx)
		c := simulation_test_install_client(&ctx.sim, 1, "incident-reader", "alice"); ctx.conns[1] = c; if c == nil do return
		conv := get_or_create_conversation(c.workspace, 93)
		customer_read_test_edge(
			conv,
			93,
			5,
			77,
			1,
		); customer_read_test_edge(conv, 93, 19, 2, 77); customer_read_test_edge(conv, 93, 41, 77, 3); customer_read_test_edge(conv, 93, 88, 4, 5)
		req := pr.ListEdgesPagedRequest {
			conv_id        = 93,
			target_type    = .Asset,
			target_id      = 77,
			limit          = 1,
			correlation_id = 81,
		}
		expected := [?]pr.EdgeID{5, 19, 41}
		for wanted, page in expected {
			nrc_sim_clear_inboxes(&ctx.sim); handle_list_edges_paged(c, req)
			wire, ok := customer_read_test_payload(t, &ctx, c, .S_EdgeListPage); if !ok do return
			total, _ := endian.get_u32(
				wire[29:],
				.Big,
			); count, _ := endian.get_u16(wire[33:], .Big); edge_id, _ := endian.get_u64(wire[39:], .Big); cursor, _ := endian.get_u64(wire[21:], .Big)
			testing.expect_value(
				t,
				total,
				u32(3),
			); testing.expect_value(t, count, u16(1)); testing.expect_value(t, pr.EdgeID(edge_id), wanted); testing.expect_value(t, pr.EdgeID(cursor), wanted)
			testing.expect_value(t, wire[20] == 1, page < 2)
			req.after_edge_id = wanted
		}
	}
}
