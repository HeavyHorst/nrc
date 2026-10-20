package main

import "btree"
import "core:encoding/json"
import "core:mem"
import "core:strings"
import pr "protocol"

Ticket_Assignee_Key :: struct {
	assignee: string,
	id:       pr.AssetID,
}

Ticket_Index_Row :: struct {
	metadata:  Ticket_Metadata, // owned decoded strings; never borrows the asset/request
	follow_up: i64,
	timestamp: i64,
	reply:     pr.AssetID,
	customers: [dynamic]pr.AssetID, // sorted live customer replies, for read-watermark rank
	dirty:     bool,
}

ticket_assignee_compare :: proc(a, b: Ticket_Assignee_Key) -> int {
	if a.assignee < b.assignee do return -1
	if a.assignee > b.assignee do return 1
	// Match the existing numeric ticket cursor's signed-ID ordering.
	if i64(a.id) < i64(b.id) do return -1
	if i64(a.id) > i64(b.id) do return 1
	return 0
}

ticket_metadata_destroy :: proc(m: ^Ticket_Metadata) {
	delete(m.title); delete(m.status); delete(m.assignee); delete(m.company_id)
	delete(m.contact_id); delete(m.requester); delete(m.requester_name)
	delete(m.priority); delete(m.follow_up_at)
	m^ = {}
}

ticket_metadata_read :: proc(data: []byte, m: ^Ticket_Metadata, allocator: mem.Allocator) -> bool {
	err := json.unmarshal(data, m, allocator = allocator)
	if e, ok := err.(json.Error); ok && e == .Out_Of_Memory do panic("failed to allocate ticket metadata")
	return err == nil
}

// Dynamic_Arena's tracking-array appends do not propagate OOM in this Odin
// release (including during destroy). Publication after WAL must fail-stop.
ticket_scratch_array_allocator :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	backing := (^mem.Allocator)(data)
	result, err := backing.procedure(backing.data, mode, size, alignment, old, old_size, loc)
	if err != nil && (mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed) do panic("failed to allocate ticket scratch bookkeeping")
	return result, err
}

// Decode in owned scratch storage: legacy previews may have duplicate extra
// fields, which the JSON decoder overwrites without releasing the earlier string.
// Clone only the final values, never publish scratch pointers into worker state.
ticket_metadata_owned :: proc(data: []byte) -> (m: Ticket_Metadata, valid: bool) {
	scratch: mem.Dynamic_Arena
	backing := context.allocator
	mem.dynamic_arena_init(
		&scratch,
		array_allocator = mem.Allocator{procedure = ticket_scratch_array_allocator, data = &backing},
		block_size = 4096,
		out_band_size = 4096,
	)
	defer mem.dynamic_arena_destroy(&scratch)
	valid = ticket_metadata_read(data, &m, mem.dynamic_arena_allocator(&scratch))
	if !valid do return {}, false
	for p in ([?]^string{&m.title, &m.status, &m.assignee, &m.company_id, &m.contact_id, &m.requester, &m.requester_name, &m.priority, &m.follow_up_at}) {
		owned, err := strings.clone(p^)
		if err != nil do panic("failed to allocate ticket metadata")
		p^ = owned
	}
	return
}

destroy_ticket_index :: proc(conv: ^Conversation_State) {
	if conv.ticket_index == nil do return
	btree.destroy(&conv.ticket_assignees)
	for _, row in conv.ticket_index {
		ticket_metadata_destroy(&row.metadata)
		delete(row.customers)
		free(row)
	}
	delete(conv.ticket_index)
	conv.ticket_index = nil
}

ticket_reply_bound :: proc(ids: []pr.AssetID, id: pr.AssetID) -> int {
	lo, hi := 0, len(ids)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if ids[mid] <= id {lo = mid + 1} else {hi = mid}
	}
	return lo
}

ticket_index_add_entry :: proc(row: ^Ticket_Index_Row, entry: ^pr.Asset) {
	row.timestamp = max(row.timestamp, entry.created_at)
	scratch: mem.Dynamic_Arena
	backing := context.allocator
	mem.dynamic_arena_init(
		&scratch,
		array_allocator = mem.Allocator{procedure = ticket_scratch_array_allocator, data = &backing},
		block_size = 4096,
		out_band_size = 4096,
	)
	defer mem.dynamic_arena_destroy(&scratch)
	// Reply activity only interprets kind; unrelated extension fields are ignored.
	m: struct {
		kind: string `json:"kind"`,
	}
	err := json.unmarshal(entry.preview, &m, allocator = mem.dynamic_arena_allocator(&scratch))
	if e, ok := err.(json.Error); ok && e == .Out_Of_Memory do panic("failed to allocate ticket entry metadata")
	if err != nil do return
	if m.kind == "public_reply" do row.reply = max(row.reply, entry.asset_id)
	if m.kind == "customer_reply" {
		at := ticket_reply_bound(row.customers[:], entry.asset_id)
		if at > 0 && row.customers[at - 1] == entry.asset_id do return
		if _, err := append(&row.customers, entry.asset_id); err != nil do panic("failed to grow ticket reply index")
		copy(row.customers[at + 1:], row.customers[at:len(row.customers) - 1])
		row.customers[at] = entry.asset_id
	}
}

