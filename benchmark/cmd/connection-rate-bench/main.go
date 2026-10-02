package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type config struct {
	ServerURL          string `json:"server_url"`
	Label              string `json:"label"`
	Concurrency        int    `json:"concurrency"`
	WorkspaceCount     int    `json:"workspace_count"`
	Duration           string `json:"duration"`
	Auth               bool   `json:"auth"`
	WebSocketClose     bool   `json:"websocket_close"`
	ReadTimeout        string `json:"read_timeout"`
	WriteTimeout       string `json:"write_timeout"`
	ReadBufferBytes    int    `json:"read_buffer_bytes"`
	WriteBufferBytes   int    `json:"write_buffer_bytes"`
	JWTIssuer          string `json:"jwt_issuer,omitempty"`
	JWTAudience        string `json:"jwt_audience,omitempty"`
	JWTUsername        string `json:"jwt_username,omitempty"`
	JWTTTL             string `json:"jwt_ttl,omitempty"`
	RequireZeroFailure bool   `json:"require_zero_failures"`
}

type result struct {
	Config             config  `json:"config"`
	StartedAt          string  `json:"started_at"`
	ElapsedSeconds     float64 `json:"elapsed_seconds"`
	Attempts           uint64  `json:"attempts"`
	Successes          uint64  `json:"successes"`
	Failures           uint64  `json:"failures"`
	DialFailures       uint64  `json:"dial_failures"`
	ServerReadyFailure uint64  `json:"server_ready_failures"`
	CloseWriteFailures uint64  `json:"close_write_failures"`
	CloseReadFailures  uint64  `json:"close_read_failures"`
	RatePerSecond      float64 `json:"rate_per_second"`
	LatencyP50MS       float64 `json:"latency_p50_ms"`
	LatencyP95MS       float64 `json:"latency_p95_ms"`
	LatencyP99MS       float64 `json:"latency_p99_ms"`
	LatencyMaxMS       float64 `json:"latency_max_ms"`
}

type counters struct {
	successes          atomic.Uint64
	dialFailures       atomic.Uint64
	serverReadyFailure atomic.Uint64
	closeWriteFailures atomic.Uint64
	closeReadFailures  atomic.Uint64
}

type websocketConnection interface {
	SetReadDeadline(time.Time) error
	SetWriteDeadline(time.Time) error
	ReadMessage() (int, []byte, error)
	WriteControl(int, []byte, time.Time) error
	Close() error
}

type lifecycleFailure uint8

const (
	lifecycleOK lifecycleFailure = iota
	lifecycleServerReadyFailure
	lifecycleCloseWriteFailure
	lifecycleCloseReadFailure
)

type options struct {
	serverURL          string
	label              string
	concurrency        int
	workspaceCount     int
	duration           time.Duration
	auth               bool
	webSocketClose     bool
	readTimeout        time.Duration
	writeTimeout       time.Duration
	requireZeroFailure bool
	jwtSecret          string
	jwtIssuer          string
	jwtAudience        string
	jwtUsername        string
	jwtTTL             time.Duration
	output             string
}

func main() {
	os.Exit(run())
}

