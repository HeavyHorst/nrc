package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/VictoriaMetrics/metrics"
	"github.com/cespare/xxhash/v2"
	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type WorkspaceMode string

const (
	WorkspaceModeStatic         WorkspaceMode = "static"
	WorkspaceModeThreadTargeted WorkspaceMode = "thread-targeted"
)

const (
	defaultNRCServer    = "ws://localhost:8080"
	defaultMetricsPort  = "8092"
	defaultPingInterval = 5 * time.Second
	defaultReadTimeout  = 60 * time.Second

	defaultWorkspaceMode    = WorkspaceModeStatic
	defaultWorkspacePrefix  = "metrics-thread"
	defaultBootstrapTimeout = 20 * time.Second

	maxWorkspaceSearchAttempts = 1_000_000
	logicalShardCount          = 256
)

var errNotConnected = errors.New("nrc metrics client not connected")

var threadFromWorkspacePattern = regexp.MustCompile(`-(\d+)-\d+$`)

type Config struct {
	NRCServer    string
	MetricsPort  string
	NRCNickname  string
	NRCBotSecret string

	WorkspaceMode      WorkspaceMode
	WorkspacePrefix    string
	BootstrapWorkspace string
	TargetThreads      uint32
	ThreadExpectation  uint32
	ExpectedThreads    uint32
	BootstrapTimeout   time.Duration

	Workspaces   []string
	PingInterval time.Duration
	ReadTimeout  time.Duration
}

type WorkspaceSample struct {
	Workspace  string
	ThreadID   uint32
	ReceivedAt time.Time
	Pong       protocol.StatsResponse
}

type ThreadSample struct {
	ThreadID         uint32
	SourceWorkspace  string
	TotalThreadsHint uint32
	ReceivedAt       time.Time
	Pong             protocol.StatsResponse
}

type CollectorState struct {
	ConfiguredWorkspaces []string
	Connected            map[string]bool
	WorkspaceSamples     map[string]WorkspaceSample
	ThreadSamples        map[uint32]ThreadSample
	ObservedThreads      uint32
	ThreadExpectation    uint32
	ThreadCountMismatch  bool
	ExpectedThreads      uint32
	CoveredThreadIDs     []uint32
	MissingThreadIDs     []uint32
	TotalConnections     uint64
}

type Collector struct {
	configuredWorkspaces []string
	expectedThreads      uint32
	threadExpectation    uint32

	mu            sync.RWMutex
	connected     map[string]bool
	samples       map[string]WorkspaceSample
	renderThreads uint32
}

type NRCClient struct {
	workspace string
	cfg       Config
	collector *Collector

	connMu      sync.RWMutex
	conn        *websocket.Conn
	writeMu     sync.Mutex
	threadIDMu  sync.RWMutex
	threadID    uint32
	hasThreadID bool
}

type healthResponse struct {
	Status               string   `json:"status"`
	Uptime               string   `json:"uptime"`
	NRCServer            string   `json:"nrc_server"`
	WorkspaceMode        string   `json:"workspace_mode"`
	WorkspacesConfigured int      `json:"workspaces_configured"`
	WorkspacesConnected  int      `json:"workspaces_connected"`
	WorkspacesWithPong   int      `json:"workspaces_with_pong"`
	ConnectedWorkspaces  []string `json:"connected_workspaces"`
	ThreadsObserved      uint32   `json:"threads_observed"`
	ThreadExpectation    uint32   `json:"thread_expectation"`
	ThreadCountMismatch  bool     `json:"thread_count_mismatch"`
	ThreadsExpected      uint32   `json:"threads_expected"`
	ThreadsCovered       int      `json:"threads_covered"`
	ThreadsMissing       int      `json:"threads_missing"`
	MissingThreadIDs     []uint32 `json:"missing_thread_ids"`
	ConnectionsTotal     uint64   `json:"connections_total"`
	PingInterval         string   `json:"ping_interval"`
	ReadTimeout          string   `json:"read_timeout"`
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		slog.Error("invalid nrc-metrics configuration", "error", err)
		os.Exit(1)
	}

	cfg, err = resolveWorkspacePlan(cfg)
	if err != nil {
		slog.Error("failed to resolve workspace coverage plan", "error", err)
		os.Exit(1)
	}

	metrics.ExposeMetadata(true)
	setGauge("nrc_metrics_build_info", 1)

	startTime := time.Now()
	collector := NewCollector(cfg.Workspaces, cfg.ExpectedThreads, cfg.ThreadExpectation)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var wg sync.WaitGroup
	for _, workspace := range cfg.Workspaces {
		client := NewNRCClient(cfg, workspace, collector)
		wg.Add(1)
		go func(c *NRCClient) {
			defer wg.Done()
			c.Run(ctx)
		}(client)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /metrics", func(w http.ResponseWriter, _ *http.Request) {
		metrics.WritePrometheus(w, true)
	})

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		state := collector.ComputeState()
		connectedWorkspaces := make([]string, 0, len(state.ConfiguredWorkspaces))
		for _, workspace := range state.ConfiguredWorkspaces {
			if state.Connected[workspace] {
				connectedWorkspaces = append(connectedWorkspaces, workspace)
			}
		}

		status := "ok"
		if len(connectedWorkspaces) == 0 {
			status = "degraded"
		}
		if state.ExpectedThreads > 0 && len(state.MissingThreadIDs) > 0 {
			status = "degraded"
		}
		if state.ThreadCountMismatch {
			status = "degraded"
		}

		resp := healthResponse{
			Status:               status,
			Uptime:               time.Since(startTime).Round(time.Second).String(),
			NRCServer:            cfg.NRCServer,
			WorkspaceMode:        string(cfg.WorkspaceMode),
			WorkspacesConfigured: len(state.ConfiguredWorkspaces),
			WorkspacesConnected:  len(connectedWorkspaces),
			WorkspacesWithPong:   len(state.WorkspaceSamples),
			ConnectedWorkspaces:  connectedWorkspaces,
			ThreadsObserved:      state.ObservedThreads,
			ThreadExpectation:    state.ThreadExpectation,
			ThreadCountMismatch:  state.ThreadCountMismatch,
			ThreadsExpected:      state.ExpectedThreads,
			ThreadsCovered:       len(state.CoveredThreadIDs),
			ThreadsMissing:       len(state.MissingThreadIDs),
			MissingThreadIDs:     append([]uint32(nil), state.MissingThreadIDs...),
			ConnectionsTotal:     state.TotalConnections,
			PingInterval:         cfg.PingInterval.String(),
			ReadTimeout:          cfg.ReadTimeout.String(),
		}

		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(resp); err != nil {
			slog.Error("failed to encode /health response", "error", err)
		}
	})

	server := &http.Server{
		Addr:    ":" + cfg.MetricsPort,
		Handler: mux,
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigCh
		slog.Info("received signal, shutting down nrc-metrics", "signal", sig)
		cancel()

		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer shutdownCancel()

		if err := server.Shutdown(shutdownCtx); err != nil {
			slog.Error("HTTP server shutdown error", "error", err)
		}
	}()

	slog.Info(
		"starting nrc-metrics",
		"nrc_server", cfg.NRCServer,
		"port", cfg.MetricsPort,
		"workspace_mode", cfg.WorkspaceMode,
		"threads_expected", cfg.ExpectedThreads,
		"thread_expectation", cfg.ThreadExpectation,
		"workspaces", strings.Join(cfg.Workspaces, ","),
		"ping_interval", cfg.PingInterval,
	)

	serveErr := server.ListenAndServe()
	if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
		slog.Error("HTTP server error", "error", serveErr)
		cancel()
	}

	wg.Wait()

	if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
		os.Exit(1)
	}

	slog.Info("nrc-metrics stopped")
}

