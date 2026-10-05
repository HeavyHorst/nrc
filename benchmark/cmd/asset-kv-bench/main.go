package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/HdrHistogram/hdrhistogram-go"
	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

const (
	defaultJWTSecret   = "dev-insecure-nrc-jwt-secret"
	defaultJWTIssuer   = "nrc-tailscale-proxy"
	defaultJWTAudience = "nrc"
)

type config struct {
	Backend       string
	Profile       string
	Ops           int
	Concurrency   int
	PipelineDepth int
	Assets        int
	PayloadSize   int
	PreviewSize   int
	Workspaces    int
	Conversations int
	Zstd          bool

	ServerURL   string
	StartServer bool
	Auth        bool
	JWTSecret   string
	JWTIssuer   string
	JWTAudience string
	JWTTTL      time.Duration

	RedisNetwork string
	RedisAddr    string
	RedisPrefix  string

	Timeout time.Duration
	Output  string
}

type assetPayload struct {
	AssetType       uint16
	ParentType      uint16
	ParentID        uint64
	Preview         string
	Payload         string
	PayloadEncoding uint8
	PayloadRawLen   uint32
}

type assetRef struct {
	ConvID uint64
	ID     uint64
	Key    string
	Asset  assetPayload
}

type operationResult struct {
	Backend        string             `json:"backend"`
	Profile        string             `json:"profile"`
	Ops            int                `json:"ops"`
	Concurrency    int                `json:"concurrency"`
	PipelineDepth  int                `json:"pipeline_depth"`
	AssetsPreload  int                `json:"assets_preload"`
	PayloadSize    int                `json:"payload_size"`
	PreviewSize    int                `json:"preview_size"`
	Zstd           bool               `json:"zstd"`
	DurationMS     float64            `json:"duration_ms"`
	OpsPerSec      float64            `json:"ops_per_sec"`
	Errors         int64              `json:"errors"`
	BytesWritten   uint64             `json:"bytes_written"`
	BytesRead      uint64             `json:"bytes_read"`
	LatencyMS      map[string]float64 `json:"latency_ms"`
	OperationsByOp map[string]int64   `json:"operations_by_op"`
}

type benchmarkOutput struct {
	StartedAt time.Time         `json:"started_at"`
	Config    config            `json:"config"`
	Results   []operationResult `json:"results"`
}

type managedServer struct {
	cmd  *exec.Cmd
	logs bytes.Buffer
}

type backendWorker interface {
	Close() error
	Create(ctx context.Context, convID uint64, asset assetPayload) (assetRef, int, int, error)
	ExecuteBatch(ctx context.Context, ops []benchOp) []benchOpResult
}

type benchOp struct {
	Kind   string
	ConvID uint64
	Ref    assetRef
	Asset  assetPayload
}

type benchOpResult struct {
	Kind     string
	Ref      assetRef
	Sent     int
	Received int
	Duration time.Duration
	Err      error
}

