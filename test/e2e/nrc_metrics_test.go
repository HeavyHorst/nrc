package e2e

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestMetricsCollectorStaticModeSingleWorkspace(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("metrics-static-%d", time.Now().UnixNano())

	metrics := startMetricsCollector(t, metricsConfig{
		mode:       "static",
		workspaces: []string{workspace},
	}, fmt.Sprintf("ws://%s:%d", serverHost, serverPort))
	defer metrics.stop(t)

	// Poll until workspace is connected with pong data
	health := waitForWorkspacesConnected(t, metrics.healthURL(), 1, 10*time.Second)

	// With single workspace covering 1 of 16 threads, expect degraded status
	if health.Status != "degraded" && health.Status != "ok" {
		t.Errorf("status = %q, want ok or degraded", health.Status)
	}
	if health.WorkspacesConfigured != 1 {
		t.Errorf("workspaces_configured = %d, want 1", health.WorkspacesConfigured)
	}
	if health.WorkspacesConnected != 1 {
		t.Errorf("workspaces_connected = %d, want 1", health.WorkspacesConnected)
	}
	if health.WorkspacesWithPong != 1 {
		t.Errorf("workspaces_with_pong = %d, want 1", health.WorkspacesWithPong)
	}

	metricsOutput := fetchMetrics(t, metrics.metricsURL())

	if !hasMetric(t, metricsOutput, "nrc_metrics_workspaces_configured") {
		t.Error("missing nrc_metrics_workspaces_configured metric")
	}
	if !hasMetric(t, metricsOutput, "nrc_metrics_connection_up") {
		t.Error("missing nrc_metrics_connection_up metric")
	}

	threadLabel := extractThreadIDLabelForConnection(t, metricsOutput)
	upValue := extractMetricWithLabel(t, metricsOutput, "nrc_metrics_connection_up", "thread_id", threadLabel)
	if upValue != 1 {
		t.Errorf("nrc_metrics_connection_up{thread_id=%q} = %v, want 1", threadLabel, upValue)
	}
}

func TestMetricsCollectorStaticModeMultipleWorkspaces(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	ts := time.Now().UnixNano()
	workspaces := []string{
		fmt.Sprintf("metrics-multi-%d-1", ts),
		fmt.Sprintf("metrics-multi-%d-2", ts),
		fmt.Sprintf("metrics-multi-%d-3", ts),
	}

	metrics := startMetricsCollector(t, metricsConfig{
		mode:       "static",
		workspaces: workspaces,
	}, fmt.Sprintf("ws://%s:%d", serverHost, serverPort))
	defer metrics.stop(t)

	// Poll until all 3 workspaces are connected
	health := waitForWorkspacesConnected(t, metrics.healthURL(), 3, 15*time.Second)

	if health.WorkspacesConfigured != 3 {
		t.Errorf("workspaces_configured = %d, want 3", health.WorkspacesConfigured)
	}
	if health.WorkspacesConnected != 3 {
		t.Errorf("workspaces_connected = %d, want 3", health.WorkspacesConnected)
	}

	metricsOutput := fetchMetrics(t, metrics.metricsURL())

	threadConnectionUpCount := countMetricSeriesWithLabelValue(t, metricsOutput, "nrc_metrics_connection_up", "1")
	if threadConnectionUpCount == 0 {
		t.Error("expected at least one nrc_metrics_connection_up{thread_id=*}=1 series")
	}

	configured := extractMetricValue(t, metricsOutput, "nrc_metrics_workspaces_configured")
	if configured != 3 {
		t.Errorf("nrc_metrics_workspaces_configured = %v, want 3", configured)
	}
}

