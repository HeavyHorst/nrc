package main

import (
	"strings"
	"sync"
	"time"

	"github.com/HdrHistogram/hdrhistogram-go"
)

type measurements struct {
	mu       sync.Mutex
	hist     map[string]*hdrhistogram.Histogram
	failures map[string]int64
	examples []string
	counts   map[string]int64
	complete bool
}

func newMeasurements() *measurements {
	return &measurements{hist: make(map[string]*hdrhistogram.Histogram), failures: make(map[string]int64), counts: make(map[string]int64)}
}
func (m *measurements) fail(category, detail string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.failures[category]++
	if len(m.examples) < 30 {
		m.examples = append(m.examples, category+": "+detail)
	}
}
func (m *measurements) count(name string, n int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.counts[name] += n
}
func (m *measurements) record(name string, d time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	h := m.hist[name]
	if h == nil {
		h = hdrhistogram.New(1, int64(time.Hour/time.Microsecond), 3)
		m.hist[name] = h
	}
	if err := h.RecordValue(max(1, d.Microseconds())); err != nil {
		m.failures["performance"]++
	}
}

func (m *measurements) report(c config) map[string]any {
	m.mu.Lock()
	defer m.mu.Unlock()
	latency := map[string]any{}
	complete := m.complete && m.failures["incomplete"] == 0
	performance := m.failures["performance"] == 0
	valid := m.failures["invalid"] == 0 && complete
	missing := []string{}
	for _, name := range []string{"read_task", "read_note", "update_task", "edit_note", "retained_send", "ping", "schedule_lag"} {
		if h := m.hist[name]; h == nil || h.TotalCount() == 0 {
			missing = append(missing, name)
			valid = false
		}
	}
	for name, h := range m.hist {
		p95, p99 := time.Duration(h.ValueAtQuantile(95))*time.Microsecond, time.Duration(h.ValueAtQuantile(99))*time.Microsecond
		latency[name] = map[string]any{"samples": h.TotalCount(), "p50_ms": float64(h.ValueAtQuantile(50)) / 1000, "p95_ms": float64(p95) / float64(time.Millisecond), "p99_ms": float64(p99) / float64(time.Millisecond), "max_ms": float64(h.Max()) / 1000}
		if strings.HasPrefix(name, "schedule_lag") {
			valid = valid && p99 <= c.LagLimit
		} else if strings.HasPrefix(name, "scheduled_") {
			// Diagnostic intended-arrival latency; request SLOs exclude scheduling lag.
		} else if name == "recovery" {
			performance = performance && time.Duration(h.Max())*time.Microsecond <= c.Recovery
		} else {
			performance = performance && p95 <= c.P95 && p99 <= c.P99
		}
	}
	correct := complete && m.failures["correctness"] == 0 && m.failures["delivery"] == 0
	reliable := complete && m.failures["reliability"] == 0 && m.failures["unknown"] == 0
	verdict := map[string]bool{"correctness": correct, "reliability": reliable, "performance": performance && complete, "measurement_valid": valid}
	return map[string]any{"config": c, "complete": complete, "passed": correct && reliable && performance && valid, "verdicts": verdict, "failures": m.failures, "failure_examples": m.examples, "missing_measurements": missing, "counts": m.counts, "latency": latency}
}
