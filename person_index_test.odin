package main

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:testing"
import hgl "hegel"
import pr "protocol"

@(test)
test_people_facets_store_lifecycle :: proc(t: ^testing.T) {
	conv := calendar_test_conversation()
	defer destroy_conversation(conv)
	ws: Workspace_State
	put := proc(conv: ^Conversation_State, ws: ^Workspace_State, id: pr.AssetID, kind: pr.AssetType, preview: string) {
		asset := alloc_asset(transmute([]byte)string("organizer"), transmute([]byte)preview, nil)
		asset.asset_id = id; asset.asset_type = kind
		asset_store_put(ws, "test", conv, asset)
	}
	expect := proc(t: ^testing.T, conv: ^Conversation_State, op: pr.Opcode, want: []string) {
		got := collect_people(conv, op)
		defer delete(got)
		testing.expect_value(t, len(got), len(want))
		for name, i in got {
			if i < len(want) do testing.expect_value(t, name, want[i])
		}
	}
	expect(t, conv, .C_ListSliceOwners, nil)
	put(conv, &ws, 1, .Slice, `{"version":1,"name":"Open","owner":"zoe"}`)
	put(conv, &ws, 2, .Slice, `{"version":1,"name":"Closed","owner":"zoe","closed":true}`)
	put(conv, &ws, 3, .Slice, `{"version":1,"name":"Other","owner":"alice"}`)
	expect(t, conv, .C_ListSliceOwners, []string{"alice", "zoe"})
	asset_store_remove(&ws, conv, 1)
	expect(t, conv, .C_ListSliceOwners, []string{"alice", "zoe"})
	put(conv, &ws, 2, .Slice, `{"version":1,"name":"Renamed owner","owner":"bob"}`)
	expect(t, conv, .C_ListSliceOwners, []string{"alice", "bob"})
	put(conv, &ws, 2, .Document, `{}`)
	expect(t, conv, .C_ListSliceOwners, []string{"alice"})
	// Same person in multiple roles/overrides: removing one reference must
	// not remove another asset's membership. Invalid previews add no names.
	put(
		conv,
		&ws,
		4,
		.Appointment,
		`{"version":2,"title":"Series","start_at":"1792404000000000000","end_at":"","timezone":"UTC","repeat":"daily","weekdays":[],"until":"","assignee":"alice","participants":["alice","bob"],"conference":"none","exceptions":[{"at":"1792490400000000000","cancelled":false,"participants":["carol"]},{"at":"1792576800000000000","cancelled":true}]}`,
	)
	put(conv, &ws, 5, .Appointment, `{"version":1,"title":"Old","start_at":"10","assignee":"bob"}`)
	put(conv, &ws, 6, .Appointment, `{"version":1,"title":"Invalid","start_at":"0","assignee":"invalid"}`)
	task_store_put(conv, calendar_test_task(1, 0, .Done, "done-only"))
	task_store_put(conv, calendar_test_task(2, 0, .Todo, "alice"))
	expect(t, conv, .C_ListCalendarPeople, []string{"alice", "bob", "carol", "done-only", "organizer"})
	asset_store_remove(&ws, conv, 4)
	expect(t, conv, .C_ListCalendarPeople, []string{"alice", "bob", "done-only"})
	put(conv, &ws, 5, .Appointment, `{"version":1,"title":"Changed","start_at":"10","assignee":"zoe"}`)
	expect(t, conv, .C_ListCalendarPeople, []string{"alice", "done-only", "zoe"})
	asset_store_remove(&ws, conv, 5)
	task_store_remove(conv, 1)
	task_store_remove(conv, 2)
	expect(t, conv, .C_ListCalendarPeople, nil)
	// Include signed-ID boundaries when skipping an entire ticket range.
	for id in ([?]pr.AssetID{7, pr.AssetID(max(i64)), pr.AssetID(max(i64)) + 1}) {
		put(conv, &ws, id, .Ticket, `{"title":"Ticket","status":"closed","assignee":"bob"}`)
	}
	put(conv, &ws, 8, .Ticket, `{"title":"Unassigned","status":"open","assignee":""}`)
	put(conv, &ws, 9, .Ticket, `{"title":"Other","status":"resolved","assignee":"é"}`)
	expect(t, conv, .C_ListTicketAssignees, []string{"bob", "é"})
	asset_store_remove(&ws, conv, 7)
	expect(t, conv, .C_ListTicketAssignees, []string{"bob", "é"})
	asset_store_remove(&ws, conv, pr.AssetID(max(i64)))
	put(conv, &ws, pr.AssetID(max(i64)) + 1, .Ticket, `{"title":"Changed","status":"open","assignee":"alice"}`)
	expect(t, conv, .C_ListTicketAssignees, []string{"alice", "é"})
}