func main() {
	cfg := config{}
	flag.StringVar(&cfg.Backend, "backend", "both", "Backend to benchmark: nrc, redis, or both")
	flag.StringVar(&cfg.Profile, "profile", "mixed", "Workload profile: create-only, read-only, mixed, write-heavy")
	flag.IntVar(&cfg.Ops, "ops", 10000, "Total measured operations per backend")
	flag.IntVar(&cfg.Concurrency, "concurrency", 16, "Concurrent workers per backend")
	flag.IntVar(&cfg.PipelineDepth, "pipeline-depth", 1, "In-flight requests per worker connection before reading responses (1 disables pipelining)")
	flag.IntVar(&cfg.Assets, "assets", 1000, "Assets to preload for read/mixed/write-heavy profiles")
	flag.IntVar(&cfg.PayloadSize, "payload-size", 4096, "Asset payload size in bytes before optional zstd compression")
	flag.IntVar(&cfg.PreviewSize, "preview-size", 128, "Asset preview size in bytes")
	flag.IntVar(&cfg.Workspaces, "workspaces", 4, "NRC workspaces / Redis key workspace shards")
	flag.IntVar(&cfg.Conversations, "conversations", 16, "Legacy compatibility flag; assets use workspace-data scope 0")
	flag.BoolVar(&cfg.Zstd, "zstd", false, "Use NRC zstd payload encoding and store equivalent compressed Redis values")

	flag.StringVar(&cfg.ServerURL, "server", "ws://localhost:8080", "NRC WebSocket server URL")
	flag.BoolVar(&cfg.StartServer, "start-server", false, "Start NRC server process automatically for NRC runs")
	flag.BoolVar(&cfg.Auth, "auth", false, "Send X-NRC-Auth JWT header for NRC runs")
	flag.StringVar(&cfg.JWTSecret, "jwt-secret", defaultJWTSecret, "JWT HMAC secret and managed NRC_JWT_SECRET")
	flag.StringVar(&cfg.JWTIssuer, "jwt-issuer", defaultJWTIssuer, "JWT issuer")
	flag.StringVar(&cfg.JWTAudience, "jwt-audience", defaultJWTAudience, "JWT audience")
	flag.DurationVar(&cfg.JWTTTL, "jwt-ttl", 5*time.Minute, "JWT TTL")

	flag.StringVar(&cfg.RedisNetwork, "redis-network", "tcp", "Redis network: tcp or unix")
	flag.StringVar(&cfg.RedisAddr, "redis-addr", "127.0.0.1:6379", "Redis address or unix socket path")
	flag.StringVar(&cfg.RedisPrefix, "redis-prefix", "nrc-asset-kv-bench", "Redis key prefix")

	flag.DurationVar(&cfg.Timeout, "timeout", 5*time.Second, "Per-operation timeout")
	flag.StringVar(&cfg.Output, "output", "", "Write JSON results to file")
	flag.Parse()

	if err := validateConfig(cfg); err != nil {
		fmt.Fprintf(os.Stderr, "invalid benchmark config: %v\n", err)
		os.Exit(2)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	backends := selectedBackends(cfg.Backend)
	var managed *managedServer
	if cfg.StartServer && containsBackend(backends, "nrc") {
		fmt.Println("Starting managed NRC server...")
		started, err := startManagedServer(cfg.ServerURL, cfg.JWTSecret)
		if err != nil {
			fmt.Fprintf(os.Stderr, "failed to start NRC server: %v\n", err)
			os.Exit(1)
		}
		managed = started
		defer stopManagedServer(managed)
	}

	fmt.Println("╔═══════════════════════════════════════════════════════════╗")
	fmt.Println("║              NRC ASSET KV COMPARISON BENCH               ║")
	fmt.Println("╚═══════════════════════════════════════════════════════════╝")
	fmt.Printf("Backends:      %s\n", strings.Join(backends, ", "))
	fmt.Printf("Profile:       %s\n", cfg.Profile)
	fmt.Printf("Ops/backend:   %d\n", cfg.Ops)
	fmt.Printf("Concurrency:   %d\n", cfg.Concurrency)
	fmt.Printf("PipelineDepth: %d\n", cfg.PipelineDepth)
	fmt.Printf("Preload:       %d assets\n", cfg.Assets)
	fmt.Printf("Payload:       %d bytes (zstd=%v)\n", cfg.PayloadSize, cfg.Zstd)
	fmt.Printf("Preview:       %d bytes\n", cfg.PreviewSize)
	fmt.Println()

	output := benchmarkOutput{StartedAt: time.Now(), Config: cfg}
	for _, backend := range backends {
		fmt.Printf("--- Running %s backend ---\n", backend)
		result, err := runBackend(ctx, cfg, backend)
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s benchmark failed: %v\n", backend, err)
			os.Exit(1)
		}
		output.Results = append(output.Results, result)
		printResult(result)
	}

	if cfg.Output != "" {
		data, err := json.MarshalIndent(output, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "failed to marshal JSON: %v\n", err)
			os.Exit(1)
		}
		if err := os.WriteFile(cfg.Output, data, 0644); err != nil {
			fmt.Fprintf(os.Stderr, "failed to write output: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("Results written to %s\n", cfg.Output)
	}
}

func validateConfig(cfg config) error {
	if cfg.Ops <= 0 {
		return fmt.Errorf("--ops must be > 0")
	}
	if cfg.Concurrency <= 0 {
		return fmt.Errorf("--concurrency must be > 0")
	}
	if cfg.PipelineDepth <= 0 {
		return fmt.Errorf("--pipeline-depth must be > 0")
	}
	if cfg.Assets <= 0 && cfg.Profile != "create-only" {
		return fmt.Errorf("--assets must be > 0 for %s", cfg.Profile)
	}
	if cfg.PayloadSize < 0 || cfg.PayloadSize > protocol.MaxPayloadLength {
		return fmt.Errorf("--payload-size must be between 0 and %d", protocol.MaxPayloadLength)
	}
	if cfg.PreviewSize < 0 || cfg.PreviewSize > protocol.MaxPreviewLength {
		return fmt.Errorf("--preview-size must be between 0 and %d", protocol.MaxPreviewLength)
	}
	if cfg.Workspaces <= 0 || cfg.Conversations <= 0 {
		return fmt.Errorf("--workspaces and --conversations must be > 0")
	}
	switch cfg.Profile {
	case "create-only", "read-only", "mixed", "write-heavy":
	default:
		return fmt.Errorf("unknown profile %q", cfg.Profile)
	}
	if _, err := url.Parse(cfg.ServerURL); err != nil {
		return fmt.Errorf("invalid --server: %w", err)
	}
	if len(selectedBackends(cfg.Backend)) == 0 {
		return fmt.Errorf("unknown --backend %q", cfg.Backend)
	}
	return nil
}

func selectedBackends(name string) []string {
	switch strings.ToLower(name) {
	case "nrc":
		return []string{"nrc"}
	case "redis":
		return []string{"redis"}
	case "both":
		return []string{"nrc", "redis"}
	default:
		return nil
	}
}

func containsBackend(backends []string, name string) bool {
	for _, backend := range backends {
		if backend == name {
			return true
		}
	}
	return false
}

func runBackend(ctx context.Context, cfg config, backend string) (operationResult, error) {
	hist := hdrhistogram.New(1, 60_000_000, 3)
	var histMu sync.Mutex
	var errorCount atomic.Int64
	var bytesWritten atomic.Uint64
	var bytesRead atomic.Uint64
	opCounts := make(map[string]int64)
	var opCountsMu sync.Mutex

	startCh := make(chan struct{})
	readyCh := make(chan error, cfg.Concurrency)
	doneCh := make(chan error, cfg.Concurrency)

	for workerID := 0; workerID < cfg.Concurrency; workerID++ {
		opsForWorker := cfg.Ops / cfg.Concurrency
		if workerID < cfg.Ops%cfg.Concurrency {
			opsForWorker++
		}
		preloadForWorker := 0
		if cfg.Profile != "create-only" {
			preloadForWorker = cfg.Assets / cfg.Concurrency
			if workerID < cfg.Assets%cfg.Concurrency {
				preloadForWorker++
			}
			if preloadForWorker == 0 {
				preloadForWorker = 1
			}
		}

		go func(workerID, opsForWorker, preloadForWorker int) {
			worker, err := openWorker(ctx, cfg, backend, workerID)
			if err != nil {
				readyCh <- err
				doneCh <- nil
				return
			}
			defer worker.Close()

			refs := make([]assetRef, 0, preloadForWorker+opsForWorker/2)
			for i := 0; i < preloadForWorker; i++ {
				asset := makeAssetPayload(cfg, workerID, i, false)
				convID := workerConvID(cfg, workerID, i)
				ref, sent, received, err := worker.Create(ctx, convID, asset)
				bytesWritten.Add(uint64(sent))
				bytesRead.Add(uint64(received))
				if err != nil {
					readyCh <- fmt.Errorf("preload worker %d asset %d: %w", workerID, i, err)
					doneCh <- nil
					return
				}
				refs = append(refs, ref)
			}

			readyCh <- nil
			<-startCh

			opIndex := 0
			for opIndex < opsForWorker {
				batchSize := cfg.PipelineDepth
				if remaining := opsForWorker - opIndex; remaining < batchSize {
					batchSize = remaining
				}
				batch := make([]benchOp, 0, batchSize)
				for j := 0; j < batchSize; j++ {
					op := chooseOperation(cfg.Profile, workerID, opIndex+j, len(refs))
					bo := benchOp{Kind: op}
					switch op {
					case "create":
						bo.Asset = makeAssetPayload(cfg, workerID, preloadForWorker+opIndex+j, false)
						bo.ConvID = workerConvID(cfg, workerID, preloadForWorker+opIndex+j)
					case "get":
						bo.Ref = refs[(opIndex+j)%len(refs)]
					case "update":
						idx := (opIndex + j) % len(refs)
						bo.Ref = refs[idx]
						bo.Asset = makeAssetPayload(cfg, workerID, preloadForWorker+opIndex+j, true)
					case "delete":
						idx := len(refs) - 1
						bo.Ref = refs[idx]
						refs = refs[:idx]
					}
					batch = append(batch, bo)
				}

				results := worker.ExecuteBatch(ctx, batch)
				for _, r := range results {
					histMu.Lock()
					_ = hist.RecordValue(r.Duration.Microseconds())
					histMu.Unlock()
					bytesWritten.Add(uint64(r.Sent))
					bytesRead.Add(uint64(r.Received))

					opCountsMu.Lock()
					opCounts[r.Kind]++
					opCountsMu.Unlock()

					if r.Err != nil {
						errorCount.Add(1)
					}

					if r.Kind == "create" && r.Err == nil && r.Ref.ID != 0 {
						refs = append(refs, r.Ref)
					}
				}
				opIndex += batchSize
			}

			doneCh <- nil
		}(workerID, opsForWorker, preloadForWorker)
	}

	for i := 0; i < cfg.Concurrency; i++ {
		if err := <-readyCh; err != nil {
			close(startCh)
			return operationResult{}, err
		}
	}

	start := time.Now()
	close(startCh)
	for i := 0; i < cfg.Concurrency; i++ {
		if err := <-doneCh; err != nil {
			return operationResult{}, err
		}
	}
	duration := time.Since(start)

	histMu.Lock()
	latency := map[string]float64{
		"p50": float64(hist.ValueAtQuantile(50)) / 1000.0,
		"p95": float64(hist.ValueAtQuantile(95)) / 1000.0,
		"p99": float64(hist.ValueAtQuantile(99)) / 1000.0,
		"max": float64(hist.Max()) / 1000.0,
	}
	histMu.Unlock()

	return operationResult{
		Backend:        backend,
		Profile:        cfg.Profile,
		Ops:            cfg.Ops,
		Concurrency:    cfg.Concurrency,
		PipelineDepth:  cfg.PipelineDepth,
		AssetsPreload:  cfg.Assets,
		PayloadSize:    cfg.PayloadSize,
		PreviewSize:    cfg.PreviewSize,
		Zstd:           cfg.Zstd,
		DurationMS:     float64(duration.Microseconds()) / 1000.0,
		OpsPerSec:      float64(cfg.Ops) / duration.Seconds(),
		Errors:         errorCount.Load(),
		BytesWritten:   bytesWritten.Load(),
		BytesRead:      bytesRead.Load(),
		LatencyMS:      latency,
		OperationsByOp: opCounts,
	}, nil
}

func chooseOperation(profile string, workerID, opIndex, availableRefs int) string {
	if availableRefs == 0 {
		return "create"
	}
	switch profile {
	case "create-only":
		return "create"
	case "read-only":
		return "get"
	case "mixed":
		bucket := (workerID*131 + opIndex*17) % 100
		if bucket < 80 {
			return "get"
		}
		if bucket < 95 {
			return "update"
		}
		return "create"
	case "write-heavy":
		bucket := (workerID*131 + opIndex*17) % 100
		if bucket < 50 {
			return "create"
		}
		if bucket < 90 {
			return "update"
		}
		return "delete"
	default:
		return "get"
	}
}

func openWorker(ctx context.Context, cfg config, backend string, workerID int) (backendWorker, error) {
	switch backend {
	case "nrc":
		return openNRCWorker(ctx, cfg, workerID)
	case "redis":
		return openRedisWorker(cfg, workerID)
	default:
		return nil, fmt.Errorf("unknown backend %q", backend)
	}
}

func makeAssetPayload(cfg config, workerID, assetIndex int, updated bool) assetPayload {
	suffix := fmt.Sprintf("worker=%d asset=%d updated=%v ", workerID, assetIndex, updated)
	payload := repeatedPayload("payload "+suffix, cfg.PayloadSize)
	preview := repeatedPayload("preview "+suffix, cfg.PreviewSize)
	asset := assetPayload{
		AssetType:       protocol.AssetTypeNote,
		ParentType:      protocol.ParentTypeNone,
		ParentID:        0,
		Preview:         preview,
		Payload:         payload,
		PayloadEncoding: protocol.AssetPayloadEncodingPlain,
		PayloadRawLen:   uint32(len(payload)),
	}
	if cfg.Zstd {
		compressed, rawLen, err := protocol.CompressAssetPayloadZstd(payload)
		if err == nil {
			asset.Payload = compressed
			asset.PayloadEncoding = protocol.AssetPayloadEncodingZstd
			asset.PayloadRawLen = rawLen
		}
	}
	return asset
}

func repeatedPayload(seed string, size int) string {
	if size <= 0 {
		return ""
	}
	var b strings.Builder
	b.Grow(size)
	for b.Len() < size {
		b.WriteString(seed)
	}
	return b.String()[:size]
}

func workerWorkspace(cfg config, workerID int) string {
	return fmt.Sprintf("asset-kv-ws-%d", workerID%cfg.Workspaces)
}

func workerConvID(cfg config, workerID, assetIndex int) uint64 {
	// Durable records belong to the workspace, not individual chat rooms.
	return protocol.WorkspaceDataConvID
}

func printResult(result operationResult) {
	fmt.Printf("Backend:       %s\n", result.Backend)
	fmt.Printf("Ops:           %d\n", result.Ops)
	fmt.Printf("PipelineDepth: %d\n", result.PipelineDepth)
	fmt.Printf("Duration:      %.2f ms\n", result.DurationMS)
	fmt.Printf("Throughput:    %.2f ops/sec\n", result.OpsPerSec)
	fmt.Printf("Latency p50:   %.3f ms\n", result.LatencyMS["p50"])
	fmt.Printf("Latency p95:   %.3f ms\n", result.LatencyMS["p95"])
	fmt.Printf("Latency p99:   %.3f ms\n", result.LatencyMS["p99"])
	fmt.Printf("Latency max:   %.3f ms\n", result.LatencyMS["max"])
	fmt.Printf("Errors:        %d\n", result.Errors)
	fmt.Printf("Bytes written: %d\n", result.BytesWritten)
	fmt.Printf("Bytes read:    %d\n", result.BytesRead)

	keys := make([]string, 0, len(result.OperationsByOp))
	for key := range result.OperationsByOp {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	if len(keys) > 0 {
		fmt.Print("Ops by type:   ")
		for i, key := range keys {
			if i > 0 {
				fmt.Print(", ")
			}
			fmt.Printf("%s=%d", key, result.OperationsByOp[key])
		}
		fmt.Println()
	}
	fmt.Println()
}

// NRC backend

type nrcWorker struct {
	cfg           config
	workerID      int
	workspaceID   string
	conn          *websocket.Conn
	nextCorrID    uint32
	nextSynthetic uint64
}

func openNRCWorker(ctx context.Context, cfg config, workerID int) (*nrcWorker, error) {
	workspaceID := workerWorkspace(cfg, workerID)
	serverURL := strings.TrimRight(cfg.ServerURL, "/") + "/" + workspaceID
	headers := http.Header{}
	if cfg.Auth {
		token, err := buildProxyStyleJWT(fmt.Sprintf("asset-kv-worker-%d", workerID), time.Now(), cfg.JWTSecret, cfg.JWTIssuer, cfg.JWTAudience, cfg.JWTTTL)
		if err != nil {
			return nil, err
		}
		headers.Set("X-NRC-Auth", token)
	}

	dialer := websocket.Dialer{HandshakeTimeout: cfg.Timeout, ReadBufferSize: 131072, WriteBufferSize: 131072}
	conn, _, err := dialer.DialContext(ctx, serverURL, headers)
	if err != nil {
		return nil, fmt.Errorf("dial NRC websocket: %w", err)
	}
	worker := &nrcWorker{cfg: cfg, workerID: workerID, workspaceID: workspaceID, conn: conn}
	if err := worker.waitReady(); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return worker, nil
}

func (w *nrcWorker) Close() error {
	if w.conn == nil {
		return nil
	}
	_ = w.conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""), time.Now().Add(time.Second))
	return w.conn.Close()
}

