package main

import "base:runtime"
import "core:c"
import "core:encoding/endian"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

import hgl "hegel"
import pr "protocol"
import sql "sqlite"
import ws "websocket"
import db "workspace_db"

// Test-only instrumentation separates page selection from the deliberately
// register-wide totals. VM work, unlike wall time, detects the excluded scan.
foreign import slice_test_sqlite "system:sqlite3"
foreign slice_test_sqlite {
	@(link_name = "sqlite3_trace_v2")
	slice_test_trace :: proc "c" (db: ^sql.Database, mask: c.uint, callback: proc "c" (_: c.uint, _: rawptr, _: rawptr, _: rawptr) -> c.int, data: rawptr) -> c.int ---
	@(link_name = "sqlite3_sql")
	slice_test_sql :: proc "c" (statement: ^sql.Statement) -> cstring ---
	@(link_name = "sqlite3_stmt_status")
	slice_test_status :: proc "c" (statement: ^sql.Statement, operation, reset: c.int) -> c.int ---
}

@(test)
test_slice_preview_wire_compatibility_hegel :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	result, err := hgl.run(
	proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		arena: virtual.Arena
		if virtual.arena_init_growing(&arena) != nil do return hgl.interesting("arena")
		defer virtual.arena_destroy(&arena)
		context.allocator = virtual.arena_allocator(&arena)
		fragments := [?]struct {
			encoded, decoded: string,
			valid:            bool,
		} {
			{`\"`, `"`, true},
			{`\\`, `\`, true},
			{`\/`, `/`, true},
			{`\n`, "\n", true},
			{`\u00e9`, "é", true},
			{`\uD83D\uDE80`, "🚀", true},
			{"e\u0301", "e\u0301", true},
			{`\'`, "", false},
			{`\x41`, "", false},
			{`\u01x0`, "", false},
			{`\u123`, "", false},
		}
		index, a := hgl.draw_i64(tc, 0, len(fragments) - 1)
		number, b := hgl.draw_i64(tc, 0, 8)
		delta, c := hgl.draw_i64(tc, -3, 3)
		if a == .Stop_Test || b == .Stop_Test || c == .Stop_Test do return hgl.abort()
		if a != nil || b != nil || c != nil do return hgl.interesting("draw")
		f := fragments[index]
		numbers := [9]string{"-9223372036854775808", "9223372036854775807", "0", "null", "1.0", "1e0", "01", "1.", "9223372036854775808"}
		// Escaped key spelling exercises key decoding; the identical nested
		// name may legitimately contain a floating point number.
		head :: `{"version":2,"name":"Slice","group_id":"1","extra":{"closed_at":1.5},"closed_\u0061t":`
		mid :: `,"outcome":"`
		tail :: `"}`
		padding := strings.repeat("x", pr.MAX_PREVIEW_LENGTH + int(delta) - len(head) - len(mid) - len(tail) - len(numbers[number]) - len(f.encoded))
		grouped := strings.concatenate({head, numbers[number], mid, padding, f.encoded, tail})
		m, group, valid := decode_slice_preview(slice_test_bytes(grouped), context.allocator)
		if valid != (f.valid && number <= 3) do return hgl.interesting("v2 accepts only JSON escapes and int64 timestamps")
		if valid {
			expected := strings.concatenate({`{"version":1,"name":"Slice","closed_\u0061t":`, numbers[number], mid, padding, f.encoded, tail})
			legacy := rewrite_slice_preview(slice_test_bytes(grouped), "")
			decoded, _, legacy_valid := decode_slice_preview(legacy, context.allocator)
			expected_outcome := strings.concatenate({padding, f.decoded})
			if !legacy_valid || group != "1" || m.outcome != expected_outcome || decoded.outcome != expected_outcome || string(legacy) != expected do return hgl.interesting("legacy downgrade preserves the encoded value and removes group")
			if delta <= 0 && len(legacy) > pr.MAX_PREVIEW_LENGTH do return hgl.interesting("legacy downgrade must fit on the wire")
		}
		return hgl.valid()
	},
	nil,
	{test_cases = 180},
	)
	testing.expectf(t, err == nil && result.passed, "Slice preview wire compatibility: %v", err)
}

