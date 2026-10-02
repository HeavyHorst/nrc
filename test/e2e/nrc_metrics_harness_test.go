package e2e

import (
	"bytes"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

const (
	metricsBotSecret = "e2e-test-bot-secret"
	metricsNickname  = "e2e-metrics-bot"
)

type metricsProcess struct {
	cmd       *exec.Cmd
	logs      bytes.Buffer
	port      int
	workDir   string
	serverURL string
}

func (p *metricsProcess) healthURL() string {
	return fmt.Sprintf("http://localhost:%d/health", p.port)
}

func (p *metricsProcess) metricsURL() string {
	return fmt.Sprintf("http://localhost:%d/metrics", p.port)
}

func (p *metricsProcess) stop(t *testing.T) {
	t.Helper()

	if p == nil || p.cmd == nil || p.cmd.Process == nil {
		return
	}

	_ = p.cmd.Process.Signal(syscall.SIGINT)

	done := make(chan error, 1)
	go func() {
		done <- p.cmd.Wait()
	}()

	select {
	case <-time.After(2 * time.Second):
		_ = p.cmd.Process.Kill()
		<-done
	case <-done:
	}

	if p.workDir != "" {
		_ = os.RemoveAll(p.workDir)
	}
}

type metricsConfig struct {
	mode          string   // "static" or "thread-targeted"
	workspaces    []string // for static mode
	targetThreads uint32   // for thread-targeted mode
	expectThreads uint32   // for thread-targeted mode
	prefix        string   // workspace prefix for thread-targeted mode
	pingInterval  time.Duration
}

func (c metricsConfig) getPingInterval() time.Duration {
	if c.pingInterval > 0 {
		return c.pingInterval
	}
	return 1 * time.Second
}

var (
	metricsBuildOnce sync.Once
	metricsBuildPath string
	metricsBuildErr  error
	metricsBuildLogs string
)

func startMetricsCollector(t *testing.T, cfg metricsConfig, nrcServerURL string) *metricsProcess {
	t.Helper()

	port, err := findFreePort()
	if err != nil {
		t.Fatalf("failed to find free port for metrics: %v", err)
	}

	workDir, err := os.MkdirTemp("", "nrc-metrics-e2e-")
	if err != nil {
		t.Fatalf("failed to create metrics work dir: %v", err)
	}

	proc := &metricsProcess{
		port:      port,
		workDir:   workDir,
		serverURL: nrcServerURL,
	}

	env := append(os.Environ(),
		fmt.Sprintf("NRC_SERVER=%s", nrcServerURL),
		fmt.Sprintf("NRC_BOT_SECRET=%s", metricsBotSecret),
		fmt.Sprintf("NRC_NICKNAME=%s", metricsNickname),
		fmt.Sprintf("METRICS_PORT=%d", port),
		fmt.Sprintf("NRC_METRICS_WORKSPACE_MODE=%s", cfg.mode),
		fmt.Sprintf("PING_INTERVAL=%s", cfg.getPingInterval()),
		fmt.Sprintf("READ_TIMEOUT=10s"),
	)

	switch cfg.mode {
	case "static":
		if len(cfg.workspaces) == 0 {
			t.Fatal("static mode requires at least one workspace")
		}
		env = append(env, fmt.Sprintf("NRC_WORKSPACES=%s", strings.Join(cfg.workspaces, ",")))
	case "thread-targeted":
		if cfg.prefix != "" {
			env = append(env, fmt.Sprintf("NRC_METRICS_WORKSPACE_PREFIX=%s", cfg.prefix))
		}
		if cfg.targetThreads > 0 {
			env = append(env, fmt.Sprintf("NRC_METRICS_TARGET_THREADS=%d", cfg.targetThreads))
		}
		if cfg.expectThreads > 0 {
			env = append(env, fmt.Sprintf("NRC_METRICS_EXPECT_THREADS=%d", cfg.expectThreads))
		}
	}

	binPath := buildMetricsBinaryOnce(t)

	cmd := exec.Command(binPath)
	cmd.Dir = workDir
	cmd.Env = env
	cmd.Stdout = &proc.logs
	cmd.Stderr = &proc.logs

	proc.cmd = cmd

	if err := cmd.Start(); err != nil {
		_ = os.RemoveAll(workDir)
		t.Fatalf("failed to start metrics collector: %v", err)
	}

	if err := waitForMetricsReady(proc.healthURL(), 10*time.Second); err != nil {
		proc.stop(t)
		t.Fatalf("metrics collector did not become ready: %v\nlogs:\n%s", err, proc.logs.String())
	}

	return proc
}

func buildMetricsBinaryOnce(t *testing.T) string {
	t.Helper()

	repoRoot := repoRootFromThisFile(t)

	metricsBuildOnce.Do(func() {
		buildDir, err := os.MkdirTemp("", "nrc-metrics-e2e-bin-")
		if err != nil {
			metricsBuildErr = fmt.Errorf("failed to create temp build dir: %w", err)
			return
		}

		metricsBuildPath = filepath.Join(buildDir, "nrc-metrics-e2e")

		metricsDir := filepath.Join(repoRoot, "services", "bots", "nrc-metrics")
		buildCmd := exec.Command("go", "build", "-o", metricsBuildPath, ".")
		buildCmd.Dir = metricsDir
		buildOutput, err := buildCmd.CombinedOutput()
		metricsBuildLogs = string(buildOutput)
		if err != nil {
			metricsBuildErr = fmt.Errorf("failed to build nrc-metrics: %w", err)
		}
	})

	if metricsBuildErr != nil {
		t.Fatalf("%v\n%s", metricsBuildErr, metricsBuildLogs)
	}

	return metricsBuildPath
}

func waitForMetricsReady(healthURL string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)

	for time.Now().Before(deadline) {
		resp, err := http.Get(healthURL)
		if err == nil && resp.StatusCode == http.StatusOK {
			resp.Body.Close()
			return nil
		}
		if resp != nil {
			resp.Body.Close()
		}
		time.Sleep(100 * time.Millisecond)
	}

	return fmt.Errorf("timeout waiting for metrics endpoint at %s", healthURL)
}

func findFreePort() (int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer ln.Close()

	return ln.Addr().(*net.TCPAddr).Port, nil
}
