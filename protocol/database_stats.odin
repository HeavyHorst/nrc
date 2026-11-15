package protocol

import "core:encoding/endian"

// Versioned, opt-in telemetry. All counters are worker-port scoped, never
// workspace/client labelled. Histogram buckets are disjoint on the wire.
DB_STATS_VERSION :: u8(2)
DB_STATS_COUNTERS :: 22
DB_STATS_HISTOGRAMS :: 8
DB_STATS_BUCKETS :: 14
DB_STATS_V1_SIZE :: 1 + 8 * (DB_STATS_COUNTERS + DB_STATS_HISTOGRAMS * (DB_STATS_BUCKETS + 1))
DB_STATS_SIZE :: DB_STATS_V1_SIZE + 24
database_stats_size :: proc(version: u8) -> int {return version == 1 ? DB_STATS_V1_SIZE : DB_STATS_SIZE}
DB_STATS_BOUNDS_NS :: [DB_STATS_BUCKETS - 1]u64 {
	50_000,
	100_000,
	250_000,
	500_000,
	1_000_000,
	2_500_000,
	5_000_000,
	10_000_000,
	25_000_000,
	50_000_000,
	100_000_000,
	250_000_000,
	1_000_000_000,
}

DB_Counter :: enum {
	In_Flight,
	Charged_Bytes,
	Capacity,
	Byte_Budget,
	Writer_In_Flight,
	Writer_Bytes,
	Read_Reserved_Requests,
	Read_Reserved_Bytes,
	Admitted_Write,
	Admitted_Read,
	Rejected_Connection,
	Rejected_Worker,
	Rejected_Unavailable,
	Errors,
	Busy,
	Group_Transactions,
	Group_Jobs,
	Cache_Hits,
	Cache_Misses,
	Cache_Writes,
	Completed_Write,
	Completed_Read,
}
DB_Histogram :: struct {
	buckets: [DB_STATS_BUCKETS]u64,
	sum_ns:  u64,
}
DatabaseStats :: struct {
	generation: [2]u64,
	sequence:   u64,
	counters:   [DB_Counter]u64,
	// Writer queue/execution/publication, reader queue/execution/publication,
	// projection finalization and SQL COMMIT (one sample per transaction).
	histograms: [DB_STATS_HISTOGRAMS]DB_Histogram,
}

serializeDatabaseStats :: proc(stats: DatabaseStats, data: []byte, version: u8 = DB_STATS_VERSION) {
	assert(len(data) == database_stats_size(version))
	data[0] = version == 1 ? u8(1) : DB_STATS_VERSION
	offset := 1
	if data[0] == DB_STATS_VERSION {
		for value in stats.generation {endian.put_u64(data[offset:], .Big, value); offset += 8}
		endian.put_u64(data[offset:], .Big, stats.sequence); offset += 8
	}
	for value in stats.counters {endian.put_u64(data[offset:], .Big, value); offset += 8}
	for hist in stats.histograms {
		for value in hist.buckets {endian.put_u64(data[offset:], .Big, value); offset += 8}
		endian.put_u64(data[offset:], .Big, hist.sum_ns); offset += 8
	}
}

parseDatabaseStats :: proc(data: []byte) -> (stats: DatabaseStats, err: ProtocolParseError) {
	if len(data) == 0 || (data[0] != 1 && data[0] != DB_STATS_VERSION) do return stats, .ContentLengthMismatch
	if len(data) != database_stats_size(data[0]) do return stats, .ContentLengthMismatch
	offset := 1
	if data[0] == DB_STATS_VERSION {
		for &value in stats.generation {value, _ = endian.get_u64(data[offset:], .Big); offset += 8}
		stats.sequence, _ = endian.get_u64(data[offset:], .Big); offset += 8
	}
	for &value in stats.counters {value, _ = endian.get_u64(data[offset:], .Big); offset += 8}
	for &hist in stats.histograms {
		for &value in hist.buckets {value, _ = endian.get_u64(data[offset:], .Big); offset += 8}
		hist.sum_ns, _ = endian.get_u64(data[offset:], .Big); offset += 8
	}
	return
}