@(test)
test_slice_groups_dissolve_without_deleting_slices :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-slice-groups-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/shard.sqlite3", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	command :: proc(t: ^testing.T, store: ^db.Store, wire: []byte, opcode: pr.Opcode, output: ^db.Command_Output) -> bool {
		if !testing.expect_value(t, db.begin(store), sql.OK) do return false
		request := db.Request {
			workspace = "groups",
			actor     = "alice",
			opcode    = pr.get_opcode(wire),
			timestamp = 42,
			body      = wire[2:],
		}
		if !testing.expect_value(t, sqlite_execute_task_command(store, &request, output), sql.OK) {db.rollback(store); return false}
		if !testing.expect_value(t, db.commit(store), sql.OK) do return false
		if !testing.expect(t, output.count > 0) do return false
		if pr.get_opcode(output.frames[0].payload) == .S_ErrorResponse && opcode != .S_ErrorResponse {
			response, _ := pr.parseErrorResponseMessage(output.frames[0].payload)
			testing.expect(t, false, string(response.error_msg))
		}
		return testing.expect_value(t, pr.get_opcode(output.frames[0].payload), opcode)
	}
	wire: [pr.MAX_PREVIEW_LENGTH + 128]byte
	unicode_outcome := strings.repeat("e\u0301", 600); defer delete(unicode_outcome)
	grouped := strings.concatenate({`{"name":"One","group_id":"1","outcome":"`, unicode_outcome, `","version":2}`}); defer delete(grouped)
	legacy := strings.concatenate(
		{`{version:1,name:'Renamed by old client',closed_at:1.,group_id:{nested:[{a:1,a:2}]},group_id:'999',outcome:'`, unicode_outcome, `'}`},
	); defer delete(legacy)
	prefix :: `{"version":1,"name":"After dissolve","outcome":"`
	large := strings.repeat("e\u0301", (pr.MAX_PREVIEW_LENGTH - len(prefix) - 2) / 3); defer delete(large)
	ungrouped := strings.concatenate({prefix, large, `"}`}); defer delete(ungrouped)
	for step in 0 ..< 10 {
		output := db.Command_Output {
			limit = 16384,
		}; defer db.destroy_command_output(&output)
		n: int
		want := pr.Opcode.S_AssetCreated
		switch step {
		case 0:
			n = pr.serializeCreateAssetRequest({asset_type = .SliceGroup, preview = slice_test_bytes("Core")}, wire[:])
		case 1:
			n = pr.serializeCreateAssetRequest({asset_type = .Slice, preview = slice_test_bytes(grouped)}, wire[:])
		case 2:
			n = pr.serializeCreateAssetRequest({asset_type = .Note, parent_type = .Asset, parent_id = 1, preview = slice_test_bytes("Cannot attach")}, wire[:])
			want = .S_ErrorResponse
		case 3:
			n = pr.serializeUpdateAssetRequest({asset_id = 2, preview = slice_test_bytes(legacy)}, wire[:]); want = .S_AssetUpdated
		case 4, 6:
			n = pr.serializeListTaskSlicesRequest({limit = 1, has_group = true, include_groups = true, group_id = step == 4 ? 1 : 0}, wire[:])
			want = .S_TaskSliceList
		case 5:
			patch: [256]byte
			delete_body: [32]byte
			for raw_len in ([2]u32{0, 1}) {
				patch_n := pr.serializeTransactionAssetPatch(
					{asset = {.Existing, .Asset, 1}, present = pr.TRANSACTION_ASSET_PATCH_PAYLOAD, payload_encoding = .Zstd, payload_raw_len = raw_len},
					patch[:],
				)
				testing.expect_value(t, sqlite_command_model_apply(&store, "groups", 43, {{.AssetPatch, patch[:patch_n]}}, nil, 0), "")
			}
			create_n := pr.serializeTransactionAssetCreate(
				{asset_type = .Slice, preview = slice_test_bytes(`{"version":2,"name":"Rejected","group_id":"1"}`)},
				patch[:],
			)
			delete_n := pr.serializeTransactionDelete({entity = {.Existing, .Asset, 1}}, delete_body[:], .Asset)
			testing.expect_value(
				t,
				sqlite_command_model_apply(&store, "groups", 43, {{.AssetDelete, delete_body[:delete_n]}, {.AssetCreate, patch[:create_n]}}, nil, 1),
				"",
			)
			patch_n := pr.serializeTransactionAssetPatch(
				{
					asset = {.Existing, .Asset, 2},
					present = pr.TRANSACTION_ASSET_PATCH_PAYLOAD,
					payload = slice_test_bytes("unchanged group"),
					payload_raw_len = 15,
				},
				patch[:],
			)
			testing.expect_value(
				t,
				sqlite_command_model_apply(&store, "groups", 43, {{.AssetPatch, patch[:patch_n]}, {.AssetDelete, delete_body[:delete_n]}}, {2, 1}),
				"",
			)
			continue
		case 7:
			for invalid in ([6]string{`{"version":2,"name":"Bad ID","group_id":"01"}`, `{"version":2,"name":"Bad number","closed_at":1.}`, `{"version":2,"name":"Bad number","closed_at":01}`, `{"version":2,"name":"Bad number","closed_at":1.0}`, `{"version":2,"name":"O\'Brien"}`, `{"version":2,"name":"path\uZZZZrest"}`}) {
				rejected := db.Command_Output {
					limit = 4096,
				}; defer db.destroy_command_output(&rejected)
				n = pr.serializeUpdateAssetRequest({asset_id = 2, preview = slice_test_bytes(invalid)}, wire[:])
				if !command(t, &store, wire[:n], .S_ErrorResponse, &rejected) do return
			}
			continue
		case 8:
			n = pr.serializeCreateAssetRequest(
				{asset_type = .Slice, preview = slice_test_bytes(`{"version":1,"name":"Legacy","group_id":{"duplicate":1,"duplicate":2},"group_id":"1"}`)},
				wire[:],
			)
		case 9:
			n = pr.serializeUpdateAssetRequest({asset_id = 2, preview = slice_test_bytes(ungrouped)}, wire[:]); want = .S_AssetUpdated
		}
		if !command(t, &store, wire[:n], want, &output) do return
		if step == 1 || step == 3 || step == 6 || step == 9 {
			for current in ([2]bool{false, true}) {
				read := db.Command_Output {
					limit = 8192,
				}; defer db.destroy_command_output(&read)
				asset: pr.Asset
				if current {
					n = pr.serializeGetRecordsByIDsRequest({ids = {2}, full_content = true, correlation_id = 71}, wire[:], .C_GetAssetsByIDs)
					if !command(t, &store, wire[:n], .S_AssetListPage, &read) do return
					page, parse_err := pr.parseAssetListPageMessage(read.frames[0].payload); defer delete(page.assets)
					if !testing.expect_value(t, parse_err, nil) || !testing.expect_value(t, len(page.assets), 1) do return
					testing.expect_value(t, page.correlation_id, u32(71))
					asset = page.assets[0]
				} else {
					n = pr.serializeGetAssetRequest(0, 2, wire[:], 71)
					if !command(t, &store, wire[:n], .S_AssetFull, &read) do return
					response, parse_err := pr.parseAssetFullMessage(read.frames[0].payload)
					if !testing.expect_value(t, parse_err, nil) do return
					testing.expect_value(t, response.correlation_id, u32(71))
					asset = response.asset
				}
				preview, group, valid := slice_preview(&asset, context.temp_allocator)
				testing.expect(t, valid)
				testing.expect_value(t, preview.version, current && step < 6 ? 2 : 1)
				testing.expect_value(t, preview.name, step == 1 ? "One" : step >= 6 ? "After dissolve" : "Renamed by old client")
				testing.expect(t, preview.outcome == (step >= 6 ? large : unicode_outcome))
				testing.expect_value(t, group, current && step < 6 ? "1" : "")
				if step == 3 {
					// Compare independently specified strict JSON, not just the Odin decoder.
					prefix := current ? `{"version":2,"name":"Renamed by old client","outcome":"` : `{"version":1,"name":"Renamed by old client","outcome":"`
					suffix := current ? `","closed_at":1,"group_id":"1"}` : `","closed_at":1}`
					expected := strings.concatenate({prefix, unicode_outcome, suffix}); defer delete(expected)
					testing.expect(t, string(asset.preview) == expected)
				}
				if !current do testing.expect(t, !strings.contains(string(asset.preview), "group_id"))
			}
		}
		if step == 6 || step == 8 {
			for id in ([3]u64{2, 3, 4}) {
				if (id == 4) != (step == 8) do continue
				n = pr.serializeTransactionAssetPatch(
					{
						asset = {.Existing, .Asset, id},
						present = pr.TRANSACTION_ASSET_PATCH_PAYLOAD,
						payload = slice_test_bytes("still editable"),
						payload_raw_len = 14,
					},
					wire[:],
				)
				testing.expect_value(t, sqlite_command_model_apply(&store, "groups", 44, {{.AssetPatch, wire[:n]}}, {id}), "")
			}
			if step == 6 {
				read := db.Command_Output {
					limit = 8192,
				}; defer db.destroy_command_output(&read)
				n = pr.serializeGetRecordsByIDsRequest({ids = {3}, full_content = true}, wire[:], .C_GetAssetsByIDs)
				if !command(t, &store, wire[:n], .S_AssetListPage, &read) do return
				page, err := pr.parseAssetListPageMessage(read.frames[0].payload); defer delete(page.assets)
				if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(page.assets), 1) do return
				testing.expect_value(t, string(page.assets[0].payload), "still editable")
				testing.expect_value(t, string(page.assets[0].preview), grouped)
			}
		}
		if want == .S_TaskSliceList {
			page, parse_err := pr.parseTaskSliceList(output.frames[0].payload); defer delete(page.slices)
			if !testing.expect_value(t, parse_err, nil) || !testing.expect_value(t, len(page.slices), 1) do return
			testing.expect_value(t, page.slices[0].slice_id, u64(2))
			testing.expect_value(t, page.slices[0].group_id, step == 4 ? u64(1) : 0)
			testing.expect_value(t, string(page.slices[0].name), step == 4 ? "Renamed by old client" : "After dissolve")
		}
		if step == 4 {
			// Valid v1 JSON5 fits on the wire; escaping its literal quotes cannot.
			quotes := strings.repeat(`"`, 2048); defer delete(quotes)
			raw := strings.concatenate({`{version:1,name:'Quoted',outcome:'`, quotes, `'}`}); defer delete(raw)
			quoted := db.Command_Output {
				limit = 16384,
			}; defer db.destroy_command_output(&quoted)
			n = pr.serializeUpdateAssetRequest({asset_id = 2, preview = slice_test_bytes(raw)}, wire[:])
			if !command(t, &store, wire[:n], .S_AssetUpdated, &quoted) do return
			response, quote_err := pr.parseAssetUpdatedMessage(quoted.frames[0].payload)
			if !testing.expect_value(t, quote_err, nil) do return
			testing.expect_value(t, string(response.asset.preview), raw)
			// The record fits as v1, but adding even a one-digit group does not.
			edit := db.Command_Output {
				limit = 16384,
			}; defer db.destroy_command_output(&edit)
			n = pr.serializeUpdateAssetRequest({asset_id = 2, preview = slice_test_bytes(ungrouped)}, wire[:])
			if !command(t, &store, wire[:n], .S_AssetUpdated, &edit) do return
			testing.expect_value(t, sqlite_rebuild_projections(&store), sql.OK)
			listing := db.Command_Output {
				limit = 8192,
			}; defer db.destroy_command_output(&listing)
			n = pr.serializeListTaskSlicesRequest({limit = 1, has_group = true, include_groups = true, group_id = 1}, wire[:])
			if !command(t, &store, wire[:n], .S_TaskSliceList, &listing) do return
			page, parse_err := pr.parseTaskSliceList(listing.frames[0].payload); defer delete(page.slices)
			if !testing.expect_value(t, parse_err, nil) || !testing.expect_value(t, len(page.slices), 1) do return
			testing.expect_value(t, page.slices[0].group_id, u64(1))
			testing.expect_value(t, string(page.slices[0].name), "After dissolve")
			// A second Slice still embeds the group when the group is dissolved.
			embedded := db.Command_Output {
				limit = 8192,
			}; defer db.destroy_command_output(&embedded)
			n = pr.serializeCreateAssetRequest({asset_type = .Slice, preview = slice_test_bytes(grouped)}, wire[:])
			if !command(t, &store, wire[:n], .S_AssetCreated, &embedded) do return
		}
	}
}

