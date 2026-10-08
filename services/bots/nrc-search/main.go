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
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type IndexEntry struct {
	Vector       []float32
	Chunks       []IndexChunk
	ContentHash  uint64
	AssetType    uint16
	ConvID       uint64
	Preview      string
	Payload      string
	PreviewLower string
	PayloadLower string
	IndexedAt    time.Time
	Bloom        uint64
	Metadata     SearchMetadata
	SearchText   string
}

func indexEntryFromStoredEmbedding(emb StoredEmbedding) *IndexEntry {
	payloadLower := strings.ToLower(searchableAssetContent(emb.AssetType, emb.Preview, emb.Payload))
	if emb.SearchText != "" {
		payloadLower = strings.ToLower(emb.SearchText)
	}
	previewLower := strings.ToLower(emb.Preview)
	return &IndexEntry{
		Vector:       emb.Vector,
		Chunks:       indexChunksFromStored(emb.Chunks),
		ContentHash:  emb.ContentHash,
		AssetType:    emb.AssetType,
		ConvID:       emb.ConvID,
		Preview:      emb.Preview,
		Payload:      emb.Payload,
		PreviewLower: previewLower,
		PayloadLower: payloadLower,
		Bloom:        BigramBloom(payloadLower) | BigramBloom(previewLower),
		Metadata:     emb.Metadata,
		SearchText:   emb.SearchText,
	}
}

type IndexChunk struct {
	Index  int
	Vector []float32
}

// BigramBloom builds a 64-bit bloom filter from all 2-byte bigrams in s.
// Used to quickly reject substring non-matches without scanning.
func BigramBloom(s string) uint64 {
	var bloom uint64
	for i := 0; i < len(s)-1; i++ {
		bigram := uint16(s[i])<<8 | uint16(s[i+1])
		bloom |= 1 << (bigram % 64)
		bloom |= 1 << ((uint32(bigram) * 0x9E3779B1) >> 26) // knuth multiplicative hash, top 6 bits
	}
	return bloom
}

type SearchResult struct {
	Entity     EntityIdentity `json:"entity"`
	Metadata   SearchMetadata `json:"metadata"`
	AssetID    uint64         `json:"asset_id,string,omitempty"`
	Score      float64        `json:"score"`
	Similarity float32        `json:"similarity,omitempty"`
	Preview    string         `json:"preview"`
	AssetType  uint16         `json:"asset_type,omitempty"`
	Payload    string         `json:"payload,omitempty"`
}

type Config struct {
	NRCServer         string
	SearchPort        string
	ModelPath         string
	TokenizerPath     string
	EmbeddingSchema   string
	EmbedAssetTypes   []uint16
	EmbedTasks        bool
	ReconcileInterval time.Duration
	NRCNickname       string
	NRCBotSecret      string
	DataDir           string
	FilesURL          string
}

func loadConfig() Config {
	cfg := Config{
		NRCServer:       envOrDefault("NRC_SERVER", "ws://localhost:8080"),
		SearchPort:      envOrDefault("SEARCH_PORT", "8090"),
		ModelPath:       envOrDefault("MODEL_PATH", "./models/model.onnx"),
		TokenizerPath:   envOrDefault("TOKENIZER_PATH", "./models/tokenizer.json"),
		EmbeddingSchema: envOrDefault("EMBEDDING_SCHEMA", default_embedding_schema),
		DataDir:         envOrDefault("DATA_DIR", "./data"),
		FilesURL:        os.Getenv("FILES_URL"),
	}

	cfg.NRCBotSecret = envOrDefault("NRC_BOT_SECRET", "")
	cfg.NRCNickname = envOrDefault("NRC_NICKNAME", "")
	if cfg.NRCNickname == "" {
		hostname, _ := os.Hostname()
		if hostname == "" {
			hostname = fmt.Sprintf("%d", os.Getpid())
		}
		cfg.NRCNickname = fmt.Sprintf("search-%s", hostname)
	}

	cfg.EmbedAssetTypes = parseAssetTypes(envOrDefault("EMBED_ASSET_TYPES", "1,2,3,4,5,8,9,10"))
	cfg.EmbedTasks = parseBool(envOrDefault("EMBED_TASKS", "true"), true)

	intervalStr := envOrDefault("RECONCILE_INTERVAL", "15m")
	d, err := time.ParseDuration(intervalStr)
	if err != nil {
		slog.Warn("invalid RECONCILE_INTERVAL, using default 15m", "value", intervalStr, "error", err)
		d = 15 * time.Minute
	}
	cfg.ReconcileInterval = d

	return cfg
}

