package main

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/cespare/xxhash/v2"
	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestWorkspacePlacement(t *testing.T) {
	for _, workers := range []int{1, 2, 3, 12} {
		counts := make([]int, workers)
		seen := map[string]bool{}
		for i, name := range workspaceNames("placement", 200, workers) {
			worker := int(xxhash.Sum64String(name)%256) % workers
			if worker != i%workers || seen[name] {
				t.Fatalf("bad placement %s on worker %d", name, worker)
			}
			seen[name] = true
			counts[worker]++
		}
		for _, n := range counts {
			if n < 200/workers || n > (200+workers-1)/workers {
				t.Fatalf("unbalanced: %v", counts)
			}
		}
	}
}

func TestIndependentVerdicts(t *testing.T) {
	c := config{P95: 250 * time.Millisecond, P99: time.Second, LagLimit: 100 * time.Millisecond, Recovery: 10 * time.Second}
	for _, tc := range []struct {
		name, metric, category, failed string
		duration                       time.Duration
	}{
		{"latency", "retained_send", "", "performance", 2 * time.Second},
		{"generator lag", "schedule_lag", "", "measurement_valid", 200 * time.Millisecond},
		{"rare operation lag", "schedule_lag_edit_note", "", "measurement_valid", 200 * time.Millisecond},
		{"lost broadcast", "", "delivery", "correctness", 0},
		{"disconnect", "", "reliability", "reliability", 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := newMeasurements()
			m.complete = true
			for _, name := range []string{"read_task", "read_note", "update_task", "edit_note", "retained_send", "ping", "schedule_lag"} {
				m.record(name, time.Millisecond)
			}
			if tc.category != "" {
				m.fail(tc.category, "injected")
			}
			if tc.metric != "" {
				m.record(tc.metric, tc.duration)
			}
			r := m.report(c)
			if r["passed"] == true {
				t.Fatal("false pass")
			}
			for key, passed := range r["verdicts"].(map[string]bool) {
				if passed == (key == tc.failed) {
					t.Fatalf("wrong %s verdict: %v", key, r)
				}
			}
		})
	}
	m := newMeasurements()
	m.complete = true
	m.fail("incomplete", "actor stopped early")
	if m.report(c)["passed"] == true {
		t.Fatal("incomplete run passed")
	}
}

func TestMissingWorkloadCannotPass(t *testing.T) {
	c := config{P95: time.Second, P99: time.Second, LagLimit: time.Second, Recovery: time.Second}
	for _, missing := range []string{"all", "read_note", "ping", "schedule_lag"} {
		m := newMeasurements()
		m.complete = true
		m.record("recovery", time.Millisecond)
		for _, name := range []string{"read_task", "read_note", "update_task", "edit_note", "retained_send", "ping", "schedule_lag"} {
			if missing != "all" && name != missing {
				m.record(name, time.Millisecond)
			}
		}
		r := m.report(c)
		if r["passed"] == true || r["verdicts"].(map[string]bool)["measurement_valid"] || len(r["missing_measurements"].([]string)) == 0 {
			t.Fatalf("missing %s accepted: %v", missing, r)
		}
	}
}