func loadConfig() (Config, error) {
	cfg := Config{
		NRCServer:          envOrDefault("NRC_SERVER", defaultNRCServer),
		MetricsPort:        envOrDefault("METRICS_PORT", defaultMetricsPort),
		NRCBotSecret:       os.Getenv("NRC_BOT_SECRET"),
		WorkspaceMode:      parseWorkspaceMode(envOrDefault("NRC_METRICS_WORKSPACE_MODE", string(defaultWorkspaceMode))),
		WorkspacePrefix:    envOrDefault("NRC_METRICS_WORKSPACE_PREFIX", defaultWorkspacePrefix),
		BootstrapWorkspace: envOrDefault("NRC_METRICS_BOOTSTRAP_WORKSPACE", "metrics-bootstrap"),
	}

	cfg.NRCNickname = envOrDefault("NRC_NICKNAME", "")
	if cfg.NRCNickname == "" {
		hostname, _ := os.Hostname()
		if hostname == "" {
			hostname = fmt.Sprintf("%d", os.Getpid())
		}
		cfg.NRCNickname = fmt.Sprintf("metrics-%s", hostname)
	}

	if cfg.WorkspaceMode != WorkspaceModeStatic && cfg.WorkspaceMode != WorkspaceModeThreadTargeted {
		return cfg, fmt.Errorf("invalid NRC_METRICS_WORKSPACE_MODE=%q (allowed: %q, %q)", cfg.WorkspaceMode, WorkspaceModeStatic, WorkspaceModeThreadTargeted)
	}

	expectedThreads, expectedAll, err := uint32FromEnvFlexible("NRC_METRICS_EXPECT_THREADS")
	if err != nil {
		return cfg, err
	}
	if !expectedAll {
		cfg.ThreadExpectation = expectedThreads
		cfg.ExpectedThreads = expectedThreads
	}

	if cfg.WorkspaceMode == WorkspaceModeStatic {
		workspaceCSV := envOrDefault("NRC_WORKSPACES", os.Getenv("NRC_WORKSPACE"))
		cfg.Workspaces = parseWorkspaceList(workspaceCSV)
		if len(cfg.Workspaces) == 0 {
			return cfg, fmt.Errorf("NRC_WORKSPACES must contain at least one workspace in static mode")
		}
	}

	if cfg.WorkspaceMode == WorkspaceModeThreadTargeted {
		if strings.TrimSpace(cfg.WorkspacePrefix) == "" {
			return cfg, fmt.Errorf("NRC_METRICS_WORKSPACE_PREFIX cannot be empty in thread-targeted mode")
		}
		if strings.TrimSpace(cfg.BootstrapWorkspace) == "" {
			return cfg, fmt.Errorf("NRC_METRICS_BOOTSTRAP_WORKSPACE cannot be empty in thread-targeted mode")
		}

		targetThreads, targetAll, err := uint32FromEnvFlexible("NRC_METRICS_TARGET_THREADS")
		if err != nil {
			return cfg, err
		}
		if !targetAll {
			cfg.TargetThreads = targetThreads
		}

		bootstrapTimeout, err := durationFromEnv("NRC_METRICS_BOOTSTRAP_TIMEOUT", defaultBootstrapTimeout)
		if err != nil {
			return cfg, err
		}
		if bootstrapTimeout <= 0 {
			return cfg, fmt.Errorf("NRC_METRICS_BOOTSTRAP_TIMEOUT must be greater than zero")
		}
		cfg.BootstrapTimeout = bootstrapTimeout

		if cfg.ThreadExpectation > 0 && cfg.TargetThreads > cfg.ThreadExpectation {
			return cfg, fmt.Errorf("NRC_METRICS_TARGET_THREADS (%d) cannot exceed NRC_METRICS_EXPECT_THREADS (%d)", cfg.TargetThreads, cfg.ThreadExpectation)
		}
	}

	if cfg.NRCBotSecret == "" {
		return cfg, fmt.Errorf("NRC_BOT_SECRET is required for bot authentication")
	}

	pingInterval, err := durationFromEnv("PING_INTERVAL", defaultPingInterval)
	if err != nil {
		return cfg, err
	}
	if pingInterval <= 0 {
		return cfg, fmt.Errorf("PING_INTERVAL must be greater than zero")
	}
	cfg.PingInterval = pingInterval

	readTimeout, err := durationFromEnv("READ_TIMEOUT", defaultReadTimeout)
	if err != nil {
		return cfg, err
	}
	minReadTimeout := 3 * cfg.PingInterval
	if readTimeout < minReadTimeout {
		slog.Warn(
			"READ_TIMEOUT too low for current ping interval, adjusting",
			"configured", readTimeout,
			"minimum", minReadTimeout,
		)
		readTimeout = minReadTimeout
	}
	cfg.ReadTimeout = readTimeout

	return cfg, nil
}

func parseWorkspaceMode(raw string) WorkspaceMode {
	mode := strings.TrimSpace(strings.ToLower(raw))
	switch mode {
	case "", string(WorkspaceModeStatic):
		return WorkspaceModeStatic
	case string(WorkspaceModeThreadTargeted), "thread_targeted", "targeted":
		return WorkspaceModeThreadTargeted
	default:
		return WorkspaceMode(mode)
	}
}

func uint32FromEnvFlexible(key string) (value uint32, isAll bool, err error) {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" || strings.EqualFold(raw, "all") {
		return 0, true, nil
	}

	parsed, parseErr := strconv.ParseUint(raw, 10, 32)
	if parseErr != nil {
		return 0, false, fmt.Errorf("invalid %s=%q: must be unsigned integer or 'all'", key, raw)
	}
	if parsed == 0 {
		return 0, false, fmt.Errorf("invalid %s=%q: must be greater than zero or 'all'", key, raw)
	}

	return uint32(parsed), false, nil
}

func envOrDefault(key, def string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return def
}