func (w *nrcWorker) waitReady() error {
	_ = w.conn.SetReadDeadline(time.Now().Add(w.cfg.Timeout))
	_, data, err := w.conn.ReadMessage()
	if err != nil {
		return fmt.Errorf("read NRC server ready: %w", err)
	}
	msg, err := protocol.ReadMessage(data)
	if err != nil {
		return err
	}
	if msg.Opcode != protocol.S_ServerReady {
		return fmt.Errorf("expected S_ServerReady, got opcode %d", msg.Opcode)
	}
	return nil
}

func (w *nrcWorker) nextCorrelationID() uint32 {
	w.nextCorrID++
	if w.nextCorrID == 0 {
		w.nextCorrID++
	}
	return w.nextCorrID
}

func (w *nrcWorker) Create(_ context.Context, convID uint64, asset assetPayload) (assetRef, int, int, error) {
	corrID := w.nextCorrelationID()
	payload := protocol.EncodeCreateAssetWithMetadataAndCorrelation(int64(convID), asset.AssetType, asset.ParentType, asset.ParentID, asset.PayloadEncoding, asset.PayloadRawLen, asset.Preview, asset.Payload, corrID)
	sent, data, err := w.sendAndWait(protocol.C_CreateAsset, payload, protocol.S_AssetCreated, corrID)
	if err != nil {
		return assetRef{}, sent, len(data), err
	}
	resp, err := protocol.DecodeAssetCreated(data)
	if err != nil {
		return assetRef{}, sent, len(data), err
	}
	return assetRef{ConvID: convID, ID: resp.Asset.AssetID, Key: w.redisLikeKey(convID, resp.Asset.AssetID), Asset: asset}, sent, len(data), nil
}

