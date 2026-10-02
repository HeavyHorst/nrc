package e2e

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"testing"
	"time"
)

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

func fetchHealth(t *testing.T, url string) *healthResponse {
	t.Helper()

	resp, err := http.Get(url)
	if err != nil {
		t.Fatalf("failed to fetch health endpoint: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("health endpoint returned status %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("failed to read health response: %v", err)
	}

	var health healthResponse
	if err := json.Unmarshal(body, &health); err != nil {
		t.Fatalf("failed to parse health response: %v\nbody: %s", err, string(body))
	}

	return &health
}

func waitForHealthStatus(t *testing.T, url string, wantStatus string, timeout time.Duration) *healthResponse {
	t.Helper()

	deadline := time.Now().Add(timeout)
	var lastHealth *healthResponse

	for time.Now().Before(deadline) {
		health := fetchHealth(t, url)
		lastHealth = health

		if health.Status == wantStatus {
			return health
		}

		time.Sleep(100 * time.Millisecond)
	}

	t.Fatalf("health status never became %q within %v, last status: %q", wantStatus, timeout, lastHealth.Status)
	return nil
}

func waitForWorkspacesConnected(t *testing.T, url string, wantCount int, timeout time.Duration) *healthResponse {
	t.Helper()

	deadline := time.Now().Add(timeout)
	var lastHealth *healthResponse

	for time.Now().Before(deadline) {
		health := fetchHealth(t, url)
		lastHealth = health

		if health.WorkspacesConnected >= wantCount && health.WorkspacesWithPong >= wantCount {
			return health
		}

		time.Sleep(100 * time.Millisecond)
	}

	t.Fatalf("workspaces never reached %d connected/pong within %v, got %d/%d",
		wantCount, timeout, lastHealth.WorkspacesConnected, lastHealth.WorkspacesWithPong)
	return nil
}

func waitForMetricsAvailable(t *testing.T, url string, timeout time.Duration) string {
	t.Helper()

	deadline := time.Now().Add(timeout)

	for time.Now().Before(deadline) {
		resp, err := http.Get(url)
		if err == nil && resp.StatusCode == http.StatusOK {
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if len(body) > 0 {
				return string(body)
			}
		}
		if resp != nil {
			resp.Body.Close()
		}
		time.Sleep(100 * time.Millisecond)
	}

	t.Fatalf("metrics endpoint never became available within %v", timeout)
	return ""
}

func fetchMetrics(t *testing.T, url string) string {
	t.Helper()

	resp, err := http.Get(url)
	if err != nil {
		t.Fatalf("failed to fetch metrics endpoint: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("metrics endpoint returned status %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("failed to read metrics response: %v", err)
	}

	return string(body)
}

func extractMetricValue(t *testing.T, metrics string, metricName string) float64 {
	t.Helper()

	pattern := fmt.Sprintf(`^%s\s+(\d+(?:\.\d+)?)$`, regexp.QuoteMeta(metricName))
	re := regexp.MustCompile("(?m)" + pattern)

	matches := re.FindStringSubmatch(metrics)
	if len(matches) < 2 {
		t.Fatalf("metric %s not found in metrics output", metricName)
	}

	val, err := strconv.ParseFloat(matches[1], 64)
	if err != nil {
		t.Fatalf("failed to parse metric value for %s: %v", metricName, err)
	}

	return val
}

func extractMetricWithLabel(t *testing.T, metrics string, metricName string, labelKey string, labelValue string) float64 {
	t.Helper()

	pattern := fmt.Sprintf(`^%s\{%s="%s".*?\}\s+(\d+(?:\.\d+)?)$`,
		regexp.QuoteMeta(metricName),
		regexp.QuoteMeta(labelKey),
		regexp.QuoteMeta(labelValue))
	re := regexp.MustCompile("(?m)" + pattern)

	matches := re.FindStringSubmatch(metrics)
	if len(matches) < 2 {
		t.Fatalf("metric %s with %s=%q not found in metrics output", metricName, labelKey, labelValue)
	}

	val, err := strconv.ParseFloat(matches[1], 64)
	if err != nil {
		t.Fatalf("failed to parse metric value for %s: %v", metricName, err)
	}

	return val
}

func hasMetric(t *testing.T, metrics string, metricName string) bool {
	t.Helper()

	pattern := fmt.Sprintf(`^%s[\s\{]`, regexp.QuoteMeta(metricName))
	re := regexp.MustCompile("(?m)" + pattern)

	return re.MatchString(metrics)
}
