// active-user-sim drives persistent, subscribed NRC sessions against disposable data.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"math/rand"
	"os"
	"os/signal"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/cespare/xxhash/v2"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type config struct {
	Server, SourceIP, Prefix, Output, Trace, StartFile                         string
	Users, Workspaces, Workers, Rooms, Partition, Partitions                   int
	Seed                                                                       int64
	Duration, Ramp, ReadInterval, MutationInterval, ChatInterval, PingInterval time.Duration
	Deadline, P95, P99, LagLimit, Recovery                                     time.Duration
	AllowDisposable                                                            bool
}

func flags() config {
	c := config{}
	flag.StringVar(&c.Server, "server", "ws://127.0.0.1:18080", "Disposable server endpoint")
	flag.StringVar(&c.SourceIP, "source-ip", "", "Comma-separated local source IPs, spread across users")
	flag.StringVar(&c.Prefix, "prefix", fmt.Sprintf("active-%d", time.Now().UnixNano()), "Unique workspace prefix; use the same prefix across partitions")
	flag.StringVar(&c.Output, "output", "active-result.json", "JSON verdict and metrics")
	flag.StringVar(&c.Trace, "trace", "active-trace.jsonl", "Action/error trace; contains synthetic data only")
	flag.StringVar(&c.StartFile, "start-file", "", "Coordinator barrier file containing a Unix nanosecond start time")
	flag.IntVar(&c.Users, "users", 20000, "Total users across all generator partitions")
	flag.IntVar(&c.Workspaces, "workspaces", 200, "Total workspaces")
	flag.IntVar(&c.Workers, "workers", 2, "Actual NRC worker count, used for shard placement")
	flag.IntVar(&c.Rooms, "rooms", 4, "Rooms per workspace (limited to leave at least two users per room)")
	flag.IntVar(&c.Partition, "partition", 0, "Zero-based generator partition")
	flag.IntVar(&c.Partitions, "partitions", 1, "Number of independent generators; whole workspaces stay together")
	flag.Int64Var(&c.Seed, "seed", 1, "Action scheduling seed")
	flag.DurationVar(&c.Duration, "duration", 10*time.Minute, "Steady-state measurement duration")
	flag.DurationVar(&c.Ramp, "ramp", 2*time.Minute, "Connection ramp duration")
	flag.DurationVar(&c.ReadInterval, "read-interval", 30*time.Second, "Mean per-user record read interval")
	flag.DurationVar(&c.MutationInterval, "mutation-interval", 120*time.Second, "Mean per-user record mutation interval")
	flag.DurationVar(&c.ChatInterval, "chat-interval", 120*time.Second, "Mean per-user retained message interval")
	flag.DurationVar(&c.PingInterval, "ping-interval", 30*time.Second, "Mean per-user application ping interval")
	flag.DurationVar(&c.Deadline, "deadline", 5*time.Second, "Individual request deadline and final delivery drain")
	flag.DurationVar(&c.P95, "p95", 250*time.Millisecond, "Per-operation steady-state p95 target")
	flag.DurationVar(&c.P99, "p99", time.Second, "Per-operation steady-state p99 target")
	flag.DurationVar(&c.LagLimit, "lag-limit", 100*time.Millisecond, "Generator scheduling p99 validity limit")
	flag.DurationVar(&c.Recovery, "recovery", 10*time.Second, "Reconnect, resubscription and reconciliation budget")
	flag.BoolVar(&c.AllowDisposable, "disposable", false, "Confirm this endpoint and workspace prefix are disposable")
	flag.Parse()
	return c
}

func (c config) validate() error {
	if !c.AllowDisposable {
		return fmt.Errorf("refusing writes without --disposable")
	}
	if c.Users < 2*c.Workspaces || c.Workspaces < 1 || c.Workers < 1 || c.Workers > 256 || c.Rooms < 1 || c.Partitions < 1 || c.Partitions > c.Workspaces || c.Partition < 0 || c.Partition >= c.Partitions {
		return fmt.Errorf("invalid counts: need at least two users/workspace and valid worker/partition counts")
	}
	if c.Prefix == "" || strings.ContainsAny(c.Prefix, "/?# ") {
		return fmt.Errorf("invalid workspace prefix")
	}
	for _, d := range []time.Duration{c.Duration, c.ReadInterval, c.MutationInterval, c.ChatInterval, c.PingInterval, c.Deadline, c.P95, c.P99, c.LagLimit, c.Recovery} {
		if d <= 0 {
			return fmt.Errorf("intervals and deadlines must be positive")
		}
	}
	if c.Ramp < 0 || c.P95 > c.P99 {
		return fmt.Errorf("invalid ramp/latency limits")
	}
	if os.Getenv("NRC_SIM_JWT_SECRET") == "" {
		return fmt.Errorf("NRC_SIM_JWT_SECRET must be set (never written to reports)")
	}
	return nil
}

