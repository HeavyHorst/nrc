package workspace_db

import "../clock"
import pr "../protocol"
import sql "../sqlite"
import "core:c"
import "core:sync"
import "core:time"

metrics_now :: proc() -> i64 {return time.to_unix_nanoseconds(clock.now_monotonic())}

metrics_observe :: proc(stats: ^pr.DatabaseStats, index: int, started: i64) {
	if stats == nil do return
	ns := u64(max(0, metrics_now() - started))
	bucket := pr.DB_STATS_BUCKETS - 1
	for bound, i in pr.DB_STATS_BOUNDS_NS {
		if ns <= bound {bucket = i; break}
	}
	sync.atomic_add(&stats.histograms[index].buckets[bucket], 1)
	sync.atomic_add(&stats.histograms[index].sum_ns, ns)
}

metrics_complete :: proc(port: ^Worker_Port, job: ^Completion) {
	metrics_observe(&port.metrics, job.lane * 3 + 2, job.admitted_at)
	sync.atomic_add(&port.metrics.counters[job.lane == 0 ? .Completed_Write : .Completed_Read], 1)
	if job.result.status != sql.OK {
		sync.atomic_add(&port.metrics.counters[.Errors], 1)
		if job.result.status & 255 == sql.BUSY do sync.atomic_add(&port.metrics.counters[.Busy], 1)
	}
}

// Called exclusively by the handle's executor, after a job/group. Resetting
// SQLite's counters prevents repeated counting of a shared shard connection.
metrics_cache :: proc(store: ^Store) {
	if store.db == nil || store.metrics == nil do return
	counters := [3]pr.DB_Counter{.Cache_Hits, .Cache_Misses, .Cache_Writes}
	for counter, i in counters {
		current, high: c.int
		if sql.db_status(store.db, c.int(7 + i), &current, &high, 1) == sql.OK {
			sync.atomic_add(&store.metrics.counters[counter], u64(max(0, current)))
		}
	}
}

// Only the worker owner may call this: credit gauges are worker-owned. Executor
// counters use atomic loads; a scrape is a live snapshot, not a transaction.
metrics_snapshot :: proc(port: ^Worker_Port) -> (result: pr.DatabaseStats) {
	port.metrics_sequence += 1
	result.sequence = port.metrics_sequence
	for _, i in result.counters do result.counters[i] = sync.atomic_load(&port.metrics.counters[i])
	for &hist, i in result.histograms {
		for &bucket, j in hist.buckets do bucket = sync.atomic_load(&port.metrics.histograms[i].buckets[j])
		hist.sum_ns = sync.atomic_load(&port.metrics.histograms[i].sum_ns)
	}
	e := port.executor
	result.counters[.In_Flight] = u64(port.in_flight)
	result.counters[.Charged_Bytes] = u64(port.charged_bytes)
	result.counters[.Capacity] = u64(e.capacity)
	result.counters[.Byte_Budget] = u64(e.byte_budget)
	result.counters[.Writer_In_Flight] = u64(port.writer_in_flight)
	result.counters[.Writer_Bytes] = u64(port.writer_charged_bytes)
	result.counters[.Read_Reserved_Requests] = u64(e.read_reserved_requests)
	result.counters[.Read_Reserved_Bytes] = u64(e.read_reserved_bytes)
	return
}