func durationFromEnv(key string, def time.Duration) (time.Duration, error) {
	value := os.Getenv(key)
	if value == "" {
		return def, nil
	}

	d, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("invalid %s=%q: %w", key, value, err)
	}
	return d, nil
}

func parseWorkspaceList(raw string) []string {
	raw = strings.ReplaceAll(raw, "\n", ",")
	raw = strings.ReplaceAll(raw, ";", ",")

	seen := make(map[string]struct{})
	workspaces := make([]string, 0)

	for _, token := range strings.Split(raw, ",") {
		workspace := strings.TrimSpace(token)
		if workspace == "" {
			continue
		}
		if _, exists := seen[workspace]; exists {
			continue
		}
		seen[workspace] = struct{}{}
		workspaces = append(workspaces, workspace)
	}

	return workspaces
}

func resolveWorkspacePlan(cfg Config) (Config, error) {
	if cfg.WorkspaceMode == WorkspaceModeStatic {
		return cfg, nil
	}

	bootstrapCtx, cancel := context.WithTimeout(context.Background(), cfg.BootstrapTimeout)
	defer cancel()

	observedThreads, bootstrapThreadID, err := discoverServerThreads(bootstrapCtx, cfg)
	if err != nil {
		return cfg, err
	}

	targetThreads := observedThreads
	if cfg.TargetThreads > 0 {
		targetThreads = minUint32(cfg.TargetThreads, observedThreads)
	}
	if cfg.ThreadExpectation > 0 {
		targetThreads = minUint32(targetThreads, cfg.ThreadExpectation)
	}
	if targetThreads == 0 {
		return cfg, fmt.Errorf("thread-targeted mode resolved zero target threads")
	}

	workspaceIDs, err := generateThreadTargetedWorkspaces(cfg.WorkspacePrefix, observedThreads, targetThreads)
	if err != nil {
		return cfg, err
	}

	cfg.Workspaces = workspaceIDs
	cfg.ExpectedThreads = targetThreads
	if cfg.ThreadExpectation > 0 {
		cfg.ExpectedThreads = cfg.ThreadExpectation
	}

	slog.Info(
		"resolved thread-targeted workspace plan",
		"bootstrap_workspace", cfg.BootstrapWorkspace,
		"bootstrap_thread_id", bootstrapThreadID,
		"threads_observed", observedThreads,
		"threads_targeted", targetThreads,
	)

	return cfg, nil
}

func discoverServerThreads(ctx context.Context, cfg Config) (uint32, uint32, error) {
	url := fmt.Sprintf("%s/%s", strings.TrimRight(cfg.NRCServer, "/"), cfg.BootstrapWorkspace)
	dialer := websocket.Dialer{HandshakeTimeout: 10 * time.Second}
	headers := http.Header{
		"X-NRC-User-Type":    []string{"bot"},
		"X-NRC-Bot-Secret":   []string{cfg.NRCBotSecret},
		"X-NRC-Bot-Nickname": []string{cfg.NRCNickname},
	}

	conn, _, err := dialer.DialContext(ctx, url, headers)
	if err != nil {
		return 0, 0, fmt.Errorf("bootstrap dial %s: %w", url, err)
	}
	defer conn.Close()

	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetReadDeadline(deadline)
	}

	pingMsg := &protocol.Message{Opcode: protocol.C_Stats, Data: protocol.EncodeStats(time.Now().UnixNano())}
	buf, err := pingMsg.Write()
	if err != nil {
		return 0, 0, fmt.Errorf("encode bootstrap ping: %w", err)
	}
	if err := conn.WriteMessage(websocket.BinaryMessage, buf); err != nil {
		return 0, 0, fmt.Errorf("send bootstrap ping: %w", err)
	}

	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			return 0, 0, fmt.Errorf("bootstrap read: %w", err)
		}

		msg, err := protocol.ReadMessage(data)
		if err != nil {
			continue
		}

		switch msg.Opcode {
		case protocol.S_StatsResponse:
			stats, err := protocol.DecodeStatsResponse(msg.Data)
			if err != nil {
				return 0, 0, fmt.Errorf("decode bootstrap stats response: %w", err)
			}
			if stats.TotalThreads == 0 {
				return 0, 0, fmt.Errorf("bootstrap stats response reported zero total_threads")
			}
			if cfg.ThreadExpectation > 0 && stats.TotalThreads != cfg.ThreadExpectation {
				slog.Warn(
					"bootstrap observed thread count differs from configured expectation",
					"observed_threads", stats.TotalThreads,
					"expected_threads", cfg.ThreadExpectation,
				)
			}
			return stats.TotalThreads, stats.ThreadID, nil
		case protocol.S_ErrorResponse:
			errResp, err := protocol.DecodeErrorResponse(msg.Data)
			if err != nil {
				return 0, 0, fmt.Errorf("decode bootstrap error response: %w", err)
			}
			return 0, 0, fmt.Errorf("bootstrap protocol error: origin_opcode=%d correlation_id=%d message=%q", errResp.OriginOpcode, errResp.CorrelationID, errResp.ErrorMessage)
		}
	}
}

func generateThreadTargetedWorkspaces(prefix string, hashThreads uint32, targetThreads uint32) ([]string, error) {
	if hashThreads == 0 {
		return nil, fmt.Errorf("cannot generate thread-targeted workspaces with zero hash threads")
	}
	if targetThreads == 0 {
		return nil, fmt.Errorf("cannot generate thread-targeted workspaces with zero target threads")
	}

	workspaceIDs := make([]string, 0, targetThreads)
	used := make(map[string]struct{}, targetThreads)

	for threadID := uint32(0); threadID < targetThreads; threadID++ {
		workspaceID, err := findWorkspaceForThread(prefix, threadID, hashThreads, used)
		if err != nil {
			return nil, err
		}
		workspaceIDs = append(workspaceIDs, workspaceID)
		used[workspaceID] = struct{}{}
	}

	return workspaceIDs, nil
}

func findWorkspaceForThread(prefix string, targetThread uint32, hashThreads uint32, used map[string]struct{}) (string, error) {
	for suffix := uint32(0); suffix < maxWorkspaceSearchAttempts; suffix++ {
		candidate := fmt.Sprintf("%s-%d-%d", prefix, targetThread, suffix)
		if _, exists := used[candidate]; exists {
			continue
		}
		logicalShard := xxhash.Sum64String(candidate) % logicalShardCount
		thread := uint32(logicalShard % uint64(hashThreads))
		if thread == targetThread {
			return candidate, nil
		}
	}

	return "", fmt.Errorf("failed to find workspace mapping for thread %d after %d attempts", targetThread, maxWorkspaceSearchAttempts)
}

func minUint32(a, b uint32) uint32 {
	if a < b {
		return a
	}
	return b
}

