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

func repoRootFromThisFile() (string, error) {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		return "", fmt.Errorf("failed to resolve current file path")
	}

	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	if _, err := os.Stat(filepath.Join(root, "server.odin")); err != nil {
		return "", fmt.Errorf("failed to validate repo root %q: %w", root, err)
	}

	return root, nil
}

func discoverOdinBinary() string {
	if custom := os.Getenv("NRC_ODIN_BIN"); custom != "" {
		return custom
	}

	const configuredOdinPath = "/home/rene/Code/Odin/odin"
	if _, err := os.Stat(configuredOdinPath); err == nil {
		return configuredOdinPath
	}

	return "odin"
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

func startManagedServer(serverURL string, jwtSecret string) (*managed_server, error) {
	repoRoot, err := repoRootFromThisFile()
	if err != nil {
		return nil, err
	}

	hostPort, err := wsURLToHostPort(serverURL)
	if err != nil {
		return nil, err
	}

	cmd := exec.Command(discoverOdinBinary(), "run", ".", "-o:speed")
	cmd.Dir = repoRoot
	cmd.Env = append(os.Environ(), "NRC_JWT_SECRET="+jwtSecret)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	proc := &managed_server{cmd: cmd}
	cmd.Stdout = &proc.logs
	cmd.Stderr = &proc.logs

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start server process: %w", err)
	}

	if err := waitForServerReady(hostPort, 60*time.Second); err != nil {
		stopManagedServer(proc)
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

	// Signal the entire process group so both `odin run` and spawned server terminate.
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
		// Avoid hanging benchmark shutdown if process reaping stalls.
	}
}

func main() {
	os.Exit(run())
}

func run() int {
	// Define flags
	serverURL := flag.String("server", "ws://localhost:8080", "WebSocket server URL")
	serverURLsCSV := flag.String("servers", "", "Comma-separated WebSocket URLs mapped one-to-one to workspaces")
	startServer := flag.Bool("start-server", false, "Start NRC server process automatically (sets NRC_JWT_SECRET)")
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
	jwtSecret := flag.String("jwt-secret", "dev-insecure-nrc-jwt-secret", "JWT HMAC secret (and NRC_JWT_SECRET when --start-server)")
	jwtIssuer := flag.String("jwt-issuer", "nrc-tailscale-proxy", "JWT issuer for X-NRC-Auth tokens")
	jwtAudience := flag.String("jwt-audience", "nrc", "JWT audience for X-NRC-Auth tokens")
	jwtTTL := flag.Duration("jwt-ttl", 5*time.Minute, "JWT TTL for X-NRC-Auth tokens")
	outputJSON := flag.String("output", "", "Output file for JSON results (optional)")

	flag.Parse()
	serverURLs := parseServerURLs(*serverURLsCSV)
	if *startServer && len(serverURLs) > 0 {
		fmt.Fprintln(os.Stderr, "--servers cannot be used with --start-server")
		return 1
	}

	// Print configuration
	fmt.Println("╔═══════════════════════════════════════════════════════════╗")
	fmt.Println("║                  NRC BENCHMARK SUITE                      ║")
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
		fmt.Println("Starting managed NRC server...")
		started, err := startManagedServer(*serverURL, *jwtSecret)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to start managed server: %v\n", err)
			return 1
		}
		managed = started
		defer stopManagedServer(managed)
	}

	// Build config
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

	// Create context with cancellation
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Handle interrupt signals
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		fmt.Println("\nReceived interrupt signal, stopping...")
		cancel()
	}()

	// Run benchmark
	runner := scenario.NewRunner(config)
	results, err := runner.Run(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Benchmark failed: %v\n", err)
		return 1
	}

	// Print results
	fmt.Println(results.String())

	// Optionally write JSON output
	if *outputJSON != "" {
		jsonData, err := results.JSON()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to marshal JSON: %v\n", err)
			return 1
		}

		if err := os.WriteFile(*outputJSON, jsonData, 0644); err != nil {
			fmt.Fprintf(os.Stderr, "Failed to write output file: %v\n", err)
			return 1
		}
		fmt.Printf("Results written to %s\n", *outputJSON)
	}

	// Print server stats if available
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

	// Print error breakdown if there are errors
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
	return 0
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
