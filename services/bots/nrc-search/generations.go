package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

type generationSpec struct {
	Directory     string
	Schema        string
	ModelPath     string
	TokenizerPath string
	Legacy        bool
}

type generationManifest struct {
	Active  generationSpec
	Retired []string
}

var generationDirectory = regexp.MustCompile(`^index-[0-9a-f]{64}$`)

func validGenerationDirectory(name string) bool {
	return name == "." || generationDirectory.MatchString(name)
}

func readGenerationManifest(root string) (generationManifest, bool, error) {
	var manifest generationManifest
	data, err := os.ReadFile(filepath.Join(root, "active-index.json"))
	if os.IsNotExist(err) {
		return manifest, false, nil
	}
	if err != nil {
		return manifest, false, err
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		return manifest, false, err
	}
	if !validGenerationDirectory(manifest.Active.Directory) {
		return manifest, false, fmt.Errorf("invalid active index directory")
	}
	for _, name := range manifest.Retired {
		if !validGenerationDirectory(name) || name == manifest.Active.Directory {
			return manifest, false, fmt.Errorf("invalid retired index directory")
		}
	}
	return manifest, true, nil
}

// The pointer is durable before either generation is retired. A crash leaves
// either the old pointer or a complete new generation, never a partial rebuild.
func writeGenerationManifest(root string, manifest generationManifest) error {
	data, err := json.Marshal(manifest)
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(root, ".active-index-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if _, err := file.Write(data); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := os.Rename(file.Name(), filepath.Join(root, "active-index.json")); err != nil {
		return err
	}
	dir, err := os.Open(root)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func cleanupRetiredGenerations(root string, manifest generationManifest) error {
	for _, name := range manifest.Retired {
		if !validGenerationDirectory(name) || name == manifest.Active.Directory {
			return fmt.Errorf("refusing index cleanup")
		}
		path := filepath.Join(root, name)
		if name == "." {
			path = filepath.Join(root, "search.db")
		}
		if err := os.RemoveAll(path); err != nil {
			return err
		}
	}
	manifest.Retired = nil
	return writeGenerationManifest(root, manifest)
}

type searchGeneration struct {
	spec    generationSpec
	storage *Storage
	manager *WorkspaceManager
	handler http.Handler
}

func openSearchGeneration(ctx context.Context, cfg Config, start time.Time, spec generationSpec, storage *Storage, embedder Embedder) (*searchGeneration, error) {
	index := NewIndex()
	index.storage = storage
	embeddings, err := storage.LoadAllEntityEmbeddings()
	if err != nil {
		return nil, err
	}
	for identity, embedding := range embeddings {
		if identity.ConvID != 0 {
			continue
		}
		if err := index.AddEntity(identity, indexEntryFromStoredEmbedding(embedding)); err != nil {
			return nil, err
		}
	}
	cfg.EmbeddingSchema, cfg.ModelPath, cfg.TokenizerPath = spec.Schema, spec.ModelPath, spec.TokenizerPath
	if spec.Legacy || spec.Schema == "embeddinggemma-2-v1-chunked" {
		cfg.FilesURL = ""
	}
	// Two generations are independent bot connections, including custom nicknames.
	cfg.NRCNickname = envOrDefault("NRC_NICKNAME", "search") + "-" + fmt.Sprintf("%x", sha256.Sum256([]byte(spec.Directory)))[:12]
	manager := NewWorkspaceManager(ctx, cfg, storage, embedder, index)
	return &searchGeneration{spec, storage, manager, newHTTPHandler(cfg, start, manager, index, embedder)}, nil
}

func (g *searchGeneration) Close() {
	g.manager.Close()
	g.manager.embedder.Close()
	if err := g.storage.Close(); err != nil {
		slog.Error("close index generation", "error", err)
	}
}

type generationRouter struct {
	mu        sync.RWMutex
	active    *searchGeneration
	root      string
	loadModel func(generationSpec) (Embedder, error)
}

func loadGenerationModel(spec generationSpec) (Embedder, error) {
	return newGenerationEmbedder(spec.ModelPath, spec.TokenizerPath, spec.Legacy)
}

func (r *generationRouter) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	r.active.handler.ServeHTTP(w, req)
}

// Check source hashes as well as queues: dropped jobs and failed attachments
// must never turn an empty queue into a successful rebuild. Unavailable files
// (403/404) are reported and retried, but do not block activation.
func (c *NRCClient) indexComplete() (bool, error) {
	c.taskMutationMu.Lock()
	defer c.taskMutationMu.Unlock()
	return c.indexCompleteLocked()
}