func NewCollector(workspaces []string, expectedThreads uint32, threadExpectation uint32) *Collector {
	connected := make(map[string]bool, len(workspaces))
	for _, workspace := range workspaces {
		connected[workspace] = false
	}

	c := &Collector{
		configuredWorkspaces: append([]string(nil), workspaces...),
		expectedThreads:      expectedThreads,
		threadExpectation:    threadExpectation,
		connected:            connected,
		samples:              make(map[string]WorkspaceSample, len(workspaces)),
	}

	c.refreshMetrics()
	return c
}

func (c *Collector) SetConnected(workspace string, connected bool) {
	c.mu.Lock()
	c.connected[workspace] = connected
	c.mu.Unlock()

	c.refreshMetrics()
}

func (c *Collector) UpdatePong(workspace string, pong protocol.StatsResponse) {
	sample := WorkspaceSample{
		Workspace:  workspace,
		ThreadID:   pong.ThreadID,
		ReceivedAt: time.Now(),
		Pong:       pong,
	}

	c.mu.Lock()
	c.samples[workspace] = sample
	c.mu.Unlock()

	c.refreshMetrics()
}

func (c *Collector) RemoveWorkspace(workspace string) {
	c.mu.Lock()
	delete(c.samples, workspace)
	c.mu.Unlock()

	c.refreshMetrics()
}

func (c *Collector) ComputeState() CollectorState {
	c.mu.RLock()
	defer c.mu.RUnlock()

	state := CollectorState{
		ConfiguredWorkspaces: append([]string(nil), c.configuredWorkspaces...),
		ExpectedThreads:      c.expectedThreads,
		ThreadExpectation:    c.threadExpectation,
		Connected:            make(map[string]bool, len(c.connected)),
		WorkspaceSamples:     make(map[string]WorkspaceSample, len(c.samples)),
		ThreadSamples:        make(map[uint32]ThreadSample),
	}

	for workspace, connected := range c.connected {
		state.Connected[workspace] = connected
	}

	for workspace, sample := range c.samples {
		state.WorkspaceSamples[workspace] = sample

		totalThreadsHint := sample.Pong.TotalThreads
		if totalThreadsHint > state.ObservedThreads {
			state.ObservedThreads = totalThreadsHint
		}
		if sample.ThreadID+1 > state.ObservedThreads {
			state.ObservedThreads = sample.ThreadID + 1
		}

		existing, ok := state.ThreadSamples[sample.ThreadID]
		if !ok || sample.ReceivedAt.After(existing.ReceivedAt) {
			state.ThreadSamples[sample.ThreadID] = ThreadSample{
				ThreadID:         sample.ThreadID,
				SourceWorkspace:  workspace,
				TotalThreadsHint: totalThreadsHint,
				ReceivedAt:       sample.ReceivedAt,
				Pong:             sample.Pong,
			}
		}
	}

	state.CoveredThreadIDs = make([]uint32, 0, len(state.ThreadSamples))
	for threadID := range state.ThreadSamples {
		state.CoveredThreadIDs = append(state.CoveredThreadIDs, threadID)
	}
	sort.Slice(state.CoveredThreadIDs, func(i, j int) bool {
		return state.CoveredThreadIDs[i] < state.CoveredThreadIDs[j]
	})

	coveredSet := make(map[uint32]struct{}, len(state.CoveredThreadIDs))
	for _, threadID := range state.CoveredThreadIDs {
		coveredSet[threadID] = struct{}{}
		state.TotalConnections += uint64(state.ThreadSamples[threadID].Pong.Connections)
	}

	if state.ExpectedThreads == 0 {
		state.ExpectedThreads = state.ObservedThreads
	}
	if state.ThreadExpectation > 0 && state.ObservedThreads > 0 && state.ObservedThreads != state.ThreadExpectation {
		state.ThreadCountMismatch = true
	}

	if state.ExpectedThreads > 0 {
		state.MissingThreadIDs = make([]uint32, 0)
		for threadID := uint32(0); threadID < state.ExpectedThreads; threadID++ {
			if _, ok := coveredSet[threadID]; !ok {
				state.MissingThreadIDs = append(state.MissingThreadIDs, threadID)
			}
		}
	}

	return state
}

func (c *Collector) refreshMetrics() {
	state := c.ComputeState()
	renderTarget := state.ExpectedThreads
	if state.ObservedThreads > renderTarget {
		renderTarget = state.ObservedThreads
	}

	c.mu.Lock()
	if renderTarget > c.renderThreads {
		c.renderThreads = renderTarget
	}
	renderThreads := c.renderThreads
	c.mu.Unlock()

	setGauge("nrc_metrics_workspaces_configured", float64(len(state.ConfiguredWorkspaces)))
	setGauge("nrc_metrics_workspaces_connected", float64(countConnected(state.Connected)))
	setGauge("nrc_metrics_workspaces_with_pong", float64(len(state.WorkspaceSamples)))
	setGauge("nrc_metrics_threads_observed", float64(state.ObservedThreads))
	setGauge("nrc_metrics_threads_expectation", float64(state.ThreadExpectation))
	setGauge("nrc_metrics_thread_count_mismatch", boolToFloat(state.ThreadCountMismatch))
	setGauge("nrc_metrics_threads_expected", float64(state.ExpectedThreads))
	setGauge("nrc_metrics_threads_covered", float64(len(state.CoveredThreadIDs)))
	setGauge("nrc_metrics_threads_missing", float64(len(state.MissingThreadIDs)))
	setGauge("nrc_metrics_connections_total", float64(state.TotalConnections))

	for _, workspace := range state.ConfiguredWorkspaces {
		sample, hasSample := state.WorkspaceSamples[workspace]
		threadID, hasThreadID := parseThreadIDFromWorkspace(workspace)
		if hasSample {
			threadID = sample.ThreadID
			hasThreadID = true
		}
		if !hasThreadID {
			continue
		}

		threadKey := strconv.FormatUint(uint64(threadID), 10)
		setGauge(metricWithLabels("nrc_metrics_connection_up", "thread_id", threadKey), boolToFloat(state.Connected[workspace]))
		setGauge(metricWithLabels("nrc_metrics_connection_has_pong", "thread_id", threadKey), boolToFloat(hasSample))

		if !hasSample {
			setGauge(metricWithLabels("nrc_metrics_connection_thread_id", "thread_id", threadKey), float64(threadID))
			setGauge(metricWithLabels("nrc_metrics_connection_last_pong_unix_seconds", "thread_id", threadKey), 0)
			setGauge(metricWithLabels("nrc_metrics_connection_last_server_timestamp_ns", "thread_id", threadKey), 0)
			setGauge(metricWithLabels("nrc_connection_send_queue_depth", "thread_id", threadKey), 0)
			setGauge(metricWithLabels("nrc_connection_send_queue_limit", "thread_id", threadKey), 0)
			setGauge(metricWithLabels("nrc_connection_send_backpressure", "thread_id", threadKey), 0)
			setGauge(metricWithLabels("nrc_connection_send_dropped_total", "thread_id", threadKey), 0)
			continue
		}

		setGauge(metricWithLabels("nrc_metrics_connection_thread_id", "thread_id", threadKey), float64(sample.ThreadID))
		setGauge(metricWithLabels("nrc_metrics_connection_last_pong_unix_seconds", "thread_id", threadKey), float64(sample.ReceivedAt.Unix()))
		setGauge(metricWithLabels("nrc_metrics_connection_last_server_timestamp_ns", "thread_id", threadKey), float64(sample.Pong.ServerTimestamp))
		setGauge(metricWithLabels("nrc_connection_send_queue_depth", "thread_id", threadKey), float64(sample.Pong.SendQueueDepth))
		setGauge(metricWithLabels("nrc_connection_send_queue_limit", "thread_id", threadKey), float64(sample.Pong.SendQueueLimit))
		setGauge(metricWithLabels("nrc_connection_send_backpressure", "thread_id", threadKey), boolToFloat(sample.Pong.SendBackpressure))
		setGauge(metricWithLabels("nrc_connection_send_dropped_total", "thread_id", threadKey), float64(sample.Pong.SendDropped))
	}

	for threadID := uint32(0); threadID < renderThreads; threadID++ {
		threadKey := strconv.FormatUint(uint64(threadID), 10)
		sample, ok := state.ThreadSamples[threadID]

		setGauge(metricWithLabels("nrc_metrics_thread_covered", "thread_id", threadKey), boolToFloat(ok))

		if !ok {
			publishThreadMetricsZero(threadID)
			continue
		}

		publishThreadMetricsSample(sample)
	}
}

