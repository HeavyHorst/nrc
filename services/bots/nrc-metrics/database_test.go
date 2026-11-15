package main

import (
	"bytes"
	"strings"
	"sync"
	"testing"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestDatabaseMetricsDeduplicationAndHistogram(t *testing.T) {
	c := NewCollector([]string{"a", "b", "old"}, 2, 2)
	stats := &protocol.DatabaseStats{}
	stats.Counters[15] = 7
	stats.Histograms[7].Buckets[0] = 2
	stats.Histograms[7].Buckets[2] = 3
	stats.Histograms[7].Buckets[13] = 1
	stats.Histograms[7].SumNS = 2_000_000_000
	for i, workspace := range []string{"a", "b"} {
		sample := *stats
		sample.Generation = [2]uint64{11, 22}
		sample.Sequence = uint64(i + 1)
		c.UpdatePong(workspace, protocol.StatsResponse{Timestamp: c.nextDatabasePoll(), ThreadID: 0, TotalThreads: 2, Database: &sample})
	}
	// A legacy v1 payload has counters but no ordering identity.
	c.UpdatePong("old", protocol.StatsResponse{ThreadID: 1, TotalThreads: 2, Database: stats})
	var out bytes.Buffer
	writeDatabaseMetrics(&out, c.ComputeState())
	text := out.String()
	for _, want := range []string{
		`# TYPE nrc_db_commit_seconds histogram`,
		`nrc_db_group_transactions_total{thread_id="0"} 7`,
		`nrc_db_commit_seconds_bucket{thread_id="0",le="0.0001"} 2`,
		`nrc_db_commit_seconds_bucket{thread_id="0",le="0.00025"} 5`,
		`nrc_db_commit_seconds_bucket{thread_id="0",le="+Inf"} 6`,
		`nrc_db_commit_seconds_count{thread_id="0"} 6`,
		`nrc_db_commit_seconds_sum{thread_id="0"} 2`,
		`nrc_db_metrics_available{thread_id="1"} 0`,
	} {
		if strings.Count(text, want+"\n") != 1 {
			t.Errorf("missing or duplicated %q\n%s", want, text)
		}
	}
	if strings.Contains(text, `nrc_db_commit_seconds_count{thread_id="1"}`) {
		t.Fatal("fabricated absent telemetry")
	}
	c.RemoveWorkspace("a")
	c.RemoveWorkspace("b")
	out.Reset()
	writeDatabaseMetrics(&out, c.ComputeState())
	if strings.Contains(out.String(), `thread_id="0"`) {
		t.Fatal("stale disconnected worker")
	}
}

func TestDatabaseMetricsDisconnectDoesNotReplayOlderSample(t *testing.T) {
	c := NewCollector([]string{"a", "b"}, 1, 1)
	generation := [2]uint64{11, 22}
	var sequence uint64
	update := func(workspace string, value uint64) {
		sequence++
		stats := &protocol.DatabaseStats{Generation: generation, Sequence: sequence}
		stats.Counters[15] = value
		stats.Histograms[7].Buckets[0] = value
		stats.Histograms[7].SumNS = value * 1000
		c.UpdatePong(workspace, protocol.StatsResponse{Timestamp: c.nextDatabasePoll(), ThreadID: 0, TotalThreads: 1, Database: stats})
	}
	scrape := func() string {
		var out bytes.Buffer
		writeDatabaseMetrics(&out, c.ComputeState())
		return out.String()
	}
	update("b", 90)
	update("a", 100)
	if !strings.Contains(scrape(), "nrc_db_group_transactions_total{thread_id=\"0\"} 100\n") {
		t.Fatal("missing current sample")
	}
	c.RemoveWorkspace("a")
	text := scrape()
	if strings.Contains(text, `nrc_db_group_transactions_total{thread_id="0"}`) || strings.Contains(text, `nrc_db_commit_seconds_count{thread_id="0"}`) {
		t.Fatal("replayed older counters/histogram after source disconnect")
	}
	if !strings.Contains(text, "nrc_db_metrics_available{thread_id=\"0\"} 0\n") {
		t.Fatal("stale sample must be unavailable")
	}
	update("b", 105)
	if !strings.Contains(scrape(), "nrc_db_group_transactions_total{thread_id=\"0\"} 105\n") {
		t.Fatal("new sample did not resume telemetry")
	}
	// Remove the last source as well. Reconnection must not forget the
	// accepted sequence, even though no workspace sample remains.
	c.SetConnected("b", false)
	c.RemoveWorkspace("b")
	c.SetConnected("b", true)
	for _, stale := range []uint64{sequence, sequence - 1} {
		stats := &protocol.DatabaseStats{Generation: generation, Sequence: stale}
		stats.Counters[15] = 999
		stats.Histograms[7].Buckets[0] = 999
		c.UpdatePong("b", protocol.StatsResponse{Timestamp: c.nextDatabasePoll(), ThreadID: 0, TotalThreads: 1, Database: stats})
		text = scrape()
		if strings.Contains(text, `nrc_db_group_transactions_total{thread_id="0"}`) || strings.Contains(text, `nrc_db_commit_seconds_count{thread_id="0"}`) {
			t.Fatalf("replayed sequence %d after complete disconnect", stale)
		}
	}
	update("b", 106) // N+1 must resume both counters and histograms.
	text = scrape()
	if !strings.Contains(text, "nrc_db_group_transactions_total{thread_id=\"0\"} 106\n") || !strings.Contains(text, "nrc_db_commit_seconds_count{thread_id=\"0\"} 106\n") {
		t.Fatal("fresh sample did not resume telemetry after complete disconnect")
	}
	// Real server restart: smaller values in a newer sample must remain visible.
	generation = [2]uint64{33, 44}
	sequence = 0
	update("b", 2)
	text = scrape()
	if !strings.Contains(text, "nrc_db_group_transactions_total{thread_id=\"0\"} 2\n") || !strings.Contains(text, "nrc_db_commit_seconds_count{thread_id=\"0\"} 2\n") {
		t.Fatal("masked real server reset")
	}
}

func TestDatabaseSampleOrderingAndGenerationFence(t *testing.T) {
	c := NewCollector([]string{"a", "b"}, 2, 2)
	old, current, restart := [2]uint64{10, 1}, [2]uint64{20, 2}, [2]uint64{30, 3}
	response := func(poll int64, generation [2]uint64, worker uint32, sequence, value uint64) protocol.StatsResponse {
		db := &protocol.DatabaseStats{Generation: generation, Sequence: sequence}
		db.Counters[15] = value
		db.Histograms[7].Buckets[0] = value
		return protocol.StatsResponse{Timestamp: poll, ThreadID: worker, TotalThreads: 2, Database: db}
	}
	check := func(worker uint32, generation [2]uint64, sequence, value uint64) {
		t.Helper()
		db := c.ComputeState().ThreadSamples[worker].Pong.Database
		if db == nil || db.Generation != generation || db.Sequence != sequence || db.Counters[15] != value || db.Histograms[7].Buckets[0] != value {
			t.Fatalf("worker %d: unexpected sample %+v", worker, db)
		}
	}
	// Both requests predate the first accepted generation. The older process's
	// first-ever reply arrives last; even an unseen epoch must not win.
	oldPoll, firstPoll := c.nextDatabasePoll(), c.nextDatabasePoll()
	c.UpdatePong("a", response(firstPoll, current, 0, 100, 100))
	c.UpdatePong("b", response(oldPoll, old, 0, 999, 999))
	check(0, current, 100, 100)
	p1, p2 := c.nextDatabasePoll(), c.nextDatabasePoll()
	c.UpdatePong("a", response(p2, current, 0, 102, 110))
	c.UpdatePong("a", response(p1, current, 0, 101, 105))
	c.UpdatePong("b", response(p2, current, 0, 102, 999)) // duplicate cannot overwrite
	check(0, current, 102, 110)
	c.UpdatePong("b", response(c.nextDatabasePoll(), current, 1, 50, 500))
	check(1, current, 50, 500)
	// A restart resets order/counters, and invalidates other workers' old DBs.
	c.UpdatePong("a", response(c.nextDatabasePoll(), restart, 0, 1, 2))
	check(0, restart, 1, 2)
	if c.ComputeState().ThreadSamples[1].Pong.Database != nil {
		t.Fatal("mixed process generations")
	}
	c.UpdatePong("b", response(c.nextDatabasePoll(), current, 1, 9999, 9999))
	if c.ComputeState().ThreadSamples[1].Pong.Database != nil {
		t.Fatal("revived retired process")
	}
	c.UpdatePong("b", response(c.nextDatabasePoll(), restart, 1, 1, 3))
	check(1, restart, 1, 3)
	// An unseen old process still cannot win after another restart.
	late := response(firstPoll, old, 0, 10000, 10000)
	c.UpdatePong("a", late)
	check(0, restart, 1, 2)
	// A genuine new process on a pre-transition poll is also deferred;
	// the next fresh request confirms it without requiring higher counters.
	c.UpdatePong("a", response(firstPoll, [2]uint64{40, 4}, 0, 1, 1))
	check(0, restart, 1, 2)
	c.UpdatePong("a", response(c.nextDatabasePoll(), [2]uint64{40, 4}, 0, 1, 1))
	check(0, [2]uint64{40, 4}, 1, 1)

	// Replies from three process incarnations are outstanding together.
	// Poll allocation precedes sending, so another connection's B poll can
	// have a larger token than C's while still reaching the older process.
	genA, genB, genC, genD := [2]uint64{40, 4}, [2]uint64{50, 5}, [2]uint64{60, 6}, [2]uint64{70, 7}
	pollA, pollB, pollC, latePollB := c.nextDatabasePoll(), c.nextDatabasePoll(), c.nextDatabasePoll(), c.nextDatabasePoll()
	c.UpdatePong("a", response(pollC, genC, 0, 1, 7))
	check(0, genC, 1, 7)
	c.UpdatePong("b", response(pollA, genA, 0, 100, 100))
	check(0, genC, 1, 7)
	c.UpdatePong("b", response(pollB, genB, 0, 200, 200))
	check(0, genC, 1, 7)
	// The fence must cover all issued polls, not just pollC's token.
	c.UpdatePong("b", response(latePollB, genB, 0, 201, 201))
	check(0, genC, 1, 7)
	c.UpdatePong("a", response(c.nextDatabasePoll(), genD, 0, 1, 1))
	check(0, genD, 1, 1)
}

func TestDatabaseConcurrentOutOfOrderSamples(t *testing.T) {
	c := NewCollector([]string{"a"}, 1, 1)
	var wg sync.WaitGroup
	for sequence := uint64(1); sequence <= 32; sequence++ {
		poll := c.nextDatabasePoll()
		wg.Add(1)
		go func(sequence uint64, poll int64) {
			defer wg.Done()
			c.UpdatePong("a", protocol.StatsResponse{Timestamp: poll, ThreadID: 0, TotalThreads: 1, Database: &protocol.DatabaseStats{Generation: [2]uint64{1, 2}, Sequence: sequence}})
		}(sequence, poll)
	}
	wg.Wait()
	if got := c.ComputeState().ThreadSamples[0].Pong.Database; got == nil || got.Sequence != 32 {
		t.Fatalf("latest sequence lost: %+v", got)
	}
}