func (w *nrcWorker) sendAndWait(opcode uint16, payload []byte, expectOpcode uint16, corrID uint32) (int, []byte, error) {
	msg := &protocol.Message{Opcode: opcode, Data: payload}
	wire, err := msg.Write()
	if err != nil {
		return 0, nil, err
	}
	_ = w.conn.SetWriteDeadline(time.Now().Add(w.cfg.Timeout))
	if err := w.conn.WriteMessage(websocket.BinaryMessage, wire); err != nil {
		return len(wire), nil, err
	}
	for {
		_ = w.conn.SetReadDeadline(time.Now().Add(w.cfg.Timeout))
		_, data, err := w.conn.ReadMessage()
		if err != nil {
			return len(wire), nil, err
		}
		msg, err := protocol.ReadMessage(data)
		if err != nil {
			return len(wire), data, err
		}
		if msg.Opcode == protocol.S_ErrorResponse {
			resp, _ := protocol.DecodeErrorResponse(msg.Data)
			if resp.CorrelationID == corrID {
				return len(wire), data, fmt.Errorf("NRC error for opcode %d: %s", resp.OriginOpcode, resp.ErrorMessage)
			}
			continue
		}
		if msg.Opcode != expectOpcode {
			continue
		}
		if responseCorrelation(msg.Opcode, msg.Data) != corrID {
			continue
		}
		return len(wire), msg.Data, nil
	}
}