func countConnected(connected map[string]bool) int {
	n := 0
	for _, isConnected := range connected {
		if isConnected {
			n++
		}
	}
	return n
}

func walKindLabel(kind uint8) string {
	switch kind {
	case protocol.StatsWALKindTask:
		return "task"
	case protocol.StatsWALKindAsset:
		return "asset"
	case protocol.StatsWALKindEdge:
		return "edge"
	default:
		return "unknown"
	}
}

func publishThreadWALKindMetricsZero(thread string, walKind string) {
	setGauge(metricWithLabels("nrc_thread_wal_kind_enabled", "thread_id", thread, "wal_kind", walKind), 0)
	setGauge(metricWithLabels("nrc_thread_wal_kind_file_size_bytes", "thread_id", thread, "wal_kind", walKind), 0)
	setGauge(metricWithLabels("nrc_thread_wal_kind_pending_bytes", "thread_id", thread, "wal_kind", walKind), 0)
	setCounter(metricWithLabels("nrc_thread_wal_kind_records_total", "thread_id", thread, "wal_kind", walKind), 0)
	setCounter(metricWithLabels("nrc_thread_wal_kind_fsync_total", "thread_id", thread, "wal_kind", walKind), 0)
	setCounter(metricWithLabels("nrc_thread_wal_kind_total_fsync_ns", "thread_id", thread, "wal_kind", walKind), 0)
	setCounter(metricWithLabels("nrc_thread_wal_kind_write_total", "thread_id", thread, "wal_kind", walKind), 0)
	setCounter(metricWithLabels("nrc_thread_wal_kind_total_write_ns", "thread_id", thread, "wal_kind", walKind), 0)
	setGauge(metricWithLabels("nrc_thread_wal_kind_compaction_mode", "thread_id", thread, "wal_kind", walKind), 0)
	setGauge(metricWithLabels("nrc_thread_wal_kind_compaction_bg_status", "thread_id", thread, "wal_kind", walKind), 0)
	setCounter(metricWithLabels("nrc_thread_wal_kind_compaction_generation", "thread_id", thread, "wal_kind", walKind), 0)
	setGauge(metricWithLabels("nrc_thread_wal_kind_compaction_snapshot_end_bytes", "thread_id", thread, "wal_kind", walKind), 0)
	setCounter(metricWithLabels("nrc_thread_wal_kind_compaction_compact_count", "thread_id", thread, "wal_kind", walKind), 0)
	setGauge(metricWithLabels("nrc_thread_wal_kind_compaction_install_cursor_bytes", "thread_id", thread, "wal_kind", walKind), 0)
	setGauge(metricWithLabels("nrc_thread_wal_kind_compaction_install_last_backlog_bytes", "thread_id", thread, "wal_kind", walKind), 0)
	setGauge(metricWithLabels("nrc_thread_wal_kind_compaction_install_budget_us", "thread_id", thread, "wal_kind", walKind), 0)
}

func publishThreadWALKindMetricsSample(thread string, walKind string, detail protocol.StatsWALDetail) {
	setGauge(metricWithLabels("nrc_thread_wal_kind_enabled", "thread_id", thread, "wal_kind", walKind), boolToFloat(detail.Enabled))
	setGauge(metricWithLabels("nrc_thread_wal_kind_file_size_bytes", "thread_id", thread, "wal_kind", walKind), float64(detail.FileSize))
	setGauge(metricWithLabels("nrc_thread_wal_kind_pending_bytes", "thread_id", thread, "wal_kind", walKind), float64(detail.PendingBytes))
	setCounter(metricWithLabels("nrc_thread_wal_kind_records_total", "thread_id", thread, "wal_kind", walKind), detail.RecordCount)
	setCounter(metricWithLabels("nrc_thread_wal_kind_fsync_total", "thread_id", thread, "wal_kind", walKind), detail.FsyncCount)
	setCounter(metricWithLabels("nrc_thread_wal_kind_total_fsync_ns", "thread_id", thread, "wal_kind", walKind), detail.TotalFsyncNS)
	setCounter(metricWithLabels("nrc_thread_wal_kind_write_total", "thread_id", thread, "wal_kind", walKind), detail.WriteCount)
	setCounter(metricWithLabels("nrc_thread_wal_kind_total_write_ns", "thread_id", thread, "wal_kind", walKind), detail.TotalWriteNS)
	setGauge(metricWithLabels("nrc_thread_wal_kind_compaction_mode", "thread_id", thread, "wal_kind", walKind), float64(detail.CompactionMode))
	setGauge(metricWithLabels("nrc_thread_wal_kind_compaction_bg_status", "thread_id", thread, "wal_kind", walKind), float64(detail.CompactionBGStatus))
	setCounter(metricWithLabels("nrc_thread_wal_kind_compaction_generation", "thread_id", thread, "wal_kind", walKind), detail.Generation)
	setGauge(metricWithLabels("nrc_thread_wal_kind_compaction_snapshot_end_bytes", "thread_id", thread, "wal_kind", walKind), float64(detail.SnapshotEnd))
	setCounter(metricWithLabels("nrc_thread_wal_kind_compaction_compact_count", "thread_id", thread, "wal_kind", walKind), detail.CompactCount)
	setGauge(metricWithLabels("nrc_thread_wal_kind_compaction_install_cursor_bytes", "thread_id", thread, "wal_kind", walKind), float64(detail.InstallCursor))
	setGauge(metricWithLabels("nrc_thread_wal_kind_compaction_install_last_backlog_bytes", "thread_id", thread, "wal_kind", walKind), float64(detail.InstallLastBacklog))
	setGauge(metricWithLabels("nrc_thread_wal_kind_compaction_install_budget_us", "thread_id", thread, "wal_kind", walKind), float64(detail.InstallBudgetUS))
}

