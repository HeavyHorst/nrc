package workspace_db

import sql "../sqlite"
import "core:fmt"
import "core:mem/virtual"
import "core:testing"

@(test)
test_monitor_delivery_leases_fifo_and_reopen :: proc(t: ^testing.T) {
	dir, path := test_database_path(t); if path == nil do return
	defer test_remove_database(dir, path)
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	store, rc := open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	// Use the same valid asset fixture as production's foreign-key contract.
	testing.expect_value(
		t,
		sql.exec(store.db, `INSERT INTO assets VALUES(x'77',x'0000000000000007',0,0,zeroblob(8),x'',1,1,0,0,x'',x'')`, nil, nil, nil),
		sql.OK,
	)
	context.allocator = virtual.arena_allocator(&arena)
	testing.expect_value(t, begin(&store), sql.OK)
	testing.expect_value(
		t,
		sql.exec(
			store.db,
			"INSERT INTO monitor_delivery_lanes(workspace,monitor_id,stream,route) VALUES(x'77',x'0000000000000007',1,x'6f70732d7631')",
			nil,
			nil,
			nil,
		),
		sql.OK,
	)
	for route in ([]string{"ops-v1", "ops-v1", "other-v1"}) {
		testing.expect_value(t, enqueue_monitor_delivery(&store, "w", 7, 1, route, 1, transmute([]byte)string(`{"state":"firing"}`)), sql.OK)
	}
	testing.expect_value(t, commit(&store), sql.OK)
	testing.expect_value(t, close(&store), sql.OK)
	store, rc = open(path)
	if !testing.expect_value(t, rc, sql.OK) do return
	testing.expect_value(t, begin(&store), sql.OK)
	first, state, status := act_on_monitor_delivery(&store, "w", 7, 1, "ops-v1", "a", "one", 1, 0, 0, 2)
	testing.expect(t, status == sql.OK && state == 2 && first.generation == 1 && first.attempts == 1)
	repeated, s, e := act_on_monitor_delivery(&store, "w", 7, 1, "ops-v1", "a", "one", 1, 0, 0, 3)
	testing.expect(t, e == sql.OK && s == 2 && repeated.id == first.id && repeated.lease_until == first.lease_until)
	_, s, e = act_on_monitor_delivery(&store, "w", 7, 1, "ops-v1", "a", "two", 1, 0, 0, 3)
	testing.expect(t, e == sql.OK && s == 1)
	_, s, e = act_on_monitor_delivery(&store, "other", 7, 1, "ops-v1", "a", "one", 1, 0, 0, 3)
	testing.expect(t, e == sql.OK && s == 0)
	_, s, e = act_on_monitor_delivery(&store, "w", 7, 1, "other-v1", "b", "two", 1, 0, 0, 3)
	testing.expect(t, e == sql.OK && s == 2)
	new, retry, waiting, dead, next: Monitor_Delivery
	new, s, e = act_on_monitor_delivery(&store, "w", 7, 1, "ops-v1", "b", "two", 1, 0, 0, first.lease_until)
	testing.expect(t, e == sql.OK && s == 2 && new.id == first.id && new.generation == 2 && new.attempts == 2)
	_, _, e = act_on_monitor_delivery(&store, "w", 7, 1, "ops-v1", "a", "one", 2, first.id, first.generation, first.lease_until + 1)
	testing.expect_value(t, e, sql.CONSTRAINT)
	retry, s, e = act_on_monitor_delivery(&store, "w", 7, 1, "ops-v1", "b", "two", 3, new.id, new.generation, first.lease_until + 1)
	testing.expect(t, e == sql.OK && s == 4 && retry.available_at == first.lease_until + 1 + 4_000_000_000)
	_, s, e = act_on_monitor_delivery(&store, "w", 7, 1, "ops-v1", "b", "two", 3, new.id, new.generation, first.lease_until + 2)
	testing.expect(t, e == sql.OK && s == 4)
	waiting, s, e = act_on_monitor_delivery(&store, "w", 7, 1, "ops-v1", "b", "two", 1, 0, 0, retry.available_at - 1)
	testing.expect(t, e == sql.OK && s == 1 && waiting.id == first.id)
	new, s, e = act_on_monitor_delivery(&store, "w", 7, 1, "ops-v1", "b", "two", 1, 0, 0, retry.available_at)
	testing.expect(t, e == sql.OK && s == 2 && new.generation == 3)
	_, s, e = act_on_monitor_delivery(&store, "w", 7, 1, "ops-v1", "b", "two", 4, new.id, new.generation, retry.available_at + 1)
	testing.expect(t, e == sql.OK && s == 4)
	dead, s, e = act_on_monitor_delivery(&store, "w", 7, 1, "ops-v1", "b", "two", 1, 0, 0, retry.available_at + 2)
	testing.expect(t, e == sql.OK && s == 3 && dead.id == first.id)
	_, s, e = act_on_monitor_delivery(&store, "w", 7, 1, "ops-v1", "b", "two", 5, dead.id, dead.generation, retry.available_at + 3)
	testing.expect(t, e == sql.OK && s == 4)
	next, s, e = act_on_monitor_delivery(&store, "w", 7, 1, "ops-v1", "b", "two", 1, 0, 0, retry.available_at + 4)
	testing.expect(t, e == sql.OK && s == 2 && next.id != first.id)
	_, s, e = act_on_monitor_delivery(&store, "w", 7, 1, "ops-v1", "b", "two", 2, next.id, next.generation, retry.available_at + 5)
	testing.expect(t, e == sql.OK && s == 4)
	_, s, e = act_on_monitor_delivery(&store, "w", 7, 1, "ops-v1", "b", "two", 2, next.id, next.generation, retry.available_at + 6)
	testing.expect(t, e == sql.OK && s == 4)
	// Crashed workers consume the same ten-attempt budget as explicit retries.
	for attempt in 2 ..= 11 {
		row, attempt_state, attempt_rc := act_on_monitor_delivery(&store, "w", 7, 1, "other-v1", "b", "two", 1, 0, 0, 3 + i64(attempt - 1) * 60_000_000_000)
		testing.expect(t, attempt_rc == sql.OK && attempt_state == (attempt == 11 ? u8(3) : u8(2)) && row.attempts == min(i64(attempt), 10))
	}
	// The removed measurement-export stream cannot be recreated through storage APIs.
	testing.expect_value(t, enqueue_monitor_delivery(&store, "w", 7, 0, "", 1, transmute([]byte)string("{}")), sql.CONSTRAINT)
	testing.expect_value(t, commit(&store), sql.OK)
	count, count_rc := scalar(&store, "SELECT entries FROM monitor_queue_usage WHERE stream=1")
	testing.expect(t, count_rc == sql.OK && count == 1)
}