func parseBool(value string, fallback bool) bool {
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		slog.Warn("invalid boolean configuration, using default", "value", value, "default", fallback)
		return fallback
	}
	return parsed
}

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func parseAssetTypes(s string) []uint16 {
	parts := strings.Split(s, ",")
	types := make([]uint16, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		n, err := strconv.ParseUint(p, 10, 16)
		if err != nil {
			slog.Warn("skipping invalid asset type", "value", p, "error", err)
			continue
		}
		types = append(types, uint16(n))
	}
	return types
}

type searchRequest struct {
	Workspace      string          `json:"workspace"`
	Query          string          `json:"query,omitempty"`
	SimilarAssetID *uint64         `json:"similar_asset_id,string,omitempty"`
	SimilarEntity  *EntityIdentity `json:"similar_entity,omitempty"`
	ConvID         uint64          `json:"conv_id,string"`
	TopN           int             `json:"top_n"`
	AssetTypes     []uint16        `json:"asset_types"`
	Filters        SearchFilters   `json:"filters,omitempty"`
	IncludePayload bool            `json:"include_payload"`
}

type searchResponse struct {
	Results []SearchResult `json:"results"`
	Stale   bool           `json:"stale,omitempty"`
}

func sameAssetTypeSet(a, b []uint16) bool {
	set := make(map[uint16]struct{}, len(a))
	for _, value := range a {
		set[value] = struct{}{}
	}
	other := make(map[uint16]struct{}, len(b))
	for _, value := range b {
		other[value] = struct{}{}
	}
	if len(set) != len(other) {
		return false
	}
	for value := range set {
		if _, ok := other[value]; !ok {
			return false
		}
	}
	return true
}

func (req *searchRequest) normalize() error {
	if req.Workspace == "" {
		return fmt.Errorf("workspace is required")
	}
	if req.ConvID != protocol.WorkspaceDataConvID {
		return fmt.Errorf("search is workspace-wide; conv_id must be 0")
	}
	if req.Filters.Customer != nil && (req.SimilarAssetID != nil || req.SimilarEntity != nil) {
		return fmt.Errorf("customer register mode does not support similar search")
	}
	if req.SimilarAssetID != nil && req.SimilarEntity != nil {
		return fmt.Errorf("similar_asset_id conflicts with similar_entity")
	}
	if len(req.AssetTypes) > 0 && len(req.Filters.AssetTypes) > 0 && !sameAssetTypeSet(req.AssetTypes, req.Filters.AssetTypes) {
		return fmt.Errorf("asset_types conflicts with filters.asset_types")
	}
	if len(req.Filters.AssetTypes) == 0 {
		req.Filters.AssetTypes = req.AssetTypes
	}
	if req.SimilarAssetID != nil {
		if *req.SimilarAssetID == 0 {
			return fmt.Errorf("similar_asset_id is required")
		}
		identity := assetIdentity(req.Workspace, *req.SimilarAssetID, req.ConvID)
		req.SimilarEntity = &identity
	}
	if req.SimilarEntity != nil {
		if req.SimilarEntity.Workspace != "" && req.SimilarEntity.Workspace != req.Workspace {
			return fmt.Errorf("similar_entity.workspace conflicts with workspace")
		}
		req.SimilarEntity.Workspace = req.Workspace
		if req.SimilarEntity.ConvID != protocol.WorkspaceDataConvID {
			return fmt.Errorf("similar_entity.conv_id must be 0")
		}
		if err := req.SimilarEntity.Validate(); err != nil {
			return err
		}
	}
	if len(req.Filters.EntityTypes) == 0 {
		if req.SimilarEntity != nil {
			req.Filters.EntityTypes = []EntityType{req.SimilarEntity.EntityType}
		} else {
			req.Filters.EntityTypes = []EntityType{EntityTypeAsset}
		}
	}
	for _, typ := range req.Filters.EntityTypes {
		if !typ.Valid() {
			return fmt.Errorf("unsupported entity type %q", typ)
		}
	}
	includesTask := false
	for _, typ := range req.Filters.EntityTypes {
		includesTask = includesTask || typ == EntityTypeTask
	}
	if req.Filters.Task != nil && !req.Filters.Task.Empty() && !includesTask {
		return fmt.Errorf("task filters require task entity type")
	}
	if includesTask {
		if req.Filters.Task == nil {
			req.Filters.Task = &TaskFilters{}
		}
		if len(req.Filters.Task.Statuses) == 0 {
			req.Filters.Task.Statuses = []uint8{protocol.TaskStatusBacklog, protocol.TaskStatusTodo, protocol.TaskStatusInProgress, protocol.TaskStatusDone}
		}
		if req.Filters.Task.OverdueBefore != nil && *req.Filters.Task.OverdueBefore <= 0 {
			return fmt.Errorf("filters.task.overdue_before must be greater than zero")
		}
	}
	if req.Query == "" && req.SimilarEntity == nil && !(len(req.Filters.EntityTypes) == 1 && includesTask) {
		return fmt.Errorf("query or similarity seed is required")
	}
	if req.Query != "" && req.SimilarEntity != nil {
		return fmt.Errorf("query conflicts with similarity seed")
	}
	if req.TopN <= 0 {
		req.TopN = 10
	}
	return nil
}