func publishThreadShardSweepMetrics(thread string, sweep *protocol.StatsShardSweep) {
	if sweep == nil {
		sweep = &protocol.StatsShardSweep{}
	}
	setCounter(metricWithLabels("nrc_thread_shard_sweep_runs_total", "thread_id", thread), sweep.RunsTotal)
	setCounter(metricWithLabels("nrc_thread_shard_sweep_ordinary_runs_total", "thread_id", thread), sweep.OrdinaryRunsTotal)
	setCounter(metricWithLabels("nrc_thread_shard_sweep_raw_runs_total", "thread_id", thread), sweep.RawRunsTotal)
	setCounter(metricWithLabels("nrc_thread_shard_sweep_input_bytes_total", "thread_id", thread), sweep.InputBytesTotal)
	setCounter(metricWithLabels("nrc_thread_shard_sweep_dirty_bytes_total", "thread_id", thread), sweep.DirtyBytesTotal)
	setCounter(metricWithLabels("nrc_thread_shard_sweep_prefix_read_bytes_total", "thread_id", thread), sweep.PrefixReadBytesTotal)
	setCounter(metricWithLabels("nrc_thread_shard_sweep_latest_read_bytes_total", "thread_id", thread), sweep.LatestReadBytesTotal)
	setCounter(metricWithLabels("nrc_thread_shard_sweep_measure_read_bytes_total", "thread_id", thread), sweep.MeasureReadBytesTotal)
	setCounter(metricWithLabels("nrc_thread_shard_sweep_copy_read_bytes_total", "thread_id", thread), sweep.CopyReadBytesTotal)
	setCounter(metricWithLabels("nrc_thread_shard_sweep_replay_read_bytes_total", "thread_id", thread), sweep.ReplayReadBytesTotal)
	setCounter(metricWithLabels("nrc_thread_shard_sweep_metadata_fallbacks_total", "thread_id", thread), sweep.MetadataFallbacksTotal)
	setCounter(metricWithLabels("nrc_thread_shard_sweep_metadata_written_bytes_total", "thread_id", thread), sweep.MetadataWrittenBytesTotal)
}

func publishThreadMetricsZero(threadID uint32) {
	thread := strconv.FormatUint(uint64(threadID), 10)
	setGauge(metricWithLabels("nrc_thread_connections", "thread_id", thread), 0)
	setGauge(metricWithLabels("nrc_thread_memory_rss_megabytes", "thread_id", thread), 0)
	setGauge(metricWithLabels("nrc_thread_buffer_pool_usage_percent", "thread_id", thread), 0)
	setGauge(metricWithLabels("nrc_thread_io_pending", "thread_id", thread), 0)
	setGauge(metricWithLabels("nrc_thread_io_ring_depth", "thread_id", thread), 0)
	setGauge(metricWithLabels("nrc_thread_io_ring_available", "thread_id", thread), 0)
	setGauge(metricWithLabels("nrc_thread_io_sq_overflow", "thread_id", thread), 0)
	setGauge(metricWithLabels("nrc_thread_wal_file_size_bytes", "thread_id", thread), 0)
	setGauge(metricWithLabels("nrc_thread_wal_pending_bytes", "thread_id", thread), 0)
	setGauge(metricWithLabels("nrc_thread_last_pong_unix_seconds", "thread_id", thread), 0)
	publishThreadShardSweepMetrics(thread, nil)

	publishThreadWALKindMetricsZero(thread, "task")
	publishThreadWALKindMetricsZero(thread, "asset")
	publishThreadWALKindMetricsZero(thread, "edge")
}

func publishThreadMetricsSample(sample ThreadSample) {
	thread := strconv.FormatUint(uint64(sample.ThreadID), 10)
	p := sample.Pong

	setGauge(metricWithLabels("nrc_thread_connections", "thread_id", thread), float64(p.Connections))
	setGauge(metricWithLabels("nrc_thread_memory_rss_megabytes", "thread_id", thread), float64(p.MemoryTotalMB))
	setGauge(metricWithLabels("nrc_thread_buffer_pool_usage_percent", "thread_id", thread), float64(p.BufferPoolPercent))
	setGauge(metricWithLabels("nrc_thread_io_pending", "thread_id", thread), float64(p.IOPending))
	setGauge(metricWithLabels("nrc_thread_io_ring_depth", "thread_id", thread), float64(p.IORingDepth))
	setGauge(metricWithLabels("nrc_thread_io_ring_available", "thread_id", thread), float64(p.IORingAvailable))
	setGauge(metricWithLabels("nrc_thread_io_sq_overflow", "thread_id", thread), float64(p.IOSQOverflow))
	setCounter(metricWithLabels("nrc_thread_io_total_completions", "thread_id", thread), p.IOTotalCompletions)
	setCounter(metricWithLabels("nrc_thread_io_total_latency_ns", "thread_id", thread), p.IOTotalLatencyNS)
	setCounter(metricWithLabels("nrc_thread_io_latency_samples", "thread_id", thread), p.IOLatencyCount)
	setGauge(metricWithLabels("nrc_thread_wal_file_size_bytes", "thread_id", thread), float64(p.WALFileSize))
	setGauge(metricWithLabels("nrc_thread_wal_pending_bytes", "thread_id", thread), float64(p.WALPendingBytes))
	setCounter(metricWithLabels("nrc_thread_wal_records_total", "thread_id", thread), p.WALRecordCount)
	setCounter(metricWithLabels("nrc_thread_wal_fsync_total", "thread_id", thread), p.WALFsyncCount)
	setCounter(metricWithLabels("nrc_thread_wal_total_fsync_ns", "thread_id", thread), p.WALTotalFsyncNS)
	setCounter(metricWithLabels("nrc_thread_wal_total_write_ns", "thread_id", thread), p.WALTotalWriteNS)
	setCounter(metricWithLabels("nrc_thread_wal_write_total", "thread_id", thread), p.WALWriteCount)
	setGauge(metricWithLabels("nrc_thread_last_pong_unix_seconds", "thread_id", thread), float64(sample.ReceivedAt.Unix()))
	publishThreadShardSweepMetrics(thread, p.ShardSweep)

	seenWalKinds := map[string]struct{}{}
	for _, detail := range p.WALDetails {
		walKind := walKindLabel(detail.Kind)
		seenWalKinds[walKind] = struct{}{}
		publishThreadWALKindMetricsSample(thread, walKind, detail)
	}

	for _, walKind := range []string{"task", "asset", "edge"} {
		if _, ok := seenWalKinds[walKind]; ok {
			continue
		}
		publishThreadWALKindMetricsZero(thread, walKind)
	}
}