@(test)
test_monitor_delivery_bounded_queues :: proc(t: ^testing.T) {
	dir, path := test_database_path(t); if path == nil do return
	defer test_remove_database(dir, path)
	store, rc := open(path, create = true)
	if !testing.expect_value(t, rc, sql.OK) do return
	defer close(&store)
	testing.expect_value(
		t,
		sql.exec(store.db, `INSERT INTO assets VALUES(x'77',x'0000000000000007',0,0,zeroblob(8),x'',1,1,0,0,x'',x'')`, nil, nil, nil),
		sql.OK,
	)
	for stream in 1 ..< 2 {
		for byte_limit in ([2]bool{false, true}) {
			count := byte_limit ? 512 : 10000
			width := byte_limit ? 32768 : 1
			route := "ops-v1"
			testing.expect_value(t, begin(&store), sql.OK)
			query := fmt.caprintf(
				`WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<%d)
 INSERT INTO monitor_deliveries(workspace,monitor_id,stream,route,id,body,created_at,available_at)
 SELECT x'77',x'0000000000000007',%d,CAST('%s' AS BLOB),CAST(printf('%%08d',i) AS BLOB),zeroblob(%d),1,1 FROM n`,
				count,
				stream,
				route,
				width,
			)
			testing.expect_value(t, sql.exec(store.db, query, nil, nil, nil), sql.OK)
			delete(query)
			body := [1]byte{'x'}
			testing.expect_value(t, enqueue_monitor_delivery(&store, "w", 7, u8(stream), route, 2, body[:]), sql.CONSTRAINT)
			entries, status := scalar(&store, "SELECT sum(entries) FROM monitor_queue_usage")
			testing.expect(t, status == sql.OK && entries == i64(count))
			testing.expect_value(t, rollback(&store), sql.OK)
			entries, status = scalar(&store, "SELECT count(*) FROM monitor_deliveries")
			testing.expect(t, status == sql.OK && entries == 0)
			entries, status = scalar(&store, "SELECT count(*) FROM monitor_queue_usage")
			testing.expect(t, status == sql.OK && entries == 0)
		}
	}
}
