package main

import "clock"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

// Small overlapping slices at the end of a much larger workspace. Unrelated
// graph-chain edges give the membership probes a nonempty background graph.
@(test)
benchmark_sqlite_slice_workorder :: proc(t: ^testing.T) {
	enabled := os.get_env("BENCH_SQLITE_SLICE", context.allocator); defer delete(enabled)
	if enabled != "1" do return
	base := os.get_env("BENCH_SQLITE_DIR", context.allocator); defer delete(base)
	for n in ([3]int{1000, 10000, 100000}) {
		dir, err := os.make_directory_temp(base, "nrc-slice-bench-*", context.allocator)
		if !testing.expect(t, err == nil) do return
		defer {os.remove_all(dir); delete(dir)}
		name := fmt.aprintf("%s/shard.sqlite3", dir); defer delete(name)
		path := strings.clone_to_cstring(name); defer delete(path)
		store, rc := db.open(path, create = true); if !testing.expect_value(t, rc, sql.OK) do return
		defer db.close(&store)
		testing.expect_value(t, db.begin(&store), sql.OK)
		first := u64(n - 199)
		for i in 0 ..< n {
			id := u64(i + 1)
			task := pr.Task {
				id         = id,
				status     = .Todo,
				priority   = u8(i % 4),
				blocked_by = id > first ? id - 1 : 0,
			}
			testing.expect_value(t, db.put_task(&store, "bench", &task), sql.OK)
			if i == 0 do continue
			key := pr.Asset {
				asset_id = id,
			}
			testing.expect_value(
				t,
				sqlite_projection_write(
					&store,
					"INSERT INTO edges VALUES(?1,?2,?3,?4,?5,?6,?7,0,x'')",
					"bench",
					&key,
					{i64(pr.TargetType.Task), id - 1, i64(pr.TargetType.Task), id, i64(pr.RelationType.References)},
				),
				sql.OK,
			)
		}
		for count in ([3]int{10, 50, 200}) {
			asset := slice_test_slice_asset(u64(count), `{"version":1,"name":"Benchmark slice"}`)
			testing.expect_value(t, sqlite_put_asset(&store, "bench", &asset), sql.OK)
			for i in 0 ..< count {
				key := pr.Asset {
					asset_id = u64(n + count * 1000 + i),
				}
				// Alternate direction so both membership paths must contribute.
				source_type := i % 2 == 0 ? pr.TargetType.Task : pr.TargetType.Asset
				target_type := i % 2 == 0 ? pr.TargetType.Asset : pr.TargetType.Task
				source := i % 2 == 0 ? first + u64(i) : u64(count)
				target := i % 2 == 0 ? u64(count) : first + u64(i)
				testing.expect_value(
					t,
					sqlite_projection_write(
						&store,
						"INSERT INTO edges VALUES(?1,?2,?3,?4,?5,?6,?7,0,x'')",
						"bench",
						&key,
						{i64(source_type), source, i64(target_type), target, i64(pr.RelationType.MemberOf)},
					),
					sql.OK,
				)
			}
		}
		testing.expect_value(t, db.commit(&store), sql.OK)
		for count in ([3]int{10, 50, 200}) {
			buffer: [1024]byte
			req := pr.TaskQueryRequest {
				status_mask = 7,
				sort        = .WorkOrder,
				limit       = 50,
				color       = 255,
				slice_id    = u64(count),
			}
			length := pr.serializeTaskQueryRequest(req, buffer[:])
			request := db.Request {
				opcode    = .C_QueryTasks,
				workspace = "bench",
				body      = buffer[2:length],
			}
			// Independently known chain order and total, checked outside timing.
			{
				output := db.Command_Output {
					limit = pr.MAX_PROTOCOL_PAYLOAD_SIZE + size_of(db.Command_Frame),
				}
				defer db.destroy_command_output(&output)
				testing.expect_value(t, db.begin(&store), sql.OK)
				testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), sql.OK)
				testing.expect_value(t, db.commit(&store), sql.OK)
				tasks: [50]pr.Task
				for &task, i in tasks {id := first + u64(i); task = {
						id         = id,
						status     = .Todo,
						priority   = u8((id - 1) % 4),
						blocked_by = i == 0 ? 0 : id - 1,
					}}
				returned := min(count, 50)
				want := pr.TaskQueryPage {
					success             = true,
					tasks               = tasks[:returned],
					total_count         = u32(count),
					has_more            = count > 50,
					next_cursor_number  = i64(returned),
					next_cursor_task_id = first + u64(returned) - 1,
				}
				encoded: [16384]byte; written := pr.serializeTaskQueryPage(want, encoded[:])
				if testing.expect_value(t, output.count, 1) do testing.expect_value(t, string(output.frames[0].payload), string(encoded[:written]))
			}
			expected := sqlite_graph_bench_once(&store, &request); testing.expect(t, expected != 0)
			pilot_rounds := 1; pilot: i64
			for {
				start := clock.now_monotonic()
				for _ in 0 ..< pilot_rounds {_ = sqlite_graph_bench_once(&store, &request)}
				pilot = max(i64(time.diff(start, clock.now_monotonic())), 1)
				if pilot >= 50_000_000 do break
				pilot_rounds *= 2
			}
			rounds := max(1, int(600_000_000 * i64(pilot_rounds) / pilot)); checksum: u64
			start := clock.now_monotonic()
			for _ in 0 ..< rounds do checksum += sqlite_graph_bench_once(&store, &request)
			elapsed := i64(time.diff(start, clock.now_monotonic()))
			testing.expect_value(t, checksum, expected * u64(rounds))
			fmt.printf("SQLITE_SLICE,%d,%d,%d,%d\n", n, count, rounds, elapsed)
		}
	}
}