type healthResponse struct {
	Status        string `json:"status"`
	IndexedAssets int    `json:"indexed_assets"`
	Model         string `json:"model"`
	Uptime        string `json:"uptime"`
}

type WorkspaceManager struct {
	mu       sync.Mutex
	clients  map[string]*NRCClient
	cfg      Config
	storage  *Storage
	embedder Embedder
	index    *Index
	ctx      context.Context
	cancel   context.CancelFunc
	workers  sync.WaitGroup
	closed   bool
}

const clientReadyTimeout = 45 * time.Second

func NewWorkspaceManager(ctx context.Context, cfg Config, storage *Storage, embedder Embedder, index *Index) *WorkspaceManager {
	ctx, cancel := context.WithCancel(ctx)
	return &WorkspaceManager{
		clients:  make(map[string]*NRCClient),
		cfg:      cfg,
		storage:  storage,
		embedder: embedder,
		index:    index,
		ctx:      ctx,
		cancel:   cancel,
	}
}

func (wm *WorkspaceManager) GetOrCreateClient(workspace string) (*NRCClient, error) {
	return wm.getAttachmentClient(wm.ctx, workspace)
}

func (wm *WorkspaceManager) getAttachmentClient(ctx context.Context, workspace string) (*NRCClient, error) {
	wm.mu.Lock()
	if wm.closed {
		wm.mu.Unlock()
		return nil, fmt.Errorf("search generation stopped")
	}
	isNew := false
	var client *NRCClient

	if existing, ok := wm.clients[workspace]; ok {
		client = existing
	} else {
		if err := wm.storage.RegisterWorkspace(workspace); err != nil {
			wm.mu.Unlock()
			return nil, err
		}
		var err error
		client, err = NewNRCClient(wm.cfg, workspace, wm.storage, wm.embedder, wm.index)
		if err != nil {
			wm.mu.Unlock()
			return nil, err
		}

		wm.workers.Add(2)
		go func() { defer wm.workers.Done(); client.Run(wm.ctx) }()
		go func() { defer wm.workers.Done(); client.DrainEmbedQueue(wm.ctx) }()

		wm.clients[workspace] = client
		isNew = true
	}
	wm.mu.Unlock()

	slog.Info("waiting for NRC client ready", "workspace", workspace, "timeout", clientReadyTimeout, "new_client", isNew)
	if err := waitForClientReady(ctx, client, clientReadyTimeout, workspace); err != nil {
		return nil, err
	}

	slog.Info("NRC client ready", "workspace", workspace)
	return client, nil
}

func (wm *WorkspaceManager) Close() {
	wm.mu.Lock()
	wm.closed = true
	wm.cancel()
	for _, client := range wm.clients {
		client.closeConnection()
	}
	wm.mu.Unlock()
	wm.workers.Wait()
	for _, client := range wm.clients {
		client.refreshWorkers.Wait()
	}
}

func waitForClientReady(ctx context.Context, client *NRCClient, timeout time.Duration, workspace string) error {
	timer := time.NewTimer(timeout)
	defer timer.Stop()

	for {
		readyCh, generation := client.ReadyState()
		select {
		case <-readyCh:
			if client.ReadyGeneration() == generation {
				return nil
			}
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
			return fmt.Errorf("timeout waiting for NRC client to become ready for workspace %s", workspace)
		}
	}
}