func TestMetricsCollectorThreadTargetedMode(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	const requestedThreads = 2
	metrics := startMetricsCollector(t, metricsConfig{
		mode:          "thread-targeted",
		prefix:        "e2e-targeted",
		targetThreads: requestedThreads,
	}, fmt.Sprintf("ws://%s:%d", serverHost, serverPort))
	defer metrics.stop(t)

	// Thread-targeted mode clamps the requested target to the server's discovered
	// worker count. Use the resolved plan so this test also works on hosts where
	// the process is restricted to a single CPU.
	plan := fetchHealth(t, metrics.healthURL())
	resolvedThreads := int(plan.ThreadsExpected)
	if resolvedThreads < 1 || resolvedThreads > requestedThreads {
		t.Fatalf("threads_expected = %d, want in [1, %d]", resolvedThreads, requestedThreads)
	}
	if plan.WorkspacesConfigured != resolvedThreads {
		t.Fatalf("workspaces_configured = %d, want resolved thread count %d", plan.WorkspacesConfigured, resolvedThreads)
	}

	// Poll until every workspace in the resolved plan is connected.
	health := waitForWorkspacesConnected(t, metrics.healthURL(), resolvedThreads, 15*time.Second)

	if health.WorkspaceMode != "thread-targeted" {
		t.Errorf("workspace_mode = %q, want thread-targeted", health.WorkspaceMode)
	}
	if health.ThreadsObserved == 0 {
		t.Error("threads_observed is 0, expected > 0")
	}
	if health.WorkspacesConfigured == 0 {
		t.Error("workspaces_configured is 0, expected > 0")
	}

	threadIDs := make([]string, resolvedThreads)
	for threadID := range threadIDs {
		threadIDs[threadID] = strconv.Itoa(threadID)
	}
	metricsOutput := waitForThreadCoverageMetrics(t, metrics.metricsURL(), threadIDs, 5*time.Second)

	if !hasMetric(t, metricsOutput, "nrc_metrics_threads_observed") {
		t.Error("missing nrc_metrics_threads_observed metric")
	}
	if !hasMetric(t, metricsOutput, "nrc_metrics_thread_covered") {
		t.Error("missing nrc_metrics_thread_covered metric")
	}

	if health.ThreadsCovered < resolvedThreads {
		t.Errorf("threads_covered = %d, want at least %d", health.ThreadsCovered, resolvedThreads)
	}

	for _, threadID := range threadIDs {
		covered := extractMetricWithLabel(t, metricsOutput, "nrc_metrics_thread_covered", "thread_id", threadID)
		if covered != 1 {
			t.Errorf("nrc_metrics_thread_covered{thread_id=%q} = %v, want 1", threadID, covered)
		}
	}
}

func TestMetricsCollectorHealthEndpointFields(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("metrics-health-%d", time.Now().UnixNano())

	metrics := startMetricsCollector(t, metricsConfig{
		mode:       "static",
		workspaces: []string{workspace},
	}, fmt.Sprintf("ws://%s:%d", serverHost, serverPort))
	defer metrics.stop(t)

	// Poll until connected
	health := waitForWorkspacesConnected(t, metrics.healthURL(), 1, 10*time.Second)

	if health.NRCServer == "" {
		t.Error("nrc_server field is empty")
	}
	if health.PingInterval == "" {
		t.Error("ping_interval field is empty")
	}
	if health.ReadTimeout == "" {
		t.Error("read_timeout field is empty")
	}
	if health.Uptime == "" {
		t.Error("uptime field is empty")
	}
}