func NewNRCClient(cfg Config, workspace string, collector *Collector) *NRCClient {
	threadID, hasThreadID := parseThreadIDFromWorkspace(workspace)
	return &NRCClient{
		workspace:   workspace,
		cfg:         cfg,
		collector:   collector,
		threadID:    threadID,
		hasThreadID: hasThreadID,
	}
}

func parseThreadIDFromWorkspace(workspace string) (uint32, bool) {
	matches := threadFromWorkspacePattern.FindStringSubmatch(workspace)
	if len(matches) != 2 {
		return 0, false
	}

	threadID, err := strconv.ParseUint(matches[1], 10, 32)
	if err != nil {
		return 0, false
	}

	return uint32(threadID), true
}

func (c *NRCClient) setThreadID(threadID uint32) {
	c.threadIDMu.Lock()
	c.threadID = threadID
	c.hasThreadID = true
	c.threadIDMu.Unlock()
}

func (c *NRCClient) getThreadID() (uint32, bool) {
	c.threadIDMu.RLock()
	defer c.threadIDMu.RUnlock()
	return c.threadID, c.hasThreadID
}

func (c *NRCClient) Run(ctx context.Context) {
	backoff := 1 * time.Second
	const maxBackoff = 30 * time.Second

	for {
		select {
		case <-ctx.Done():
			c.closeConn()
			return
		default:
		}

		if err := c.connect(ctx); err != nil {
			incCounter(metricWithLabels("nrc_metrics_client_connect_error_total", "workspace", c.workspace))
			if threadID, ok := c.getThreadID(); ok {
				thread := strconv.FormatUint(uint64(threadID), 10)
				incCounter(metricWithLabels("nrc_metrics_client_connect_error_total", "thread_id", thread))
			} else {
				incCounter(metricWithLabels("nrc_metrics_client_connect_error_total", "thread_id", "unknown"))
			}
			slog.Error("nrc-metrics client connect failed", "workspace", c.workspace, "error", err)
		} else {
			backoff = 1 * time.Second
			c.collector.SetConnected(c.workspace, true)
			incCounter(metricWithLabels("nrc_metrics_client_connect_total", "workspace", c.workspace))
			if threadID, ok := c.getThreadID(); ok {
				thread := strconv.FormatUint(uint64(threadID), 10)
				incCounter(metricWithLabels("nrc_metrics_client_connect_total", "thread_id", thread))
			} else {
				incCounter(metricWithLabels("nrc_metrics_client_connect_total", "thread_id", "unknown"))
			}

			pingCtx, cancelPing := context.WithCancel(ctx)
			go c.pingLoop(pingCtx)
			go func() {
				<-ctx.Done()
				// Force-unblock readPump when shutting down so test harness stop()
				// doesn't wait for read timeouts before process exit.
				c.closeConn()
			}()
			c.readPump(ctx)
			cancelPing()

			c.closeConn()
			c.collector.SetConnected(c.workspace, false)
			c.collector.RemoveWorkspace(c.workspace)
			incCounter(metricWithLabels("nrc_metrics_client_disconnect_total", "workspace", c.workspace))
			if threadID, ok := c.getThreadID(); ok {
				thread := strconv.FormatUint(uint64(threadID), 10)
				incCounter(metricWithLabels("nrc_metrics_client_disconnect_total", "thread_id", thread))
			} else {
				incCounter(metricWithLabels("nrc_metrics_client_disconnect_total", "thread_id", "unknown"))
			}
		}

		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}

		backoff *= 2
		if backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
}

func (c *NRCClient) connect(ctx context.Context) error {
	url := fmt.Sprintf("%s/%s", strings.TrimRight(c.cfg.NRCServer, "/"), c.workspace)

	dialer := websocket.Dialer{
		HandshakeTimeout: 10 * time.Second,
	}

	headers := http.Header{
		"X-NRC-User-Type":    []string{"bot"},
		"X-NRC-Bot-Secret":   []string{c.cfg.NRCBotSecret},
		"X-NRC-Bot-Nickname": []string{c.cfg.NRCNickname},
	}

	conn, _, err := dialer.DialContext(ctx, url, headers)
	if err != nil {
		return fmt.Errorf("dial %s: %w", url, err)
	}

	conn.SetReadDeadline(time.Now().Add(c.cfg.ReadTimeout))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(c.cfg.ReadTimeout))
		return nil
	})

	c.connMu.Lock()
	c.conn = conn
	c.connMu.Unlock()

	slog.Info("nrc-metrics workspace connected", "workspace", c.workspace, "url", url)
	return nil
}

func (c *NRCClient) pingLoop(ctx context.Context) {
	if err := c.sendPing(); err != nil {
		slog.Warn("initial ping failed", "workspace", c.workspace, "error", err)
		return
	}

	ticker := time.NewTicker(c.cfg.PingInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := c.sendPing(); err != nil {
				slog.Warn("ping failed", "workspace", c.workspace, "error", err)
				return
			}
		}
	}
}

func (c *NRCClient) sendPing() error {
	if threadID, ok := c.getThreadID(); ok {
		thread := strconv.FormatUint(uint64(threadID), 10)
		incCounter(metricWithLabels("nrc_metrics_client_ping_sent_total", "thread_id", thread))
	} else {
		incCounter(metricWithLabels("nrc_metrics_client_ping_sent_total", "thread_id", "unknown"))
	}

	if err := c.sendProtocolMessage(protocol.C_Stats, protocol.EncodeStats(time.Now().UnixNano())); err != nil {
		incCounter(metricWithLabels("nrc_metrics_client_ping_error_total", "workspace", c.workspace))
		if threadID, ok := c.getThreadID(); ok {
			thread := strconv.FormatUint(uint64(threadID), 10)
			incCounter(metricWithLabels("nrc_metrics_client_ping_error_total", "thread_id", thread))
		} else {
			incCounter(metricWithLabels("nrc_metrics_client_ping_error_total", "thread_id", "unknown"))
		}
		c.closeConn()
		return err
	}

	incCounter(metricWithLabels("nrc_metrics_client_ping_sent_total", "workspace", c.workspace))
	return nil
}

func (c *NRCClient) sendProtocolMessage(opcode uint16, payload []byte) error {
	msg := &protocol.Message{Opcode: opcode, Data: payload}
	buf, err := msg.Write()
	if err != nil {
		return fmt.Errorf("encode message: %w", err)
	}

	conn := c.getConn()
	if conn == nil {
		return errNotConnected
	}

	c.writeMu.Lock()
	err = conn.WriteMessage(websocket.BinaryMessage, buf)
	c.writeMu.Unlock()

	if err != nil {
		return fmt.Errorf("write message: %w", err)
	}

	return nil
}