func (w *nrcWorker) ExecuteBatch(_ context.Context, ops []benchOp) []benchOpResult {
	results := make([]benchOpResult, len(ops))
	type pendingInfo struct {
		idx      int
		expectOp uint16
	}
	byCorrID := make(map[uint32]pendingInfo, len(ops))

	batchStart := time.Now()
	for i, op := range ops {
		results[i].Kind = op.Kind
		results[i].Ref = op.Ref

		corrID := w.nextCorrelationID()
		var expectOp uint16
		var wire []byte

		switch op.Kind {
		case "create":
			expectOp = protocol.S_AssetCreated
			p := protocol.EncodeCreateAssetWithMetadataAndCorrelation(
				int64(op.ConvID), op.Asset.AssetType, op.Asset.ParentType, op.Asset.ParentID,
				op.Asset.PayloadEncoding, op.Asset.PayloadRawLen, op.Asset.Preview, op.Asset.Payload, corrID)
			wire, _ = (&protocol.Message{Opcode: protocol.C_CreateAsset, Data: p}).Write()
		case "get":
			expectOp = protocol.S_AssetFull
			p := protocol.EncodeGetAssetWithCorrelation(int64(op.Ref.ConvID), op.Ref.ID, corrID)
			wire, _ = (&protocol.Message{Opcode: protocol.C_GetAsset, Data: p}).Write()
		case "update":
			expectOp = protocol.S_AssetUpdated
			p := protocol.EncodeUpdateAssetWithMetadataAndCorrelation(
				int64(op.Ref.ConvID), op.Ref.ID,
				op.Asset.PayloadEncoding, op.Asset.PayloadRawLen, op.Asset.Preview, op.Asset.Payload, corrID)
			wire, _ = (&protocol.Message{Opcode: protocol.C_UpdateAsset, Data: p}).Write()
		case "delete":
			expectOp = protocol.S_AssetDeleted
			p := protocol.EncodeDeleteAssetWithCorrelation(int64(op.Ref.ConvID), op.Ref.ID, corrID)
			wire, _ = (&protocol.Message{Opcode: protocol.C_DeleteAsset, Data: p}).Write()
		}

		byCorrID[corrID] = pendingInfo{idx: i, expectOp: expectOp}
		results[i].Sent = len(wire)
		if w.cfg.Timeout > 0 {
			_ = w.conn.SetWriteDeadline(time.Now().Add(w.cfg.Timeout))
		}
		if err := w.conn.WriteMessage(websocket.BinaryMessage, wire); err != nil {
			results[i].Err = err
			results[i].Duration = time.Since(batchStart)
			delete(byCorrID, corrID)
		}
	}

	for len(byCorrID) > 0 {
		if w.cfg.Timeout > 0 {
			_ = w.conn.SetReadDeadline(time.Now().Add(w.cfg.Timeout))
		}
		_, data, err := w.conn.ReadMessage()
		if err != nil {
			for _, pending := range byCorrID {
				results[pending.idx].Err = err
				results[pending.idx].Received = len(data)
				results[pending.idx].Duration = time.Since(batchStart)
			}
			return results
		}

		msg, readErr := protocol.ReadMessage(data)
		if readErr != nil {
			continue
		}

		if msg.Opcode == protocol.S_ErrorResponse {
			resp, decodeErr := protocol.DecodeErrorResponse(msg.Data)
			if decodeErr != nil {
				continue
			}
			pending, ok := byCorrID[resp.CorrelationID]
			if !ok {
				continue
			}
			delete(byCorrID, resp.CorrelationID)
			results[pending.idx].Received = len(msg.Data)
			results[pending.idx].Duration = time.Since(batchStart)
			results[pending.idx].Err = fmt.Errorf("NRC error for opcode %d: %s", resp.OriginOpcode, resp.ErrorMessage)
			continue
		}

		respCorr := responseCorrelation(msg.Opcode, msg.Data)
		if respCorr == 0 {
			continue
		}
		pending, ok := byCorrID[respCorr]
		if !ok {
			continue
		}
		delete(byCorrID, respCorr)

		results[pending.idx].Received = len(msg.Data)
		results[pending.idx].Duration = time.Since(batchStart)
		if msg.Opcode != pending.expectOp {
			results[pending.idx].Err = fmt.Errorf("unexpected NRC response opcode %d, expected %d", msg.Opcode, pending.expectOp)
			continue
		}
		if msg.Opcode == protocol.S_AssetCreated {
			resp, decErr := protocol.DecodeAssetCreated(msg.Data)
			if decErr != nil {
				results[pending.idx].Err = decErr
				continue
			}
			op := ops[pending.idx]
			results[pending.idx].Ref = assetRef{ConvID: op.ConvID, ID: resp.Asset.AssetID, Key: w.redisLikeKey(op.ConvID, resp.Asset.AssetID), Asset: op.Asset}
		}
	}
	return results
}