// NRC hashes workspace bytes into 256 stable shards, then maps shard to worker.
func workspaceNames(prefix string, count, workers int) []string {
	names := make([]string, count)
	for i := range names {
		for suffix := 0; ; suffix++ {
			s := fmt.Sprintf("%s-%d-%d", prefix, i, suffix)
			if int(xxhash.Sum64String(s)%256)%workers == i%workers {
				names[i] = s
				break
			}
		}
	}
	return names
}

func main() {
	c := flags()
	if err := c.validate(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	s, err := newSimulation(c)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	err = s.run(ctx)
	if err != nil {
		s.metrics.fail("incomplete", err.Error())
	}
	s.close()
	result := s.metrics.report(c)
	result["go_version"] = runtime.Version()
	result["gomaxprocs"] = runtime.GOMAXPROCS(0)
	result["workspaces"] = s.placement()
	data, marshalErr := json.MarshalIndent(result, "", "  ")
	if marshalErr != nil {
		panic(marshalErr)
	}
	if err := os.WriteFile(c.Output, append(data, '\n'), 0600); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	fmt.Println(string(data))
	if result["passed"] != true {
		os.Exit(1)
	}
}

type simulation struct {
	c       config
	metrics *measurements
	spaces  []*workspace
	actors  []*actor
	trace   *os.File
	traceMu sync.Mutex
}

func newSimulation(c config) (*simulation, error) {
	f, err := os.OpenFile(c.Trace, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return nil, err
	}
	s := &simulation{c: c, metrics: newMeasurements(), trace: f}
	for i, name := range workspaceNames(c.Prefix, c.Workspaces, c.Workers) {
		if i%c.Partitions != c.Partition {
			continue
		}
		w := &workspace{name: name, index: i, sim: s, tasks: make(map[string]*event), messages: make(map[string]*event), assets: make(map[string]*event), edges: make(map[string]*event)}
		n := c.Users / c.Workspaces
		if i < c.Users%c.Workspaces {
			n++
		}
		rooms := min(c.Rooms, n/2)
		for j := 0; j < n; j++ {
			a := &actor{id: i + j*c.Workspaces, local: j, room: uint64(1 + j%rooms), ws: w, cache: make(map[uint64]taskState), assets: make(map[uint64]assetState), edges: make(map[uint64]protocol.Edge)}
			w.actors = append(w.actors, a)
			s.actors = append(s.actors, a)
		}
		s.spaces = append(s.spaces, w)
	}
	return s, nil
}

func (s *simulation) log(v any) {
	s.traceMu.Lock()
	defer s.traceMu.Unlock()
	if err := json.NewEncoder(s.trace).Encode(v); err != nil {
		s.metrics.fail("invalid", "trace write: "+err.Error())
	}
}

func (s *simulation) placement() []map[string]any {
	var out []map[string]any
	for _, w := range s.spaces {
		shard := xxhash.Sum64String(w.name) % 256
		out = append(out, map[string]any{"name": w.name, "shard": shard, "worker": shard % uint64(s.c.Workers), "users": len(w.actors)})
	}
	return out
}

func (s *simulation) close() {
	for _, a := range s.actors {
		a.close()
	}
	s.trace.Close()
}

func sleepUntil(ctx context.Context, t time.Time) error {
	timer := time.NewTimer(max(0, time.Until(t)))
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func parallel(ctx context.Context, n, limit int, fn func(int) error) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var wg sync.WaitGroup
	jobs := make(chan int)
	var first error
	var once sync.Once
	for range min(n, limit) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range jobs {
				if err := fn(i); err != nil {
					once.Do(func() { first = err; cancel() })
				}
			}
		}()
	}
loop:
	for i := 0; i < n; i++ {
		select {
		case <-ctx.Done():
			break loop
		case jobs <- i:
		}
	}
	close(jobs)
	wg.Wait()
	if first != nil {
		return first
	}
	return ctx.Err()
}