@(test)
test_slice_page_skips_closed_index_range :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "nrc-slice-page-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer {os.remove_all(dir); delete(dir)}
	name := fmt.aprintf("%s/shard.sqlite3", dir); defer delete(name)
	path := strings.clone_to_cstring(name); defer delete(path)
	store, rc := db.open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	for id in 1 ..= 10000 {
		asset := slice_test_slice_asset(u64(id), `{"version":1,"name":"Closed","closed":true}`)
		testing.expect_value(t, sqlite_put_asset(&store, "w", &asset), sql.OK)
	}
	testing.expect_value(t, db.commit(&store), sql.OK)
	work: [4]int // Page statements, page VM steps, grouped count and name VM steps.
	testing.expect_value(
		t,
		slice_test_trace(
			store.db,
			2,
			proc "c" (_: c.uint, data, statement, _: rawptr) -> c.int {
				context = runtime.default_context()
				s := (^sql.Statement)(statement)
				query := string(slice_test_sql(s))
				work := (^[4]int)(data)
				if strings.has_prefix(query, "WITH page AS MATERIALIZED") {
					work[0] += 1
					work[1] += int(slice_test_status(s, 4, 0)) // SQLITE_STMTSTATUS_VM_STEP
				} else if strings.has_prefix(query, "SELECT\n coalesce(sum") && strings.contains(query, "m.group_id=?10") {
					work[2] += int(slice_test_status(s, 4, 0))
				} else if strings.has_prefix(query, "SELECT m.asset_id,m.name,m.owner,m.closed,m.sort_at") && strings.contains(query, "m.group_id=?6") {
					work[3] += int(slice_test_status(s, 4, 0))
				}
				return 0
			},
			&work,
		),
		sql.OK,
	)
	defer slice_test_trace(store.db, 0, nil, nil)
	for with_open in ([2]bool{false, true}) {
		if with_open {
			asset := slice_test_slice_asset(10001, `{"version":1,"name":"Open"}`, 10)
			testing.expect_value(t, db.begin(&store), sql.OK)
			testing.expect_value(t, sqlite_put_asset(&store, "w", &asset), sql.OK)
			testing.expect_value(t, db.commit(&store), sql.OK)
		}
		for has_owner in ([2]bool{false, true}) {
			for cursor in 0 ..< 3 {
				req := pr.ListTaskSlicesRequest {
					limit           = 1,
					has_owner       = has_owner,
					has_cursor      = cursor != 0,
					cursor_closed   = cursor == 2,
					cursor_sort_at  = 10,
					cursor_slice_id = 10001,
				}
				buffer: [1024]byte
				n := pr.serializeListTaskSlicesRequest(req, buffer[:])
				request := db.Request {
					workspace = "w",
					opcode    = .C_ListTaskSlices,
					body      = buffer[2:n],
				}
				output := db.Command_Output {
					limit = 4096,
				}; defer db.destroy_command_output(&output)
				work = {}
				testing.expect_value(t, db.begin(&store), sql.OK)
				testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), sql.OK)
				testing.expect_value(t, db.rollback(&store), sql.OK)
				testing.expect_value(t, work[0], 1)
				testing.expect(t, work[1] < 1000, fmt.tprintf("page selection executed %d VM steps", work[1]))
				want := pr.TaskSliceList {
					success     = true,
					total_count = with_open ? 1 : 0,
				}
				if with_open && cursor == 0 {
					want.slices = {pr.TaskSlice{slice_id = 10001, name = slice_test_bytes("Open")}}
					want.next_cursor_slice_id = 10001; want.next_cursor_sort_at = 10
				}
				encoded: [4096]byte
				written := pr.serializeTaskSliceList(want, encoded[:])
				if testing.expect_value(t, output.count, 1) do testing.expect_value(t, string(output.frames[0].payload), string(encoded[:written]))
			}
		}
	}
	// A rare project must not probe every unrelated slice, even when closed
	// records are eligible. Include continuation and a completely absent project.
	testing.expect_value(t, db.begin(&store), sql.OK)
	group := pr.Asset {
		asset_id   = 10002,
		asset_type = .SliceGroup,
		preview    = slice_test_bytes("Rare"),
	}
	testing.expect_value(t, sqlite_put_asset(&store, "w", &group), sql.OK)
	for id in ([2]u64{10000, 10001}) {
		asset := slice_test_slice_asset(
			id,
			id == 10000 ? `{"version":2,"name":"Closed","closed":true,"group_id":"10002"}` : `{"version":2,"name":"Open","group_id":"10002"}`,
		)
		testing.expect_value(t, sqlite_put_asset(&store, "w", &asset), sql.OK)
	}
	task := pr.Task {
		id      = 20000,
		status  = .Todo,
		project = slice_test_bytes("rare"),
	}
	testing.expect_value(t, db.put_task(&store, "w", &task), sql.OK)
	edge := pr.Asset {
		asset_id = 20000,
	}
	testing.expect_value(t, sqlite_projection_write(&store, "INSERT INTO edges VALUES(?1,?2,2,?2,1,?3,7,0,x'')", "w", &edge, {u64(10000)}), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	for mode in 0 ..< 5 {
		req := pr.ListTaskSlicesRequest {
			limit          = 1,
			include_closed = true,
			has_group      = true,
			include_groups = true,
			group_id       = 10002,
		}
		if mode == 1 {req.has_cursor = true; req.cursor_sort_at = 10; req.cursor_slice_id = 10001}
		if mode == 2 do req.project = slice_test_bytes("rare")
		if mode == 3 {req.has_name = true; req.name = slice_test_bytes("los")}
		if mode == 4 {req.has_owner = true; req.include_closed = false}
		buffer: [1024]byte
		n := pr.serializeListTaskSlicesRequest(req, buffer[:])
		request := db.Request {
			workspace = "w",
			opcode    = .C_ListTaskSlices,
			body      = buffer[2:n],
		}
		output := db.Command_Output {
			limit = 4096,
		}; defer db.destroy_command_output(&output)
		work = {}
		testing.expect_value(t, db.begin(&store), sql.OK)
		testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), sql.OK)
		testing.expect_value(t, db.rollback(&store), sql.OK)
		if mode == 3 {
			testing.expect(t, work[3] > 0 && work[3] < 1000, fmt.tprintf("group name candidates: %d VM steps", work[3]))
		} else {
			testing.expect_value(t, work[0], 1)
			testing.expect(t, work[1] < 1000 && work[2] > 0 && work[2] < 1000, fmt.tprintf("group page: %d VM steps, count: %d VM steps", work[1], work[2]))
		}
		if !testing.expect_value(t, output.count, 1) do return
		page, err := pr.parseTaskSliceList(output.frames[0].payload); defer delete(page.slices)
		if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(page.slices), 1) do return
		testing.expect_value(t, page.total_count, mode < 2 ? u32(2) : 1)
		testing.expect_value(t, page.has_more, mode == 0)
		testing.expect_value(t, page.slices[0].slice_id, mode == 0 || mode == 4 ? u64(10001) : 10000)
		testing.expect_value(t, page.slices[0].group_id, u64(10002))
	}
	for project in ([2]string{"rare", "absent"}) {
		for cursor in ([2]bool{false, true}) {
			req := pr.ListTaskSlicesRequest {
				limit           = 1,
				include_closed  = true,
				project         = slice_test_bytes(project),
				has_cursor      = cursor,
				cursor_closed   = true,
				cursor_slice_id = 10000,
			}
			buffer: [1024]byte
			n := pr.serializeListTaskSlicesRequest(req, buffer[:])
			request := db.Request {
				workspace = "w",
				opcode    = .C_ListTaskSlices,
				body      = buffer[2:n],
			}
			output := db.Command_Output {
				limit = 4096,
			}; defer db.destroy_command_output(&output)
			work = {}
			testing.expect_value(t, db.begin(&store), sql.OK)
			testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), sql.OK)
			testing.expect_value(t, db.rollback(&store), sql.OK)
			testing.expect_value(t, work[0], 1)
			testing.expect(t, work[1] < 1000, fmt.tprintf("project page executed %d VM steps", work[1]))
			want := pr.TaskSliceList {
				success     = true,
				total_count = project == "rare" ? 1 : 0,
			}
			if project == "rare" && !cursor {
				want.slices = {pr.TaskSlice{slice_id = 10000, name = slice_test_bytes("Closed"), flags = pr.TaskSliceFlag_CLOSED, todo = 1}}
				want.next_cursor_closed = true; want.next_cursor_slice_id = 10000
			}
			encoded: [4096]byte
			written := pr.serializeTaskSliceList(want, encoded[:])
			if testing.expect_value(t, output.count, 1) do testing.expect_value(t, string(output.frames[0].payload), string(encoded[:written]))
		}
		// Missing summaries inside/outside the project are errors, unless the
		// damaged slice is excluded by owner or closure. Roll back each probe.
		for scope in 0 ..< 4 {
			req := pr.ListTaskSlicesRequest {
				limit          = 1,
				include_closed = scope != 3,
				has_owner      = scope == 2,
				project        = slice_test_bytes(project),
			}
			buffer: [1024]byte
			n := pr.serializeListTaskSlicesRequest(req, buffer[:])
			request := db.Request {
				workspace = "w",
				opcode    = .C_ListTaskSlices,
				body      = buffer[2:n],
			}
			output := db.Command_Output {
				limit = 4096,
			}; defer db.destroy_command_output(&output)
			testing.expect_value(t, db.begin(&store), sql.OK)
			key := pr.Asset {
				asset_id = scope == 1 ? 10000 : 1,
			}
			if scope == 2 {
				testing.expect_value(
					t,
					sqlite_projection_write(&store, "UPDATE slice_metadata SET owner=x'6f74686572' WHERE workspace=?1 AND asset_id=?2", "w", &key, nil),
					sql.OK,
				)
			}
			testing.expect_value(t, sqlite_projection_write(&store, "DELETE FROM slice_summaries WHERE workspace=?1 AND slice_id=?2", "w", &key, nil), sql.OK)
			testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), scope < 2 ? sql.CORRUPT : sql.OK)
			if scope < 2 {
				testing.expect_value(t, output.count, 0)
			} else {
				want := pr.TaskSliceList {
					success = true,
				}
				if scope == 2 && project == "rare" {
					want.total_count = 1
					want.slices = {pr.TaskSlice{slice_id = 10000, name = slice_test_bytes("Closed"), flags = pr.TaskSliceFlag_CLOSED, todo = 1}}
					want.next_cursor_closed = true; want.next_cursor_slice_id = 10000
				}
				encoded: [4096]byte
				written := pr.serializeTaskSliceList(want, encoded[:])
				if testing.expect_value(t, output.count, 1) do testing.expect_value(t, string(output.frames[0].payload), string(encoded[:written]))
			}
			testing.expect_value(t, db.rollback(&store), sql.OK)
		}
	}
}

