package main

import "clock"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import pr "protocol"

// Synthetic closed/read tickets: half assigned to the reader, 10% of all
// tickets due, one unrelated note per ticket. This reproduces the original
// Attention measurement. Query timing includes arena lifetime and serialization,
// not fixture construction, network, WAL or allocator instrumentation.
@(test)
benchmark_ticket_attention :: proc(t: ^testing.T) {
	enabled := os.get_env("BENCH_TICKET_ATTENTION", context.allocator)
	defer delete(enabled)
	if enabled != "1" do return
	n := message_store_benchmark_env_int("MEASURE_TICKETS", 100)
	entries := message_store_benchmark_env_int("MEASURE_ENTRIES", 10)
	allocation_mode := os.get_env("BENCH_TICKET_ALLOC", context.allocator)
	defer delete(allocation_mode)
	backing := context.allocator
	fixture: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&fixture) == nil)
	defer virtual.arena_destroy(&fixture)
	context.allocator = virtual.arena_allocator(&fixture)
	conv: Conversation_State
	conv.assets = make(map[pr.AssetID]^pr.Asset)
	init_note_index(&conv)
	reads := make(map[pr.AssetID]pr.AssetID)
	for i in 0 ..< n {
		id := pr.AssetID(i * (entries + 1) + 1)
		preview := fmt.aprintf(
			`{{"version":1,"title":"Customer ticket %d","company_id":"","contact_id":"","requester":"ada@example.test","requester_name":"Ada","status":"closed","assignee":"%s","priority":"normal","follow_up_at":"%s"}}`,
			i,
			i % 2 == 0 ? "alice" : "bob",
			i % 10 == 0 ? "1000" : "2000",
		)
		asset := new(pr.Asset)
		asset^ = {
			asset_id   = id,
			asset_type = .Ticket,
			preview    = transmute([]byte)preview,
			created_at = 1,
		}
		conv.assets[id] = asset
		reads[id] = id + pr.AssetID(entries)
		for j in 0 ..< entries {
			entry := new(pr.Asset)
			entry^ = {
				asset_id    = id + pr.AssetID(j + 1),
				asset_type  = .TicketEntry,
				parent_type = .Asset,
				parent_id   = u64(id),
				preview     = transmute([]byte)string(`{"version":1,"kind":"public_reply","author":"alice"}`),
				created_at  = i64(j + 2),
			}
			conv.assets[entry.asset_id] = entry
			index_asset_parent(&conv, entry)
		}
		note := new(pr.Asset)
		note^ = {
			asset_id   = pr.AssetID(n * (entries + 1) + i + 1),
			asset_type = .Note,
		}
		conv.assets[note.asset_id] = note
	}
	if allocation_mode == "1" || allocation_mode == "2" {
		if allocation_mode == "2" {
			for _, asset in conv.assets do if asset.asset_type == .TicketEntry {
				asset.preview = transmute([]byte)string(`{"version":1,"kind":"customer_reply","author":"alice"}`)
			}
		}
		tracker: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracker, backing)
		{
			context.allocator = mem.tracking_allocator(&tracker)
			for i in 0 ..< n do ticket_index_put(&conv, conv.assets[pr.AssetID(i * (entries + 1) + 1)])
			fmt.printf(
				"TICKET_INDEX_MEMORY tickets=%d entries=%d live_bytes=%d allocations=%d customers=%s\n",
				n,
				entries,
				tracker.current_memory_allocated,
				len(tracker.allocation_map),
				allocation_mode,
			)
			destroy_ticket_index(&conv)
		}
		testing.expect_value(t, len(tracker.allocation_map), 0)
		mem.tracking_allocator_destroy(&tracker)
		return
	}
	// Parent-last reconstruction exercises the existing parent index; this is
	// derived-state reconstruction time, not disk replay throughput.
	{
		context.allocator = backing
		start := clock.now_monotonic()._nsec
		for i in 0 ..< n do ticket_index_put(&conv, conv.assets[pr.AssetID(i * (entries + 1) + 1)])
		elapsed := clock.now_monotonic()._nsec - start
		fmt.printf("TICKET_INDEX_BUILD tickets=%d entries=%d ns=%d\n", n, entries, elapsed)
	}
	defer {context.allocator = backing; destroy_ticket_index(&conv)}
	// Measure index maintenance separately from reads. This excludes WAL/network
	// and asset allocation. The reply cycle includes removing the newest entry,
	// forcing the affected parent's extrema repair (the expensive write case).
	{
		context.allocator = backing
		entry := pr.Asset {
			asset_id    = pr.AssetID(n * (entries + 2) + 1),
			asset_type  = .TicketEntry,
			parent_type = .Asset,
			parent_id   = 1,
			created_at  = i64(entries + 2),
			preview     = transmute([]byte)string(`{"kind":"customer_reply"}`),
		}
		for reply_cycle in ([?]bool{false, true}) {
			rounds := 1
			for {
				start := clock.now_monotonic()._nsec
				for _ in 0 ..< rounds {
					if reply_cycle {
						conv.assets[entry.asset_id] = &entry; index_asset_parent(&conv, &entry)
						ticket_index_put(&conv, &entry)
						ticket_index_remove(&conv, &entry)
						remove_asset_parent_from_index(&conv, &entry); delete_key(&conv.assets, entry.asset_id)
						ticket_index_repair(&conv, 1)
					} else {
						ticket_index_remove(&conv, conv.assets[1], true)
						ticket_index_put(&conv, conv.assets[1])
					}
				}
				elapsed := clock.now_monotonic()._nsec - start
				testing.expect_value(t, len(conv.ticket_index[1].customers), 0)
				testing.expect_value(t, conv.ticket_index[1].reply, pr.AssetID(entries + 1))
				if elapsed >= 600_000_000 {
					fmt.printf("TICKET_INDEX_WRITE tickets=%d entries=%d reply_cycle=%v ns=%d\n", n, entries, reply_cycle, elapsed / i64(rounds))
					break
				}
				rounds *= 2
			}
		}
	}
	for indexed in ([?]bool{false, true}) {
		for full in ([?]bool{false, true}) {
			// Warm, then calibrate to >=0.6s. A single slow full scan can exceed it.
			_ = ticket_attention_bench_read(&conv, reads, indexed, full)
			rounds := 1
			for {
				start := clock.now_monotonic()._nsec
				checksum: u64
				for _ in 0 ..< rounds do checksum += ticket_attention_bench_read(&conv, reads, indexed, full)
				elapsed := clock.now_monotonic()._nsec - start
				due_count := (n + 9) / 10
				count := full ? due_count : min(due_count, 100)
				first := due_count - count
				expected := u64(count + 10 * (entries + 1) * (first + due_count - 1) * count / 2)
				testing.expect_value(t, checksum, expected * u64(rounds))
				if elapsed >= 600_000_000 {
					fmt.printf(
						"TICKET_ATTENTION tickets=%d entries=%d indexed=%v full=%v rounds=%d ns=%d\n",
						n,
						entries,
						indexed,
						full,
						rounds,
						elapsed / i64(rounds),
					)
					break
				}
				rounds *= 2
			}
		}
	}
}