func (s *simulation) run(ctx context.Context) error {
	rampStart := time.Now()
	fmt.Fprintf(os.Stderr, "Connecting %d users across %d workspaces\n", len(s.actors), len(s.spaces))
	if err := parallel(ctx, len(s.actors), 32, func(i int) error {
		if err := sleepUntil(ctx, rampStart.Add(s.c.Ramp*time.Duration(i)/time.Duration(len(s.actors)))); err != nil {
			return err
		}
		return s.actors[i].connect(ctx)
	}); err != nil {
		return fmt.Errorf("startup: %w", err)
	}
	if err := parallel(ctx, len(s.spaces), 16, func(i int) error { return s.spaces[i].seed(ctx) }); err != nil {
		return err
	}
	if err := s.drain(ctx); err != nil {
		return err
	}
	start := time.Now().Add(time.Second)
	if s.c.StartFile != "" {
		if err := os.WriteFile(s.c.Output+".ready", []byte("ready\n"), 0600); err != nil {
			return err
		}
		for {
			data, err := os.ReadFile(s.c.StartFile)
			if err == nil {
				var ns int64
				if _, err = fmt.Sscan(string(data), &ns); err != nil {
					return err
				}
				start = time.Unix(0, ns)
				break
			}
			if !os.IsNotExist(err) {
				return err
			}
			if err = sleepUntil(ctx, time.Now().Add(100*time.Millisecond)); err != nil {
				return err
			}
		}
	}
	if err := sleepUntil(ctx, start); err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "Measuring subscribed activity")
	var wg sync.WaitGroup
	for _, a := range s.actors {
		wg.Add(1)
		go func() { defer wg.Done(); a.active(ctx, start) }()
	}
	wg.Wait()
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if err := s.drain(ctx); err != nil {
		s.metrics.fail("delivery", err.Error())
	}
	fmt.Fprintln(os.Stderr, "Reconciling caches, subscriptions, reconnects and retained history")
	if err := parallel(ctx, len(s.spaces), 8, func(i int) error { return s.spaces[i].verify(ctx) }); err != nil {
		return err
	}
	if err := s.drain(ctx); err != nil {
		s.metrics.fail("delivery", err.Error())
	}
	s.metrics.mu.Lock()
	s.metrics.complete = true
	s.metrics.mu.Unlock()
	return nil
}

func (s *simulation) drain(ctx context.Context) error {
	until := time.Now().Add(s.c.Deadline)
	for {
		missing := 0
		for _, w := range s.spaces {
			w.mu.Lock()
			for _, table := range []map[string]*event{w.tasks, w.messages, w.assets, w.edges} {
				for _, e := range table {
					if e.accepted {
						missing += e.remaining
					}
				}
			}
			w.mu.Unlock()
		}
		if missing == 0 {
			return nil
		}
		if time.Now().After(until) {
			return fmt.Errorf("%d expected live deliveries missing after drain", missing)
		}
		if err := sleepUntil(ctx, time.Now().Add(20*time.Millisecond)); err != nil {
			return err
		}
	}
}

func (a *actor) active(ctx context.Context, start time.Time) {
	c := a.ws.sim.c
	rng := rand.New(rand.NewSource(c.Seed + int64(a.id)*104729))
	intervals := []time.Duration{c.ReadInterval, c.MutationInterval, c.ChatInterval, c.PingInterval}
	next := make([]time.Time, len(intervals))
	for i, d := range intervals {
		next[i] = start.Add(time.Duration(rng.Float64() * float64(d)))
	}
	end := start.Add(c.Duration)
	for {
		kind := 0
		for i := range next {
			if next[i].Before(next[kind]) {
				kind = i
			}
		}
		due := next[kind]
		if !due.Before(end) {
			return
		}
		if err := sleepUntil(ctx, due); err != nil {
			return
		}
		lag := max(time.Duration(0), time.Since(due))
		a.ws.sim.metrics.record("schedule_lag", lag)
		// Finish actions scheduled before the boundary, even if their timer fires
		// just after it. Scheduling lag remains visible instead of dropping work.
		var err error
		operation := ""
		switch kind {
		case 0:
			if rng.Intn(4) == 0 {
				operation = "read_note"
				_, err = a.getAsset(ctx, a.ws.assetIDs[0], true)
			} else {
				operation = "read_task"
				_, err = a.getTask(ctx, a.ws.taskIDs[a.local%len(a.ws.taskIDs)], true)
			}
		case 1:
			if rng.Intn(3) == 0 {
				operation = "edit_note"
				err = a.editNote(ctx, true)
			} else {
				operation = "update_task"
				err = a.mutate(ctx, true)
			}
		case 2:
			operation = "retained_send"
			err = a.chat(ctx, true, rng.Intn(100) == 0)
		case 3:
			operation = "ping"
			_, err = a.request(ctx, "ping", true, func(id uint32) (uint16, []byte, error) { return pingRequest(id) })
		}
		a.ws.sim.metrics.record("schedule_lag_"+operation, lag)
		a.ws.sim.metrics.record("scheduled_"+operation, time.Since(due))
		if err != nil {
			a.ws.sim.metrics.fail("incomplete", fmt.Sprintf("user %d stopped: %v", a.id, err))
			a.ws.sim.log(map[string]any{"user": a.id, "error": err.Error(), "time": time.Now()})
			return
		}
		// Advance from the intended deadline, never completion: lag cannot silently reduce offered load.
		next[kind] = due.Add(time.Duration((0.5 + rng.Float64()) * float64(intervals[kind])))
	}
}