worker_db_test_slice_expect :: proc(t: ^testing.T, c: ^NRC_Connection, req: pr.ListTaskSlicesRequest, want: pr.TaskSliceList) {
	buffer: [1024]byte
	n := pr.serializeListTaskSlicesRequest(req, buffer[:]); assert(n > 0)
	process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
	if !testing.expect_value(t, send_queue_len(c), 1) do return
	item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
	frame := frame_lease_data(item.lease); _, offset, _ := ws.readFrameHeader(frame)
	expected := want; expected.correlation_id = req.correlation_id
	encoded: [4096]byte
	written := pr.serializeTaskSliceList(expected, encoded[:]); assert(written > 0)
	testing.expect_value(t, string(frame[offset:]), string(encoded[:written]))
}

worker_db_test_slices :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	store, rc := db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM edges; DELETE FROM assets; DELETE FROM tasks", nil, nil, nil), sql.OK)
	tasks := [?]pr.Task {
		{id = 1, status = .Todo, blocked_by = 2, project = slice_test_bytes("srv"), created_at = 10, updated_at = 30},
		{id = 2, status = .Done, created_at = 5, updated_at = 40},
		{id = 3, status = .InProgress, created_at = 20, updated_at = 50},
		{id = 4, status = .Backlog},
		{id = 5, status = .Note},
	}
	for &task in tasks do testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.OK)
	assets := [?]pr.Asset {
		slice_test_slice_asset(71, `{"version":1,"name":"Änderung","owner":"alice"}`),
		slice_test_slice_asset(72, `{"version":1,"name":"Closed","closed":true}`, 100),
		slice_test_slice_asset(max(u64), `{"version":1,"name":"Empty"}`, 60),
		slice_test_slice_asset(74, `{"version":1}`), // Invalid projections stay absent.
		{asset_id = 1, asset_type = .Note, preview = slice_test_bytes(`{"project":"NRC"}`), updated_at = 60},
		{asset_id = 2, asset_type = .File, updated_at = 55},
		{asset_id = 3, asset_type = .ReviewForm, preview = slice_test_bytes(`{"title":"Review","archived":true}`)},
		{asset_id = 4, asset_type = .ReviewAnswer, preview = slice_test_bytes(`{"title":"Review","run_id":"1"}`)},
	}
	for &asset in assets do testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &asset), sql.OK)
	testing.expect_value(t, sqlite_put_asset(&store, "foreign-slices", &assets[0]), sql.OK)
	edges := [?]pr.Edge {
		{source_type = .Task, source_id = 1, target_type = .Asset, target_id = 71},
		{source_type = .Asset, source_id = 71, target_type = .Task, target_id = 2},
		{source_type = .Task, source_id = 2, target_type = .Asset, target_id = 72},
		{source_type = .Task, source_id = 3, target_type = .Asset, target_id = 72},
		{source_type = .Task, source_id = 5, target_type = .Asset, target_id = 71},
		{source_type = .Asset, source_id = 1, target_type = .Asset, target_id = 71},
		{source_type = .Asset, source_id = 71, target_type = .Asset, target_id = 2},
		{source_type = .Task, source_id = 999, target_type = .Asset, target_id = 71},
		{source_type = .Asset, source_id = 3, target_type = .Asset, target_id = 71},
		{source_type = .Asset, source_id = 72, target_type = .Asset, target_id = 3},
		{source_type = .Asset, source_id = 4, target_type = .Asset, target_id = 71},
	}
	for edge, i in edges {
		key := pr.Asset {
			asset_id = u64(i + 1),
		}
		testing.expect_value(
			t,
			sqlite_projection_write(
				&store,
				"INSERT INTO edges VALUES(?1,?2,?3,?4,?5,?6,?7,0,x'')",
				c.workspace_id,
				&key,
				{i64(edge.source_type), edge.source_id, i64(edge.target_type), edge.target_id, i64(pr.RelationType.MemberOf)},
			),
			sql.OK,
		)
	}
	testing.expect_value(t, db.commit(&store), sql.OK)
	open := pr.TaskSlice {
		slice_id         = 71,
		name             = slice_test_bytes("Änderung"),
		owner            = slice_test_bytes("alice"),
		todo             = 1,
		done             = 1,
		blocked          = 1,
		notes            = 1,
		files            = 1,
		oldest_active_at = 10,
		last_moved_at    = 60,
	}
	empty := pr.TaskSlice {
		slice_id = max(u64),
		name     = slice_test_bytes("Empty"),
	}
	closed := pr.TaskSlice {
		slice_id         = 72,
		name             = slice_test_bytes("Closed"),
		flags            = pr.TaskSliceFlag_CLOSED,
		in_progress      = 1,
		done             = 1,
		oldest_active_at = 20,
		last_moved_at    = 50,
	}
	req := pr.ListTaskSlicesRequest {
		limit          = 1,
		correlation_id = 930,
	}
	worker_db_test_slice_expect(
		t,
		c,
		req,
		{
			success = true,
			slices = {open},
			total_count = 2,
			has_more = true,
			next_cursor_sort_at = 60,
			next_cursor_slice_id = 71,
			assigned_tasks = 3,
			unassigned_tasks = 1,
		},
	)
	with_reviews := open; with_reviews.reviews = 1
	worker_db_test_slice_expect(
		t,
		c,
		{limit = 10, include_reviews = true, correlation_id = 931},
		{
			success = true,
			include_reviews = true,
			slices = {with_reviews, empty},
			total_count = 2,
			next_cursor_sort_at = 60,
			next_cursor_slice_id = max(u64),
			assigned_tasks = 3,
			unassigned_tasks = 1,
		},
	)
	worker_db_test_slice_expect(
		t,
		c,
		{limit = 10, include_reviews = true, has_name = true, name = slice_test_bytes("Änderung"), correlation_id = 932},
		{success = true, include_reviews = true, slices = {with_reviews}, total_count = 1, next_cursor_sort_at = 60, next_cursor_slice_id = 71},
	)
	req.has_cursor = true; req.cursor_sort_at = 60; req.cursor_slice_id = 71
	worker_db_test_slice_expect(t, c, req, {success = true, slices = {empty}, total_count = 2, next_cursor_sort_at = 60, next_cursor_slice_id = max(u64)})
	// Crossing the open/closed boundary must seek the next range rather than
	// dropping a closed record whose timestamp sorts above the open cursor.
	req.include_closed = true; req.cursor_slice_id = max(u64)
	worker_db_test_slice_expect(
		t,
		c,
		req,
		{success = true, slices = {closed}, total_count = 3, next_cursor_closed = true, next_cursor_sort_at = 100, next_cursor_slice_id = 72},
	)
	// Continue through closed timestamp ties across the signed-ID boundary,
	// then into older closed records. Check both ordering indexes over the wire.
	saved_req := req
	extra_closed := [?]pr.Asset {
		slice_test_slice_asset(u64(1) << 63, `{"version":1,"name":"High ID","closed":true}`, 100),
		slice_test_slice_asset(max(u64) - 1, `{"version":1,"name":"Higher ID","closed":true}`, 100),
		slice_test_slice_asset(75, `{"version":1,"name":"Older","closed":true}`, 80),
	}
	testing.expect_value(t, db.begin(&store), sql.OK)
	for &asset in extra_closed do testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &asset), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	closed_pages := [?]pr.TaskSlice {
		closed,
		{slice_id = u64(1) << 63, name = slice_test_bytes("High ID"), flags = pr.TaskSliceFlag_CLOSED},
		{slice_id = max(u64) - 1, name = slice_test_bytes("Higher ID"), flags = pr.TaskSliceFlag_CLOSED},
		{slice_id = 75, name = slice_test_bytes("Older"), flags = pr.TaskSliceFlag_CLOSED},
	}
	for has_owner in ([2]bool{false, true}) {
		req = saved_req; req.has_owner = has_owner
		total: u32 = has_owner ? 5 : 6
		for entry, i in closed_pages {
			at: i64 = i == 3 ? 80 : 100
			worker_db_test_slice_expect(
				t,
				c,
				req,
				{
					success = true,
					slices = {entry},
					total_count = total,
					has_more = i < 3,
					next_cursor_closed = true,
					next_cursor_sort_at = at,
					next_cursor_slice_id = entry.slice_id,
				},
			)
			req.cursor_closed = true; req.cursor_sort_at = at; req.cursor_slice_id = entry.slice_id
		}
		worker_db_test_slice_expect(t, c, req, {success = true, total_count = total})
	}
	// The project-driven path must retain the same closed cursor ordering.
	project_task := tasks[1]; project_task.project = slice_test_bytes("paging")
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.put_task(&store, c.workspace_id, &project_task), sql.OK)
	for asset, i in extra_closed {
		key := pr.Asset {
			asset_id = u64(200 + i),
		}
		testing.expect_value(
			t,
			sqlite_projection_write(&store, "INSERT INTO edges VALUES(?1,?2,2,?3,1,?4,7,0,x'')", c.workspace_id, &key, {u64(2), asset.asset_id}),
			sql.OK,
		)
		closed_pages[i + 1].done = 1
		closed_pages[i + 1].last_moved_at = 40
	}
	testing.expect_value(t, db.commit(&store), sql.OK)
	// Five matches at limit four use the project path and need a lookahead.
	req = saved_req; req.has_cursor = false; req.limit = 4; req.project = slice_test_bytes("paging")
	worker_db_test_slice_expect(
		t,
		c,
		req,
		{
			success = true,
			slices = {open, closed_pages[0], closed_pages[1], closed_pages[2]},
			total_count = 5,
			has_more = true,
			next_cursor_closed = true,
			next_cursor_sort_at = 100,
			next_cursor_slice_id = max(u64) - 1,
		},
	)
	req.has_cursor = true; req.cursor_closed = true; req.cursor_sort_at = 100; req.cursor_slice_id = max(u64) - 1
	worker_db_test_slice_expect(
		t,
		c,
		req,
		{success = true, slices = {closed_pages[3]}, total_count = 5, next_cursor_closed = true, next_cursor_sort_at = 80, next_cursor_slice_id = 75},
	)
	for has_owner in ([2]bool{false, true}) {
		req = saved_req; req.has_owner = has_owner; req.project = slice_test_bytes("paging")
		total: u32 = has_owner ? 4 : 5
		req.limit = 4
		worker_db_test_slice_expect(
			t,
			c,
			req,
			{success = true, slices = closed_pages[:], total_count = total, next_cursor_closed = true, next_cursor_sort_at = 80, next_cursor_slice_id = 75},
		)
		// Exercise both sides of the strategy boundary with closed cursors,
		// including timestamp ties spanning 2^63 and the exhausted final page.
		for extra in ([2]u16{1, 2}) {
			req.limit = u16(total) - extra
			for cursor, i in closed_pages {
				req.cursor_closed = true; req.cursor_sort_at = i == 3 ? 80 : 100; req.cursor_slice_id = cursor.slice_id
				end := min(i + 1 + int(req.limit), len(closed_pages))
				want := pr.TaskSliceList {
					success     = true,
					total_count = total,
					slices      = closed_pages[i + 1:end],
					has_more    = end < len(closed_pages),
				}
				if end > i + 1 {
					want.next_cursor_closed = true
					want.next_cursor_sort_at = end == 4 ? 80 : 100
					want.next_cursor_slice_id = closed_pages[end - 1].slice_id
				}
				worker_db_test_slice_expect(t, c, req, want)
			}
		}
		req = saved_req; req.has_owner = has_owner; req.project = slice_test_bytes("paging")
		req.limit = 1
		for entry, i in closed_pages {
			at: i64 = i == 3 ? 80 : 100
			worker_db_test_slice_expect(
				t,
				c,
				req,
				{
					success = true,
					slices = {entry},
					total_count = total,
					has_more = i < 3,
					next_cursor_closed = true,
					next_cursor_sort_at = at,
					next_cursor_slice_id = entry.slice_id,
				},
			)
			req.cursor_closed = true; req.cursor_sort_at = at; req.cursor_slice_id = entry.slice_id
		}
		worker_db_test_slice_expect(t, c, req, {success = true, total_count = total})
	}
	testing.expect_value(t, db.begin(&store), sql.OK)
	for _, i in extra_closed {
		key := pr.Asset {
			asset_id = u64(200 + i),
		}
		testing.expect_value(t, sqlite_projection_write(&store, "DELETE FROM edges WHERE workspace=?1 AND id=?2", c.workspace_id, &key, nil), sql.OK)
	}
	testing.expect_value(t, db.put_task(&store, c.workspace_id, &tasks[1]), sql.OK)
	for &asset in extra_closed do testing.expect_value(t, sqlite_projection_write(&store, "DELETE FROM assets WHERE workspace=?1 AND id=?2", c.workspace_id, &asset, nil), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	req = saved_req
	req.has_cursor = false; req.include_closed = true; req.limit = 10
	worker_db_test_slice_expect(
		t,
		c,
		req,
		{
			success = true,
			slices = {open, empty, closed},
			total_count = 3,
			next_cursor_closed = true,
			next_cursor_sort_at = 100,
			next_cursor_slice_id = 72,
			assigned_tasks = 3,
			unassigned_tasks = 1,
		},
	)
	req.has_owner = true; req.owner = nil
	worker_db_test_slice_expect(
		t,
		c,
		req,
		{success = true, slices = {empty, closed}, total_count = 2, next_cursor_closed = true, next_cursor_sort_at = 100, next_cursor_slice_id = 72},
	)
	req.has_owner = false; req.has_name = true; req.name = slice_test_bytes("ÄND")
	worker_db_test_slice_expect(t, c, req, {success = true, slices = {open}, total_count = 1, next_cursor_sort_at = 60, next_cursor_slice_id = 71})
	req.has_name = false; req.name = nil; req.project = slice_test_bytes("NRC")
	worker_db_test_slice_expect(t, c, req, {success = true, slices = {open}, total_count = 1, next_cursor_sort_at = 60, next_cursor_slice_id = 71})
	req.project = slice_test_bytes("nrc")
	worker_db_test_slice_expect(t, c, req, {success = true})
	// Project matching and ordering follow note edits even when the asset has
	// the same ID as a task. Missing projections still use the canonical record.
	member := assets[4]
	member.updated_at = 80
	member.preview = slice_test_bytes(`{"project":"Changed"}`)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &member), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	req.project = slice_test_bytes("NRC")
	worker_db_test_slice_expect(t, c, req, {success = true})
	req.project = slice_test_bytes("Changed")
	changed := open; changed.last_moved_at = 80
	worker_db_test_slice_expect(t, c, req, {success = true, slices = {changed}, total_count = 1, next_cursor_sort_at = 80, next_cursor_slice_id = 71})
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(
		t,
		sqlite_projection_write(&store, "DELETE FROM note_metadata WHERE workspace=?1 AND asset_id=?2", c.workspace_id, &member, nil),
		sql.OK,
	)
	testing.expect_value(t, db.commit(&store), sql.OK)
	worker_db_test_slice_expect(t, c, req, {success = true})
	req.project = nil; req.has_name = true; req.name = slice_test_bytes("ÄND")
	worker_db_test_slice_expect(t, c, req, {success = true, slices = {changed}, total_count = 1, next_cursor_sort_at = 80, next_cursor_slice_id = 71})
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &assets[4]), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	req.has_name = false; req.name = nil
	worker_db_test_query_expect(t, c, {status_mask = 15, color = 255, sort = .WorkOrder, slice_id = 71, limit = 1, correlation_id = 931}, tasks[:], {0, 1})
	req.project = nil
	buffer: [1024]byte
	n := pr.serializeListTaskSlicesRequest(req, buffer[:])
	request := db.Request {
		workspace = c.workspace_id,
		opcode    = .C_ListTaskSlices,
		body      = buffer[2:n],
	}
	for budget in ([2]int{1, 4096}) {
		output := db.Command_Output {
			limit = budget,
		}; defer db.destroy_command_output(&output)
		testing.expect_value(t, db.begin(&store), sql.OK)
		testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), budget == 1 ? sql.TOOBIG : sql.OK)
		testing.expect_value(t, output.count, budget == 1 ? 0 : 1)
		// Indexed pages must not materialize the whole register, even on failure.
		sqlite_projection_test_assert(t, &store, "SELECT count(*)=0 FROM sqlite_temp_master WHERE name='nrc_slices'")
		testing.expect_value(t, db.rollback(&store), sql.OK)
	}
	// Change records through the other connection after summaries are warm.
	tasks[0].status = .Done; tasks[0].blocked_by = 0; tasks[0].updated_at = 90
	tasks[0].project = slice_test_bytes("ChangedTask")
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.put_task(&store, c.workspace_id, &tasks[0]), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	changed = open; changed.todo = 0; changed.done = 2; changed.blocked = 0
	changed.oldest_active_at = 0; changed.last_moved_at = 90
	req.project = slice_test_bytes("srv")
	worker_db_test_slice_expect(t, c, req, {success = true})
	req.project = slice_test_bytes("ChangedTask")
	worker_db_test_slice_expect(t, c, req, {success = true, slices = {changed}, total_count = 1, next_cursor_sort_at = 90, next_cursor_slice_id = 71})
	tasks[0].status = .Note
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.put_task(&store, c.workspace_id, &tasks[0]), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	changed.done = 1; changed.last_moved_at = 60
	req.project = nil
	worker_db_test_slice_expect(
		t,
		c,
		req,
		{
			success = true,
			slices = {changed, empty, closed},
			total_count = 3,
			next_cursor_closed = true,
			next_cursor_sort_at = 100,
			next_cursor_slice_id = 72,
			assigned_tasks = 2,
			unassigned_tasks = 1,
		},
	)
	// Removing a reverse membership must invalidate the same slice.
	key := pr.Asset {
		asset_id = 2,
	}
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sqlite_projection_write(&store, "DELETE FROM edges WHERE workspace=?1 AND id=?2", c.workspace_id, &key, nil), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	changed.done = 0
	req.has_name = true; req.name = slice_test_bytes("ÄND")
	worker_db_test_slice_expect(t, c, req, {success = true, slices = {changed}, total_count = 1, next_cursor_sort_at = 60, next_cursor_slice_id = 71})
	// A previously dangling task becomes a real member without editing its edge.
	late := pr.Task {
		id         = 999,
		status     = .Backlog,
		created_at = 11,
		updated_at = 110,
	}
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.put_task(&store, c.workspace_id, &late), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	changed.backlog = 1; changed.oldest_active_at = 11; changed.last_moved_at = 110
	worker_db_test_slice_expect(t, c, req, {success = true, slices = {changed}, total_count = 1, next_cursor_sort_at = 110, next_cursor_slice_id = 71})
	// Rebuilding inside a rolled-back transaction cannot publish derived state.
	late.status = .Done; late.updated_at = 120
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.put_task(&store, c.workspace_id, &late), sql.OK)
	output := db.Command_Output {
		limit = 4096,
	}; defer db.destroy_command_output(&output)
	testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), sql.OK)
	testing.expect_value(t, output.count, 1)
	testing.expect_value(t, db.rollback(&store), sql.OK)
	worker_db_test_slice_expect(t, c, req, {success = true, slices = {changed}, total_count = 1, next_cursor_sort_at = 110, next_cursor_slice_id = 71})
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.remove_task(&store, c.workspace_id, 0, 999), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	changed.backlog = 0; changed.oldest_active_at = 0; changed.last_moved_at = 60
	worker_db_test_slice_expect(t, c, req, {success = true, slices = {changed}, total_count = 1, next_cursor_sort_at = 60, next_cursor_slice_id = 71})
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(
		t,
		sqlite_projection_write(&store, "INSERT INTO edges VALUES(?1,?2,1,?3,2,?4,7,0,x'')", c.workspace_id, &key, {u64(71), u64(4)}),
		sql.OK,
	)
	testing.expect_value(t, db.commit(&store), sql.OK)
	changed.backlog = 1
	worker_db_test_slice_expect(t, c, req, {success = true, slices = {changed}, total_count = 1, next_cursor_sort_at = 60, next_cursor_slice_id = 71})
	// Moving an edge invalidates both the old and new endpoints.
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(
		t,
		sqlite_projection_write(
			&store,
			"UPDATE edges SET source_type=2,source_id=?3,target_type=1,target_id=?4 WHERE workspace=?1 AND id=?2",
			c.workspace_id,
			&key,
			{u64(4), u64(72)},
		),
		sql.OK,
	)
	testing.expect_value(t, db.commit(&store), sql.OK)
	changed.backlog = 0
	worker_db_test_slice_expect(t, c, req, {success = true, slices = {changed}, total_count = 1, next_cursor_sort_at = 60, next_cursor_slice_id = 71})
	req.name = slice_test_bytes("Closed"); closed.backlog = 1
	worker_db_test_slice_expect(
		t,
		c,
		req,
		{success = true, slices = {closed}, total_count = 1, next_cursor_closed = true, next_cursor_sort_at = 100, next_cursor_slice_id = 72},
	)
	// A fresh executor reads summaries persisted by the writer's finalization.
	want_closed := pr.TaskSliceList {
		success              = true,
		slices               = {closed},
		total_count          = 1,
		next_cursor_closed   = true,
		next_cursor_sort_at  = 100,
		next_cursor_slice_id = 72,
	}
	// Reject any rebuild to distinguish persisted reuse from recomputation.
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			"CREATE TRIGGER reject_slice_rebuild BEFORE INSERT ON slice_summaries BEGIN SELECT RAISE(ABORT,'unexpected rebuild'); END",
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	worker_db_test_slice_reopen(t, path, c.workspace_id, req, want_closed)
	testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER reject_slice_rebuild", nil, nil, nil), sql.OK)
	tasks[3].created_at = 15; tasks[3].project = slice_test_bytes("Restart")
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.put_task(&store, c.workspace_id, &tasks[3]), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	closed.oldest_active_at = 15
	want_closed.slices[0] = closed
	req.project = slice_test_bytes("Restart")
	worker_db_test_slice_reopen(t, path, c.workspace_id, req, want_closed)
	worker_db_test_slice_expect(t, c, req, want_closed)
	// A malformed offline write is not repaired by a reader. Writer-side repair
	// must also roll back if a deferred FK violation fires at COMMIT.
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			`CREATE TABLE slice_fault_parent(id INTEGER PRIMARY KEY);
 CREATE TABLE slice_fault_child(id INTEGER REFERENCES slice_fault_parent(id) DEFERRABLE INITIALLY DEFERRED);
 CREATE TRIGGER slice_fault AFTER UPDATE OF oldest ON slice_summaries
 BEGIN INSERT INTO slice_fault_child VALUES(1); END;`,
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	tasks[3].status = .Done
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.put_task(&store, c.workspace_id, &tasks[3]), sql.OK)
	// Deliberately bypass finalization to simulate an incomplete offline import.
	testing.expect_value(t, sql.exec(store.db, "COMMIT", nil, nil, nil), sql.OK)
	worker_db_test_slice_expect(t, c, req, {error = slice_test_bytes("Failed to read slices")})
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.CONSTRAINT)
	testing.expect_value(t, db.rollback(&store), sql.OK)
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=0 FROM slice_fault_child")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM slice_summaries WHERE backlog=1 AND oldest=15")
	sqlite_projection_test_assert(t, &store, "SELECT count(*)=1 FROM slice_pending")
	testing.expect_value(t, sql.exec(store.db, "DROP TRIGGER slice_fault; DROP TABLE slice_fault_child; DROP TABLE slice_fault_parent", nil, nil, nil), sql.OK)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	closed.backlog = 0; closed.done = 2; closed.oldest_active_at = 20
	want_closed.slices[0] = closed
	worker_db_test_slice_reopen(t, path, c.workspace_id, req, want_closed)
	worker_db_test_slice_expect(t, c, req, want_closed)
	worker_db_test_slice_reopen(
		t,
		path,
		c.workspace_id,
		{limit = 10, include_closed = true},
		{
			success = true,
			slices = {changed, empty, closed},
			total_count = 3,
			next_cursor_closed = true,
			next_cursor_sort_at = 100,
			next_cursor_slice_id = 72,
			assigned_tasks = 3,
		},
	)
	// Drop the closed slice projection after coverage was materialized. Its
	// membership rows must disappear even though canonical edges still exist.
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM slice_metadata WHERE asset_id=x'0000000000000048'", nil, nil, nil), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	req = {
		limit          = 10,
		correlation_id = 932,
	}
	for _ in 0 ..< 2 do worker_db_test_slice_expect(t, c, req, {success = true, slices = {changed, empty}, total_count = 2, next_cursor_sort_at = 60, next_cursor_slice_id = max(u64), unassigned_tasks = 3})
	// Exercise the wire category boundary on both rebuilds and cache hits.
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM edges; DELETE FROM assets; DELETE FROM tasks", nil, nil, nil), sql.OK)
	boundary := slice_test_slice_asset(71, `{"version":1,"name":"Boundary"}`)
	testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &boundary), sql.OK)
	testing.expect_value(t, db.put_task(&store, c.workspace_id, &tasks[0]), sql.OK)
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			`WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<65536)
 INSERT INTO tasks SELECT workspace,CAST(printf('%08d',x) AS BLOB),x'',x'',CASE WHEN x=65536 THEN 4 ELSE 1 END,0,x'',0,0,x'',CASE WHEN x=2 THEN 0 ELSE 10 END,0,x'',0,x'0000000000000000',0,x'',x'' FROM n CROSS JOIN tasks WHERE id=x'0000000000000001';
 DELETE FROM tasks WHERE id=x'0000000000000001';
 INSERT INTO edges SELECT workspace,id,2,id,1,x'0000000000000047',7,0,x'' FROM tasks;`,
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	testing.expect_value(t, db.commit(&store), sql.OK)
	boundary_entry := pr.TaskSlice {
		slice_id         = 71,
		name             = slice_test_bytes("Boundary"),
		todo             = 65535,
		oldest_active_at = 10,
	}
	want_boundary := pr.TaskSliceList {
		success              = true,
		slices               = {boundary_entry},
		total_count          = 1,
		next_cursor_slice_id = 71,
		assigned_tasks       = 65535,
	}
	for _ in 0 ..< 2 do worker_db_test_slice_expect(t, c, req, want_boundary)
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(
		t,
		sql.exec(store.db, "UPDATE tasks SET status=1,project=CAST('overflow' AS BLOB) WHERE id=CAST('00065536' AS BLOB)", nil, nil, nil),
		sql.OK,
	)
	first_page := slice_test_slice_asset(73, `{"version":1,"name":"First page"}`, 200)
	testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &first_page), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	req.limit = 1 // The overflowing slice is outside the requested page.
	for _ in 0 ..< 2 do worker_db_test_slice_expect(t, c, req, {error = slice_test_bytes("Slice listing representation limit exceeded: member category exceeds 65535")})
	req.project = slice_test_bytes("absent")
	worker_db_test_slice_expect(t, c, req, {success = true})
	req.project = slice_test_bytes("overflow"); req.has_cursor = true; req.cursor_closed = true
	worker_db_test_slice_expect(t, c, req, {error = slice_test_bytes("Slice listing representation limit exceeded: member category exceeds 65535")})
	req.has_owner = true; req.owner = slice_test_bytes("excluded")
	worker_db_test_slice_expect(t, c, req, {success = true})
	req.project = nil; req.has_cursor = false; req.cursor_closed = false; req.has_owner = false; req.owner = nil
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM assets WHERE id=x'0000000000000049'", nil, nil, nil), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM tasks WHERE id=CAST('00065536' AS BLOB)", nil, nil, nil), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	for _ in 0 ..< 2 do worker_db_test_slice_expect(t, c, req, want_boundary)
	// Missing creation times never displace a known active creation time.
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "UPDATE tasks SET created_at=0 WHERE id=CAST('00065535' AS BLOB)", nil, nil, nil), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	boundary_entry.oldest_active_at = 10
	want_boundary.slices[0] = boundary_entry
	for _ in 0 ..< 2 do worker_db_test_slice_expect(t, c, req, want_boundary)
}

