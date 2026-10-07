package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type generationTestModel struct {
	vector           []float32
	started, release chan struct{}
	once             sync.Once
	closed           atomic.Bool
}

func (e *generationTestModel) Embed(text string) ([]float32, error) {
	if e.closed.Load() {
		return nil, fmt.Errorf("model already retired")
	}
	if e.started != nil && strings.HasPrefix(text, "title: ") {
		e.once.Do(func() { close(e.started) })
		<-e.release
	}
	return append([]float32(nil), e.vector...), nil
}
func (e *generationTestModel) Close() { e.closed.Store(true) }

func TestEagerShadowRebuildServesOldModelThenSwitchesAndRecovers(t *testing.T) {
	for _, schema := range []string{"embeddinggemma-300m-v2-chunked", "embeddinggemma-2-v2-attachments"} {
		t.Run(schema, func(t *testing.T) { testEagerShadowRebuild(t, schema) })
	}
}

func testEagerShadowRebuild(t *testing.T, oldSchema string) {
	t.Helper()
	root := t.TempDir()
	storage, err := NewStorage(root)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := storage.EnsureEmbeddingSchema(oldSchema); err != nil {
		t.Fatal(err)
	}
	if err := storage.StoreEntityEmbedding(taskIdentity("active", 21, 0), StoredEmbedding{Vector: []float32{1, 0}, Preview: "source task", Payload: "old text", ContentHash: 123, Metadata: SearchMetadata{Task: &TaskMetadata{Status: 1}}}); err != nil {
		t.Fatal(err)
	}
	if err := storage.EnqueueAsset("queue-only", 8, QueueEntry{Preview: "obsolete queued snapshot"}); err != nil {
		t.Fatal(err)
	}
	if err := storage.SetRoomSync("sync-only", 0, RoomSyncState{LastFullSync: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err := storage.RegisterWorkspace("empty"); err != nil {
		t.Fatal(err)
	}
	storage.Close()

	var seenMu sync.Mutex
	seen := make(map[string]bool)
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		workspace := strings.TrimPrefix(r.URL.Path, "/")
		ready := bytes.NewBuffer(nil)
		writeTestString(ready, "test")
		binary.Write(ready, binary.BigEndian, uint32(1))
		wire, _ := protocolWireMessage(protocol.S_ServerReady, ready.Bytes())
		if conn.WriteMessage(websocket.BinaryMessage, wire) != nil {
			return
		}
		for {
			_, data, err := conn.ReadMessage()
			if err != nil {
				return
			}
			message, err := protocol.ReadMessage(data)
			if err != nil {
				return
			}
			if message.Opcode == protocol.C_ListTasksPaged {
				seenMu.Lock()
				seen[workspace] = true
				seenMu.Unlock()
				var tasks []*protocol.Task
				if workspace != "empty" {
					tasks = []*protocol.Task{{ID: 21, ConvID: 0, Title: "source task", Description: "fresh from canonical server", Status: 1}}
				}
				correlation := binary.BigEndian.Uint32(message.Data[len(message.Data)-4:])
				wire, _ := protocolWireMessage(protocol.S_TaskListPage, encodeTaskPage(0, tasks, false, protocol.TaskPageCursor{}, correlation))
				if conn.WriteMessage(websocket.BinaryMessage, wire) != nil {
					return
				}
			}
		}
	}))
	defer server.Close()
	legacy := strings.HasPrefix(oldSchema, "embeddinggemma-300m-")
	previousModel, previousTokenizer := "new-model", "new-tokenizer"
	t.Setenv("PREVIOUS_MODEL_PATH", "")
	t.Setenv("PREVIOUS_TOKENIZER_PATH", "")
	if legacy {
		previousModel, previousTokenizer = "old-model", "old-tokenizer"
		t.Setenv("PREVIOUS_MODEL_PATH", previousModel)
		t.Setenv("PREVIOUS_TOKENIZER_PATH", previousTokenizer)
	}
	oldModel := &generationTestModel{vector: []float32{1, 0}}
	newModel := &generationTestModel{vector: []float32{0, 1}, started: make(chan struct{}), release: make(chan struct{})}
	var releaseOnce sync.Once
	cfg := Config{DataDir: root, EmbeddingSchema: default_embedding_schema, ModelPath: "new-model", TokenizerPath: "new-tokenizer", EmbedTasks: true, ReconcileInterval: time.Hour, NRCServer: strings.Replace(server.URL, "http://", "ws://", 1)}
	factory := func(spec generationSpec) (Embedder, error) {
		if spec.Schema == oldSchema {
			if spec.ModelPath != previousModel || spec.TokenizerPath != previousTokenizer || spec.Legacy != legacy {
				t.Errorf("wrong old model: %+v", spec)
			}
			return oldModel, nil
		}
		return newModel, nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	router, err := startGenerationRouter(ctx, cfg, time.Now(), factory)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { defer close(done); router.rebuild(ctx, cfg, time.Now()) }()
	defer func() { cancel(); releaseOnce.Do(func() { close(newModel.release) }); <-done; router.active.Close() }()
	select {
	case <-newModel.started:
	case <-time.After(5 * time.Second):
		t.Fatal("rebuild did not start without a search request")
	}
	if schema, _ := router.active.storage.EmbeddingSchema(); schema != oldSchema {
		t.Fatal("serving index was reset")
	}
	if _, found, _ := readGenerationManifest(root); found {
		t.Fatal("activated partial rebuild")
	}
	response, _ := postTaskSearch(t, router, `{"workspace":"active","query":"source task","filters":{"entity_types":["task"]}}`)
	if len(response.Results) != 1 || response.Results[0].Similarity < 0.99 {
		t.Fatalf("old model/index pair not serving: %+v", response)
	}
	if oldModel.closed.Load() {
		t.Fatal("old model retired while replacement blocked")
	}
	// A workspace first observed during rebuild must also be included.
	if err := router.active.storage.RegisterWorkspace("late"); err != nil {
		t.Fatal(err)
	}
	releaseOnce.Do(func() { close(newModel.release) })
	select {
	case <-done:
	case <-time.After(15 * time.Second):
		t.Fatal("shadow index did not activate")
	}
	if !oldModel.closed.Load() || router.active.spec.ModelPath != "new-model" {
		t.Fatal("model/index did not switch together")
	}
	seenMu.Lock()
	for _, workspace := range []string{"active", "queue-only", "sync-only", "empty", "late"} {
		if !seen[workspace] {
			t.Errorf("workspace %s was not eagerly rebuilt", workspace)
		}
	}
	seenMu.Unlock()
	if router.active.manager.index.Count() != 4 {
		t.Fatalf("new index count=%d", router.active.manager.index.Count())
	}
	for _, workspace := range []string{"active", "queue-only", "sync-only", "late"} {
		entry, ok := router.active.manager.index.GetEntity(taskIdentity(workspace, 21, 0))
		if !ok || !strings.Contains(entry.Payload, "fresh from canonical server") || entry.Vector[1] < 0.99 {
			t.Fatalf("wrong rebuilt record for %s: %+v", workspace, entry)
		}
	}
	if _, err := os.Stat(filepath.Join(root, "search.db")); !os.IsNotExist(err) {
		t.Fatal("retired database not deleted")
	}
	router.active.Close()
	// Simulate a crash after pointer activation but before cleanup completed.
	manifest, _, err := readGenerationManifest(root)
	if err != nil {
		t.Fatal(err)
	}
	manifest.Retired = []string{"."}
	if err := os.WriteFile(filepath.Join(root, "search.db"), []byte("retired"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := writeGenerationManifest(root, manifest); err != nil {
		t.Fatal(err)
	}
	router, err = startGenerationRouter(ctx, cfg, time.Now(), func(spec generationSpec) (Embedder, error) { return &generationTestModel{vector: []float32{0, 1}}, nil })
	if err != nil {
		t.Fatal(err)
	}
	if router.active.spec.Schema != default_embedding_schema || router.active.manager.index.Count() != 4 {
		t.Fatal("restart lost activated generation")
	}
	if _, err := os.Stat(filepath.Join(root, "search.db")); !os.IsNotExist(err) {
		t.Fatal("restart did not finish retirement")
	}
	response, _ = postTaskSearch(t, router, `{"workspace":"queue-only","query":"source task","filters":{"entity_types":["task"]}}`)
	if len(response.Results) != 1 || response.Results[0].Similarity < 0.99 {
		t.Fatalf("new model/index pair not serving after restart: %+v", response)
	}
}

func TestShadowReadinessRejectsDroppedJobsAndFailedAttachments(t *testing.T) {
	c, err := NewNRCClient(Config{EmbedAssetTypes: []uint16{3}}, "ws", newTestStorage(t), &flakyEmbedder{failures: 3}, NewIndex())
	if err != nil {
		t.Fatal(err)
	}
	c.subscribedRooms[0] = true
	c.inventoryEpochs[0] = c.ReadyGeneration()
	asset := protocol.Asset{AssetID: 9, AssetType: 3, Preview: "required source", Payload: "{}"}
	c.ingestAsset(asset, true, 0)
	id, entry, ok, err := c.storage.PeekQueueEntry("ws")
	if err != nil || !ok {
		t.Fatal("missing job")
	}
	for i := 0; i < 3; i++ {
		c.processEmbedJob(EmbedJob{Workspace: "ws", AssetID: id, Entry: entry})
	}
	if empty, _ := c.storage.QueuesEmpty("ws"); !empty {
		t.Fatal("fixture job was not dropped")
	}
	if ready, err := c.indexComplete(); err != nil || ready {
		t.Fatal("empty queue incorrectly marked dropped job complete")
	}
	c.ingestAsset(asset, true, 0)
	c.drainPersistentQueue()
	if ready, err := c.indexComplete(); err != nil || !ready {
		t.Fatalf("recovered job not complete: %v", err)
	}
	indexed, _ := c.index.Get("ws", 9)
	copy := *indexed
	copy.Metadata.Attachments = []AttachmentSearch{{Status: "failed"}}
	c.index.Add("ws", 9, &copy)
	if ready, _ := c.indexComplete(); ready {
		t.Fatal("failed media falsely marked complete")
	}
}

func TestGenerationManifestRejectsUnsafeCleanupAndLeavesPartialBuildInactive(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "search.db"), []byte("old"), 0600); err != nil {
		t.Fatal(err)
	}
	manifest := generationManifest{Active: generationSpec{Directory: "."}, Retired: []string{"."}}
	if err := cleanupRetiredGenerations(root, manifest); err == nil {
		t.Fatal("deleted active index")
	}
	manifest.Retired = []string{"../outside"}
	if err := writeGenerationManifest(root, manifest); err != nil {
		t.Fatal(err)
	}
	if _, _, err := readGenerationManifest(root); err == nil {
		t.Fatal("unsafe manifest accepted")
	}
	data, _ := os.ReadFile(filepath.Join(root, "search.db"))
	if string(data) != "old" {
		t.Fatal("old index altered")
	}
	manifest.Retired = nil
	if err := writeGenerationManifest(root, manifest); err != nil {
		t.Fatal(err)
	}
	partial := filepath.Join(root, "index-"+strings.Repeat("a", 64))
	if err := os.Mkdir(partial, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(partial, "search.db"), []byte("partial"), 0600); err != nil {
		t.Fatal(err)
	}
	reloaded, found, err := readGenerationManifest(root)
	if err != nil || !found || reloaded.Active.Directory != "." {
		t.Fatal("partial generation became active")
	}
	encoded, _ := json.Marshal(reloaded)
	if strings.Contains(string(encoded), partial) {
		t.Fatal("partial build published")
	}
}

