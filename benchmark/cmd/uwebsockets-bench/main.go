package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/nrc/benchmark/scenario"
)

type managed_server struct {
	cmd  *exec.Cmd
	logs bytes.Buffer
}

func benchmarkDir() (string, error) {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		return "", fmt.Errorf("failed to resolve current file path")
	}
	toolDir := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", "uwebsockets"))
	if _, err := os.Stat(filepath.Join(toolDir, "server.cpp")); err != nil {
		return "", fmt.Errorf("failed to resolve uwebsockets benchmark dir %q: %w", toolDir, err)
	}
	return toolDir, nil
}

func wsURLToHostPort(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", fmt.Errorf("parse server URL: %w", err)
	}
	if u.Host == "" {
		return "", fmt.Errorf("server URL missing host")
	}
	host := u.Host
	if _, _, err := net.SplitHostPort(u.Host); err != nil {
		if u.Scheme == "wss" {
			host = net.JoinHostPort(u.Host, "443")
		} else {
			host = net.JoinHostPort(u.Host, "80")
		}
	}
	return host, nil
}

func waitForServerReady(hostPort string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", hostPort, 250*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("timeout waiting for server on %s", hostPort)
}

func startManagedServer(serverURL string, auth bool) (*managed_server, error) {
	dir, err := benchmarkDir()
	if err != nil {
		return nil, err
	}

	hostPort, err := wsURLToHostPort(serverURL)
	if err != nil {
		return nil, err
	}

	cmd := exec.Command("bash", "run-server.sh")
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), fmt.Sprintf("AUTH_ENABLED=%d", map[bool]int{false: 0, true: 1}[auth]))
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	proc := &managed_server{cmd: cmd}
	cmd.Stdout = &proc.logs
	cmd.Stderr = &proc.logs

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start managed uwebsockets server: %w", err)
	}

	if err := waitForServerReady(hostPort, 60*time.Second); err != nil {
		_ = cmd.Process.Signal(syscall.SIGINT)
		_ = cmd.Wait()
		return nil, fmt.Errorf("server did not become ready: %v\nserver logs:\n%s", err, proc.logs.String())
	}

	return proc, nil
}

func stopManagedServer(s *managed_server) {
	if s == nil || s.cmd == nil || s.cmd.Process == nil {
		return
	}

	done := make(chan error, 1)
	go func() {
		done <- s.cmd.Wait()
	}()

	if pgid, err := syscall.Getpgid(s.cmd.Process.Pid); err == nil {
		_ = syscall.Kill(-pgid, syscall.SIGINT)
	} else {
		_ = s.cmd.Process.Signal(syscall.SIGINT)
	}

	select {
	case <-done:
		return
	case <-time.After(5 * time.Second):
	}

	if pgid, err := syscall.Getpgid(s.cmd.Process.Pid); err == nil {
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
	} else {
		_ = s.cmd.Process.Kill()
	}

	select {
	case <-done:
	case <-time.After(2 * time.Second):
	}
}