worker_db_test_slice_reopen :: proc(t: ^testing.T, path: cstring, workspace: string, req: pr.ListTaskSlicesRequest, want: pr.TaskSliceList) {
	paths := [1]cstring{path}
	e, err := db.start_executor(paths[:], 1, 2, 65536, 4096, td.backing_allocator, command_handler = sqlite_execute_task_command)
	if !testing.expect_value(t, err, .None) do return
	defer db.destroy_executor(e)
	p := &e.ports[0]
	defer {db.finish_submissions(p); db.join_executor(e)}
	buffer: [1024]byte
	n := pr.serializeListTaskSlicesRequest(req, buffer[:])
	if !testing.expect(t, db.submit(p, {operation = .Command, workspace = workspace, opcode = .C_ListTaskSlices, body = buffer[2:n]})) do return
	for {
		if job, ok := db.receive(p); ok {
			defer db.release_completion(p, job)
			testing.expect_value(t, job.result.status, sql.OK)
			if testing.expect_value(t, job.result.command.count, 1) {
				expected := want; expected.correlation_id = req.correlation_id
				encoded: [4096]byte
				written := pr.serializeTaskSliceList(expected, encoded[:])
				testing.expect_value(t, string(job.result.command.frames[0].payload), string(encoded[:written]))
			}
			break
		}
		db.rearm_completions(p)
		fds := [1]linux.Poll_Fd{{fd = p.wake.fd, events = {.IN}}}
		count, poll_err := linux.poll(fds[:], 5000)
		if poll_err == .EINTR do continue
		assert(poll_err == .NONE && count == 1, "slice reopen completion timed out")
	}
}

