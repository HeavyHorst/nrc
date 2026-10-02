package main

import (
	"flag"
	"fmt"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

type run_config struct {
	server_url        string
	workspace_prefix  string
	total_connections int
	concurrency       int
	wait_ready        bool
	hold_duration     time.Duration
	read_timeout      time.Duration
	write_timeout     time.Duration
}

func main() {
	cfg := parse_flags()

	fmt.Println("=== NRC Accept Benchmark (Simple) ===")
	fmt.Printf("server:        %s\n", cfg.server_url)
	fmt.Printf("connections:   %d\n", cfg.total_connections)
	fmt.Printf("concurrency:   %d\n", cfg.concurrency)
	fmt.Printf("wait-ready:    %v\n", cfg.wait_ready)
	fmt.Printf("hold-duration: %v\n", cfg.hold_duration)
	fmt.Println()

	jobs := make(chan int, cfg.concurrency)
	latencies := make([]time.Duration, 0, cfg.total_connections)
	var lat_mu sync.Mutex

	var success_count atomic.Uint64
	var fail_count atomic.Uint64

	start := time.Now()
	var wg sync.WaitGroup
	for worker := 0; worker < cfg.concurrency; worker++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for idx := range jobs {
				latency, ok := connect_once(cfg, idx)
				if !ok {
					fail_count.Add(1)
					continue
				}

				success_count.Add(1)
				lat_mu.Lock()
				latencies = append(latencies, latency)
				lat_mu.Unlock()
			}
		}()
	}

	for i := 0; i < cfg.total_connections; i++ {
		jobs <- i
	}
	close(jobs)
	wg.Wait()
	elapsed := time.Since(start)

	print_summary(cfg, elapsed, latencies, success_count.Load(), fail_count.Load())
}

func parse_flags() run_config {
	server_url := flag.String("server", "ws://localhost:8080", "WebSocket server URL")
	workspace_prefix := flag.String("workspace-prefix", "acc-bench", "Workspace ID prefix")
	total_connections := flag.Int("connections", 10000, "Total connection attempts")
	concurrency := flag.Int("concurrency", 256, "Concurrent dial workers")
	wait_ready := flag.Bool("wait-ready", true, "Wait for first server frame (S_ServerReady) before counting success")
	hold_duration := flag.Duration("hold", 0, "Keep each successful connection open for this duration before close")
	read_timeout := flag.Duration("read-timeout", 5*time.Second, "Read timeout when waiting for server frame")
	write_timeout := flag.Duration("write-timeout", 2*time.Second, "Write timeout for close control frame")
	flag.Parse()

	if *total_connections <= 0 {
		*total_connections = 1
	}
	if *concurrency <= 0 {
		*concurrency = 1
	}

	return run_config{
		server_url:        strings.TrimRight(*server_url, "/"),
		workspace_prefix:  *workspace_prefix,
		total_connections: *total_connections,
		concurrency:       *concurrency,
		wait_ready:        *wait_ready,
		hold_duration:     *hold_duration,
		read_timeout:      *read_timeout,
		write_timeout:     *write_timeout,
	}
}

func connect_once(cfg run_config, idx int) (time.Duration, bool) {
	workspace_id := fmt.Sprintf("%s-%d", cfg.workspace_prefix, idx)
	url := fmt.Sprintf("%s/%s", cfg.server_url, workspace_id)

	dialer := websocket.Dialer{
		HandshakeTimeout: 10 * time.Second,
		ReadBufferSize:   64 * 1024,
		WriteBufferSize:  64 * 1024,
	}

	started := time.Now()
	conn, _, err := dialer.Dial(url, nil)
	if err != nil {
		return 0, false
	}

	if cfg.wait_ready {
		_ = conn.SetReadDeadline(time.Now().Add(cfg.read_timeout))
		_, _, err = conn.ReadMessage()
		if err != nil {
			_ = conn.Close()
			return 0, false
		}
	}

	latency := time.Since(started)

	if cfg.hold_duration > 0 {
		time.Sleep(cfg.hold_duration)
	}

	_ = conn.SetWriteDeadline(time.Now().Add(cfg.write_timeout))
	_ = conn.WriteControl(
		websocket.CloseMessage,
		websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""),
		time.Now().Add(cfg.write_timeout),
	)
	_ = conn.Close()

	return latency, true
}

func print_summary(cfg run_config, elapsed time.Duration, latencies []time.Duration, success_count uint64, fail_count uint64) {
	total := success_count + fail_count
	rate := 0.0
	if elapsed > 0 {
		rate = float64(total) / elapsed.Seconds()
	}

	fmt.Println("=== Results ===")
	fmt.Printf("elapsed:           %v\n", elapsed)
	fmt.Printf("attempted:         %d\n", total)
	fmt.Printf("succeeded:         %d\n", success_count)
	fmt.Printf("failed:            %d\n", fail_count)
	fmt.Printf("attempt-rate:      %.1f conn/s\n", rate)

	if len(latencies) == 0 {
		fmt.Println("latency:           no successful connections")
		fmt.Println()
		fmt.Println("Tip: try lower --concurrency or verify server availability.")
		return
	}

	sort.Slice(latencies, func(i, j int) bool {
		return latencies[i] < latencies[j]
	})

	fmt.Printf("latency p50:       %.3f ms\n", to_millis(quantile(latencies, 0.50)))
	fmt.Printf("latency p95:       %.3f ms\n", to_millis(quantile(latencies, 0.95)))
	fmt.Printf("latency p99:       %.3f ms\n", to_millis(quantile(latencies, 0.99)))
	fmt.Printf("latency max:       %.3f ms\n", to_millis(latencies[len(latencies)-1]))
	fmt.Println()

	fmt.Println("Example:")
	fmt.Printf("  go run ./accept_bench --server=%s --connections=%d --concurrency=%d\n", cfg.server_url, cfg.total_connections, cfg.concurrency)
}

func quantile(data []time.Duration, q float64) time.Duration {
	if len(data) == 0 {
		return 0
	}
	if q <= 0 {
		return data[0]
	}
	if q >= 1 {
		return data[len(data)-1]
	}

	idx := int(float64(len(data)-1) * q)
	return data[idx]
}

func to_millis(d time.Duration) float64 {
	return float64(d) / float64(time.Millisecond)
}
