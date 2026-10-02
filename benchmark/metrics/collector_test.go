package metrics

import (
	"errors"
	"testing"
	"time"

	"hegel.dev/go/hegel"
)

func TestCollectorSeparatesSteadyStateFromTeardown(t *testing.T) {
	hegel.Test(t, func(ht *hegel.T) {
		connections := int(hegel.Draw(ht, hegel.Integers[uint8](0, 255)))
		steadyDisconnects := 0
		if connections > 0 {
			steadyDisconnects = hegel.Draw(ht, hegel.Integers[int](0, connections))
		}
		steadyErrors := int(hegel.Draw(ht, hegel.Integers[uint8](0, 255)))
		teardownDisconnects := int(hegel.Draw(ht, hegel.Integers[uint8](0, 255)))
		teardownErrors := int(hegel.Draw(ht, hegel.Integers[uint8](0, 255)))

		collector := NewCollector()
		collector.Start()
		for range connections {
			collector.RecordConnect(time.Microsecond)
		}
		for range steadyDisconnects {
			collector.RecordUnexpectedDisconnect(errors.New("steady disconnect"), false)
		}
		for range steadyErrors {
			collector.RecordError(errors.New("steady"))
		}

		before := collector.Snapshot()
		if before.ActiveConnections != uint64(connections-steadyDisconnects) {
			ht.Fatalf("active connections: got %d, want %d", before.ActiveConnections, connections-steadyDisconnects)
		}
		if before.SteadyStateDisconnects != uint64(steadyDisconnects) || before.TotalErrors != uint64(steadyErrors) {
			ht.Fatalf("steady counters: got disconnects=%d errors=%d, want disconnects=%d errors=%d",
				before.SteadyStateDisconnects, before.TotalErrors, steadyDisconnects, steadyErrors)
		}

		boundary := collector.EndSteadyState()
		if boundary.SteadyStateDisconnects != before.SteadyStateDisconnects {
			ht.Fatalf("boundary changed steady disconnects: before=%d boundary=%d", before.SteadyStateDisconnects, boundary.SteadyStateDisconnects)
		}
		for range teardownDisconnects {
			collector.RecordUnexpectedDisconnect(errors.New("teardown disconnect"), false)
		}
		for range teardownErrors {
			collector.RecordError(errors.New("teardown"))
		}

		after := collector.Snapshot()
		if after.SteadyStateDisconnects != before.SteadyStateDisconnects || after.TotalErrors != before.TotalErrors {
			ht.Fatalf("teardown changed steady counters: before=%+v after=%+v", before, after)
		}
		if after.TeardownDisconnects != uint64(teardownDisconnects) || after.TeardownErrors != uint64(teardownErrors) {
			ht.Fatalf("teardown counters: got disconnects=%d errors=%d, want disconnects=%d errors=%d",
				after.TeardownDisconnects, after.TeardownErrors, teardownDisconnects, teardownErrors)
		}
	})
}

func TestCollectorClassifiesTerminalReadAtomically(t *testing.T) {
	collector := NewCollector()
	collector.RecordConnect(time.Microsecond)
	collector.RecordUnexpectedDisconnect(errors.New("steady terminal read"), true)

	steady := collector.EndSteadyState()
	if steady.ActiveConnections != 0 || steady.SteadyStateDisconnects != 1 || steady.TotalErrors != 1 {
		t.Fatalf("steady terminal read was not classified together: %+v", steady)
	}

	collector.RecordUnexpectedDisconnect(errors.New("teardown terminal read"), true)
	teardown := collector.Snapshot()
	if teardown.SteadyStateDisconnects != 1 || teardown.TotalErrors != 1 || teardown.TeardownDisconnects != 1 || teardown.TeardownErrors != 1 {
		t.Fatalf("teardown terminal read changed steady-state classification: %+v", teardown)
	}
}