slice_test_bytes :: proc(value: string) -> []byte {return transmute([]byte)value}
// slice_test_slice_asset registers a slice record. The preview is spelled out at
// each call site so a test shows exactly what it stores. The record's own creation
// time is the floor of the register's order, so a test that cares about the order
// sets it; every other test leaves it at zero.
slice_test_slice_asset :: proc(id: pr.AssetID, preview: string, created_at: i64 = 0) -> pr.Asset {
	return pr.Asset{asset_type = .Slice, asset_id = id, created_at = created_at, updated_at = 4000, preview = slice_test_bytes(preview)}
}

@(test)
test_slice_records_must_carry_a_display_name :: proc(t: ^testing.T) {
	// The register must be able to decode every accepted record.
	_, ok := slice_preview_name(slice_test_bytes(`{"version":1,"name":"Beta"}`), context.temp_allocator)
	testing.expect(t, ok, "a well-formed record names its slice")
	broken_records := [4]string{`not json`, `{"name":"Beta"}`, `{"version":1,"name":""}`, `{"version":3,"name":"Beta"}`}
	for broken in broken_records {
		_, broken_ok := slice_preview_name(slice_test_bytes(broken), context.temp_allocator)
		testing.expect(t, !broken_ok, "a record without a usable name is refused")
	}
}

