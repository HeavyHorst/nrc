package main

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"

import "byte_pool"
import pr "protocol"

CUSTOMER_READ_DEFAULT_LIMIT :: 50
CUSTOMER_READ_MAX_LIMIT :: 250

Customer_Preview :: struct {
	version:      int,
	title:        string,
	archived:     bool,
	number:       string,
	sector:       string,
	account_type: string,
	city:         string,
	address:      string,
	website:      string,
	assignee:     string,
	role:         string,
	email:        string,
	phone:        string,
}

customer_preview :: proc(asset: ^pr.Asset, allocator := context.allocator) -> (m: Customer_Preview, ok: bool) {
	if asset == nil || json.unmarshal(asset.preview, &m, allocator = allocator) != nil do return
	ok = m.version == 1 && len(m.title) > 0
	return
}

customer_query_matches :: proc(asset: ^pr.Asset, m: Customer_Preview, query_lower: string, match_asset_id := true) -> bool {
	if len(query_lower) == 0 do return true
	searchable := fmt.aprint(
		m.title,
		" ",
		m.number,
		" ",
		m.sector,
		" ",
		m.account_type,
		" ",
		m.city,
		" ",
		m.address,
		" ",
		m.website,
		" ",
		m.assignee,
		" ",
		m.role,
		" ",
		m.email,
		" ",
		m.phone,
	)
	defer delete(searchable)
	preview_lower := strings.to_lower(searchable); defer delete(preview_lower)
	if strings.contains(preview_lower, query_lower) do return true
	if match_asset_id {
		id := fmt.aprint(asset.asset_id); defer delete(id)
		return strings.contains(id, query_lower)
	}
	return false
}

handle_list_edges_paged :: proc(c: ^NRC_Connection, req: pr.ListEdgesPagedRequest) {
	msg := pr.EdgeListPageMessage {
		conv_id        = req.conv_id,
		target_type    = req.target_type,
		target_id      = req.target_id,
		correlation_id = req.correlation_id,
	}
	ws := get_connection_workspace(c)
	conv: ^Conversation_State
	if ws != nil do conv = get_conversation(ws, req.conv_id)
	edges := make([dynamic]pr.Edge, 0, CUSTOMER_READ_MAX_LIMIT); defer delete(edges)
	if conv != nil {
		key := Edge_Entity_Key {
			target_type = req.target_type,
			target_id   = req.target_id,
		}
		if edge_ids, ok := conv.edges_by_entity[key]; ok {
			ids := make([dynamic]pr.EdgeID, 0, len(edge_ids)); defer delete(ids)
			for id in edge_ids {if conv.edges[id] != nil {msg.total_count += 1; if id > req.after_edge_id do append(&ids, id)}}
			slice.sort(ids[:])
			limit := min(CUSTOMER_READ_MAX_LIMIT, int(req.limit)); if limit == 0 do limit = CUSTOMER_READ_DEFAULT_LIMIT
			size := pr.getSizeEdgeListPageMessage(msg)
			for id in ids {
				edge := conv.edges[id]
				if len(edges) == limit || size + pr.getSizeEdge(edge^) > MAX_PROTOCOL_PAYLOAD_SIZE {msg.has_more = true; break}
				append(&edges, edge^); size += pr.getSizeEdge(edge^); msg.next_edge_id = id
			}
		}
	}
	msg.edges = edges[:]
	if msg.has_more && len(edges) == 0 {send_error_response(c, .C_ListEdgesPaged, "Edge exceeds page byte limit", req.correlation_id); return}
	buf, h := allocate_websocket_frame_buffer(pr.getSizeEdgeListPageMessage(msg), "incident edge page"); if buf == nil do return
	n := pr.serializeEdgeListPageMessage(msg, buf[h:]); if n < 0 {byte_pool.release(td.spool, buf); return}; _ = send_pooled_buffer(c, buf[:h + n])
}

handle_search_customers :: proc(c: ^NRC_Connection, req: pr.SearchCustomersRequest) {
	msg := pr.CustomerSearchPageMessage {
		conv_id        = req.conv_id,
		correlation_id = req.correlation_id,
	}
	ws := get_connection_workspace(c)
	conv: ^Conversation_State
	if ws != nil do conv = get_conversation(ws, req.conv_id)
	results := make([dynamic]pr.Asset, 0, CUSTOMER_READ_MAX_LIMIT); defer delete(results)
	if conv != nil {
		// Reuse JSON scratch storage across records; do not reserve virtual memory
		// or parse a company's preview twice for every search candidate.
		arena: virtual.Arena
		if virtual.arena_init_growing(&arena) != nil {send_error_response(c, .C_SearchCustomers, "Search allocation failed", req.correlation_id); return}
		defer virtual.arena_destroy(&arena)
		query_lower := strings.to_lower(string(req.query)); defer delete(query_lower)
		matched := make(map[pr.AssetID]bool); defer delete(matched)
		valid_companies := make(map[pr.AssetID]bool); defer delete(valid_companies)
		for id, asset in conv.assets {
			if asset.asset_type != .CustomerCompany do continue
			virtual.arena_free_all(&arena)
			metadata, valid := customer_preview(asset, virtual.arena_allocator(&arena))
			if valid &&
			   (req.include_archived ||
					   !metadata.archived) {valid_companies[id] = true; if customer_query_matches(asset, metadata, query_lower) do matched[id] = true}
		}
		if len(query_lower) > 0 {
			for contact_id, contact in conv.assets {
				if contact.asset_type != .CustomerContact do continue
				virtual.arena_free_all(&arena)
				metadata, valid := customer_preview(contact, virtual.arena_allocator(&arena))
				if !valid || !customer_query_matches(contact, metadata, query_lower, false) do continue
				key := Edge_Entity_Key {
					target_type = .Asset,
					target_id   = u64(contact_id),
				}
				edge_ids, has_edges := conv.edges_by_entity[key]
				if !has_edges do continue
				for edge_id in edge_ids {
					edge := conv.edges[edge_id]
					if edge == nil || edge.relation != .MemberOf || edge.source_type != .Asset || edge.target_type != .Asset do continue
					other := pr.AssetID(edge.source_id); if other == contact_id do other = pr.AssetID(edge.target_id)
					if valid_companies[other] do matched[other] = true
				}
			}
		}
		ids := make([dynamic]pr.AssetID, 0, len(matched)); defer delete(ids)
		for id in matched {msg.total_count += 1; if id > req.after_company_id do append(&ids, id)}
		slice.sort(ids[:])
		limit := min(CUSTOMER_READ_MAX_LIMIT, int(req.limit)); if limit == 0 do limit = CUSTOMER_READ_DEFAULT_LIMIT
		size := pr.getSizeCustomerSearchPageMessage(msg)
		for id in ids {
			asset := conv.assets[id]
			if len(results) == limit || size + pr.getSizeAssetHeader(asset^) > MAX_PROTOCOL_PAYLOAD_SIZE {msg.has_more = true; break}
			append(&results, asset^); size += pr.getSizeAssetHeader(asset^); msg.next_company_id = id
		}
	}
	msg.assets = results[:]
	if msg.has_more && len(results) == 0 {send_error_response(c, .C_SearchCustomers, "Company exceeds page byte limit", req.correlation_id); return}
	buf, h := allocate_websocket_frame_buffer(pr.getSizeCustomerSearchPageMessage(msg), "customer search page"); if buf == nil do return
	n := pr.serializeCustomerSearchPageMessage(msg, buf[h:]); if n < 0 {byte_pool.release(td.spool, buf); return}; _ = send_pooled_buffer(c, buf[:h + n])
}