func newHTTPHandler(cfg Config, startTime time.Time, wm *WorkspaceManager, index *Index, embedder Embedder) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("POST /attachment/text", attachmentTextHandler(cfg.NRCBotSecret, func(ctx context.Context, workspace string) (*NRCClient, error) {
		client, err := wm.getAttachmentClient(ctx, workspace)
		return client, err
	}))

	mux.HandleFunc("POST /search", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(protocol.SearchAPIVersionHeader, protocol.SearchAPIVersion)
		var req searchRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
			return
		}
		if err := req.normalize(); err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusBadRequest)
			return
		}

		client, err := wm.GetOrCreateClient(req.Workspace)
		if err != nil {
			slog.Error("failed to get client for workspace", "workspace", req.Workspace, "error", err)
			http.Error(w, `{"error":"failed to connect to workspace"}`, http.StatusInternalServerError)
			return
		}

		reconcileCtx, reconcileCancel := context.WithTimeout(r.Context(), 30*time.Second)
		stale := false
		if !client.IsSubscribed(req.ConvID) {
			slog.Info("room not subscribed, triggering subscription", "workspace", req.Workspace, "conv_id", req.ConvID)
			if err := client.SubscribeAndReconcile(reconcileCtx, req.ConvID); err != nil {
				slog.Warn("failed to subscribe and reconcile, searching with cached data", "workspace", req.Workspace, "conv_id", req.ConvID, "error", err)
				stale = true
			}
		} else if client.NeedsReconcile(req.ConvID, cfg.ReconcileInterval) {
			slog.Info("reconciling stale room", "workspace", req.Workspace, "conv_id", req.ConvID)
			if err := client.SubscribeAndReconcile(reconcileCtx, req.ConvID); err != nil {
				slog.Warn("reconciliation failed, searching with stale data", "workspace", req.Workspace, "conv_id", req.ConvID, "error", err)
				stale = true
			}
		}
		reconcileCancel()

		var results []SearchResult
		if req.SimilarEntity != nil {
			results, err = index.SimilarEntityParallel(*req.SimilarEntity, req.TopN, req.Filters, runtime.NumCPU())
		} else {
			results, err = index.SearchEntitiesParallel(req.Workspace, req.Query, embedder, req.ConvID, req.TopN, req.Filters, runtime.NumCPU())
		}
		if err != nil {
			if errors.Is(err, ErrSeedNotIndexed) {
				http.Error(w, `{"error":"seed entity is not indexed"}`, http.StatusBadRequest)
				return
			}
			slog.Error("search failed", "error", err)
			http.Error(w, `{"error":"search failed"}`, http.StatusInternalServerError)
			return
		}

		if !req.IncludePayload {
			for i := range results {
				results[i].Payload = ""
			}
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(searchResponse{Results: results, Stale: stale})
	})

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(healthResponse{
			Status:        "ok",
			IndexedAssets: index.Count(),
			Model:         cfg.ModelPath,
			Uptime:        time.Since(startTime).Round(time.Second).String(),
		})
	})

	return mux
}

func main() {
	cfg := loadConfig()
	startTime := time.Now()

	slog.Info("starting nrc-search",
		"server", cfg.NRCServer,
		"port", cfg.SearchPort,
		"model", cfg.ModelPath,
		"embedding_schema", cfg.EmbeddingSchema,
		"reconcile_interval", cfg.ReconcileInterval,
		"embed_asset_types", cfg.EmbedAssetTypes,
		"embed_tasks", cfg.EmbedTasks,
	)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	router, err := startGenerationRouter(ctx, cfg, startTime, loadGenerationModel)
	if err != nil {
		slog.Error("failed to open active search generation", "error", err)
		os.Exit(1)
	}
	rebuildDone := make(chan struct{})
	if router.active.spec.Schema != cfg.EmbeddingSchema {
		go func() { defer close(rebuildDone); router.rebuild(ctx, cfg, startTime) }()
	} else {
		close(rebuildDone)
	}
	defer func() {
		cancel()
		<-rebuildDone
		router.mu.Lock()
		defer router.mu.Unlock()
		router.active.Close()
	}()

	server := &http.Server{
		Addr:    ":" + cfg.SearchPort,
		Handler: router,
	}

	// Graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigCh
		slog.Info("received signal, shutting down", "signal", sig)
		cancel()

		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer shutdownCancel()

		if err := server.Shutdown(shutdownCtx); err != nil {
			slog.Error("HTTP server shutdown error", "error", err)
		}
	}()

	slog.Info(fmt.Sprintf("HTTP server listening on :%s", cfg.SearchPort))
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		slog.Error("HTTP server error", "error", err)
		os.Exit(1)
	}

	slog.Info("nrc-search stopped")
}