func (c *NRCClient) indexCompleteLocked() (bool, error) {
	if !c.IsSubscribed(0) {
		return false, nil
	}
	if c.inventoryDirty[0] {
		return false, nil
	}
	if epoch, inventoried := c.inventoryEpochs[0]; !inventoried || epoch != c.ReadyGeneration() {
		return false, nil
	}
	for key := range c.unresolvedTasks {
		if key.ConvID == 0 {
			return false, nil
		}
	}
	empty, err := c.storage.QueuesEmpty(c.workspace)
	if err != nil || !empty {
		return false, err
	}
	for key, hash := range c.expectedHashes {
		if key.ConvID != 0 {
			continue
		}
		identity := EntityIdentity{Workspace: c.workspace, EntityType: key.EntityType, EntityID: key.EntityID, ConvID: key.ConvID}
		entry, ok := c.index.GetEntity(identity)
		if !ok || entry.ContentHash != hash {
			return false, nil
		}
		for _, attachment := range entry.Metadata.Attachments {
			if attachment.Status == "failed" {
				return false, nil
			}
		}
	}
	return true, nil
}

func (r *generationRouter) promote(next *searchGeneration, built map[string]bool) (bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	// Requests that introduced a workspace have finished registering it before
	// this lock can be acquired. Include it before deleting the old generation.
	workspaces, err := r.active.storage.Workspaces()
	if err != nil {
		return false, err
	}
	for _, workspace := range workspaces {
		if !built[workspace] {
			return false, nil
		}
		next.manager.mu.Lock()
		client := next.manager.clients[workspace]
		next.manager.mu.Unlock()
		client.taskMutationMu.Lock()
		defer client.taskMutationMu.Unlock()
		complete, err := client.indexCompleteLocked()
		if err != nil || !complete {
			return false, err
		}
	}
	if err := next.storage.db.Sync(); err != nil {
		return false, err
	}
	// Persist search.db's directory entry and the generation directory itself
	// before publishing a durable pointer to them (file fsync alone is insufficient).
	for _, path := range []string{filepath.Join(r.root, next.spec.Directory), r.root} {
		dir, err := os.Open(path)
		if err != nil {
			return false, err
		}
		err = dir.Sync()
		dir.Close()
		if err != nil {
			return false, err
		}
	}
	manifest := generationManifest{Active: next.spec, Retired: []string{r.active.spec.Directory}}
	if err := writeGenerationManifest(r.root, manifest); err != nil {
		return false, err
	}
	r.active = next
	return true, nil
}

