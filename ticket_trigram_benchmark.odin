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

// Set NRC_TICKET_BENCH to a disposable directory. Seed once per build and
// reopen the same immutable fixture in each independent timing process.
@(test)
benchmark_ticket_trigram :: proc(t: ^testing.T) {
	base := os.get_env("NRC_TICKET_BENCH", context.allocator); defer delete(base)
	if base == "" do return
	for n in ([2]int{1000, 10000}) {
		name := fmt.aprintf("%s/%d.db", base, n); defer delete(name)
		path := strings.clone_to_cstring(name); defer delete(path)
		seed := !os.exists(name)
		st, rc := db.open(path, create = seed); assert(rc == sql.OK); defer db.close(&st)
		put :: proc(st: ^db.Store, i, n: int, workspace: string) {
			title := fmt.aprint(
				`{"version":1,"title":"Request `,
				i,
				`","company_id":"","contact_id":"","requester":"","requester_name":"","status":"open","assignee":"alice"}`,
			); defer delete(title)
			a := pr.Asset {
				asset_id   = u64(i),
				asset_type = .Ticket,
				created_at = i64(i),
				preview    = transmute([]byte)title,
			}; assert(sqlite_put_asset(st, workspace, &a, true) == sql.OK)
			for j in 0 ..< 10 {
				id := n + 10 * i + j; body := strings.repeat("Please check the network. ", 12); defer delete(body)
				text := fmt.aprint(body, i % 100 == 0 && j == 9 ? "Late needle" : ""); defer delete(text)
				e := pr.Asset {
					asset_type      = .TicketEntry,
					asset_id        = u64(id),
					parent_type     = .Asset,
					parent_id       = u64(i),
					created_at      = i64(id),
					preview         = transmute([]byte)sqlite_command_asset_preview(.TicketEntry),
					payload         = transmute([]byte)text,
					payload_raw_len = u32(len(text)),
				}; assert(sqlite_put_asset(st, workspace, &e, true) == sql.OK)
			}
		}
		if seed {
			assert(db.begin(&st) == sql.OK); for i in 1 ..= n {put(&st, i, n, "bench")}; assert(db.commit(&st) == sql.OK)
		}
		for sort in ([5]string{"activity", "title", "priority", "unread", "attention"}) {
			for term in ([4]string{"request", "late needle", "no-such-term", ""}) {
				if term == "" && sort != "attention" do continue
				suffix :=
					sort == "attention" ? `id","mode":"attention","descending":true,"omit_total_count":true,"limit":100}` : strings.concatenate({sort, `","limit":50}`})
				defer if sort != "attention" do delete(suffix)
				query := strings.concatenate({`{"search":"`, term, `","sort":"`, suffix}); defer delete(query)
				b: [256]byte; l := pr.serializeTicketQueryRequest(1, transmute([]byte)query, b[:]); r := db.Request {
					workspace = "bench",
					actor     = "alice",
					opcode    = .C_QueryTickets,
					body      = b[2:l],
				}
				once :: proc(st: ^db.Store, r: ^db.Request) -> u64 {o := db.Command_Output {
						limit = pr.MAX_PROTOCOL_PAYLOAD_SIZE + size_of(db.Command_Frame),
					}; defer db.destroy_command_output(
						&o,
					); assert(db.begin(st) == sql.OK); assert(sqlite_query_tickets(st, r, &o) == sql.OK); assert(db.commit(st) == sql.OK); assert(pr.get_opcode(o.frames[0].payload) == .S_TicketPage); h: u64 = 1; for v in o.frames[0].payload {h = h * 31 + u64(v)}; return h}
				start := clock.now_monotonic()
				h := once(&st, &r)
				rounds := max(1, int(500000000 / max(i64(time.diff(start, clock.now_monotonic())), 1)))
				start = clock.now_monotonic()
				sum: u64
				for _ in 0 ..< rounds {sum += once(&st, &r)}
				elapsed := time.diff(start, clock.now_monotonic()); assert(sum == h * u64(rounds))
				fmt.printf("read,%d,%s,%s,%d,%.4f\n", n, sort, term, h, f64(elapsed) / f64(rounds) / 1e6)
			}
		}
		// Includes fixture construction and projection writes; excludes durable commit.
		assert(db.begin(&st) == sql.OK)
		start := clock.now_monotonic(); for i in 1 ..= 500 {put(&st, i, n, "writes")}
		elapsed := time.diff(start, clock.now_monotonic()); assert(db.rollback(&st) == sql.OK)
		fmt.printf("write,%d,fixture_and_write_ms_per_family_before_commit,%.4f\n", n, f64(elapsed) / 500e6)
	}
}
