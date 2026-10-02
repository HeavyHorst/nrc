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
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

var errClientReadyTimeout = errors.New("timeout waiting for NRC client ready")

type Config struct {
	NRCServer          string
	AIPort             string
	LLMProvider        string
	LLMModel           string
	LLMAPIKey          string
	LLMBaseURL         string
	SearchURL          string
	SourcebotURL       string
	SourcebotAPIKey    string
	SourcebotBearer    string
	SourcebotRepos     string
	NRCNickname        string
	NRCBotSecret       string
	MaxContextTokens   int
	LLMMaxOutputTokens int
}

func loadConfig() Config {
	cfg := Config{
		NRCServer:       envOrDefault("NRC_SERVER", "ws://localhost:8080"),
		AIPort:          envOrDefault("AI_PORT", "8091"),
		LLMProvider:     envOrDefault("LLM_PROVIDER", "openai"),
		LLMModel:        envOrDefault("LLM_MODEL", "gpt-4o-mini"),
		LLMAPIKey:       os.Getenv("LLM_API_KEY"),
		LLMBaseURL:      os.Getenv("LLM_BASE_URL"),
		SearchURL:       envOrDefault("SEARCH_URL", "http://localhost:8090"),
		SourcebotURL:    os.Getenv("SOURCEBOT_URL"),
		SourcebotAPIKey: os.Getenv("SOURCEBOT_API_KEY"),
		SourcebotBearer: os.Getenv("SOURCEBOT_BEARER_TOKEN"),
		SourcebotRepos:  os.Getenv("SOURCEBOT_ALLOWED_REPOS"),
		NRCBotSecret:    os.Getenv("NRC_BOT_SECRET"),
	}

	cfg.NRCNickname = envOrDefault("NRC_NICKNAME", "")
	if cfg.NRCNickname == "" {
		hostname, _ := os.Hostname()
		if hostname == "" {
			hostname = fmt.Sprintf("%d", os.Getpid())
		}
		cfg.NRCNickname = fmt.Sprintf("Sullivan-%s", hostname)
	}

	maxTokens := envOrDefault("MAX_CONTEXT_TOKENS", "128000")
	n, err := strconv.Atoi(maxTokens)
	if err != nil {
		slog.Warn("invalid MAX_CONTEXT_TOKENS, using default 128000", "value", maxTokens, "error", err)
		n = 128000
	}
	cfg.MaxContextTokens = n

	maxOut := envOrDefault("LLM_MAX_OUTPUT_TOKENS", "")
	if maxOut != "" {
		mo, err := strconv.Atoi(maxOut)
		if err != nil || mo <= 0 {
			slog.Warn("invalid LLM_MAX_OUTPUT_TOKENS, using model-aware default", "value", maxOut, "error", err)
		} else {
			cfg.LLMMaxOutputTokens = mo
		}
	}
	if cfg.LLMMaxOutputTokens == 0 {
		cfg.LLMMaxOutputTokens = defaultMaxOutputTokens(cfg.LLMProvider, cfg.LLMModel)
	}

	return cfg
}

// defaultMaxOutputTokens returns a sane max-output-token budget per provider/model
// when LLM_MAX_OUTPUT_TOKENS is not set explicitly. Frontier models (DeepSeek V4,
// Anthropic, OpenAI) get generous headroom well below their ceilings; small local
// Ollama models stay bounded.
func defaultMaxOutputTokens(provider, model string) int {
	p := strings.ToLower(strings.TrimSpace(provider))
	m := strings.ToLower(strings.TrimSpace(model))
	switch {
	case p == "deepseek" || strings.Contains(m, "deepseek"):
		return 32768
	case p == "anthropic" || strings.Contains(m, "claude"):
		return 8192
	case p == "openai" || strings.Contains(m, "gpt"):
		return 8192
	case p == "ollama":
		return 4096
	default:
		return 4096
	}
}

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

const (
	clientIdleTimeout      = 30 * time.Minute
	clientReadyTimeout     = 5 * time.Second
	clientReadyMaxAttempts = 3
)

type WorkspaceManager struct {
	mu      sync.Mutex
	clients map[string]*NRCClient
	cfg     Config
	ctx     context.Context
}

func NewWorkspaceManager(ctx context.Context, cfg Config) *WorkspaceManager {
	wm := &WorkspaceManager{
		clients: make(map[string]*NRCClient),
		cfg:     cfg,
		ctx:     ctx,
	}
	go wm.cleanupLoop()
	return wm
}

func (wm *WorkspaceManager) cleanupLoop() {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()

	for {
		select {
		case <-wm.ctx.Done():
			return
		case <-ticker.C:
			wm.evictIdle()
		}
	}
}

func (wm *WorkspaceManager) evictIdle() {
	now := time.Now().Unix()
	cutoff := int64(clientIdleTimeout / time.Second)

	wm.mu.Lock()
	var toEvict []string
	for ws, client := range wm.clients {
		if now-client.lastAccess.Load() > cutoff {
			toEvict = append(toEvict, ws)
		}
	}
	evicted := make([]*NRCClient, 0, len(toEvict))
	for _, ws := range toEvict {
		evicted = append(evicted, wm.clients[ws])
		delete(wm.clients, ws)
	}
	wm.mu.Unlock()

	for _, client := range evicted {
		slog.Info("evicting idle NRC client", "workspace", client.workspace)
		client.Stop()
	}
}