func responseCorrelation(opcode uint16, data []byte) uint32 {
	switch opcode {
	case protocol.S_AssetCreated, protocol.S_AssetUpdated, protocol.S_AssetFull:
		if len(data) < 4 {
			return 0
		}
		return binary.BigEndian.Uint32(data[len(data)-4:])
	case protocol.S_AssetDeleted:
		if len(data) != 20 {
			return 0
		}
		return binary.BigEndian.Uint32(data[16:20])
	default:
		return 0
	}
}

func (w *nrcWorker) redisLikeKey(convID, assetID uint64) string {
	return fmt.Sprintf("%s:%s:%d:%d", w.cfg.RedisPrefix, w.workspaceID, convID, assetID)
}

// Redis backend

type redisWorker struct {
	cfg         config
	workerID    int
	workspaceID string
	conn        net.Conn
	r           *bufio.Reader
	nextID      uint64
}

func openRedisWorker(cfg config, workerID int) (*redisWorker, error) {
	conn, err := net.DialTimeout(cfg.RedisNetwork, cfg.RedisAddr, cfg.Timeout)
	if err != nil {
		return nil, fmt.Errorf("dial Redis: %w", err)
	}
	return &redisWorker{cfg: cfg, workerID: workerID, workspaceID: workerWorkspace(cfg, workerID), conn: conn, r: bufio.NewReader(conn)}, nil
}