func TestShadowReadinessWaitsForMovedTaskRefreshAndFailureRecovery(t *testing.T) {
	for _, queued := range []bool{false, true} {
		t.Run(fmt.Sprintf("queued=%v", queued), func(t *testing.T) {
			c, err := NewNRCClient(Config{EmbedTasks: true}, "ws", newTestStorage(t), &recordingEmbedder{}, NewIndex())
			if err != nil {
				t.Fatal(err)
			}
			if queued {
				c.ingestTask(&protocol.Task{ID: 55, Title: "task", Status: protocol.TaskStatusTodo}, true, 0, false)
			}
			started, release := make(chan struct{}), make(chan struct{})
			var releaseOnce sync.Once
			defer func() { releaseOnce.Do(func() { close(release) }); c.refreshWorkers.Wait() }()
			var inventoryRequests atomic.Int32
			canonical := &protocol.Task{ID: 55, Title: "task", Status: protocol.TaskStatusDone}
			c.sendMessage = func(opcode uint16, payload []byte) error {
				if opcode == protocol.C_GetTask {
					close(started)
					<-release
					return fmt.Errorf("temporary canonical refresh failure")
				}
				if opcode == protocol.C_ListTasksPaged {
					if inventoryRequests.Add(1) == 1 {
						move := bytes.NewBuffer(nil)
						binary.Write(move, binary.BigEndian, uint64(55))
						binary.Write(move, binary.BigEndian, uint64(0))
						move.WriteByte(protocol.TaskStatusDone)
						binary.Write(move, binary.BigEndian, uint16(0))
						binary.Write(move, binary.BigEndian, int64(100))
						writeTestString(move, "alice")
						binary.Write(move, binary.BigEndian, uint32(0))
						c.handleTaskMoved(context.Background(), move.Bytes())
					}
					correlation := binary.BigEndian.Uint32(payload[len(payload)-4:])
					c.handleTaskListPage(encodeTaskPage(0, []*protocol.Task{canonical}, false, protocol.TaskPageCursor{}, correlation))
				}
				return nil
			}
			if err := c.SubscribeAndReconcile(context.Background(), 0); err != nil {
				t.Fatal(err)
			}
			select {
			case <-started:
			case <-time.After(time.Second):
				t.Fatal("refresh never started")
			}
			c.drainPersistentQueue()
			if ready, err := c.indexComplete(); err != nil || ready {
				t.Fatal("pending refresh allowed activation with empty queues")
			}
			releaseOnce.Do(func() { close(release) })
			c.refreshWorkers.Wait()
			if ready, err := c.indexComplete(); err != nil || ready {
				t.Fatal("failed refresh allowed activation")
			}
			if err := c.SubscribeAndReconcile(context.Background(), 0); err != nil {
				t.Fatal(err)
			}
			if ready, err := c.indexComplete(); err != nil || !ready {
				t.Fatalf("canonical recovery did not resolve readiness: %v", err)
			}
			entry, ok := c.index.GetEntity(taskIdentity("ws", 55, 0))
			if !ok || entry.Metadata.Task.Status != protocol.TaskStatusDone {
				t.Fatal("activation readiness did not preserve canonical status")
			}
		})
	}
}

