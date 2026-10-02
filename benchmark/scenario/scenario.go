package scenario

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/cespare/xxhash/v2"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/nrc/benchmark/client"
	"github.com/nrc/benchmark/metrics"
)

const numServerThreads = 12 // Must match server's thread count

// generateDistributedWorkspaceIDs creates workspace IDs that are guaranteed to
// distribute evenly across server threads using the same xxhash logic as the server.
func generateDistributedWorkspaceIDs(numWorkspaces int) []string {
	workspaceIDs := make([]string, numWorkspaces)
	threadCounts := make([]int, numServerThreads)

	// For each desired workspace, find a name that hashes to a balanced thread
	for i := 0; i < numWorkspaces; i++ {
		targetThread := i % numServerThreads

		// Find a workspace name that hashes to the target thread
		for suffix := 0; ; suffix++ {
			candidate := fmt.Sprintf("ws-%d-%d", i, suffix)
			hash := xxhash.Sum64String(candidate)
			thread := int(hash % uint64(numServerThreads))

			if thread == targetThread {
				workspaceIDs[i] = candidate
				threadCounts[thread]++
				break
			}
		}
	}

	return workspaceIDs
}

// Config holds the benchmark scenario configuration
type Config struct {
	ServerURL        string
	ServerURLs       []string
	NumUsers         int
	Duration         time.Duration
	RampUpDuration   time.Duration
	FanoutSampleRate int
	MessageInterval  time.Duration
	PingInterval     time.Duration
	MessageSize      int
	NumWorkspaces    int
	NumConversations int
	ConvsPerUser     int
	Seed             int64
	EnableAuth       bool
	JWTSecret        string
	JWTIssuer        string
	JWTAudience      string
	JWTTTL           time.Duration
}

// DefaultConfig returns a sensible default configuration
func DefaultConfig() Config {
	return Config{
		ServerURL:        "ws://localhost:8080",
		NumUsers:         100,
		Duration:         60 * time.Second,
		RampUpDuration:   10 * time.Second,
		FanoutSampleRate: 100,
		MessageInterval:  1 * time.Second,
		PingInterval:     10 * time.Second,
		MessageSize:      128,
		NumWorkspaces:    4,
		NumConversations: 10,
		ConvsPerUser:     3,
		Seed:             1,
		EnableAuth:       false,
		JWTSecret:        "dev-insecure-nrc-jwt-secret",
		JWTIssuer:        "nrc-tailscale-proxy",
		JWTAudience:      "nrc",
		JWTTTL:           5 * time.Minute,
	}
}

type jwt_header struct {
	Alg string `json:"alg"`
	Typ string `json:"typ"`
}

type jwt_claims struct {
	Sub      string `json:"sub"`
	Username string `json:"username"`
	Iss      string `json:"iss"`
	Aud      string `json:"aud"`
	Exp      int64  `json:"exp"`
	Nbf      int64  `json:"nbf"`
}

func buildProxyStyleJWT(username string, now time.Time, secret, issuer, audience string, ttl time.Duration) (string, error) {
	headerJSON, err := json.Marshal(jwt_header{Alg: "HS256", Typ: "JWT"})
	if err != nil {
		return "", fmt.Errorf("marshal jwt header: %w", err)
	}

	claims := jwt_claims{
		Sub:      username,
		Username: username,
		Iss:      issuer,
		Aud:      audience,
		Nbf:      now.Unix() - 2,
		Exp:      now.Add(ttl).Unix(),
	}

	claimsJSON, err := json.Marshal(claims)
	if err != nil {
		return "", fmt.Errorf("marshal jwt claims: %w", err)
	}

	headerSegment := base64.RawURLEncoding.EncodeToString(headerJSON)
	payloadSegment := base64.RawURLEncoding.EncodeToString(claimsJSON)
	signingInput := headerSegment + "." + payloadSegment

	mac := hmac.New(sha256.New, []byte(secret))
	if _, err := mac.Write([]byte(signingInput)); err != nil {
		return "", fmt.Errorf("sign jwt: %w", err)
	}

	signatureSegment := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return signingInput + "." + signatureSegment, nil
}