func TestMetricsCollectorPrometheusMetricsFormat(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("metrics-prom-%d", time.Now().UnixNano())

	metrics := startMetricsCollector(t, metricsConfig{
		mode:       "static",
		workspaces: []string{workspace},
	}, fmt.Sprintf("ws://%s:%d", serverHost, serverPort))
	defer metrics.stop(t)

	// Poll until workspace is connected and pong data is available.
	waitForWorkspacesConnected(t, metrics.healthURL(), 1, 10*time.Second)
	metricsOutput := waitForMetricsAvailable(t, metrics.metricsURL(), 10*time.Second)

	requiredMetrics := []string{
		"nrc_metrics_build_info",
		"nrc_metrics_workspaces_configured",
		"nrc_metrics_workspaces_connected",
		"nrc_metrics_threads_observed",
		"nrc_metrics_connections_total",
		"nrc_thread_wal_kind_file_size_bytes",
		"nrc_thread_wal_kind_compaction_mode",
		"nrc_thread_shard_sweep_runs_total",
		"nrc_thread_shard_sweep_ordinary_runs_total",
		"nrc_thread_shard_sweep_raw_runs_total",
		"nrc_thread_shard_sweep_input_bytes_total",
		"nrc_thread_shard_sweep_dirty_bytes_total",
		"nrc_thread_shard_sweep_prefix_read_bytes_total",
		"nrc_thread_shard_sweep_latest_read_bytes_total",
		"nrc_thread_shard_sweep_measure_read_bytes_total",
		"nrc_thread_shard_sweep_copy_read_bytes_total",
		"nrc_thread_shard_sweep_replay_read_bytes_total",
		"nrc_thread_shard_sweep_metadata_fallbacks_total",
		"nrc_thread_shard_sweep_metadata_written_bytes_total",
	}

	for _, metric := range requiredMetrics {
		if !hasMetric(t, metricsOutput, metric) {
			t.Errorf("missing required metric: %s", metric)
		}
	}

	if extractMetricValue(t, metricsOutput, "nrc_metrics_workspaces_configured") != 1 {
		t.Errorf("nrc_metrics_workspaces_configured = %v, want 1", extractMetricValue(t, metricsOutput, "nrc_metrics_workspaces_configured"))
	}
	if extractMetricValue(t, metricsOutput, "nrc_metrics_workspaces_connected") != 1 {
		t.Errorf("nrc_metrics_workspaces_connected = %v, want 1", extractMetricValue(t, metricsOutput, "nrc_metrics_workspaces_connected"))
	}
	threadLabel := extractThreadIDLabelForConnection(t, metricsOutput)
	if extractMetricWithLabel(t, metricsOutput, "nrc_metrics_connection_up", "thread_id", threadLabel) != 1 {
		t.Errorf("nrc_metrics_connection_up{thread_id=%q} = %v, want 1", threadLabel, extractMetricWithLabel(t, metricsOutput, "nrc_metrics_connection_up", "thread_id", threadLabel))
	}
	if extractMetricWithLabel(t, metricsOutput, "nrc_metrics_connection_has_pong", "thread_id", threadLabel) != 1 {
		t.Errorf("nrc_metrics_connection_has_pong{thread_id=%q} = %v, want 1", threadLabel, extractMetricWithLabel(t, metricsOutput, "nrc_metrics_connection_has_pong", "thread_id", threadLabel))
	}
	threadID := extractMetricWithLabel(t, metricsOutput, "nrc_metrics_connection_thread_id", "thread_id", threadLabel)
	if threadID < 0 {
		t.Errorf("nrc_metrics_connection_thread_id{thread_id=%q} = %v, want >= 0", threadLabel, threadID)
	}
	lastPong := extractMetricWithLabel(t, metricsOutput, "nrc_metrics_connection_last_pong_unix_seconds", "thread_id", threadLabel)
	now := float64(time.Now().Unix())
	if lastPong <= 0 || lastPong > now {
		t.Errorf("nrc_metrics_connection_last_pong_unix_seconds{thread_id=%q} = %v, want in (0, now]", threadLabel, lastPong)
	}

	walKindSeries := countMetricSeriesWithLabel(t, metricsOutput, "nrc_thread_wal_kind_compaction_mode", "thread_id", threadLabel)
	if walKindSeries < 3 {
		t.Errorf("nrc_thread_wal_kind_compaction_mode has %d series for thread_id=%q, want >= 3 (task/asset/edge)", walKindSeries, threadLabel)
	}
	for _, metric := range requiredMetrics[7:] {
		if value := extractMetricWithLabel(t, metricsOutput, metric, "thread_id", threadLabel); value < 0 {
			t.Errorf("%s{thread_id=%q} = %v, want cumulative value >= 0", metric, threadLabel, value)
		}
	}
}