func TestReconcileDeletesRecoveredJobsCommittedDuringInventoryAndDroppedExpectations(t *testing.T) {
	for _, entityType := range []EntityType{EntityTypeAsset, EntityTypeTask} {
		t.Run(string(entityType), func(t *testing.T) {
			storage := newTestStorage(t)
			id := EntityIdentity{Workspace: "ws", EntityType: entityType, EntityID: 90}
			entry := QueueEntry{Preview: "offline deleted", AssetType: 3}
			if entityType == EntityTypeAsset {
				storage.EnqueueAsset("ws", 90, entry)
			} else {
				storage.EnqueueEntity(id, entry)
			}
			e := &blockingEmbedder{started: make(chan struct{}), release: make(chan struct{})}
			c, err := NewNRCClient(Config{EmbedAssetTypes: []uint16{3}, EmbedTasks: true}, "ws", storage, e, NewIndex())
			if err != nil {
				t.Fatal(err)
			}
			// The expectation survived in memory after a dropped job, but its
			// source disappeared before reconnect. It must not block forever.
			dropped := EntityIdentity{Workspace: "ws", EntityType: entityType, EntityID: 91}
			c.expectedHashes[dropped.key()] = 123
			done := make(chan struct{})
			go func() { defer close(done); c.processEmbedJob(EmbedJob{Workspace: "ws", Identity: id, Entry: entry}) }()
			<-e.started
			var releaseOnce sync.Once
			defer func() { releaseOnce.Do(func() { close(e.release) }); <-done }()
			c.sendMessage = func(opcode uint16, payload []byte) error {
				// Finish a recovered job after the inventory cutoff but before its
				// empty response. Completion time is not a newer live mutation.
				releaseOnce.Do(func() { close(e.release) })
				<-done
				if opcode == protocol.C_ListAssetsPaged {
					c.pendingReconcilePageMu.Lock()
					ch := c.pendingReconcilePage[0]
					delete(c.pendingReconcilePage, 0)
					c.pendingReconcilePageMu.Unlock()
					ch <- &protocol.AssetListPageResponse{}
				} else if opcode == protocol.C_ListTasksPaged {
					correlation := binary.BigEndian.Uint32(payload[len(payload)-4:])
					c.handleTaskListPage(encodeTaskPage(0, nil, false, protocol.TaskPageCursor{}, correlation))
				}
				return nil
			}
			c.subscribedRooms[0] = true
			if err := c.Reconcile(context.Background(), 0); err != nil {
				t.Fatal(err)
			}
			if c.index.Count() != 0 || len(c.expectedHashes) != 0 {
				t.Fatal("offline-deleted record/expectation survived canonical cleanup")
			}
			if ready, err := c.indexComplete(); err != nil || !ready {
				t.Fatalf("empty canonical workspace cannot activate: %v", err)
			}
			stored, err := storage.LoadAllEntityEmbeddings()
			if err != nil || len(stored) != 0 {
				t.Fatalf("stale record survived on disk: %+v %v", stored, err)
			}
		})
	}
}