ticket_attention_bench_read :: proc(conv: ^Conversation_State, reads: map[pr.AssetID]pr.AssetID, indexed, full: bool) -> (checksum: u64) {
	q := Ticket_Query {
		mode             = "attention",
		sort             = "id",
		descending       = true,
		limit            = 100,
		omit_total_count = indexed,
	}
	for {
		arena: virtual.Arena
		if virtual.arena_init_growing(&arena) != nil do return 0
		a := virtual.arena_allocator(&arena)
		page, assets := collect_ticket_page(conv, q, "alice", a, reads, now_ms = 1000)
		metadata, _ := json.marshal(page, allocator = a)
		msg := pr.TicketPage {
			metadata = metadata,
			assets   = assets[:],
		}
		buffer := make([]byte, pr.getSizeTicketPage(msg), a)
		_ = pr.serializeTicketPage(msg, buffer)
		for asset in assets do checksum += u64(asset.asset_id)
		more := full && page.has_more
		delete(q.cursor.id); delete(q.cursor.number); delete(q.cursor.text)
		q.cursor = {strings.clone(page.cursor.id), strings.clone(page.cursor.number), strings.clone(page.cursor.text)}
		virtual.arena_destroy(&arena)
		if !more do break
	}
	delete(q.cursor.id); delete(q.cursor.number); delete(q.cursor.text)
	return
}