// Opt-in real-server contract tests exercise the CLI, not mock call ordering.
// A proxy drops a live event or corrupts history to prove the checker rejects bad delivery.
func TestCLIRealServer(t *testing.T) {
	serverBin := os.Getenv("NRC_SIM_SERVER_BIN")
	if serverBin == "" {
		t.Skip("set NRC_SIM_SERVER_BIN to an optimized NRC binary")
	}
	serverBin, err := filepath.Abs(serverBin)
	if err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(t.TempDir(), "sim")
	buildArgs := []string{"build", "-o", bin, "."}
	if os.Getenv("NRC_SIM_RACE") == "1" {
		buildArgs = []string{"build", "-race", "-o", bin, "."}
	}
	if out, err := exec.Command("go", buildArgs...).CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	for _, mode := range []string{"healthy", "drop-live", "corrupt-history", "ready-high", "ready-cutoff", "history-high", "history-cutoff", "history-cursor", "live-boundary", "duplicate-ack", "latency", "deadline", "disconnect"} {
		t.Run(mode, func(t *testing.T) {
			root := t.TempDir()
			for shard := 0; shard < 256; shard++ {
				p := filepath.Join(root, "data", "sharded-00000000000000000001", fmt.Sprintf("shard_%03d", shard))
				if err := os.MkdirAll(p, 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(p, "active.wal"), nil, 0600); err != nil {
					t.Fatal(err)
				}
			}
			manifest, err := base64.StdEncoding.DecodeString("TlJDTAABAAAAAAAAAAAAAQIBAAAAAAAAAAABAAABAACsNnTeRP92XA==")
			if err != nil {
				t.Fatal(err)
			}
			if err = os.WriteFile(filepath.Join(root, "data", "storage-layout.manifest"), manifest, 0600); err != nil {
				t.Fatal(err)
			}
			listener, err := net.Listen("tcp4", "0.0.0.0:0")
			if err != nil {
				t.Fatal(err)
			}
			_, port, _ := net.SplitHostPort(listener.Addr().String())
			addr := net.JoinHostPort("127.0.0.1", port)
			listener.Close()
			log, err := os.Create(filepath.Join(root, "server.log"))
			if err != nil {
				t.Fatal(err)
			}
			defer log.Close()
			server := exec.Command(serverBin)
			server.Dir = root
			for _, v := range os.Environ() {
				if !strings.HasPrefix(v, "NRC_") {
					server.Env = append(server.Env, v)
				}
			}
			server.Env = append(server.Env, "NRC_PORT="+port, "NRC_THREAD_COUNT=2", "NRC_DISABLE_CPU_AFFINITY=1", "NRC_MESSAGE_RETENTION=24h", "NRC_JWT_SECRET=test-simulator-secret", "NRC_LOG_LEVEL=error")
			server.Stdout = log
			server.Stderr = log
			if err = server.Start(); err != nil {
				t.Fatal(err)
			}
			defer func() {
				server.Process.Signal(os.Interrupt)
				done := make(chan error, 1)
				go func() { done <- server.Wait() }()
				select {
				case <-done:
				case <-time.After(20 * time.Second):
					server.Process.Kill()
					<-done
				}
			}()
			deadline := time.Now().Add(20 * time.Second)
			for {
				c, err := net.DialTimeout("tcp", addr, 100*time.Millisecond)
				if err == nil {
					c.Close()
					break
				}
				if time.Now().After(deadline) {
					logs, _ := os.ReadFile(filepath.Join(root, "server.log"))
					t.Fatalf("server startup timeout: %s", logs)
				}
				time.Sleep(50 * time.Millisecond)
			}
			var injected atomic.Bool
			var liveFrames atomic.Int64
			upgrader := websocket.Upgrader{}
			proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				up, _, err := websocket.DefaultDialer.Dial("ws://"+addr+r.URL.Path, http.Header{"X-Nrc-Auth": {r.Header.Get("X-Nrc-Auth")}})
				if err != nil {
					http.Error(w, err.Error(), 502)
					return
				}
				down, err := upgrader.Upgrade(w, r, nil)
				if err != nil {
					up.Close()
					return
				}
				defer up.Close()
				defer down.Close()
				go func() {
					defer up.Close()
					for {
						typ, wire, err := down.ReadMessage()
						if err != nil {
							return
						}
						if err = up.WriteMessage(typ, wire); err != nil {
							return
						}
					}
				}()
				for {
					typ, wire, err := up.ReadMessage()
					if err != nil {
						return
					}
					m, decodeErr := protocol.ReadMessage(wire)
					if decodeErr == nil && m.Opcode == protocol.S_AckSendMessage && mode == "duplicate-ack" && injected.CompareAndSwap(false, true) {
						if err = down.WriteMessage(typ, wire); err != nil {
							return
						}
						// Let the actor consume the first ACK before delivering its duplicate.
						time.Sleep(20 * time.Millisecond)
					}
					if decodeErr == nil && m.Opcode == protocol.S_SubscriptionReady && (mode == "ready-high" || mode == "ready-cutoff") {
						ready, err := protocol.DecodeSubscriptionReady(m.Data)
						if err == nil && len(ready.Entries) == 1 && ready.Entries[0].HighWaterSeq > 0 && injected.CompareAndSwap(false, true) {
							if mode == "ready-high" {
								binary.BigEndian.PutUint64(m.Data[14:], 0)
							} else {
								binary.BigEndian.PutUint64(m.Data[22:], 1)
							}
							wire, _ = m.Write()
						}
					}
					if decodeErr == nil && m.Opcode == protocol.S_AckSendMessage && mode == "deadline" && injected.CompareAndSwap(false, true) {
						time.Sleep(750 * time.Millisecond)
					}
					if decodeErr == nil && m.Opcode == protocol.S_MessagePage {
						page, err := protocol.DecodeMessagePage(m.Data)
						if err == nil && len(page.Messages) > 0 {
							offset := -1
							if page.CorrelationID != 0 {
								switch mode {
								case "history-high":
									offset = 11
								case "history-cutoff":
									offset = 19
								case "history-cursor":
									if !page.HasMore {
										offset = 27
									}
								}
							} else if mode == "live-boundary" {
								offset = 27
							}
							if offset >= 0 && injected.CompareAndSwap(false, true) {
								binary.BigEndian.PutUint64(m.Data[offset:], 0)
								wire, _ = m.Write()
							}
							// Let fixture setup finish; inject during measured activity.
							live := page.CorrelationID == 0 && liveFrames.Add(1) > 20
							if mode == "drop-live" && live && injected.CompareAndSwap(false, true) {
								continue
							}
							if mode == "disconnect" && live && injected.CompareAndSwap(false, true) {
								return
							}
							if mode == "corrupt-history" && page.CorrelationID != 0 && injected.CompareAndSwap(false, true) {
								wire[len(wire)-1] ^= 1
							}
						}
					}
					if err = down.WriteMessage(typ, wire); err != nil {
						return
					}
				}
			}))
			defer proxy.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			args := []string{"--disposable", "--server=" + "ws" + strings.TrimPrefix(proxy.URL, "http"), "--users=8", "--workspaces=2", "--workers=2", "--rooms=1", "--ramp=50ms", "--duration=1s", "--deadline=500ms", "--read-interval=30ms", "--mutation-interval=40ms", "--chat-interval=10ms", "--ping-interval=30ms", "--output=" + filepath.Join(root, "report.json"), "--trace=" + filepath.Join(root, "trace.jsonl")}
			if mode == "latency" {
				args = append(args, "--p95=1ns", "--p99=1ns")
			}
			cmd := exec.CommandContext(ctx, bin, args...)
			cmd.Env = append(os.Environ(), "NRC_SIM_JWT_SECRET=test-simulator-secret")
			out, runErr := cmd.CombinedOutput()
			data, err := os.ReadFile(filepath.Join(root, "report.json"))
			if err != nil {
				t.Fatalf("missing report: %v\n%s", err, out)
			}
			var report struct {
				Passed   bool
				Verdicts map[string]bool
				Counts   map[string]int64
				Failures map[string]int64
				Latency  map[string]struct {
					Samples int64
					Max     float64 `json:"max_ms"`
				}
			}
			if err = json.Unmarshal(data, &report); err != nil {
				t.Fatal(err)
			}
			if mode == "healthy" {
				if runErr != nil || !report.Passed || report.Counts["paginated_histories_verified"] != 2 || report.Counts["reconnect_checks"] != 2 {
					t.Fatalf("healthy run failed or did not exercise pagination/recovery: %v\n%s", runErr, out)
				}
				for _, op := range []string{"read_task", "read_note", "update_task", "edit_note", "retained_send", "ping"} {
					requests, lag, scheduled := report.Latency[op], report.Latency["schedule_lag_"+op], report.Latency["scheduled_"+op]
					if requests.Samples == 0 || lag.Samples != requests.Samples || scheduled.Samples != requests.Samples || scheduled.Max < requests.Max {
						t.Fatalf("invalid per-operation timing for %s: %v", op, report.Latency)
					}
				}
			} else {
				if mode != "latency" && !injected.Load() {
					t.Fatal("fault was never injected")
				}
				if runErr == nil || report.Passed {
					t.Fatalf("fault accepted: %s", out)
				}
				if (mode == "latency" || mode == "deadline") && report.Verdicts["performance"] {
					t.Fatal("latency gate failed to reject")
				}
				if mode == "corrupt-history" && report.Verdicts["correctness"] {
					t.Fatal("corrupt history passed")
				}
				category := map[string]string{"drop-live": "delivery", "corrupt-history": "correctness", "ready-high": "correctness", "ready-cutoff": "correctness", "history-high": "correctness", "history-cutoff": "correctness", "history-cursor": "correctness", "live-boundary": "correctness", "duplicate-ack": "correctness", "deadline": "performance", "disconnect": "reliability"}[mode]
				if category != "" && report.Failures[category] == 0 {
					t.Fatalf("fault failed for the wrong reason: %s", out)
				}
			}
		})
	}
}