func TestShadowInitializationFailureAndInterruptionPreserveServingIndex(t *testing.T) {
	root := t.TempDir()
	storage, err := NewStorage(root)
	if err != nil {
		t.Fatal(err)
	}
	oldSchema := "embeddinggemma-300m-v2-chunked"
	storage.EnsureEmbeddingSchema(oldSchema)
	storage.StoreEntityEmbedding(taskIdentity("ws", 9, 0), StoredEmbedding{Vector: []float32{1, 0}, Preview: "keep me"})
	storage.Close()
	cfg := Config{DataDir: root, EmbeddingSchema: default_embedding_schema}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	oldModel := &generationTestModel{vector: []float32{1, 0}}
	router, err := startGenerationRouter(ctx, cfg, time.Now(), func(spec generationSpec) (Embedder, error) {
		if spec.Legacy {
			return oldModel, nil
		}
		cancel()
		return nil, fmt.Errorf("candidate model unavailable")
	})
	if err != nil {
		t.Fatal(err)
	}
	router.rebuild(ctx, cfg, time.Now())
	if oldModel.closed.Load() || router.active.spec.Schema != oldSchema || router.active.manager.index.Count() != 1 {
		t.Fatal("failed/interrupted rebuild altered serving generation")
	}
	router.active.Close()
	restarted, err := startGenerationRouter(context.Background(), cfg, time.Now(), func(spec generationSpec) (Embedder, error) {
		if !spec.Legacy {
			t.Fatal("restart selected unpublished shadow")
		}
		return &generationTestModel{vector: []float32{1, 0}}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.active.Close()
	if restarted.active.manager.index.Count() != 1 {
		t.Fatal("restart lost old records")
	}
}

func TestAllReconciledAssetTypesUseFullPagination(t *testing.T) {
	c, err := NewNRCClient(Config{EmbedAssetTypes: []uint16{1, 2, 3, 4, 5}}, "ws", newTestStorage(t), &recordingEmbedder{}, NewIndex())
	if err != nil {
		t.Fatal(err)
	}
	pages := make(map[uint16]int)
	c.sendMessage = func(opcode uint16, payload []byte) error {
		if opcode != protocol.C_ListAssetsPaged {
			t.Fatalf("unpaged inventory opcode %d", opcode)
		}
		assetType := binary.BigEndian.Uint16(payload[8:10])
		if payload[10] != 1 || binary.BigEndian.Uint16(payload[11:13]) != 1 {
			t.Fatal("inventory must fetch bounded full-content pages")
		}
		page := pages[assetType]
		if page == 1 && (payload[13] != 1 || binary.BigEndian.Uint64(payload[14:22]) != 17 || binary.BigEndian.Uint64(payload[22:30]) != uint64(assetType)*10) {
			t.Fatal("pagination cursor was lost")
		}
		pages[assetType]++
		c.pendingReconcilePageMu.Lock()
		ch := c.pendingReconcilePage[0]
		delete(c.pendingReconcilePage, 0)
		c.pendingReconcilePageMu.Unlock()
		ch <- &protocol.AssetListPageResponse{HasMore: page == 0, NextCursorUpdatedAt: 17, NextCursorAssetID: uint64(assetType) * 10,
			Assets: []protocol.Asset{{AssetID: uint64(assetType)*10 + uint64(page), AssetType: assetType}}}
		return nil
	}
	assets, err := c.fetchReconcileAssets(context.Background(), 0)
	if err != nil || len(assets) != 10 {
		t.Fatalf("incomplete inventory: %d records, %v", len(assets), err)
	}
	for assetType := uint16(1); assetType <= 5; assetType++ {
		if pages[assetType] != 2 {
			t.Fatalf("type %d was not paginated", assetType)
		}
	}
}

func TestCanonicalInventoryInvalidatesDelayedSuccessfulRefresh(t *testing.T) {
	for _, present := range []bool{false, true} {
		t.Run(fmt.Sprintf("present=%v", present), func(t *testing.T) {
			c, err := NewNRCClient(Config{EmbedTasks: true}, "ws", newTestStorage(t), &recordingEmbedder{}, NewIndex())
			if err != nil {
				t.Fatal(err)
			}
			identity := taskIdentity("ws", 88, 0)
			version := c.nextVersion.Add(1)
			c.taskMutations[identity.key()] = version
			c.unresolvedTasks[identity.key()] = version
			started, release, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
			var releaseOnce sync.Once
			defer func() { releaseOnce.Do(func() { close(release) }); <-done }()
			c.sendMessage = func(opcode uint16, payload []byte) error {
				if opcode == protocol.C_GetTask {
					close(started)
					<-release
					c.handleTaskFull(encodeTaskFull(&protocol.Task{ID: 88, Title: "obsolete refresh"}, binary.BigEndian.Uint32(payload[16:20])))
				} else if opcode == protocol.C_ListTasksPaged {
					var tasks []*protocol.Task
					if present {
						tasks = []*protocol.Task{{ID: 88, Title: "current canonical task", Status: protocol.TaskStatusDone}}
					}
					c.handleTaskListPage(encodeTaskPage(0, tasks, false, protocol.TaskPageCursor{}, binary.BigEndian.Uint32(payload[len(payload)-4:])))
				}
				return nil
			}
			go func() { defer close(done); c.refreshTask(context.Background(), identity, version) }()
			<-started
			if err := c.SubscribeAndReconcile(context.Background(), 0); err != nil {
				t.Fatal(err)
			}
			releaseOnce.Do(func() { close(release) })
			<-done
			if empty, _ := c.storage.QueuesEmpty("ws"); !empty {
				t.Fatal("obsolete refresh recreated queue")
			}
			entry, found := c.index.GetEntity(identity)
			if found != present || (found && entry.Preview != "current canonical task") {
				t.Fatal("obsolete refresh overwrote canonical inventory")
			}
		})
	}
}

func TestDisconnectBlocksPromotionUntilCurrentConnectionInventory(t *testing.T) {
	root := t.TempDir()
	cfg := Config{DataDir: root, EmbeddingSchema: default_embedding_schema}
	oldStorage, err := NewStorage(root)
	if err != nil {
		t.Fatal(err)
	}
	oldStorage.RegisterWorkspace("ws")
	old, err := openSearchGeneration(context.Background(), cfg, time.Now(), generationSpec{Directory: ".", Schema: "old"}, oldStorage, &generationTestModel{})
	if err != nil {
		t.Fatal(err)
	}
	defer old.Close()
	nextSpec := generationSpec{Directory: "index-" + strings.Repeat("a", 64), Schema: cfg.EmbeddingSchema}
	nextStorage, err := NewStorage(filepath.Join(root, nextSpec.Directory))
	if err != nil {
		t.Fatal(err)
	}
	next, err := openSearchGeneration(context.Background(), cfg, time.Now(), nextSpec, nextStorage, &generationTestModel{})
	if err != nil {
		t.Fatal(err)
	}
	defer next.Close()
	c, _ := NewNRCClient(cfg, "ws", nextStorage, next.manager.embedder, next.manager.index)
	next.manager.clients["ws"] = c
	c.sendMessage = func(uint16, []byte) error { return nil }
	if err := c.SubscribeAndReconcile(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	c.invalidateConnection()
	router := &generationRouter{active: old, root: root}
	if promoted, err := router.promote(next, map[string]bool{"ws": true}); err != nil || promoted {
		t.Fatal("disconnected shadow activated")
	}
	if _, found, _ := readGenerationManifest(root); found {
		t.Fatal("disconnected shadow published durable pointer")
	}
	// A reconciliation spanning a second disconnect must not certify either
	// connection, even if every returned inventory page was successful.
	c.embedTasks = true
	c.sendMessage = func(opcode uint16, payload []byte) error {
		if opcode == protocol.C_ListTasksPaged {
			c.invalidateConnection()
			c.handleTaskListPage(encodeTaskPage(0, nil, false, protocol.TaskPageCursor{}, binary.BigEndian.Uint32(payload[len(payload)-4:])))
		}
		return nil
	}
	if err := c.SubscribeAndReconcile(context.Background(), 0); err == nil {
		t.Fatal("cross-connection inventory certified")
	}
	c.embedTasks = false
	c.sendMessage = func(uint16, []byte) error { return nil }
	if err := c.SubscribeAndReconcile(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	if promoted, err := router.promote(next, map[string]bool{"ws": true}); err != nil || !promoted {
		t.Fatalf("fresh inventory did not permit activation: %v", err)
	}
}