func run() int {
	opts := parseFlags()
	if err := validateOptions(opts); err != nil {
		fmt.Fprintf(os.Stderr, "configuration error: %v\n", err)
		return 2
	}

	header := http.Header{"X-User": {opts.jwtUsername}}
	if opts.auth {
		token, err := buildJWT(opts.jwtUsername, opts.jwtSecret, opts.jwtIssuer, opts.jwtAudience, opts.jwtTTL)
		if err != nil {
			fmt.Fprintf(os.Stderr, "build JWT: %v\n", err)
			return 2
		}
		header.Set("X-NRC-Auth", token)
	}

	dialer := websocket.Dialer{
		HandshakeTimeout: opts.readTimeout,
		ReadBufferSize:   4096,
		WriteBufferSize:  4096,
	}

	startedAt := time.Now().UTC()
	deadline := time.Now().Add(opts.duration)
	started := time.Now()
	var counts counters
	latencies := make([][]int64, opts.concurrency)
	var wg sync.WaitGroup

	for worker := 0; worker < opts.concurrency; worker++ {
		worker := worker
		wg.Add(1)
		go func() {
			defer wg.Done()
			workspace := fmt.Sprintf("connrate-%d", worker%opts.workspaceCount)
			local := make([]int64, 0, 4096)
			for time.Now().Before(deadline) {
				connectedAt := time.Now()
				conn, _, err := dialer.Dial(opts.serverURL+"/"+workspace, header)
				if err != nil {
					counts.dialFailures.Add(1)
					continue
				}

				readyLatency, failure := completeLifecycle(conn, opts, connectedAt)
				_ = conn.Close()
				switch failure {
				case lifecycleServerReadyFailure:
					counts.serverReadyFailure.Add(1)
					continue
				case lifecycleCloseWriteFailure:
					counts.closeWriteFailures.Add(1)
					continue
				case lifecycleCloseReadFailure:
					counts.closeReadFailures.Add(1)
					continue
				}

				counts.successes.Add(1)
				local = append(local, readyLatency)
			}
			latencies[worker] = local
		}()
	}

	wg.Wait()
	elapsed := time.Since(started)
	allLatencies := make([]int64, 0, int(counts.successes.Load()))
	for _, local := range latencies {
		allLatencies = append(allLatencies, local...)
	}
	sort.Slice(allLatencies, func(i, j int) bool { return allLatencies[i] < allLatencies[j] })

	dialFailures := counts.dialFailures.Load()
	serverReadyFailures := counts.serverReadyFailure.Load()
	closeWriteFailures := counts.closeWriteFailures.Load()
	closeReadFailures := counts.closeReadFailures.Load()
	failures := dialFailures + serverReadyFailures + closeWriteFailures + closeReadFailures
	successes := counts.successes.Load()
	measurement := result{
		Config: config{
			ServerURL:          opts.serverURL,
			Label:              opts.label,
			Concurrency:        opts.concurrency,
			WorkspaceCount:     opts.workspaceCount,
			Duration:           opts.duration.String(),
			Auth:               opts.auth,
			WebSocketClose:     opts.webSocketClose,
			ReadTimeout:        opts.readTimeout.String(),
			WriteTimeout:       opts.writeTimeout.String(),
			ReadBufferBytes:    4096,
			WriteBufferBytes:   4096,
			JWTIssuer:          opts.jwtIssuer,
			JWTAudience:        opts.jwtAudience,
			JWTUsername:        opts.jwtUsername,
			JWTTTL:             opts.jwtTTL.String(),
			RequireZeroFailure: opts.requireZeroFailure,
		},
		StartedAt:          startedAt.Format(time.RFC3339Nano),
		ElapsedSeconds:     elapsed.Seconds(),
		Attempts:           successes + failures,
		Successes:          successes,
		Failures:           failures,
		DialFailures:       dialFailures,
		ServerReadyFailure: serverReadyFailures,
		CloseWriteFailures: closeWriteFailures,
		CloseReadFailures:  closeReadFailures,
		RatePerSecond:      float64(successes) / elapsed.Seconds(),
		LatencyP50MS:       percentileMS(allLatencies, 0.50),
		LatencyP95MS:       percentileMS(allLatencies, 0.95),
		LatencyP99MS:       percentileMS(allLatencies, 0.99),
		LatencyMaxMS:       percentileMS(allLatencies, 1.00),
	}

	fmt.Printf(
		"label=%s concurrency=%d elapsed=%.3fs successes=%d failures=%d close_write_failures=%d close_read_failures=%d rate=%.1f/s p50=%.3fms p95=%.3fms p99=%.3fms\n",
		opts.label,
		opts.concurrency,
		measurement.ElapsedSeconds,
		measurement.Successes,
		measurement.Failures,
		measurement.CloseWriteFailures,
		measurement.CloseReadFailures,
		measurement.RatePerSecond,
		measurement.LatencyP50MS,
		measurement.LatencyP95MS,
		measurement.LatencyP99MS,
	)

	if opts.output != "" {
		encoded, err := json.MarshalIndent(measurement, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "encode result: %v\n", err)
			return 2
		}
		encoded = append(encoded, '\n')
		if err := os.WriteFile(opts.output, encoded, 0o644); err != nil {
			fmt.Fprintf(os.Stderr, "write result: %v\n", err)
			return 2
		}
	}

	if opts.requireZeroFailure && failures != 0 {
		return 1
	}
	return 0
}

func completeLifecycle(conn websocketConnection, opts options, connectedAt time.Time) (int64, lifecycleFailure) {
	if err := conn.SetReadDeadline(time.Now().Add(opts.readTimeout)); err != nil {
		return 0, lifecycleServerReadyFailure
	}
	messageType, data, err := conn.ReadMessage()
	if err != nil || messageType != websocket.BinaryMessage {
		return 0, lifecycleServerReadyFailure
	}
	message, err := protocol.ReadMessage(data)
	if err != nil || message.Opcode != protocol.S_ServerReady {
		return 0, lifecycleServerReadyFailure
	}
	ready, err := protocol.ParseServerReady(data)
	if err != nil {
		return 0, lifecycleServerReadyFailure
	}
	if opts.auth && (ready.Username != opts.jwtUsername || !ready.IsAuthenticated) {
		return 0, lifecycleServerReadyFailure
	}
	readyLatency := time.Since(connectedAt).Nanoseconds()
	if !opts.webSocketClose {
		return readyLatency, lifecycleOK
	}

	closeDeadline := time.Now().Add(opts.writeTimeout)
	if err := conn.SetWriteDeadline(closeDeadline); err != nil {
		return 0, lifecycleCloseWriteFailure
	}
	if err := conn.WriteControl(
		websocket.CloseMessage,
		websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""),
		closeDeadline,
	); err != nil {
		return 0, lifecycleCloseWriteFailure
	}
	if err := conn.SetReadDeadline(time.Now().Add(opts.readTimeout)); err != nil {
		return 0, lifecycleCloseReadFailure
	}
	_, _, err = conn.ReadMessage()
	var closeError *websocket.CloseError
	if !errors.As(err, &closeError) || closeError.Code != websocket.CloseNormalClosure {
		return 0, lifecycleCloseReadFailure
	}
	return readyLatency, lifecycleOK
}