sqlite_graph_bench_once :: proc(store: ^db.Store, request: ^db.Request) -> u64 {
	output := db.Command_Output {
		limit = pr.MAX_PROTOCOL_PAYLOAD_SIZE + size_of(db.Command_Frame),
	}
	defer db.destroy_command_output(&output)
	if db.begin(store) != sql.OK do return 0
	if sqlite_execute_task_command(store, request, &output) != sql.OK {db.rollback(store); return 0}
	if db.commit(store) != sql.OK || output.count != 1 do return 0
	checksum: u64
	for b in output.frames[0].payload do checksum = checksum * 31 + u64(b)
	return checksum
}

sqlite_graph_bench_validate :: proc(t: ^testing.T, store: ^db.Store, request: ^db.Request, n: int) {
	output := db.Command_Output {
		limit = pr.MAX_PROTOCOL_PAYLOAD_SIZE + size_of(db.Command_Frame),
	}
	defer db.destroy_command_output(&output)
	testing.expect_value(t, db.begin(store), sql.OK)
	testing.expect_value(t, sqlite_execute_task_command(store, request, &output), sql.OK)
	testing.expect_value(t, db.commit(store), sql.OK)
	if !testing.expect_value(t, output.count, 1) do return
	payload := output.frames[0].payload
	nodes: [500]pr.GraphQueryNode; path: [500]pr.GraphPathNode; edges: [1500]pr.Edge; degrees: [100]pr.GraphDegreeEntry
	#partial switch request.opcode {
	case .C_GraphQuery:
		msg, err := pr.parseGraphQueryResult(payload, nodes[:], edges[:]); testing.expect(t, err == nil)
		testing.expect_value(t, len(msg.nodes), min(n + 1, 500)); testing.expect_value(t, len(msg.edges), n < 500 ? 2 * n - 1 : 997)
		testing.expect_value(t, msg.truncated, n >= 500)
	case .C_GraphShortestPath:
		msg, err := pr.parseGraphShortestPathResult(payload, path[:], edges[:]); testing.expect(t, err == nil)
		testing.expect(t, msg.found); testing.expect_value(t, msg.path_length, u8(4))
		for node, i in msg.nodes do testing.expect_value(t, node.target_id, u64(i + 1))
	case .C_GraphCommonNeighbors:
		msg, err := pr.parseGraphCommonNeighborsResult(payload, path[:], edges[:]); testing.expect(t, err == nil)
		testing.expect_value(t, len(msg.nodes), 50); testing.expect_value(t, len(msg.edges), 100)
		for node, i in msg.nodes do testing.expect_value(t, node.target_id, u64(i + 1))
	case .C_GraphDegree:
		msg, err := pr.parseGraphDegreeResult(payload, degrees[:]); testing.expect(t, err == nil)
		testing.expect_value(t, len(msg.entries), 50); testing.expect_value(t, msg.entries[0], pr.GraphDegreeEntry{.Asset, 1, u16(min(n, 499))})
	case .C_QueryTasks:
		tasks: [50]pr.Task
		for &task, i in tasks do task = {
			id         = u64(i + 1),
			status     = .Todo,
			blocked_by = u64(i),
			priority   = u8(i % 4),
		}
		msg := pr.TaskQueryPage {
			success             = true,
			tasks               = tasks[:],
			has_more            = true,
			total_count         = u32(n),
			next_cursor_number  = 50,
			next_cursor_task_id = 50,
		}
		buffer: [16384]byte; size := pr.serializeTaskQueryPage(msg, buffer[:])
		testing.expect_value(t, string(payload), string(buffer[:size]))
	}
}