// Eagerly rebuild even workspaces never queried after this deployment. A failed
// or interrupted attempt retains the serving index and resumes from disk.
func (r *generationRouter) rebuild(ctx context.Context, cfg Config, start time.Time) {
	old := r.active
	spec := generationSpec{Directory: fmt.Sprintf("index-%x", sha256.Sum256([]byte(cfg.EmbeddingSchema))), Schema: cfg.EmbeddingSchema, ModelPath: cfg.ModelPath, TokenizerPath: cfg.TokenizerPath}
	var next *searchGeneration
	defer func() {
		if next != nil {
			next.Close()
		}
	}()
	built := make(map[string]bool)
	lastAttempt := make(map[string]time.Time)
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for ctx.Err() == nil {
		if next == nil {
			storage, err := NewStorage(filepath.Join(r.root, spec.Directory))
			if err == nil {
				_, _, err = storage.EnsureEmbeddingSchema(spec.Schema)
				if err == nil {
					var embedder Embedder
					embedder, err = r.loadModel(spec)
					if err == nil {
						next, err = openSearchGeneration(ctx, cfg, start, spec, storage, embedder)
						if err != nil {
							embedder.Close()
						}
					}
				}
				if err != nil {
					storage.Close()
				}
			}
			if err != nil {
				slog.Error("shadow index initialization failed; old search stays active", "error", err)
				if !waitRebuild(ctx, time.Minute) {
					return
				}
				continue
			}
		}
		workspaces, err := old.storage.Workspaces()
		if err != nil {
			slog.Error("enumerate rebuild workspaces", "error", err)
			if !waitRebuild(ctx, time.Minute) {
				return
			}
			continue
		}
		for _, workspace := range workspaces {
			client, err := next.manager.GetOrCreateClient(workspace)
			if err != nil {
				slog.Warn("shadow workspace unavailable", "workspace", workspace, "error", err)
				continue
			}
			complete, err := client.indexComplete()
			if err != nil {
				slog.Warn("shadow index readiness", "error", err)
				continue
			}
			if built[workspace] && complete {
				continue
			}
			empty, err := next.storage.QueuesEmpty(workspace)
			if err != nil {
				continue
			}
			if built[workspace] && !empty {
				continue
			}
			if time.Since(lastAttempt[workspace]) < time.Minute {
				continue
			}
			lastAttempt[workspace] = time.Now()
			if err := client.SubscribeAndReconcile(ctx, 0); err != nil {
				built[workspace] = false
				slog.Warn("shadow inventory failed", "workspace", workspace, "error", err)
				continue
			}
			built[workspace] = true
			slog.Info("shadow inventory loaded", "workspace", workspace)
		}
		if ctx.Err() != nil {
			return
		}
		promoted, err := r.promote(next, built)
		if err != nil {
			slog.Error("shadow activation failed; old search stays active", "error", err)
		}
		if promoted {
			slog.Info("activated rebuilt search index", "schema", spec.Schema)
			next = nil  // Router owns it now.
			old.Close() // No request can still hold the retired generation.
			if err := cleanupRetiredGenerations(r.root, generationManifest{Active: spec, Retired: []string{old.spec.Directory}}); err != nil {
				slog.Error("retired index cleanup will retry at startup", "error", err)
			}
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func waitRebuild(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func startGenerationRouter(ctx context.Context, cfg Config, start time.Time, loadModel func(generationSpec) (Embedder, error)) (*generationRouter, error) {
	manifest, found, err := readGenerationManifest(cfg.DataDir)
	if err != nil {
		return nil, err
	}
	if found {
		if _, err := os.Stat(filepath.Join(cfg.DataDir, manifest.Active.Directory, "search.db")); err != nil {
			return nil, fmt.Errorf("active index unavailable: %w", err)
		}
	}
	spec := manifest.Active
	if !found {
		spec.Directory = "."
	}
	storage, err := NewStorage(filepath.Join(cfg.DataDir, spec.Directory))
	if err != nil {
		return nil, err
	}
	schema, err := storage.EmbeddingSchema()
	if err != nil {
		storage.Close()
		return nil, err
	}
	if !found {
		embeddings, err := storage.LoadAllEntityEmbeddings()
		if err != nil {
			storage.Close()
			return nil, err
		}
		workspaces, err := storage.Workspaces()
		if err != nil {
			storage.Close()
			return nil, err
		}
		if schema == "" && len(embeddings) == 0 && len(workspaces) == 0 {
			_, _, err = storage.EnsureEmbeddingSchema(cfg.EmbeddingSchema)
			schema = cfg.EmbeddingSchema
			if err != nil {
				storage.Close()
				return nil, err
			}
		}
		if schema == "" {
			schema = "embeddinggemma-300m-v2-chunked"
		}
		spec.Schema, spec.ModelPath, spec.TokenizerPath = schema, cfg.ModelPath, cfg.TokenizerPath
		if schema != cfg.EmbeddingSchema {
			spec.Legacy = strings.HasPrefix(schema, "embeddinggemma-300m-")
			if spec.Legacy {
				spec.ModelPath = envOrDefault("PREVIOUS_MODEL_PATH", "/app/models/legacy/model.onnx")
				spec.TokenizerPath = envOrDefault("PREVIOUS_TOKENIZER_PATH", "/app/models/legacy/tokenizer.json")
			} else if !strings.HasPrefix(schema, "embeddinggemma-2-") && os.Getenv("PREVIOUS_MODEL_PATH") == "" {
				storage.Close()
				return nil, fmt.Errorf("unknown previous schema %q: configure its matching PREVIOUS_MODEL_PATH and PREVIOUS_TOKENIZER_PATH", schema)
			} else {
				spec.ModelPath = envOrDefault("PREVIOUS_MODEL_PATH", cfg.ModelPath)
				spec.TokenizerPath = envOrDefault("PREVIOUS_TOKENIZER_PATH", cfg.TokenizerPath)
			}
		}
	}
	if found && schema != spec.Schema {
		storage.Close()
		return nil, fmt.Errorf("active index schema differs from manifest")
	}
	embedder, err := loadModel(spec)
	if err != nil {
		storage.Close()
		return nil, err
	}
	active, err := openSearchGeneration(ctx, cfg, start, spec, storage, embedder)
	if err != nil {
		embedder.Close()
		storage.Close()
		return nil, err
	}
	if found {
		if err := cleanupRetiredGenerations(cfg.DataDir, manifest); err != nil {
			slog.Error("retired index cleanup", "error", err)
		}
	}
	return &generationRouter{active: active, root: cfg.DataDir, loadModel: loadModel}, nil
}