func (c *NRCClient) readPump(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		conn := c.getConn()
		if conn == nil {
			return
		}

		_, data, err := conn.ReadMessage()
		if err != nil {
			if !errors.Is(ctx.Err(), context.Canceled) {
				incCounter(metricWithLabels("nrc_metrics_client_read_error_total", "workspace", c.workspace))
				if threadID, ok := c.getThreadID(); ok {
					thread := strconv.FormatUint(uint64(threadID), 10)
					incCounter(metricWithLabels("nrc_metrics_client_read_error_total", "thread_id", thread))
				} else {
					incCounter(metricWithLabels("nrc_metrics_client_read_error_total", "thread_id", "unknown"))
				}
				slog.Warn("nrc-metrics read error", "workspace", c.workspace, "error", err)
			}
			return
		}

		conn.SetReadDeadline(time.Now().Add(c.cfg.ReadTimeout))

		msg, err := protocol.ReadMessage(data)
		if err != nil {
			incCounter(metricWithLabels("nrc_metrics_client_decode_error_total", "workspace", c.workspace, "opcode", "wire"))
			if threadID, ok := c.getThreadID(); ok {
				thread := strconv.FormatUint(uint64(threadID), 10)
				incCounter(metricWithLabels("nrc_metrics_client_decode_error_total", "thread_id", thread, "opcode", "wire"))
			} else {
				incCounter(metricWithLabels("nrc_metrics_client_decode_error_total", "thread_id", "unknown", "opcode", "wire"))
			}
			slog.Warn("failed to parse protocol message", "workspace", c.workspace, "error", err)
			continue
		}

		opcode := strconv.FormatUint(uint64(msg.Opcode), 10)
		switch msg.Opcode {
		case protocol.S_ServerReady:
			c.handleServerReady(data)
		case protocol.S_StatsResponse:
			pong, err := protocol.DecodeStatsResponse(msg.Data)
			if err != nil {
				incCounter(metricWithLabels("nrc_metrics_client_decode_error_total", "workspace", c.workspace, "opcode", opcode))
				if threadID, ok := c.getThreadID(); ok {
					thread := strconv.FormatUint(uint64(threadID), 10)
					incCounter(metricWithLabels("nrc_metrics_client_decode_error_total", "thread_id", thread, "opcode", opcode))
				} else {
					incCounter(metricWithLabels("nrc_metrics_client_decode_error_total", "thread_id", "unknown", "opcode", opcode))
				}
				slog.Warn("failed to decode stats response", "workspace", c.workspace, "error", err)
				continue
			}

			c.setThreadID(pong.ThreadID)
			thread := strconv.FormatUint(uint64(pong.ThreadID), 10)

			incCounter(metricWithLabels("nrc_metrics_client_pong_received_total", "workspace", c.workspace))
			incCounter(metricWithLabels("nrc_metrics_client_pong_received_total", "thread_id", thread))
			c.collector.UpdatePong(c.workspace, *pong)
		case protocol.S_ErrorResponse:
			errResp, err := protocol.DecodeErrorResponse(msg.Data)
			if err != nil {
				incCounter(metricWithLabels("nrc_metrics_client_decode_error_total", "workspace", c.workspace, "opcode", opcode))
				if threadID, ok := c.getThreadID(); ok {
					thread := strconv.FormatUint(uint64(threadID), 10)
					incCounter(metricWithLabels("nrc_metrics_client_decode_error_total", "thread_id", thread, "opcode", opcode))
				} else {
					incCounter(metricWithLabels("nrc_metrics_client_decode_error_total", "thread_id", "unknown", "opcode", opcode))
				}
				slog.Warn("failed to decode error response", "workspace", c.workspace, "error", err)
				continue
			}

			thread := "unknown"
			if threadID, ok := c.getThreadID(); ok {
				thread = strconv.FormatUint(uint64(threadID), 10)
			}

			incCounter(metricWithLabels(
				"nrc_metrics_client_protocol_error_total",
				"workspace", c.workspace,
				"origin_opcode", strconv.FormatUint(uint64(errResp.OriginOpcode), 10),
			))
			incCounter(metricWithLabels(
				"nrc_metrics_client_protocol_error_total",
				"thread_id", thread,
				"origin_opcode", strconv.FormatUint(uint64(errResp.OriginOpcode), 10),
			))

			slog.Warn(
				"received protocol error response",
				"workspace", c.workspace,
				"origin_opcode", errResp.OriginOpcode,
				"correlation_id", errResp.CorrelationID,
				"error", errResp.ErrorMessage,
			)
		default:
			// Ignore unrelated protocol messages.
		}
	}
}

func (c *NRCClient) handleServerReady(rawMessage []byte) {
	ready, err := protocol.ParseServerReady(rawMessage)
	if err != nil {
		incCounter(metricWithLabels("nrc_metrics_client_decode_error_total", "workspace", c.workspace, "opcode", strconv.FormatUint(uint64(protocol.S_ServerReady), 10)))
		slog.Warn("failed to parse server ready", "workspace", c.workspace, "error", err)
		return
	}

	slog.Info(
		"nrc-metrics workspace ready",
		"workspace", c.workspace,
		"build", ready.BuildVersion,
		"protocol_version", ready.ProtocolVersion,
		"cpu", ready.CPUModel,
		"username", ready.Username,
		"authenticated", ready.IsAuthenticated,
	)
}

func (c *NRCClient) getConn() *websocket.Conn {
	c.connMu.RLock()
	defer c.connMu.RUnlock()
	return c.conn
}

func (c *NRCClient) closeConn() {
	c.connMu.Lock()
	defer c.connMu.Unlock()

	if c.conn != nil {
		_ = c.conn.Close()
		c.conn = nil
	}
}

func metricWithLabels(base string, labels ...string) string {
	if len(labels) == 0 {
		return base
	}
	if len(labels)%2 != 0 {
		panic("metric labels must be key/value pairs")
	}

	var b strings.Builder
	b.Grow(len(base) + len(labels)*8)
	b.WriteString(base)
	b.WriteByte('{')
	for i := 0; i < len(labels); i += 2 {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(labels[i])
		b.WriteByte('=')
		b.WriteString(strconv.Quote(labels[i+1]))
	}
	b.WriteByte('}')
	return b.String()
}

func setGauge(name string, value float64) {
	metrics.GetOrCreateGauge(name, nil).Set(value)
}

func setCounter(name string, value uint64) {
	metrics.GetOrCreateCounter(name).Set(value)
}

func incCounter(name string) {
	metrics.GetOrCreateCounter(name).Inc()
}

func boolToFloat(v bool) float64 {
	if v {
		return 1
	}
	return 0
}
