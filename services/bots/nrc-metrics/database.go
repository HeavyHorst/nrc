package main

import (
	"fmt"
	"io"
	"strconv"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

var databaseCounterNames = [...]string{
	"in_flight", "charged_bytes", "capacity", "byte_budget",
	"writer_in_flight", "writer_bytes", "read_reserved_requests", "read_reserved_bytes",
	"admitted_write_total", "admitted_read_total",
	"rejected_connection_total", "rejected_worker_total", "rejected_unavailable_total",
	"errors_total", "busy_total", "group_transactions_total", "group_jobs_total",
	"cache_hits_total", "cache_misses_total", "cache_writes_total",
	"completed_write_total", "completed_read_total",
}

var databaseHistogramNames = [...]string{
	"writer_queue", "writer_execution", "writer_publication",
	"reader_queue", "reader_execution", "reader_publication",
	"projection_finalize", "commit",
}

// The timestamp field is an opaque echoed token. A collector-local serial
// fences outstanding polls without trusting wall clocks or counter values.
func (c *Collector) nextDatabasePoll() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.databasePoll++
	return c.databasePoll
}

// Caller holds c.mu. One collector targets one NRC process, not a load-balanced
// pool. Generation switches invalidate every worker's old DB sample together.
func (c *Collector) acceptDatabaseSample(pong *protocol.StatsResponse) bool {
	db := pong.Database
	if db == nil {
		return true
	}
	if db.Generation == [2]uint64{} || db.Sequence == 0 {
		// Legacy v1 remains decodable, but cannot provide ordered telemetry.
		pong.Database = nil
		return true
	}
	if pong.Timestamp <= 0 || pong.Timestamp > c.databasePoll {
		return false
	}
	if _, retired := c.retiredGenerations[db.Generation]; retired {
		return false
	}
	if db.Generation != c.databaseGeneration {
		// A previously unseen incarnation on an already outstanding poll may
		// be older than the current one. Require a post-transition request.
		if pong.Timestamp <= c.generationFence {
			return false
		}
		if c.databaseGeneration != [2]uint64{} {
			c.retiredGenerations[c.databaseGeneration] = struct{}{}
		}
		c.databaseGeneration = db.Generation
		c.generationFence = c.databasePoll
		clear(c.databaseSequences)
		for workspace, sample := range c.samples {
			sample.Pong.Database = nil
			c.samples[workspace] = sample
		}
	}
	if db.Sequence <= c.databaseSequences[pong.ThreadID] {
		return false
	}
	c.databaseSequences[pong.ThreadID] = db.Sequence
	return true
}

// ComputeState deduplicates by worker, including when multiple monitoring
// workspaces land on the same worker. Do not publish executor-global counters
// once per worker. Missing telemetry is absent, not a fabricated zero sample.
func writeDatabaseMetrics(w io.Writer, state CollectorState) {
	fmt.Fprintln(w, "# TYPE nrc_db_metrics_available gauge")
	for _, id := range state.CoveredThreadIDs {
		available := 0
		if state.ThreadSamples[id].Pong.Database != nil {
			available = 1
		}
		fmt.Fprintf(w, "nrc_db_metrics_available{thread_id=%q} %d\n", strconv.FormatUint(uint64(id), 10), available)
	}
	for index, suffix := range databaseCounterNames {
		kind := "counter"
		if index < 8 {
			kind = "gauge"
		}
		name := "nrc_db_" + suffix
		fmt.Fprintf(w, "# TYPE %s %s\n", name, kind)
		for _, id := range state.CoveredThreadIDs {
			if stats := state.ThreadSamples[id].Pong.Database; stats != nil {
				fmt.Fprintf(w, "%s{thread_id=%q} %d\n", name, strconv.FormatUint(uint64(id), 10), stats.Counters[index])
			}
		}
	}
	for index, suffix := range databaseHistogramNames {
		name := "nrc_db_" + suffix + "_seconds"
		fmt.Fprintf(w, "# TYPE %s histogram\n", name)
		for _, id := range state.CoveredThreadIDs {
			stats := state.ThreadSamples[id].Pong.Database
			if stats == nil {
				continue
			}
			thread := strconv.FormatUint(uint64(id), 10)
			hist := stats.Histograms[index]
			var count uint64
			for bucket, value := range hist.Buckets {
				count += value
				bound := "+Inf"
				if bucket < len(protocol.DatabaseBoundsNS) {
					bound = strconv.FormatFloat(float64(protocol.DatabaseBoundsNS[bucket])/1e9, 'g', -1, 64)
				}
				fmt.Fprintf(w, "%s_bucket{thread_id=%q,le=%q} %d\n", name, thread, bound, count)
			}
			fmt.Fprintf(w, "%s_sum{thread_id=%q} %g\n%s_count{thread_id=%q} %d\n", name, thread, float64(hist.SumNS)/1e9, name, thread, count)
		}
	}
}