// Runner executes the benchmark scenario
type Runner struct {
	config    Config
	collector *metrics.Collector
	clients   []*client.Client
	mu        sync.RWMutex
}

// NewRunner creates a new scenario runner
func NewRunner(config Config) *Runner {
	return &Runner{
		config:    config,
		collector: metrics.NewCollector(),
		clients:   make([]*client.Client, 0, config.NumUsers),
	}
}

// Run executes the benchmark scenario
func (r *Runner) Run(ctx context.Context) (*metrics.Snapshot, error) {
	fmt.Printf("Starting benchmark: %d users, %v duration\n", r.config.NumUsers, r.config.Duration)
	serverURLs, err := configuredServerURLs(r.config)
	if err != nil {
		return nil, err
	}
	if r.config.EnableAuth {
		if r.config.JWTSecret == "" {
			return nil, fmt.Errorf("auth enabled but JWT secret is empty")
		}
		fmt.Printf("Authentication: enabled (issuer=%s audience=%s)\n", r.config.JWTIssuer, r.config.JWTAudience)
	}

	r.collector.Start()
	startupCtx, stopStartup := context.WithCancel(context.Background())
	defer stopStartup()
	shutdownClients := make(chan struct{})

	// Calculate ramp-up timing
	var rampDelay time.Duration
	if r.config.RampUpDuration > 0 && r.config.NumUsers > 1 {
		rampDelay = r.config.RampUpDuration / time.Duration(r.config.NumUsers)
	}

	// Generate conversation IDs
	convIDs := make([]int64, r.config.NumConversations)
	for i := range convIDs {
		convIDs[i] = int64(i + 1)
	}

	// Generate workspace IDs that distribute evenly across server threads
	workspaceIDs := generateDistributedWorkspaceIDs(r.config.NumWorkspaces)
	fmt.Printf("Generated %d workspaces distributed across %d threads\n", len(workspaceIDs), numServerThreads)

	// Launch clients
	var wg sync.WaitGroup
	var startupWG sync.WaitGroup
	var connectErrors atomic.Uint64

	for i := 0; i < r.config.NumUsers; i++ {
		wg.Add(1)
		startupWG.Add(1)

		go func(userID int) {
			defer wg.Done()
			startupComplete := false
			defer func() {
				if !startupComplete {
					startupWG.Done()
				}
			}()

			// Ramp-up delay
			if rampDelay > 0 {
				select {
				case <-startupCtx.Done():
					r.collector.RecordConnectFailed()
					connectErrors.Add(1)
					return
				case <-time.After(rampDelay * time.Duration(userID)):
				}
			}

			// Select workspace and its deterministic endpoint. Multiple endpoints let the
			// fanout benchmark keep each workspace inside one isolated server event loop.
			workspaceIndex, workspaceUserID := workspaceAssignment(userID, len(workspaceIDs))
			workspaceID := workspaceIDs[workspaceIndex]
			serverURL := serverURLForWorkspace(serverURLs, workspaceIndex)

			// Select conversations for this user
			userConvs := make([]int64, 0, r.config.ConvsPerUser)
			for j := 0; j < r.config.ConvsPerUser; j++ {
				idx := (workspaceUserID + j) % len(convIDs)
				userConvs = append(userConvs, convIDs[idx])
			}

			cfg := client.ClientConfig{
				ServerURL:        serverURL,
				WorkspaceID:      workspaceID,
				Nickname:         fmt.Sprintf("user-%d", userID),
				Conversations:    userConvs,
				RandomSeed:       r.config.Seed + int64(userID)*1_000_003,
				FanoutSampleRate: r.config.FanoutSampleRate,
				MessageInterval:  r.config.MessageInterval,
				PingInterval:     r.config.PingInterval,
				MessageSize:      r.config.MessageSize,
				ReadTimeout:      30 * time.Second,
				WriteTimeout:     10 * time.Second,
			}

			if r.config.EnableAuth {
				headers := make(http.Header)
				headers.Set("X-User", cfg.Nickname)

				token, err := buildProxyStyleJWT(
					cfg.Nickname,
					time.Now(),
					r.config.JWTSecret,
					r.config.JWTIssuer,
					r.config.JWTAudience,
					r.config.JWTTTL,
				)
				if err != nil {
					r.collector.RecordConnectFailed()
					connectErrors.Add(1)
					return
				}
				headers.Set("X-NRC-Auth", token)
				cfg.AuthHeader = headers
			} else {
				headers := make(http.Header)
				headers.Set("X-User", cfg.Nickname)
				cfg.AuthHeader = headers
			}

			c := client.NewClient(userID, cfg)
			c.SetCallbacks(
				r.onMessageAck,
				r.onPongReceived,
				r.onMessageReceived,
				r.onError,
				r.onDisconnect,
				r.onStateChange,
			)

			if err := c.ConnectContext(startupCtx); err != nil {
				r.collector.RecordConnectFailed()
				connectErrors.Add(1)
				return
			}
			if startupCtx.Err() != nil {
				c.Stop()
				r.collector.RecordConnectFailed()
				connectErrors.Add(1)
				return
			}

			r.mu.Lock()
			r.clients = append(r.clients, c)
			r.mu.Unlock()

			clientMetrics := c.Metrics()
			r.collector.RecordConnect(clientMetrics.ConnectTime)
			startupWG.Done()
			startupComplete = true

			<-shutdownClients
			c.Stop()

		}(i)
	}

	// Progress reporting stops before the steady-state snapshot so teardown cannot produce
	// a misleading final progress line.
	progressCtx, stopProgress := context.WithCancel(ctx)
	progressDone := make(chan struct{})
	go func() {
		defer close(progressDone)
		r.progressReporter(progressCtx)
	}()

	// Wait for duration or context cancellation
	select {
	case <-ctx.Done():
	case <-time.After(r.config.Duration):
	}

	stopProgress()
	<-progressDone
	stopStartup()
	startupWG.Wait()

	// Atomically close the steady-state phase before intentional client shutdown.
	r.syncClientCounters()
	steadyStateSnapshot := r.collector.EndSteadyState()

	// Signal all clients to stop
	fmt.Println("\nStopping clients...")
	close(shutdownClients)

	// Wait for all clients to finish
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(10 * time.Second):
		fmt.Println("Warning: some clients did not stop gracefully")
	}

	if count := connectErrors.Load(); count > 0 {
		fmt.Printf("Warning: %d connection errors occurred\n", count)
	}

	// Preserve the steady-state result while attaching separately classified teardown activity.
	postTeardownSnapshot := r.collector.Snapshot()
	steadyStateSnapshot.TeardownDisconnects = postTeardownSnapshot.TeardownDisconnects
	steadyStateSnapshot.TeardownErrors = postTeardownSnapshot.TeardownErrors
	steadyStateSnapshot.TeardownErrorsByType = postTeardownSnapshot.TeardownErrorsByType

	return steadyStateSnapshot, nil
}