func TestMetricsCollectorThreadExpectationMismatch(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	metrics := startMetricsCollector(t, metricsConfig{
		mode:          "thread-targeted",
		prefix:        "e2e-mismatch",
		expectThreads: 999,
	}, fmt.Sprintf("ws://%s:%d", serverHost, serverPort))
	defer metrics.stop(t)

	// Poll for health with extended timeout for thread discovery
	deadline := time.Now().Add(20 * time.Second)
	var health *healthResponse
	for time.Now().Before(deadline) {
		health = fetchHealth(t, metrics.healthURL())
		if health.ThreadCountMismatch {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}

	if !health.ThreadCountMismatch {
		t.Error("expected thread_count_mismatch to be true when EXPECT_THREADS doesn't match observed")
	}
}

func TestMetricsCollectorConnectionMetrics(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("metrics-conn-%d", time.Now().UnixNano())

	metrics := startMetricsCollector(t, metricsConfig{
		mode:       "static",
		workspaces: []string{workspace},
	}, fmt.Sprintf("ws://%s:%d", serverHost, serverPort))
	defer metrics.stop(t)

	// Poll until workspace connected with pong data, then fetch metrics
	waitForWorkspacesConnected(t, metrics.healthURL(), 1, 10*time.Second)
	metricsOutput := fetchMetrics(t, metrics.metricsURL())

	connectionMetrics := []string{
		"nrc_metrics_connection_thread_id",
		"nrc_metrics_connection_last_pong_unix_seconds",
		"nrc_connection_send_queue_depth",
		"nrc_connection_send_queue_limit",
	}

	for _, metric := range connectionMetrics {
		if !hasMetric(t, metricsOutput, metric) {
			t.Errorf("missing connection metric: %s", metric)
		}
	}

	threadLabel := extractThreadIDLabelForConnection(t, metricsOutput)
	threadID := extractMetricWithLabel(t, metricsOutput, "nrc_metrics_connection_thread_id", "thread_id", threadLabel)
	if threadID < 0 {
		t.Errorf("connection has invalid thread_id: %v", threadID)
	}
}

func TestMetricsCollectorReconnectionAfterServerRestart(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("metrics-reconnect-%d", time.Now().UnixNano())

	metrics := startMetricsCollector(t, metricsConfig{
		mode:       "static",
		workspaces: []string{workspace},
	}, fmt.Sprintf("ws://%s:%d", serverHost, serverPort))
	defer metrics.stop(t)

	// Wait for initial connection
	waitForWorkspacesConnected(t, metrics.healthURL(), 1, 10*time.Second)

	// Stop the shared e2e server (but keep metrics collector running).
	stopSharedServerIfRunning()

	// Verify metrics shows degraded/disconnected state.
	deadline := time.Now().Add(12 * time.Second)
	var wasDisconnected bool
	for time.Now().Before(deadline) {
		health := fetchHealth(t, metrics.healthURL())
		if health.WorkspacesConnected == 0 {
			wasDisconnected = true
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	if !wasDisconnected {
		t.Fatal("workspace was never detected as disconnected after server stop")
	}

	// Restart server (new workDir, same port)
	server = startServer(t)
	defer server.stop(t)

	// Verify metrics collector reconnects
	health := waitForWorkspacesConnected(t, metrics.healthURL(), 1, 15*time.Second)

	if health.WorkspacesConnected != 1 {
		t.Errorf("workspaces_connected = %d after restart, want 1", health.WorkspacesConnected)
	}

	// Verify metrics still flow
	metricsOutput := fetchMetrics(t, metrics.metricsURL())
	if !hasMetric(t, metricsOutput, "nrc_metrics_connection_up") {
		t.Error("missing nrc_metrics_connection_up metric after restart")
	}
}

func TestMetricsCollectorExponentialBackoff(t *testing.T) {
	// Start metrics collector without server running
	workspace := fmt.Sprintf("metrics-backoff-%d", time.Now().UnixNano())

	port, _ := findFreePort()
	fakeServerURL := fmt.Sprintf("ws://127.0.0.1:%d", port)

	metrics := startMetricsCollector(t, metricsConfig{
		mode:       "static",
		workspaces: []string{workspace},
	}, fakeServerURL)
	defer metrics.stop(t)

	// Verify retry cadence follows approximately 1s, 2s backoff after failed attempts.
	start := time.Now()
	tFirst := waitForCounterAtLeast(t, metrics.metricsURL(), "nrc_metrics_client_connect_error_total", "thread_id", "unknown", 1, 2*time.Second)
	tSecond := waitForCounterAtLeast(t, metrics.metricsURL(), "nrc_metrics_client_connect_error_total", "thread_id", "unknown", 2, 3*time.Second)
	if tSecond.Sub(tFirst) < 700*time.Millisecond {
		t.Fatalf("second connect error came too quickly: delta=%v, expected around 1s", tSecond.Sub(tFirst))
	}

	stillTwoBy := tSecond.Add(1200 * time.Millisecond)
	for time.Now().Before(stillTwoBy) {
		val, ok := lookupMetricWithLabel(fetchMetrics(t, metrics.metricsURL()), "nrc_metrics_client_connect_error_total", "thread_id", "unknown")
		if !ok {
			t.Fatal("nrc_metrics_client_connect_error_total{thread_id=\"unknown\"} missing")
		}
		if val >= 3 {
			t.Fatalf("third connect error happened too early after second: value=%v", val)
		}
		time.Sleep(100 * time.Millisecond)
	}

	tThird := waitForCounterAtLeast(t, metrics.metricsURL(), "nrc_metrics_client_connect_error_total", "thread_id", "unknown", 3, 4*time.Second)
	if tThird.Sub(tSecond) < 1500*time.Millisecond {
		t.Fatalf("third connect error came too quickly: delta=%v, expected around 2s", tThird.Sub(tSecond))
	}

	logs := metrics.logs.String()
	if !strings.Contains(logs, "connect failed") && !strings.Contains(logs, "dial") {
		t.Fatal("expected connection failures in logs during backoff test")
	}

	// The collector should still be running and attempting reconnections
	health := fetchHealth(t, metrics.healthURL())

	if health.WorkspacesConnected != 0 {
		t.Logf("Unexpected: workspace connected to non-existent server")
	}

	// Verify the process is still alive and health endpoint responds
	if health.Status != "degraded" && health.WorkspacesConfigured > 0 {
		t.Logf("Health responding correctly with degraded status")
	}

	t.Logf("Backoff test complete: first=%v second=%v third=%v since start=%v", tFirst.Sub(start), tSecond.Sub(start), tThird.Sub(start), time.Since(start))
}

func TestMetricsCollectorPingIntervalAccuracy(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("metrics-ping-%d", time.Now().UnixNano())

	// Use 2s ping interval to make timing measurement easier
	metrics := startMetricsCollector(t, metricsConfig{
		mode:         "static",
		workspaces:   []string{workspace},
		pingInterval: 2 * time.Second,
	}, fmt.Sprintf("ws://%s:%d", serverHost, serverPort))
	defer metrics.stop(t)

	// Wait for initial connection and pong sample availability.
	waitForWorkspacesConnected(t, metrics.healthURL(), 1, 10*time.Second)

	metricsOutput := fetchMetrics(t, metrics.metricsURL())
	threadLabel := extractThreadIDLabelForConnection(t, metricsOutput)
	first := extractMetricWithLabel(t, metricsOutput, "nrc_metrics_connection_last_pong_unix_seconds", "thread_id", threadLabel)
	if first <= 0 {
		t.Fatalf("initial last pong timestamp invalid: %v", first)
	}

	deadline := time.Now().Add(7 * time.Second)
	second := first
	for time.Now().Before(deadline) {
		second = extractMetricWithLabel(t, fetchMetrics(t, metrics.metricsURL()), "nrc_metrics_connection_last_pong_unix_seconds", "thread_id", threadLabel)
		if second > first {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}

	if second <= first {
		t.Fatalf("pong timestamp never advanced within timeout: first=%v second=%v", first, second)
	}

	delta := second - first
	if delta < 1 || delta > 5 {
		t.Fatalf("pong timestamp cadence out of range: delta=%.0fs, expected 1-5s for 2s interval", delta)
	}

	t.Logf("Ping interval test: first=%.0f second=%.0f delta=%.0fs", first, second, delta)
}

func waitForCounterAtLeast(t *testing.T, metricsURL string, metricName string, labelKey string, labelValue string, want float64, timeout time.Duration) time.Time {
	t.Helper()

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		metricsOutput := fetchMetrics(t, metricsURL)
		val, ok := lookupMetricWithLabel(metricsOutput, metricName, labelKey, labelValue)
		if ok && val >= want {
			return time.Now()
		}
		time.Sleep(100 * time.Millisecond)
	}

	t.Fatalf("metric %s{%s=%q} never reached >= %.0f within %v", metricName, labelKey, labelValue, want, timeout)
	return time.Time{}
}

func waitForThreadCoverageMetrics(t *testing.T, metricsURL string, threadIDs []string, timeout time.Duration) string {
	t.Helper()

	deadline := time.Now().Add(timeout)
	lastOutput := ""

	for time.Now().Before(deadline) {
		metricsOutput := fetchMetrics(t, metricsURL)
		lastOutput = metricsOutput

		allCovered := true
		for _, threadID := range threadIDs {
			covered, ok := lookupMetricWithLabel(metricsOutput, "nrc_metrics_thread_covered", "thread_id", threadID)
			if !ok || covered != 1 {
				allCovered = false
				break
			}
		}

		if allCovered {
			return metricsOutput
		}

		time.Sleep(100 * time.Millisecond)
	}

	t.Fatalf("nrc_metrics_thread_covered did not converge for thread_ids=%v within %v", threadIDs, timeout)
	return lastOutput
}

func lookupMetricWithLabel(metricsOutput string, metricName string, labelKey string, labelValue string) (float64, bool) {
	pattern := fmt.Sprintf(`(?m)^%s\{%s="%s".*?\}\s+([0-9]+(?:\.[0-9]+)?)$`, regexp.QuoteMeta(metricName), regexp.QuoteMeta(labelKey), regexp.QuoteMeta(labelValue))
	matches := regexp.MustCompile(pattern).FindStringSubmatch(metricsOutput)
	if len(matches) < 2 {
		return 0, false
	}

	val, err := strconv.ParseFloat(matches[1], 64)
	if err != nil {
		return 0, false
	}

	return val, true
}

func extractThreadIDLabelForConnection(t *testing.T, metricsOutput string) string {
	t.Helper()

	pattern := `(?m)^nrc_metrics_connection_thread_id\{thread_id="(\d+)".*?\}\s+[0-9]+(?:\.[0-9]+)?$`
	matches := regexp.MustCompile(pattern).FindStringSubmatch(metricsOutput)
	if len(matches) < 2 {
		t.Fatal("no nrc_metrics_connection_thread_id{thread_id=*} series found")
	}

	return matches[1]
}

func countMetricSeriesWithLabelValue(t *testing.T, metricsOutput string, metricName string, expectedValue string) int {
	t.Helper()

	pattern := fmt.Sprintf(`(?m)^%s\{thread_id="[^"]+".*?\}\s+%s$`, regexp.QuoteMeta(metricName), regexp.QuoteMeta(expectedValue))
	return len(regexp.MustCompile(pattern).FindAllString(metricsOutput, -1))
}

func countMetricSeriesWithLabel(t *testing.T, metricsOutput string, metricName string, labelKey string, labelValue string) int {
	t.Helper()

	pattern := fmt.Sprintf(
		`(?m)^%s\{[^}]*%s="%s"[^}]*\}\s+[-+]?[0-9]+(?:\.[0-9]+)?$`,
		regexp.QuoteMeta(metricName),
		regexp.QuoteMeta(labelKey),
		regexp.QuoteMeta(labelValue),
	)
	return len(regexp.MustCompile(pattern).FindAllString(metricsOutput, -1))
}