func (wm *WorkspaceManager) GetOrCreateClient(workspace string) (*NRCClient, error) {
	for attempt := 1; attempt <= clientReadyMaxAttempts; attempt++ {
		client, isNew := wm.getOrStartClientLocked(workspace)

		slog.Info("waiting for NRC client ready", "workspace", workspace, "attempt", attempt, "timeout", clientReadyTimeout, "new_client", isNew)
		err := waitForClientReady(wm.ctx, client, clientReadyTimeout)
		if err == nil {
			slog.Info("NRC client ready", "workspace", workspace, "attempt", attempt)
			return client, nil
		}
		if !errors.Is(err, errClientReadyTimeout) {
			return nil, err
		}

		slog.Warn("NRC client ready timeout, forcing reconnect", "workspace", workspace, "attempt", attempt, "max_attempts", clientReadyMaxAttempts)
		wm.removeClientIfCurrent(workspace, client)
		client.Stop()
	}

	return nil, fmt.Errorf("timeout waiting for NRC client to become ready for workspace %s after %d attempts", workspace, clientReadyMaxAttempts)
}

func (wm *WorkspaceManager) getOrStartClientLocked(workspace string) (*NRCClient, bool) {
	wm.mu.Lock()
	defer wm.mu.Unlock()

	if client, ok := wm.clients[workspace]; ok {
		return client, false
	}

	client := NewNRCClient(wm.cfg, workspace)
	clientCtx, clientCancel := context.WithCancel(wm.ctx)
	client.cancel = clientCancel
	go client.Run(clientCtx)
	wm.clients[workspace] = client
	return client, true
}

func (wm *WorkspaceManager) removeClientIfCurrent(workspace string, candidate *NRCClient) {
	wm.mu.Lock()
	defer wm.mu.Unlock()

	if current, ok := wm.clients[workspace]; ok && current == candidate {
		delete(wm.clients, workspace)
	}
}

func waitForClientReady(ctx context.Context, client *NRCClient, timeout time.Duration) error {
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
			return errClientReadyTimeout
		}
	}
}

func main() {
	cfg := loadConfig()
	startTime := time.Now()

	slog.Info("starting nrc-ai",
		"server", cfg.NRCServer,
		"port", cfg.AIPort,
		"llm_provider", cfg.LLMProvider,
		"llm_model", cfg.LLMModel,
		"llm_max_output_tokens", cfg.LLMMaxOutputTokens,
		"search_url", cfg.SearchURL,
		"sourcebot_configured", strings.TrimSpace(cfg.SourcebotURL) != "",
		"ask_engine", "fantasy",
	)

	llm, err := NewLLM(cfg.LLMProvider, cfg.LLMModel, cfg.LLMAPIKey, cfg.LLMBaseURL)
	if err != nil {
		slog.Error("failed to initialize LLM", "error", err)
		os.Exit(1)
	}
	slog.Info("LLM initialized", "provider", cfg.LLMProvider, "model", cfg.LLMModel)

	search := NewSearchClient(cfg.SearchURL)
	var sourcebot *SourcebotClient
	if strings.TrimSpace(cfg.SourcebotURL) != "" {
		sourcebot, err = NewSourcebotClient(cfg.SourcebotURL, cfg.SourcebotAPIKey, cfg.SourcebotBearer, cfg.SourcebotRepos)
		if err != nil {
			slog.Warn("sourcebot integration disabled", "error", err)
			sourcebot = nil
		} else {
			slog.Info("sourcebot integration enabled", "url", cfg.SourcebotURL)
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	wm := NewWorkspaceManager(ctx, cfg)
	agentSessions := newAgentSessionStore(30*time.Minute, 20)

	mux := http.NewServeMux()

	mux.HandleFunc("POST /paste-to-task", handlePasteToTask(llm))
	mux.HandleFunc("POST /paste-to-note", handlePasteToNote(llm, search))
	mux.HandleFunc("POST /retrieve", handleRetrieve(wm, search))
	mux.HandleFunc("POST /ask/apply", handleAskApply(wm, agentSessions))
	mux.HandleFunc("POST /ask/session/reset", handleAskSessionReset(agentSessions))
	mux.HandleFunc("GET /ask/session/{id}", handleAskSessionGet(agentSessions))
	askHandler, err := handleAskFantasy(wm, search, sourcebot, cfg, cfg.MaxContextTokens, agentSessions)
	if err != nil {
		slog.Error("failed to initialize fantasy ask engine", "error", err)
		mux.HandleFunc("POST /ask/ready", func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			json.NewEncoder(w).Encode(map[string]string{
				"error": "ask endpoint unavailable: ask engine failed to initialize",
			})
		})
		mux.HandleFunc("POST /ask", func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			json.NewEncoder(w).Encode(map[string]string{
				"error": "ask endpoint unavailable: ask engine failed to initialize",
			})
		})
		slog.Warn("ask route disabled; paste endpoints remain available")
	} else {
		slog.Info("fantasy ask engine enabled", "provider", cfg.LLMProvider, "model", cfg.LLMModel)
		mux.HandleFunc("POST /ask/ready", handleAskReady(wm))
		mux.HandleFunc("POST /ask", askHandler)
	}

	type healthResponse struct {
		Status      string `json:"status"`
		LLMProvider string `json:"llm_provider"`
		LLMModel    string `json:"llm_model"`
		Sourcebot   bool   `json:"sourcebot_enabled"`
		Uptime      string `json:"uptime"`
	}

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(healthResponse{
			Status:      "ok",
			LLMProvider: cfg.LLMProvider,
			LLMModel:    cfg.LLMModel,
			Sourcebot:   sourcebot != nil,
			Uptime:      time.Since(startTime).Round(time.Second).String(),
		})
	})

	server := &http.Server{
		Addr:    ":" + cfg.AIPort,
		Handler: mux,
	}

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

	slog.Info(fmt.Sprintf("HTTP server listening on :%s", cfg.AIPort))
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		slog.Error("HTTP server error", "error", err)
		os.Exit(1)
	}

	slog.Info("nrc-ai stopped")
}