func configuredServerURLs(config Config) ([]string, error) {
	if config.NumWorkspaces < 1 {
		return nil, fmt.Errorf("workspaces must be positive")
	}
	if len(config.ServerURLs) == 0 {
		if config.ServerURL == "" {
			return nil, fmt.Errorf("server URL is empty")
		}
		return []string{config.ServerURL}, nil
	}
	if len(config.ServerURLs) != 1 && len(config.ServerURLs) != config.NumWorkspaces {
		return nil, fmt.Errorf(
			"server URL count must be 1 or match workspaces: got %d URLs for %d workspaces",
			len(config.ServerURLs),
			config.NumWorkspaces,
		)
	}
	for i, serverURL := range config.ServerURLs {
		if serverURL == "" {
			return nil, fmt.Errorf("server URL %d is empty", i)
		}
	}
	return config.ServerURLs, nil
}

func serverURLForWorkspace(serverURLs []string, workspaceIndex int) string {
	if len(serverURLs) == 1 {
		return serverURLs[0]
	}
	return serverURLs[workspaceIndex]
}

func workspaceAssignment(userID, workspaceCount int) (workspaceIndex, workspaceUserID int) {
	return userID % workspaceCount, userID / workspaceCount
}

func (r *Runner) onMessageAck(clientID int, observedRTT time.Duration, ackTimestamp int64) {
	r.collector.RecordMessageAck(observedRTT)
	if ackTimestamp > 0 {
		lag := time.Since(time.Unix(0, ackTimestamp))
		r.collector.RecordMessageAckLag(lag)
	}
}