// End-to-end executor-command work, not queue/network latency. Fresh file-backed
// synthetic fixtures, warm cache, FULL/WAL, temp_store=FILE, 1 MiB cache budget.
@(test)
benchmark_sqlite_graph_queries :: proc(t: ^testing.T) {
	enabled := os.get_env("BENCH_SQLITE_GRAPH", context.allocator); defer delete(enabled)
	if enabled != "1" do return
	base := os.get_env("BENCH_SQLITE_DIR", context.allocator); defer delete(base)
	for n in ([3]int{100, 1000, 10000}) {
		dir, err := os.make_directory_temp(base, "nrc-sqlite-graph-bench-*", context.allocator)
		if !testing.expect(t, err == nil) do return
		defer {os.remove_all(dir); delete(dir)}
		name := fmt.aprintf("%s/shard.sqlite3", dir); defer delete(name)
		path := strings.clone_to_cstring(name); defer delete(path)
		store, rc := db.open(path, create = true); if !testing.expect_value(t, rc, sql.OK) do return
		defer db.close(&store)
		testing.expect_value(t, db.begin(&store), sql.OK)
		for i in 0 ..< n {
			task := pr.Task {
				id         = u64(i + 1),
				status     = .Todo,
				blocked_by = u64(i),
				priority   = u8(i % 4),
			}
			testing.expect_value(t, db.put_task(&store, "bench", &task), sql.OK)
		}
		edge_id: u64 = 0
		for kind in 0 ..< 3 {
			count := kind == 0 ? n - 1 : (kind == 1 ? min(n, 499) : 50)
			for i in 0 ..< count {
				edge_id += 1; key := pr.Asset {
					asset_id = edge_id,
				}
				source_type := kind == 0 ? pr.TargetType.Task : pr.TargetType.Asset
				source := kind == 0 ? u64(i + 1) : u64(kind)
				target := kind == 0 ? u64(i + 2) : u64(i + 1)
				testing.expect_value(
					t,
					sqlite_projection_write(
						&store,
						"INSERT INTO edges VALUES(?1,?2,?3,?4,?5,?6,?7,0,x'')",
						"bench",
						&key,
						{i64(source_type), source, i64(pr.TargetType.Task), target, i64(pr.RelationType.References)},
					),
					sql.OK,
				)
			}
		}
		testing.expect_value(t, db.commit(&store), sql.OK)
		for kind in 0 ..< 6 {
			buffer: [1024]byte; length := 0; opcode: pr.Opcode; label: string
			switch kind {
			case 0:
				opcode = .C_GraphQuery; label = "bfs"
				length = pr.serializeGraphQueryRequest({start_type = .Asset, start_id = 1, max_depth = 2, direction = .Outgoing}, buffer[:])
			case 1:
				opcode = .C_GraphShortestPath; label = "shortest"
				length = pr.serializeGraphShortestPathRequest(
					{from_type = .Task, from_id = 1, to_type = .Task, to_id = 5, max_depth = 4, direction = .Outgoing},
					buffer[:],
				)
			case 2:
				opcode = .C_GraphDegree; label = "degree"; length = pr.serializeGraphDegreeRequest({top_n = 50}, buffer[:])
			case 3:
				opcode = .C_GraphCommonNeighbors; label = "common"
				length = pr.serializeGraphCommonNeighborsRequest({a_type = .Asset, a_id = 1, b_type = .Asset, b_id = 2, direction = .Outgoing}, buffer[:])
			case 4:
				opcode = .C_GraphRank; label = "rank"
				req := pr.GraphRankRequest {
					anchor_count = 2,
					max_depth    = 2,
					top_n        = 50,
					direction    = .Both,
				}; req.anchors[0] = {.Asset, 1}; req.anchors[1] = {.Asset, 2}
				length = pr.serializeGraphRankRequest(req, buffer[:])
			case 5:
				opcode = .C_QueryTasks; label = "workorder"
				length = pr.serializeTaskQueryRequest({status_mask = 7, sort = .WorkOrder, limit = 50, color = 255}, buffer[:])
			}
			request := db.Request {
				opcode    = opcode,
				workspace = "bench",
				body      = buffer[2:length],
			}
			sqlite_graph_bench_validate(t, &store, &request, n)
			expected := sqlite_graph_bench_once(&store, &request); testing.expect(t, expected != 0)
			pilot_rounds := 1; pilot: i64
			for {
				start := clock.now_monotonic()
				for _ in 0 ..< pilot_rounds {_ = sqlite_graph_bench_once(&store, &request)}
				pilot = max(i64(time.diff(start, clock.now_monotonic())), 1)
				if pilot >= 50_000_000 do break
				pilot_rounds *= 2
			}
			rounds := max(1, int(600_000_000 * i64(pilot_rounds) / pilot)); checksum: u64
			start := clock.now_monotonic()
			for _ in 0 ..< rounds do checksum += sqlite_graph_bench_once(&store, &request)
			elapsed := i64(time.diff(start, clock.now_monotonic()))
			testing.expect_value(t, checksum, expected * u64(rounds))
			fmt.printf("SQLITE_GRAPH,%s,%d,%d,%d,%d\n", label, n, edge_id, rounds, elapsed)
		}
	}
}