// Deliberately decode primary records rather than consulting the index or its
// production parsers. The generated records below are valid, except for the
// explicitly unsupported/unnamed slices, which the reference rejects itself.
people_test_reference_reason :: proc(conv: ^Conversation_State) -> string {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return "reference arena"
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	sets := [3]map[string]bool{make(map[string]bool, a), make(map[string]bool, a), make(map[string]bool, a)}
	for _, asset in conv.assets {
		m: struct {
			version:        int,
			name, assignee: string,
			participants:   []string,
			exceptions:     []struct {
				cancelled:    bool,
				participants: []string,
			},
		}
		if json.unmarshal(asset.preview, &m, allocator = a) != nil do return "reference JSON"
		#partial switch asset.asset_type {
		case .Slice:
			if m.version == 1 && len(m.name) > 0 && len(m.name) <= pr.MAX_PROJECT_LENGTH {
				owner: struct {
					owner: string,
				}
				if json.unmarshal(asset.preview, &owner, allocator = a) != nil do return "reference owner JSON"
				sets[0][owner.owner] = true
			}
		case .Ticket:
			sets[1][m.assignee] = true
		case .Appointment:
			sets[2][m.assignee] = true
			if m.version == 2 {
				sets[2][string(asset.owner)] = true
				for name in m.participants do sets[2][name] = true
				for ex in m.exceptions {
					if !ex.cancelled do for name in ex.participants do sets[2][name] = true
				}
			}
		case:
		}
	}
	for _, task in conv.tasks {
		if task.status != .Note do sets[2][string(task.assignee)] = true
	}
	ops := [?]pr.Opcode{.C_ListSliceOwners, .C_ListTicketAssignees, .C_ListCalendarPeople}
	reasons := [?]string {
		"slice owners differ from primary-map scan",
		"ticket assignees differ from primary-map scan",
		"calendar people differ from primary-map scan",
	}
	for op, i in ops {
		expected := make([dynamic]string, 0, len(sets[i]), a)
		for name in sets[i] do if name != "" do append(&expected, name)
		slice.sort_by(expected[:], proc(a, b: string) -> bool {return a < b})
		actual := collect_people(conv, op)
		defer delete(actual)
		if len(actual) != len(expected) do return reasons[i]
		for name, j in actual do if name != expected[j] do return reasons[i]
	}
	return ""
}

// One fixture vocabulary is shared with the transport/replay campaign. Its
// reference above interprets only stored fields, not this generation logic.
people_test_asset_preview :: proc(kind: int, first, second: string, flags: int) -> (typ: pr.AssetType, preview: string) {
	switch kind {
	case 1:
		return .Slice, fmt.aprintf(`{{"version":1,"name":"Slice","owner":"%s","closed":%s}}`, first, flags & 1 == 0 ? "false" : "true")
	case 2:
		return .Ticket, fmt.aprintf(
			`{{"version":1,"title":"Ticket","assignee":"%s","status":"%s","company_id":"","contact_id":"","requester":"","requester_name":""}}`,
			first,
			flags & 1 == 0 ? "open" : "closed",
		)
	case 3:
		return .Appointment, fmt.aprintf(`{{"version":1,"title":"Legacy","start_at":"100","assignee":"%s"}}`, first)
	case 4:
		// Roles may overlap across one record and across records. Override
		// membership alternates between replacement, inherited, and cancelled.
		exception :=
			flags % 3 == 0 ? `"cancelled":true` : flags % 3 == 1 ? `"cancelled":false` : fmt.aprintf(`"cancelled":false,"participants":["%s"]`, second)
		defer if flags % 3 == 2 do delete(exception)
		return .Appointment, fmt.aprintf(
			`{{"version":2,"title":"Series","start_at":"1792404000000000000","end_at":"","timezone":"UTC","repeat":"daily","weekdays":[],"until":"","assignee":"%s","participants":["%s"],"conference":"none","exceptions":[{{"at":"1792490400000000000",%s}}]}}`,
			first,
			first == "" ? second : first,
			exception,
		)
	case 5:
		return .Document, fmt.aprintf(`{{"assignee":"%s","owner":"%s"}}`, first, second)
	case:
		return .Slice, fmt.aprintf(`{{"version":%d,"name":"%s","owner":"%s"}}`, flags & 1 == 0 ? 2 : 1, flags & 1 == 0 ? "Unsupported" : "", first)
	}
}

prop_people_facets_stateful :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	conv := calendar_test_conversation()
	defer destroy_conversation(conv)
	ws: Workspace_State
	names := [?]string{"", "alice", "bob", "é"}
	limits := [5]i64{9, 5, 3, 3, 5}
	// Forty-eight commands over six IDs force reuse, duplicate memberships,
	// post-image replacement and final-reference deletion, not just random reads.
	for _ in 0 ..< 48 {
		choice: [5]int
		for &v, j in choice {
			n, err := hgl.draw_i64(tc, 0, limits[j])
			if err == .Stop_Test do return hgl.abort()
			if err != nil do return hgl.interesting("people command draw")
			v = int(n)
		}
		op, slot, first, second, flags := choice[0], choice[1], names[choice[2]], names[choice[3]], choice[4]
		id := pr.AssetID(slot + 1)
		switch op {
		case 0:
			asset_store_remove(&ws, conv, id)
		case 7:
			task_store_remove(conv, pr.TaskID(id))
		case 8:
			task_store_put(conv, calendar_test_task(pr.TaskID(id), 0, pr.TaskStatus(flags % 5), first))
		case 9:
			if old := conv.tasks[pr.TaskID(id)]; old != nil {
				post := old^; post.status = pr.TaskStatus(flags % 5)
				task_store_move(conv, &post)
			}
		case:
			typ, preview := people_test_asset_preview(op, first, second == "" ? "bob" : second, flags)
			asset := alloc_asset(transmute([]byte)second, transmute([]byte)preview, nil)
			delete(preview)
			asset.asset_id = id; asset.asset_type = typ
			asset_store_put(&ws, "people-model", conv, asset)
		}
		if reason := people_test_reference_reason(conv); reason != "" do return hgl.interesting(reason)
	}
	// Drain every reference, checking intermediate states as well as emptiness.
	for id in 1 ..= 6 {
		asset_store_remove(&ws, conv, pr.AssetID(id))
		task_store_remove(conv, pr.TaskID(id))
		if reason := people_test_reference_reason(conv); reason != "" do return hgl.interesting(reason)
	}
	return hgl.valid()
}

@(test)
test_hegel_people_facets_stateful :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	result, err := hgl.run(prop_people_facets_stateful, nil, {test_cases = 128})
	testing.expectf(t, err == nil, "people state machine: err=%v interesting=%v", err, result.interesting_test_cases)
}