@(test)
test_task_slice_list_wire_roundtrip :: proc(t: ^testing.T) {
	msg := pr.TaskSliceList {
		conv_id              = 0,
		success              = true,
		has_more             = true,
		next_cursor_closed   = true,
		next_cursor_sort_at  = 1234,
		next_cursor_slice_id = 78,
		total_count          = 9,
		assigned_tasks       = 7,
		unassigned_tasks     = 11,
		slices               = []pr.TaskSlice {
			{
				name = slice_test_bytes("Alpha"),
				slice_id = 77,
				owner = slice_test_bytes("rene"),
				flags = pr.TaskSliceFlag_CLOSED,
				backlog = 1,
				todo = 2,
				in_progress = 3,
				done = 4,
				blocked = 5,
				notes = 6,
				files = 7,
				tickets = 8,
				oldest_active_at = 111,
				last_moved_at = 222,
			},
			{name = slice_test_bytes("Beta"), slice_id = 78, todo = 1, last_moved_at = 333},
		},
		error                = slice_test_bytes(""),
		correlation_id       = 4242,
	}

	buf := make([]byte, pr.getSizeTaskSliceList(msg))
	defer delete(buf)
	written := pr.serializeTaskSliceList(msg, buf)
	testing.expect_value(t, written, len(buf))

	parsed, err := pr.parseTaskSliceList(buf, context.temp_allocator)
	testing.expect_value(t, err, pr.ProtocolParseError.None)
	testing.expect_value(t, parsed.conv_id, msg.conv_id)
	testing.expect(t, parsed.success, "success flag should survive the roundtrip")
	testing.expect(t, parsed.has_more, "has_more should survive the roundtrip")
	testing.expect(t, parsed.next_cursor_closed, "the cursor carries the closure of the slice it names")
	testing.expect_value(t, parsed.next_cursor_sort_at, i64(1234))
	testing.expect_value(t, parsed.next_cursor_slice_id, pr.AssetID(78))
	testing.expect_value(t, parsed.total_count, u32(9))
	testing.expect_value(t, parsed.assigned_tasks, u32(7))
	testing.expect_value(t, parsed.unassigned_tasks, u32(11))
	testing.expect_value(t, parsed.correlation_id, u32(4242))
	testing.expect_value(t, len(parsed.slices), 2)

	first := parsed.slices[0]
	testing.expect_value(t, string(first.name), "Alpha")
	testing.expect_value(t, first.slice_id, pr.AssetID(77))
	testing.expect_value(t, string(first.owner), "rene")
	testing.expect(t, slice_has_flag(first, pr.TaskSliceFlag_CLOSED), "closed flag survives")
	testing.expect_value(t, first.backlog, u16(1))
	testing.expect_value(t, first.todo, u16(2))
	testing.expect_value(t, first.in_progress, u16(3))
	testing.expect_value(t, first.done, u16(4))
	testing.expect_value(t, first.blocked, u16(5))
	testing.expect_value(t, first.notes, u16(6))
	testing.expect_value(t, first.files, u16(7))
	testing.expect_value(t, first.tickets, u16(8))
	testing.expect_value(t, first.oldest_active_at, i64(111))
	testing.expect_value(t, first.last_moved_at, i64(222))
	testing.expect_value(t, pr.task_slice_open_count(first), u16(6))
	testing.expect_value(t, pr.task_slice_member_count(first), 31)

	second := parsed.slices[1]
	testing.expect_value(t, string(second.name), "Beta")
	testing.expect_value(t, second.slice_id, pr.AssetID(78))
	testing.expect(t, !slice_has_flag(second, pr.TaskSliceFlag_CLOSED), "an open slice carries no closed flag")

	// Trailing bytes are rejected rather than ignored.
	padded := make([]byte, len(buf) + 1)
	defer delete(padded)
	copy(padded, buf)
	_, padded_err := pr.parseTaskSliceList(padded, context.temp_allocator)
	testing.expect_value(t, padded_err, pr.ProtocolParseError.ContentLengthMismatch)
}

