package main

import "btree"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import pr "protocol"

// Own each distinct name once, independently of asset post-images and parser
// arenas. Counts remove a name only when its final reference disappears.
Person_Count :: struct {
	name:  string,
	count: int,
}

person_count_change :: proc(index: ^map[string]Person_Count, name: string, remove: bool) {
	if name == "" do return
	entry, exists := index^[name]
	if remove {
		assert(exists && entry.count > 0, "missing person index membership")
		if entry.count == 1 {
			delete_key(index, name)
			delete(entry.name)
		} else {
			entry.count -= 1
			state_map_set(index, entry.name, entry)
		}
		return
	}
	if !exists {
		owned, err := strings.clone(name)
		if err != nil do panic("failed to allocate person index name")
		entry.name = owned
	}
	entry.count += 1
	state_map_set(index, entry.name, entry)
}

destroy_person_counts :: proc(index: ^map[string]Person_Count) {
	for _, entry in index^ do delete(entry.name)
	delete(index^)
	index^ = nil
}

// Eager maintenance through the asset store also rebuilds these facets during
// replay. Do not tie it to the calendar's lazily initialized time indexes.
index_asset_people :: proc(conv: ^Conversation_State, asset: ^pr.Asset, remove := false) {
	if asset.asset_type != .Slice && asset.asset_type != .Appointment do return
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do panic("failed to allocate person index scratch")
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	if asset.asset_type == .Slice {
		m, valid := slice_preview(asset, a)
		if valid do person_count_change(&conv.slice_owners, m.owner, remove)
		return
	}
	r, valid := parse_appointment_preview(asset.preview, a)
	if !valid do return
	person_count_change(&conv.appointment_people, string(r.assignee), remove)
	if r.version != 2 do return
	person_count_change(&conv.appointment_people, string(asset.owner), remove)
	for person in r.participants do person_count_change(&conv.appointment_people, person, remove)
	for ex in r.exceptions {
		if ex.cancelled || !ex.has_participants do continue
		for person in ex.participants do person_count_change(&conv.appointment_people, person, remove)
	}
}

// Only index keys are read, never assets or paginated register results. Calendar
// candidates intentionally include Done/no-deadline task assignees, matching the
// task facet. Appointment names include non-cancelled occurrence overrides.
collect_people :: proc(conv: ^Conversation_State, opcode: pr.Opcode) -> (names: [dynamic]string) {
	if conv == nil do return
	#partial switch opcode {
	case .C_ListSliceOwners:
		for name in conv.slice_owners do append(&names, name)
	case .C_ListTicketAssignees:
		if conv.ticket_index == nil do return
		it := btree.iter(&conv.ticket_assignees)
		defer btree.iter_destroy(&it)
		for ok := btree.iter_first(&it); ok; {
			name := btree.item(&it).assignee
			if name != "" do append(&names, name)
			// Skip the whole assignee range in logarithmic time, rather than
			// visiting every ticket. The comparator orders IDs as signed i64.
			ok = btree.iter_seek(&it, Ticket_Assignee_Key{name, pr.AssetID(max(i64))})
			if ok && btree.item(&it).assignee == name do ok = btree.iter_next(&it)
		}
		return
	case .C_ListCalendarPeople:
		for name in conv.appointment_people do append(&names, name)
		for name in conv.task_assignee_indexes {
			if name != "" {
				if _, exists := conv.appointment_people[name]; !exists do append(&names, name)
			}
		}
	}
	slice.sort_by(names[:], proc(a, b: string) -> bool {return a < b})
	return
}

process_list_people :: proc(c: ^NRC_Connection, req: pr.ListTaskProjectsRequest, opcode: pr.Opcode) {
	names := collect_people(get_conversation(get_connection_workspace(c), req.conv_id), opcode)
	defer delete(names)
	response: pr.Opcode
	#partial switch opcode {
	case .C_ListSliceOwners:
		response = .S_SliceOwners
	case .C_ListTicketAssignees:
		response = .S_TicketAssignees
	case .C_ListCalendarPeople:
		response = .S_CalendarPeople
	}
	send_task_projects(c, req.conv_id, names[:], req.correlation_id, response)
}