func parseFlags() options {
	var opts options
	flag.StringVar(&opts.serverURL, "server", "ws://127.0.0.1:8080", "WebSocket server URL")
	flag.StringVar(&opts.label, "label", "server", "Result label")
	flag.IntVar(&opts.concurrency, "concurrency", 128, "Parallel connection loops")
	flag.IntVar(&opts.workspaceCount, "workspaces", 48, "Workspace names distributed across connection loops")
	flag.DurationVar(&opts.duration, "duration", 30*time.Second, "Measurement duration")
	flag.BoolVar(&opts.auth, "auth", true, "Send an X-NRC-Auth JWT")
	flag.BoolVar(&opts.webSocketClose, "websocket-close", true, "Send a WebSocket close frame before closing TCP")
	flag.DurationVar(&opts.readTimeout, "read-timeout", 5*time.Second, "Handshake and ServerReady read timeout")
	flag.DurationVar(&opts.writeTimeout, "write-timeout", time.Second, "WebSocket close write timeout")
	flag.BoolVar(&opts.requireZeroFailure, "require-zero-failures", false, "Exit non-zero after writing results if a connection failed")
	flag.StringVar(&opts.jwtSecret, "jwt-secret", "dev-insecure-nrc-jwt-secret", "JWT HMAC secret")
	flag.StringVar(&opts.jwtIssuer, "jwt-issuer", "nrc-tailscale-proxy", "JWT issuer")
	flag.StringVar(&opts.jwtAudience, "jwt-audience", "nrc", "JWT audience")
	flag.StringVar(&opts.jwtUsername, "jwt-username", "connrate", "JWT and X-User username")
	flag.DurationVar(&opts.jwtTTL, "jwt-ttl", time.Hour, "JWT validity")
	flag.StringVar(&opts.output, "output", "", "Write JSON result to this path")
	flag.Parse()
	opts.serverURL = strings.TrimRight(opts.serverURL, "/")
	return opts
}

func validateOptions(opts options) error {
	if opts.serverURL == "" {
		return fmt.Errorf("--server must not be empty")
	}
	if opts.label == "" {
		return fmt.Errorf("--label must not be empty")
	}
	if opts.concurrency <= 0 {
		return fmt.Errorf("--concurrency must be greater than zero")
	}
	if opts.workspaceCount <= 0 {
		return fmt.Errorf("--workspaces must be greater than zero")
	}
	if opts.duration <= 0 {
		return fmt.Errorf("--duration must be greater than zero")
	}
	if opts.readTimeout <= 0 || opts.writeTimeout <= 0 {
		return fmt.Errorf("timeouts must be greater than zero")
	}
	if opts.auth && (opts.jwtSecret == "" || opts.jwtIssuer == "" || opts.jwtAudience == "" || opts.jwtUsername == "") {
		return fmt.Errorf("JWT secret, issuer, audience, and username are required with --auth")
	}
	if opts.auth && opts.jwtTTL <= 0 {
		return fmt.Errorf("--jwt-ttl must be greater than zero")
	}
	return nil
}

func buildJWT(username, secret, issuer, audience string, ttl time.Duration) (string, error) {
	now := time.Now()
	header, err := json.Marshal(map[string]string{"alg": "HS256", "typ": "JWT"})
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(map[string]any{
		"sub":      username,
		"username": username,
		"iss":      issuer,
		"aud":      audience,
		"nbf":      now.Add(-time.Second).Unix(),
		"exp":      now.Add(ttl).Unix(),
	})
	if err != nil {
		return "", err
	}
	encode := base64.RawURLEncoding.EncodeToString
	unsigned := encode(header) + "." + encode(claims)
	mac := hmac.New(sha256.New, []byte(secret))
	if _, err := mac.Write([]byte(unsigned)); err != nil {
		return "", err
	}
	return unsigned + "." + encode(mac.Sum(nil)), nil
}

func percentileMS(sortedValues []int64, quantile float64) float64 {
	if len(sortedValues) == 0 {
		return 0
	}
	if quantile <= 0 {
		return float64(sortedValues[0]) / float64(time.Millisecond)
	}
	if quantile >= 1 {
		return float64(sortedValues[len(sortedValues)-1]) / float64(time.Millisecond)
	}
	index := int(float64(len(sortedValues)-1) * quantile)
	return float64(sortedValues[index]) / float64(time.Millisecond)
}