// The request body carries no opcode: conv_id, the two flags, the owner, the
// name, the page bound, the cursor and the correlation id.
@(test)
test_list_task_slices_request_parse :: proc(t: ^testing.T) {
	body := [22]byte{}
	endian.put_u64(body[:], .Big, 0)
	body[8] = 1 // include_closed
	body[9] = 0 // no owner filter
	endian.put_u16(body[10:], .Big, 0)
	body[12] = 0 // no name filter
	endian.put_u16(body[13:], .Big, 0)
	endian.put_u16(body[15:], .Big, 100)
	body[17] = 0 // first page
	endian.put_u32(body[18:], .Big, 7)

	req, err := pr.parseListTaskSlicesRequest(body[:])
	testing.expect_value(t, err, pr.ProtocolParseError.None)
	testing.expect(t, req.include_closed, "include_closed should parse")
	testing.expect(t, !req.has_owner, "an absent owner filter is no filter")
	testing.expect(t, !req.has_name, "an absent name filter is no filter")
	testing.expect_value(t, req.limit, u16(100))
	testing.expect(t, !req.has_cursor, "a first page carries no cursor")
	testing.expect_value(t, req.correlation_id, u32(7))

	// A flag outside its range, a page bound outside its range, a short body and
	// trailing bytes are all refused.
	body[8] = 2
	_, invalid_err := pr.parseListTaskSlicesRequest(body[:])
	testing.expect_value(t, invalid_err, pr.ProtocolParseError.InvalidValue)
	body[8] = 0

	endian.put_u16(body[15:], .Big, 0)
	_, zero_limit_err := pr.parseListTaskSlicesRequest(body[:])
	testing.expect_value(t, zero_limit_err, pr.ProtocolParseError.TooMany)
	endian.put_u16(body[15:], .Big, pr.MAX_TASK_SLICE_COUNT + 1)
	_, large_limit_err := pr.parseListTaskSlicesRequest(body[:])
	testing.expect_value(t, large_limit_err, pr.ProtocolParseError.TooMany)
	endian.put_u16(body[15:], .Big, 100)

	_, short_err := pr.parseListTaskSlicesRequest(body[:21])
	testing.expect_value(t, short_err, pr.ProtocolParseError.TooShort)

	long := [23]byte{}
	copy(long[:], body[:])
	_, long_err := pr.parseListTaskSlicesRequest(long[:])
	testing.expect_value(t, long_err, pr.ProtocolParseError.TooShort)
}

@(test)
test_list_task_slices_project_wire :: proc(t: ^testing.T) {
	request := pr.ListTaskSlicesRequest {
		limit           = 100,
		project         = slice_test_bytes("NRC"),
		correlation_id  = 7,
		has_cursor      = true,
		cursor_slice_id = 71,
		cursor_sort_at  = 9000,
	}
	buf := make([]byte, pr.getSizeListTaskSlicesRequest(request))
	defer delete(buf)
	testing.expect_value(t, pr.serializeListTaskSlicesRequest(request, buf), len(buf))
	parsed, err := pr.parseListTaskSlicesRequest(buf[2:])
	testing.expect_value(t, err, pr.ProtocolParseError.None)
	testing.expect_value(t, string(parsed.project), "NRC")
	testing.expect_value(t, parsed.correlation_id, u32(7))
	testing.expect_value(t, parsed.cursor_slice_id, pr.AssetID(71))
	_, short_err := pr.parseListTaskSlicesRequest(buf[2:len(buf) - 1])
	testing.expect_value(t, short_err, pr.ProtocolParseError.ContentLengthMismatch)
	buf[len(buf) - 1] = 0xFF
	_, utf8_err := pr.parseListTaskSlicesRequest(buf[2:])
	testing.expect_value(t, utf8_err, pr.ProtocolParseError.InvalidValue)
	endian.put_u16(buf[len(buf) - 5:], .Big, pr.MAX_PROJECT_LENGTH + 1)
	_, length_err := pr.parseListTaskSlicesRequest(buf[2:])
	testing.expect_value(t, length_err, pr.ProtocolParseError.InvalidValue)
}

@(test)
test_list_task_slices_request_carries_filters_and_a_cursor :: proc(t: ^testing.T) {
	owner := "anke"
	name := "shard"
	body := make([]byte, 22 + len(owner) + len(name) + 17)
	defer delete(body)
	endian.put_u64(body[:], .Big, 0)
	body[8] = 0
	body[9] = 1
	endian.put_u16(body[10:], .Big, u16(len(owner)))
	copy(body[12:], slice_test_bytes(owner))
	offset := 12 + len(owner)
	body[offset] = 1
	offset += 1
	endian.put_u16(body[offset:], .Big, u16(len(name)))
	offset += 2
	copy(body[offset:], slice_test_bytes(name))
	offset += len(name)
	endian.put_u16(body[offset:], .Big, 50)
	offset += 2
	body[offset] = 1
	offset += 1
	body[offset] = 1 // the cursor names a closed slice
	offset += 1
	endian.put_i64(body[offset:], .Big, 9000)
	offset += 8
	endian.put_u64(body[offset:], .Big, 77)
	offset += 8
	endian.put_u32(body[offset:], .Big, 9)

	req, err := pr.parseListTaskSlicesRequest(body)
	testing.expect_value(t, err, pr.ProtocolParseError.None)
	testing.expect(t, req.has_owner && string(req.owner) == owner, "the owner filter parses")
	testing.expect(t, req.has_name && string(req.name) == name, "the name filter parses")
	testing.expect_value(t, req.limit, u16(50))
	testing.expect(t, req.has_cursor, "the cursor parses")
	testing.expect(t, req.cursor_closed, "the cursor carries the closure of the slice it names")
	testing.expect_value(t, req.cursor_sort_at, i64(9000))
	testing.expect_value(t, req.cursor_slice_id, pr.AssetID(77))
	testing.expect_value(t, req.correlation_id, u32(9))

	// A filter that is absent carries no name, and one that is present has to
	// name something.
	body[9] = 0
	_, owner_err := pr.parseListTaskSlicesRequest(body)
	testing.expect_value(t, owner_err, pr.ProtocolParseError.InvalidValue)
}
@(test)
test_slice_page_fits_one_frame :: proc(t: ^testing.T) {
	name := make([]byte, pr.MAX_PROJECT_LENGTH)
	defer delete(name)
	owner := make([]byte, pr.MAX_ASSIGNEE_LENGTH)
	defer delete(owner)
	slices := make([]pr.TaskSlice, pr.MAX_TASK_SLICE_COUNT)
	defer delete(slices)
	for i in 0 ..< len(slices) {
		slices[i] = pr.TaskSlice {
			name     = name,
			owner    = owner,
			slice_id = pr.AssetID(i + 1),
		}
	}

	msg := pr.TaskSliceList {
		slices = slices,
	}
	testing.expect(t, pr.getSizeTaskSliceList(msg) <= MAX_PROTOCOL_PAYLOAD_SIZE, "the largest page a request may ask for fits one frame")
}

@(test)
test_slice_opcodes_are_accepted_by_get_opcode :: proc(t: ^testing.T) {
	request := [2]byte{}
	request[0] = u8(u16(pr.Opcode.C_ListTaskSlices) >> 8)
	request[1] = u8(u16(pr.Opcode.C_ListTaskSlices) & 0xFF)
	testing.expect_value(t, pr.get_opcode(request[:]), pr.Opcode.C_ListTaskSlices)

	response := [2]byte{}
	response[0] = u8(u16(pr.Opcode.S_TaskSliceList) >> 8)
	response[1] = u8(u16(pr.Opcode.S_TaskSliceList) & 0xFF)
	testing.expect_value(t, pr.get_opcode(response[:]), pr.Opcode.S_TaskSliceList)
}