func (w *redisWorker) Close() error {
	if w.conn == nil {
		return nil
	}
	return w.conn.Close()
}

func (w *redisWorker) Create(_ context.Context, convID uint64, asset assetPayload) (assetRef, int, int, error) {
	w.nextID++
	assetID := (uint64(w.workerID) << 48) | w.nextID
	key := w.key(convID, assetID)
	value := encodeRedisAsset(w.workspaceID, convID, assetID, asset)
	sent, received, err := w.do("SET", []byte(key), value)
	return assetRef{ConvID: convID, ID: assetID, Key: key, Asset: asset}, sent, received, err
}

func (w *redisWorker) ExecuteBatch(_ context.Context, ops []benchOp) []benchOpResult {
	results := make([]benchOpResult, len(ops))
	var reqBuf bytes.Buffer

	for i, op := range ops {
		results[i].Kind = op.Kind
		beforeLen := reqBuf.Len()
		switch op.Kind {
		case "create":
			w.nextID++
			assetID := (uint64(w.workerID) << 48) | w.nextID
			key := w.key(op.ConvID, assetID)
			value := encodeRedisAsset(w.workspaceID, op.ConvID, assetID, op.Asset)
			writeRESPArray(&reqBuf, "SET", []byte(key), value)
			results[i].Ref = assetRef{ConvID: op.ConvID, ID: assetID, Key: key, Asset: op.Asset}
		case "get":
			writeRESPArray(&reqBuf, "GET", []byte(op.Ref.Key))
		case "update":
			value := encodeRedisAsset(w.workspaceID, op.Ref.ConvID, op.Ref.ID, op.Asset)
			writeRESPArray(&reqBuf, "SET", []byte(op.Ref.Key), value)
		case "delete":
			writeRESPArray(&reqBuf, "DEL", []byte(op.Ref.Key))
		}
		results[i].Sent = reqBuf.Len() - beforeLen
	}

	batchStart := time.Now()
	_ = w.conn.SetDeadline(time.Now().Add(w.cfg.Timeout))
	if _, writeErr := w.conn.Write(reqBuf.Bytes()); writeErr != nil {
		for i := range ops {
			results[i].Err = writeErr
			results[i].Duration = time.Since(batchStart)
		}
		return results
	}

	for i := range ops {
		recv, err := readRESP(w.r)
		results[i].Received = recv
		results[i].Duration = time.Since(batchStart)
		if err != nil {
			results[i].Err = err
		}
	}
	return results
}

func (w *redisWorker) key(convID, assetID uint64) string {
	return fmt.Sprintf("%s:%s:%d:%d", w.cfg.RedisPrefix, w.workspaceID, convID, assetID)
}

func (w *redisWorker) do(command string, args ...[]byte) (int, int, error) {
	var req bytes.Buffer
	writeRESPArray(&req, command, args...)
	_ = w.conn.SetDeadline(time.Now().Add(w.cfg.Timeout))
	if _, err := w.conn.Write(req.Bytes()); err != nil {
		return req.Len(), 0, err
	}
	received, err := readRESP(w.r)
	return req.Len(), received, err
}

func writeRESPArray(buf *bytes.Buffer, command string, args ...[]byte) {
	fmt.Fprintf(buf, "*%d\r\n", len(args)+1)
	writeRESPBulk(buf, []byte(command))
	for _, arg := range args {
		writeRESPBulk(buf, arg)
	}
}

func writeRESPBulk(buf *bytes.Buffer, data []byte) {
	fmt.Fprintf(buf, "$%d\r\n", len(data))
	buf.Write(data)
	buf.WriteString("\r\n")
}

func readRESP(r *bufio.Reader) (int, error) {
	prefix, err := r.ReadByte()
	if err != nil {
		return 0, err
	}
	read := 1
	line, n, err := readRESPLine(r)
	read += n
	if err != nil {
		return read, err
	}

	switch prefix {
	case '+':
		return read, nil
	case '-':
		return read, errors.New(line)
	case ':':
		return read, nil
	case '$':
		length, err := strconv.Atoi(line)
		if err != nil {
			return read, err
		}
		if length < 0 {
			return read, fmt.Errorf("redis nil bulk response")
		}
		payload := make([]byte, length+2)
		n, err := io.ReadFull(r, payload)
		read += n
		if err != nil {
			return read, err
		}
		if payload[length] != '\r' || payload[length+1] != '\n' {
			return read, fmt.Errorf("malformed redis bulk terminator")
		}
		return read, nil
	default:
		return read, fmt.Errorf("unsupported redis response prefix %q", prefix)
	}
}