func (r *Runner) onPongReceived(clientID int, rtt time.Duration, pong *protocol.StatsResponse) {
	r.collector.RecordPong(rtt, pong)
}

func (r *Runner) onMessageReceived(clientID int, payload []byte) {
	ts := decode_new_message_timestamp(payload)
	if ts > 0 {
		lag := time.Since(time.Unix(0, ts))
		r.collector.RecordFanoutLag(lag)
	}
}

func decode_new_message_timestamp(payload []byte) int64 {
	if len(payload) < 18 {
		return 0
	}
	offset := 16
	usernameLen := int(binary.BigEndian.Uint16(payload[offset : offset+2]))
	offset += 2
	if len(payload) < offset+usernameLen+8 {
		return 0
	}
	timestampOffset := offset + usernameLen
	return int64(binary.BigEndian.Uint64(payload[timestampOffset : timestampOffset+8]))
}

func (r *Runner) onError(clientID int, err error) {
	r.collector.RecordError(err)
}

func (r *Runner) onDisconnect(clientID int, err error, countAsError bool) {
	r.collector.RecordUnexpectedDisconnect(err, countAsError)
}

func (r *Runner) onStateChange(clientID int, oldState, newState client.ConnectionState) {
	// Could log state transitions for debugging
}

func (r *Runner) progressReporter(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	previousTime := time.Now()
	previousSent := uint64(0)
	previousReceived := uint64(0)

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			r.syncClientCounters()
			snap := r.collector.Snapshot()
			now := time.Now()
			interval := now.Sub(previousTime).Seconds()
			sentRate := float64(snap.MessagesSent-previousSent) / interval
			receivedRate := float64(snap.MessagesReceived-previousReceived) / interval
			fmt.Printf("[%v] Active: %d | Msgs: %d sent, %d recv | Window: %.0f sent/s, %.0f recv/s | Disconnects: %d | Errors: %d | ACK Obs p99: %.2fms | ACK Lag p99: %.2fms | Fanout p99: %.2fms\n",
				snap.Duration.Round(time.Second),
				snap.ActiveConnections,
				snap.MessagesSent,
				snap.MessagesReceived,
				sentRate,
				receivedRate,
				snap.SteadyStateDisconnects,
				snap.TotalErrors,
				snap.MessageRTTP99,
				snap.AckLagP99,
				snap.FanoutLagP99,
			)
			previousTime = now
			previousSent = snap.MessagesSent
			previousReceived = snap.MessagesReceived
		}
	}
}

func (r *Runner) syncClientCounters() {
	r.mu.RLock()
	clients := append([]*client.Client(nil), r.clients...)
	r.mu.RUnlock()

	totalSent := uint64(0)
	totalReceived := uint64(0)
	totalBytesSent := uint64(0)
	totalBytesReceived := uint64(0)
	for _, c := range clients {
		metrics := c.Metrics()
		totalSent += metrics.MessagesSent
		totalReceived += metrics.MessagesReceived
		totalBytesSent += metrics.BytesSent
		totalBytesReceived += metrics.BytesReceived
	}
	r.collector.SetMessagesSent(totalSent)
	r.collector.SetMessagesReceived(totalReceived)
	r.collector.SetBytes(totalBytesSent, totalBytesReceived)
}