func main() {
	serverURL := flag.String("server", "ws://127.0.0.1:8082", "WebSocket server URL")
	serverURLsCSV := flag.String("servers", "", "Comma-separated WebSocket URLs mapped one-to-one to workspaces")
	startServer := flag.Bool("start-server", false, "Start uWebSockets C++ server via run-server.sh")
	numUsers := flag.Int("users", 100, "Number of concurrent users to simulate")
	duration := flag.Duration("duration", 60*time.Second, "Benchmark duration")
	rampUp := flag.Duration("ramp-up", 10*time.Second, "Ramp-up duration (time to start all users)")
	msgInterval := flag.Duration("msg-interval", 1*time.Second, "Interval between messages per user")
	pingInterval := flag.Duration("ping-interval", 10*time.Second, "Interval between pings per user (0 to disable)")
	fanoutSampleRate := flag.Int("fanout-sample-rate", 100, "Sample every N received fanout messages for lag calculation (1 = all, 0 = disable)")
	msgSize := flag.Int("msg-size", 128, "Message payload size in bytes")
	numWorkspaces := flag.Int("workspaces", 4, "Number of workspaces to distribute users across")
	numConvs := flag.Int("conversations", 10, "Number of conversations per workspace")
	convsPerUser := flag.Int("convs-per-user", 3, "Number of conversations each user subscribes to")
	seed := flag.Int64("seed", 1, "Base seed for deterministic per-client traffic")
	enableAuth := flag.Bool("auth", false, "Send X-NRC-Auth JWT header like e2e")
	jwtSecret := flag.String("jwt-secret", "dev-insecure-nrc-jwt-secret", "JWT HMAC secret (used for token generation)")
	jwtIssuer := flag.String("jwt-issuer", "nrc-tailscale-proxy", "JWT issuer for X-NRC-Auth tokens")
	jwtAudience := flag.String("jwt-audience", "nrc", "JWT audience for X-NRC-Auth tokens")
	jwtTTL := flag.Duration("jwt-ttl", 5*time.Minute, "JWT TTL for X-NRC-Auth tokens")
	outputJSON := flag.String("output", "", "Output file for JSON results (optional)")
	flag.Parse()
	serverURLs := parseServerURLs(*serverURLsCSV)
	if *startServer && len(serverURLs) > 0 {
		fmt.Fprintln(os.Stderr, "--servers cannot be used with --start-server")
		os.Exit(1)
	}

	fmt.Println("╔═══════════════════════════════════════════════════════════╗")
	fmt.Println("║             UWEBSOCKETS BASELINE BENCHMARK                ║")
	fmt.Println("╚═══════════════════════════════════════════════════════════╝")
	fmt.Println()
	fmt.Printf("Server:        %s\n", *serverURL)
	if len(serverURLs) > 0 {
		fmt.Printf("Servers:       %s\n", strings.Join(serverURLs, ","))
	}
	fmt.Printf("Start Server:  %v\n", *startServer)
	fmt.Printf("Auth Enabled:  %v\n", *enableAuth)
	fmt.Printf("Users:         %d\n", *numUsers)
	fmt.Printf("Duration:      %v\n", *duration)
	fmt.Printf("Ramp-up:       %v\n", *rampUp)
	fmt.Printf("Msg Interval:  %v\n", *msgInterval)
	fmt.Printf("Msg Size:      %d bytes\n", *msgSize)
	fmt.Printf("Workspaces:    %d\n", *numWorkspaces)
	fmt.Printf("Conversations: %d\n", *numConvs)
	fmt.Printf("Convs/User:    %d\n", *convsPerUser)
	fmt.Printf("Seed:          %d\n", *seed)
	fmt.Println()

	var managed *managed_server
	if *startServer {
		fmt.Println("Starting managed uWebSockets benchmark server...")
		started, err := startManagedServer(*serverURL, *enableAuth)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to start managed uWebSockets server: %v\n", err)
			os.Exit(1)
		}
		managed = started
		defer stopManagedServer(managed)
	}

	config := scenario.Config{
		ServerURL:        *serverURL,
		ServerURLs:       serverURLs,
		NumUsers:         *numUsers,
		Duration:         *duration,
		RampUpDuration:   *rampUp,
		FanoutSampleRate: *fanoutSampleRate,
		MessageInterval:  *msgInterval,
		PingInterval:     *pingInterval,
		MessageSize:      *msgSize,
		NumWorkspaces:    *numWorkspaces,
		NumConversations: *numConvs,
		ConvsPerUser:     *convsPerUser,
		Seed:             *seed,
		EnableAuth:       *enableAuth,
		JWTSecret:        *jwtSecret,
		JWTIssuer:        *jwtIssuer,
		JWTAudience:      *jwtAudience,
		JWTTTL:           *jwtTTL,
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		fmt.Println("\nReceived interrupt signal, stopping...")
		cancel()
	}()

	runner := scenario.NewRunner(config)
	results, err := runner.Run(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Benchmark failed: %v\n", err)
		os.Exit(1)
	}

	fmt.Println(results.String())

	if *outputJSON != "" {
		jsonData, err := results.JSON()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to marshal JSON: %v\n", err)
			os.Exit(1)
		}

		if err := os.WriteFile(*outputJSON, jsonData, 0644); err != nil {
			fmt.Fprintf(os.Stderr, "Failed to write output file: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("Results written to %s\n", *outputJSON)
	}

	if results.ServerStats != nil {
		fmt.Println("\n=== Server Stats (from last pong) ===")
		fmt.Printf("Threads:        %d\n", results.ServerStats.TotalThreads)
		fmt.Printf("Connections:    %d\n", results.ServerStats.Connections)
		fmt.Printf("Memory:         %d MB\n", results.ServerStats.MemoryMB)
		fmt.Printf("Buffer Pool:    %d%%\n", results.ServerStats.BufferPoolPercent)
		fmt.Printf("IO Pending:     %d\n", results.ServerStats.IOPending)
		fmt.Printf("Send Queue:     %d\n", results.ServerStats.SendQueueDepth)
		fmt.Printf("Backpressure:   %v\n", results.ServerStats.SendBackpressure)
	}

	if len(results.ErrorsByType) > 0 {
		fmt.Println("\n=== Errors By Type ===")
		for errType, count := range results.ErrorsByType {
			fmt.Printf("  %s: %d\n", errType, count)
		}
	}
	if len(results.DisconnectReasons) > 0 {
		fmt.Println("\n=== Steady-State Disconnect Reasons ===")
		for reason, count := range results.DisconnectReasons {
			fmt.Printf("  %s: %d\n", reason, count)
		}
	}
	if len(results.TeardownErrorsByType) > 0 {
		fmt.Println("\n=== Teardown Errors By Type ===")
		for errType, count := range results.TeardownErrorsByType {
			fmt.Printf("  %s: %d\n", errType, count)
		}
	}
}

func parseServerURLs(raw string) []string {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	for i := range parts {
		parts[i] = strings.TrimSpace(parts[i])
	}
	return parts
}