func readRESPLine(r *bufio.Reader) (string, int, error) {
	line, err := r.ReadString('\n')
	if err != nil {
		return "", len(line), err
	}
	if len(line) < 2 || line[len(line)-2] != '\r' {
		return "", len(line), fmt.Errorf("malformed redis response line")
	}
	return line[:len(line)-2], len(line), nil
}

func encodeRedisAsset(workspaceID string, convID, assetID uint64, asset assetPayload) []byte {
	owner := "asset-kv-bench"
	now := time.Now().UnixNano()
	payloadSize := 2 + len(workspaceID) + 2 + 8 + 2 + 8 + 2 + len(owner) + 8 + 8 + 8 + 1 + 4 + 2 + len(asset.Preview) + 2 + len(asset.Payload)
	buf := make([]byte, payloadSize)
	offset := 0
	putString16(buf, &offset, workspaceID)
	binary.BigEndian.PutUint16(buf[offset:], asset.AssetType)
	offset += 2
	binary.BigEndian.PutUint64(buf[offset:], assetID)
	offset += 8
	binary.BigEndian.PutUint16(buf[offset:], asset.ParentType)
	offset += 2
	binary.BigEndian.PutUint64(buf[offset:], asset.ParentID)
	offset += 8
	putString16(buf, &offset, owner)
	binary.BigEndian.PutUint64(buf[offset:], uint64(now))
	offset += 8
	binary.BigEndian.PutUint64(buf[offset:], uint64(now))
	offset += 8
	binary.BigEndian.PutUint64(buf[offset:], convID)
	offset += 8
	buf[offset] = asset.PayloadEncoding
	offset++
	binary.BigEndian.PutUint32(buf[offset:], asset.PayloadRawLen)
	offset += 4
	putString16(buf, &offset, asset.Preview)
	putString16(buf, &offset, asset.Payload)
	return buf
}

func putString16(buf []byte, offset *int, value string) {
	binary.BigEndian.PutUint16(buf[*offset:], uint16(len(value)))
	*offset += 2
	copy(buf[*offset:], value)
	*offset += len(value)
}

// Managed server and JWT helpers.

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
	const configuredOdinPath = "/home/rene/Work/Code/Odin/odin"
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

func startManagedServer(serverURL string, jwtSecret string) (*managedServer, error) {
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
	proc := &managedServer{cmd: cmd}
	cmd.Stdout = &proc.logs
	cmd.Stderr = &proc.logs
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start server process: %w", err)
	}
	if err := waitForServerReady(hostPort, 10*time.Second); err != nil {
		_ = cmd.Process.Signal(syscall.SIGINT)
		_ = cmd.Wait()
		return nil, fmt.Errorf("server did not become ready: %v\nserver logs:\n%s", err, proc.logs.String())
	}
	// The listener can open before every worker has finished WAL replay and is
	// ready to complete the WebSocket handshake. Give managed benchmark runs a
	// short grace period so large local data files don't cause first-dial noise.
	time.Sleep(2 * time.Second)
	return proc, nil
}

func stopManagedServer(s *managedServer) {
	if s == nil || s.cmd == nil || s.cmd.Process == nil {
		return
	}
	done := make(chan error, 1)
	go func() { done <- s.cmd.Wait() }()
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

type jwtHeader struct {
	Alg string `json:"alg"`
	Typ string `json:"typ"`
}

type jwtClaims struct {
	Sub      string `json:"sub"`
	Username string `json:"username"`
	Iss      string `json:"iss"`
	Aud      string `json:"aud"`
	Exp      int64  `json:"exp"`
	Nbf      int64  `json:"nbf"`
}

func buildProxyStyleJWT(username string, now time.Time, secret, issuer, audience string, ttl time.Duration) (string, error) {
	headerJSON, err := json.Marshal(jwtHeader{Alg: "HS256", Typ: "JWT"})
	if err != nil {
		return "", err
	}
	claimsJSON, err := json.Marshal(jwtClaims{Sub: username, Username: username, Iss: issuer, Aud: audience, Nbf: now.Unix() - 2, Exp: now.Add(ttl).Unix()})
	if err != nil {
		return "", err
	}
	headerSegment := base64.RawURLEncoding.EncodeToString(headerJSON)
	payloadSegment := base64.RawURLEncoding.EncodeToString(claimsJSON)
	signingInput := headerSegment + "." + payloadSegment
	mac := hmac.New(sha256.New, []byte(secret))
	if _, err := mac.Write([]byte(signingInput)); err != nil {
		return "", err
	}
	signature := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return signingInput + "." + signature, nil
}