// Only exceptional removals/reclassifications repair extrema. Ordinary append is
// incremental. Reuse the existing parent tree, including child-before-parent replay.
ticket_index_repair :: proc(conv: ^Conversation_State, id: pr.AssetID) {
	row := conv.ticket_index[id]
	if row == nil || !row.dirty do return
	asset := conv.assets[id]
	if asset == nil do return
	row.timestamp = asset.created_at
	row.reply = 0
	clear(&row.customers)
	it := btree.iter(&conv.asset_parents)
	defer btree.iter_destroy(&it)
	start := Entity_Reference_Key {
		kind      = u8(pr.ParentType.Asset),
		parent_id = u64(id),
	}
	for ok := btree.iter_seek(&it, start); ok; ok = btree.iter_next(&it) {
		key := btree.item(&it)
		if key.kind != start.kind || key.parent_id != start.parent_id do break
		entry := conv.assets[pr.AssetID(key.entity_id)]
		if entry != nil && entry.asset_type == .TicketEntry do ticket_index_add_entry(row, entry)
	}
	row.dirty = false
}

// Called while the old asset and its index keys are still alive. Repair must
// happen only AFTER the asset map and parent tree contain the post-image.
ticket_index_remove :: proc(conv: ^Conversation_State, asset: ^pr.Asset, keep_ticket := false) {
	if asset.asset_type == .Ticket {
		row := conv.ticket_index[asset.asset_id]
		if row == nil do return
		_, _ = btree.remove(&conv.ticket_assignees, Ticket_Assignee_Key{row.metadata.assignee, asset.asset_id})
		ticket_metadata_destroy(&row.metadata)
		if !keep_ticket {
			delete(row.customers); free(row); delete_key(&conv.ticket_index, asset.asset_id)
		}
	} else if asset.asset_type == .TicketEntry && asset.parent_type == .Asset {
		row := conv.ticket_index[pr.AssetID(asset.parent_id)]
		if row == nil do return
		at := ticket_reply_bound(row.customers[:], asset.asset_id)
		if at > 0 && row.customers[at - 1] == asset.asset_id {
			copy(row.customers[at - 1:], row.customers[at:])
			pop(&row.customers)
		}
		row.dirty = row.dirty || row.reply == asset.asset_id || row.timestamp == asset.created_at
	}
}

ticket_index_put :: proc(conv: ^Conversation_State, asset: ^pr.Asset) {
	if asset.asset_type == .Ticket {
		if conv.ticket_index == nil {
			conv.ticket_index = make(map[pr.AssetID]^Ticket_Index_Row)
			conv.ticket_assignees = btree.create(Ticket_Assignee_Key, ticket_assignee_compare, btree.Options{degree = 32})
		}
		row := conv.ticket_index[asset.asset_id]
		if row == nil {
			row = new(Ticket_Index_Row)
			if row == nil do panic("failed to allocate ticket index row")
			row.dirty = true
			state_map_set(&conv.ticket_index, asset.asset_id, row)
		}
		valid: bool
		row.metadata, valid = ticket_metadata_owned(asset.preview)
		if !valid {
			delete(row.customers); free(row); delete_key(&conv.ticket_index, asset.asset_id)
			return
		}
		row.follow_up, _ = ticket_follow_up_time(row.metadata.follow_up_at)
		row.timestamp = max(row.timestamp, asset.created_at)
		_, _ = btree.set(&conv.ticket_assignees, Ticket_Assignee_Key{row.metadata.assignee, asset.asset_id})
		ticket_index_repair(conv, asset.asset_id)
	} else if asset.asset_type == .TicketEntry && asset.parent_type == .Asset {
		row := conv.ticket_index[pr.AssetID(asset.parent_id)]
		if row != nil && !row.dirty do ticket_index_add_entry(row, asset)
		ticket_index_repair(conv, pr.AssetID(asset.parent_id))
	}
}

ticket_index_activity :: proc(
	row: ^Ticket_Index_Row,
	asset: ^pr.Asset,
	username: string,
	read: pr.AssetID,
	now_ms: i64,
) -> (
	activity: Ticket_Activity,
	latest: pr.AssetID,
) {
	latest = asset.asset_id
	if len(row.customers) > 0 do latest = max(latest, row.customers[len(row.customers) - 1])
	activity.unread = len(row.customers) - ticket_reply_bound(row.customers[:], read)
	if asset.asset_id > read && string(asset.owner) != username do activity.unread += 1
	status := row.metadata.status
	paused := latest == asset.asset_id && (status == "waiting_customer" || status == "resolved" || status == "closed")
	activity.waiting = row.reply <= latest && !paused
	activity.follow_up_due = row.follow_up > 0 && row.follow_up <= now_ms
	return
}
