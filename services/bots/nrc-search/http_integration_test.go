package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func taskSearchTestHandler(t *testing.T, cfg Config, storage *Storage, embedder Embedder, index *Index, clients ...*NRCClient) http.Handler {
	t.Helper()
	wm := NewWorkspaceManager(context.Background(), cfg, storage, embedder, index)
	for _, client := range clients {
		client.mu.Lock()
		client.subscribedRooms[0] = true
		client.roomSyncTimes[0] = time.Now()
		client.mu.Unlock()
		client.closeReady()
		wm.clients[client.workspace] = client
	}
	return newHTTPHandler(cfg, time.Now(), wm, index, embedder)
}

func postTaskSearch(t *testing.T, handler http.Handler, body string) (searchResponse, http.Header) {
	t.Helper()
	var contract searchRequest
	if err := json.Unmarshal([]byte(body), &contract); err != nil {
		t.Fatalf("invalid test search request: %v\n%s", err, body)
	}
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/search", bytes.NewBufferString(body))
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("POST /search returned %d: %s", recorder.Code, recorder.Body.String())
	}
	var response searchResponse
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatalf("decode search response: %v", err)
	}
	return response, recorder.Header()
}

func TestTaskSearchHTTPTaskLifecycleReconciliationAndReload(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "search")
	storage, err := NewStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	embedder := &recordingEmbedder{}
	index := NewIndex()
	cfg := Config{EmbedTasks: true, ReconcileInterval: time.Hour}
	client, err := NewNRCClient(cfg, "lifecycle-ws", storage, embedder, index)
	if err != nil {
		t.Fatal(err)
	}
	handler := taskSearchTestHandler(t, cfg, storage, embedder, index, client)
	task := &protocol.Task{
		ID: 28, ConvID: 0, Title: "Mixed-Case Search Title", Description: "initial lifecycle body",
		Status: protocol.TaskStatusTodo, Assignee: "Alice", Priority: 3, Color: 4,
		Project: "NRC", ExternalRef: "NRC-28", DueAt: 80, BlockedBy: 99, UpdatedAt: 50,
	}

	client.handleTaskCreated(encodeTaskEvent(task))
	drainOneTask(t, client)
	response, headers := postTaskSearch(t, handler, `{
		"workspace":"lifecycle-ws","query":"mixed-case search","conv_id":"0","top_n":1,
		"filters":{"entity_types":["task"],"task":{"statuses":[1],"assignees":["alice"],"projects":["nrc"],"priorities":[3],"colors":[4],"task_ids":["28"],"external_refs":["nrc-28"],"blocked":true,"blocked_by":["99"],"overdue_before":100}}}
	`)
	if headers.Get(protocol.SearchAPIVersionHeader) != protocol.SearchAPIVersion {
		t.Fatalf("typed capability header = %q", headers.Get(protocol.SearchAPIVersionHeader))
	}
	if len(response.Results) != 1 || response.Results[0].Entity.EntityType != EntityTypeTask || response.Results[0].Preview != task.Title {
		t.Fatalf("created task search = %#v", response.Results)
	}

	task.Title = "Persisted MiXeD Display Title"
	task.Description = "updated searchable content"
	task.Status = protocol.TaskStatusDone
	task.CompletedAt = 90
	task.CompletedBy = "Alice"
	task.UpdatedAt = 90
	client.handleTaskUpdated(encodeTaskEvent(task))
	drainOneTask(t, client)
	response, _ = postTaskSearch(t, handler, `{"workspace":"lifecycle-ws","query":"UPDATED SEARCHABLE","conv_id":"0","filters":{"entity_types":["task"]}}`)
	if len(response.Results) != 1 || response.Results[0].Preview != task.Title || response.Results[0].Metadata.Task.Status != protocol.TaskStatusDone {
		t.Fatalf("updated Done task search = %#v", response.Results)
	}

	if err := storage.Close(); err != nil {
		t.Fatal(err)
	}
	storage, err = NewStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	reloadedIndex := NewIndex()
	stored, err := storage.LoadAllEntityEmbeddings()
	if err != nil {
		t.Fatal(err)
	}
	for identity, embedding := range stored {
		if err := reloadedIndex.AddEntity(identity, indexEntryFromStoredEmbedding(embedding)); err != nil {
			t.Fatal(err)
		}
	}
	reloadedClient, err := NewNRCClient(cfg, "lifecycle-ws", storage, embedder, reloadedIndex)
	if err != nil {
		t.Fatal(err)
	}
	handler = taskSearchTestHandler(t, cfg, storage, embedder, reloadedIndex, reloadedClient)
	response, _ = postTaskSearch(t, handler, `{"workspace":"lifecycle-ws","query":"persisted mixed display","conv_id":"0","filters":{"entity_types":["task"]}}`)
	if len(response.Results) != 1 || response.Results[0].Preview != "Persisted MiXeD Display Title" {
		t.Fatalf("reloaded mixed-case result = %#v", response.Results)
	}

	stale := taskIdentity("lifecycle-ws", 90, 0)
	staleEntry := &IndexEntry{ConvID: 0, Vector: []float32{1, 0}, Preview: "stale task", ContentHash: 1, Metadata: SearchMetadata{Task: &TaskMetadata{Status: protocol.TaskStatusTodo}}}
	if err := reloadedIndex.AddEntity(stale, staleEntry); err != nil {
		t.Fatal(err)
	}
	if err := storage.StoreEntityEmbedding(stale, storedEmbeddingFromEntry(staleEntry)); err != nil {
		t.Fatal(err)
	}
	discovered := &protocol.Task{ID: 29, ConvID: 0, Title: "Unloaded Done History", Description: "found by full reconciliation", Status: protocol.TaskStatusDone, CompletedAt: 100, UpdatedAt: 100}
	reloadedClient.sendMessage = func(opcode uint16, payload []byte) error {
		if opcode != protocol.C_ListTasksPaged {
			t.Fatalf("reconcile opcode = %d", opcode)
		}
		correlationID := binary.BigEndian.Uint32(payload[len(payload)-4:])
		reloadedClient.handleTaskListPage(encodeTaskPage(0, []*protocol.Task{task, discovered}, false, protocol.TaskPageCursor{}, correlationID))
		return nil
	}
	reloadedClient.mu.Lock()
	reloadedClient.roomSyncTimes[0] = time.Time{}
	reloadedClient.mu.Unlock()
	response, _ = postTaskSearch(t, handler, `{"workspace":"lifecycle-ws","query":"unloaded done history","conv_id":"0","filters":{"entity_types":["task"],"task":{"task_ids":["29"]}}}`)
	if len(response.Results) != 1 || response.Results[0].Entity.EntityID != 29 || response.Results[0].Metadata.Task.Status != protocol.TaskStatusDone {
		t.Fatalf("reconciled Done history = %#v", response.Results)
	}
	if response.Stale {
		t.Fatal("successfully committed reconciliation was marked stale")
	}
	if _, ok := reloadedIndex.GetEntity(stale); ok {
		t.Fatal("stale task survived protocol reconciliation")
	}

	deleted := make([]byte, 20)
	binary.BigEndian.PutUint64(deleted[0:8], 29)
	binary.BigEndian.PutUint64(deleted[8:16], 0)
	reloadedClient.handleTaskDeleted(deleted)
	response, _ = postTaskSearch(t, handler, `{"workspace":"lifecycle-ws","query":"unloaded done history","conv_id":"0","filters":{"entity_types":["task"],"task":{"task_ids":["29"]}}}`)
	if len(response.Results) != 0 {
		t.Fatalf("deleted task remained searchable: %#v", response.Results)
	}
}

func TestTaskSearchHTTPTypedIdentityAndPreRankingIsolation(t *testing.T) {
	storage := newTestStorage(t)
	embedder := &mockEmbedderForTest{vec: []float32{1, 0}}
	index := NewIndex()
	cfg := Config{EmbedTasks: true, ReconcileInterval: time.Hour}
	clients := make([]*NRCClient, 0, 2)
	for _, workspace := range []string{"ws-a", "ws-b"} {
		client, err := NewNRCClient(cfg, workspace, storage, embedder, index)
		if err != nil {
			t.Fatal(err)
		}
		clients = append(clients, client)
	}
	handler := taskSearchTestHandler(t, cfg, storage, embedder, index, clients...)

	for id := uint64(1); id <= 12; id++ {
		identity := taskIdentity("ws-a", id, 0)
		if err := index.AddEntity(identity, &IndexEntry{ConvID: 0, Vector: []float32{1, 0}, Preview: "strong match", Metadata: SearchMetadata{Task: &TaskMetadata{Status: protocol.TaskStatusTodo, Project: "other"}}}); err != nil {
			t.Fatal(err)
		}
	}
	matching := &IndexEntry{ConvID: 0, Vector: []float32{0, 1}, Preview: "weak match", Metadata: SearchMetadata{Task: &TaskMetadata{
		Status: protocol.TaskStatusDone, Assignee: "Alice", Project: "NRC", Color: 4, BlockedBy: 99, DueAt: 80, ExternalRef: "NRC-42",
	}}}
	for _, identity := range []EntityIdentity{
		taskIdentity("ws-a", 42, 0), taskIdentity("ws-a", 42, 8), taskIdentity("ws-a", 42, 1<<63|9), taskIdentity("ws-b", 42, 0),
	} {
		copy := *matching
		copy.ConvID = identity.ConvID
		if err := index.AddEntity(identity, &copy); err != nil {
			t.Fatal(err)
		}
	}
	if err := index.AddEntity(assetIdentity("ws-a", 42, 0), &IndexEntry{ConvID: 0, Vector: []float32{1, 0}, AssetType: protocol.AssetTypeNote, Preview: "legacy asset"}); err != nil {
		t.Fatal(err)
	}

	response, _ := postTaskSearch(t, handler, `{
		"workspace":"ws-a","query":"match","conv_id":"0","top_n":1,
		"filters":{"entity_types":["task"],"task":{"statuses":[3],"assignees":["alice"],"projects":["nrc"],"colors":[4],"task_ids":["42"],"external_refs":["nrc-42"],"blocked":true,"blocked_by":["99"]}}}
	`)
	if len(response.Results) != 1 || response.Results[0].Entity != taskIdentity("ws-a", 42, 0) {
		t.Fatalf("pre-ranked isolated result = %#v", response.Results)
	}

	legacy, _ := postTaskSearch(t, handler, `{"workspace":"ws-a","query":"legacy asset","conv_id":"0"}`)
	if len(legacy.Results) != 1 || legacy.Results[0].Entity.EntityType != EntityTypeAsset || legacy.Results[0].AssetID != 42 {
		t.Fatalf("legacy asset search = %#v", legacy.Results)
	}
	unified, _ := postTaskSearch(t, handler, `{"workspace":"ws-a","query":"match","conv_id":"0","filters":{"entity_types":["asset","task"]}}`)
	for _, result := range unified.Results {
		if result.Entity.Workspace != "ws-a" || result.Entity.ConvID != 0 {
			t.Fatalf("unified search leaked identity: %#v", unified.Results)
		}
	}
}

func TestTaskSearchHTTPMarksUncommittedReconciliationStale(t *testing.T) {
	storage := newTestStorage(t)
	embedder := &flakyEmbedder{failures: 1}
	index := NewIndex()
	cfg := Config{EmbedTasks: true, ReconcileInterval: time.Hour}
	client, err := NewNRCClient(cfg, "stale-ws", storage, embedder, index)
	if err != nil {
		t.Fatal(err)
	}
	handler := taskSearchTestHandler(t, cfg, storage, embedder, index, client)
	client.sendMessage = func(opcode uint16, payload []byte) error {
		if opcode != protocol.C_ListTasksPaged {
			t.Fatalf("reconcile opcode = %d", opcode)
		}
		correlationID := binary.BigEndian.Uint32(payload[len(payload)-4:])
		client.handleTaskListPage(encodeTaskPage(0, []*protocol.Task{{
			ID: 30, ConvID: 0, Title: "Not Committed Yet", Status: protocol.TaskStatusDone,
		}}, false, protocol.TaskPageCursor{}, correlationID))
		return nil
	}
	client.mu.Lock()
	client.roomSyncTimes[0] = time.Time{}
	client.mu.Unlock()

	response, _ := postTaskSearch(t, handler, `{"workspace":"stale-ws","query":"not committed","conv_id":"0","filters":{"entity_types":["task"]}}`)
	if !response.Stale || len(response.Results) != 0 {
		t.Fatalf("failed reconciliation response = %#v", response)
	}
	if _, queued, err := storage.GetEntityQueueEntry(taskIdentity("stale-ws", 30, 0)); err != nil || !queued {
		t.Fatalf("failed reconciled task was not retained for retry: queued=%v err=%v", queued, err)
	}
}

func TestTaskSearchHTTPConcurrentReconciliationSharesFailure(t *testing.T) {
	storage := newTestStorage(t)
	embedder := &recordingEmbedder{}
	index := NewIndex()
	cfg := Config{EmbedTasks: true, ReconcileInterval: time.Hour}
	client, err := NewNRCClient(cfg, "shared-ws", storage, embedder, index)
	if err != nil {
		t.Fatal(err)
	}
	handler := taskSearchTestHandler(t, cfg, storage, embedder, index, client)
	client.mu.Lock()
	client.roomSyncTimes[0] = time.Time{}
	client.mu.Unlock()

	started := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	var taskPageRequests atomic.Int32
	client.sendMessage = func(opcode uint16, _ []byte) error {
		if opcode != protocol.C_ListTasksPaged {
			return errors.New("unexpected reconciliation opcode")
		}
		taskPageRequests.Add(1)
		once.Do(func() { close(started) })
		<-release
		return errors.New("shared task-page failure")
	}

	type result struct {
		response searchResponse
		status   int
		err      error
	}
	request := func(results chan<- result) {
		recorder := httptest.NewRecorder()
		httpRequest := httptest.NewRequest(http.MethodPost, "/search", bytes.NewBufferString(`{"workspace":"shared-ws","query":"task","conv_id":"0","filters":{"entity_types":["task"]}}`))
		handler.ServeHTTP(recorder, httpRequest)
		var response searchResponse
		err := json.NewDecoder(recorder.Body).Decode(&response)
		results <- result{response: response, status: recorder.Code, err: err}
	}
	results := make(chan result, 2)
	go request(results)
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("leader reconciliation did not start")
	}
	go request(results)
	time.Sleep(20 * time.Millisecond)
	close(release)
	for i := 0; i < 2; i++ {
		got := <-results
		if got.err != nil || got.status != http.StatusOK || !got.response.Stale {
			t.Fatalf("shared reconciliation response = %+v", got)
		}
	}
	if got := taskPageRequests.Load(); got != 1 {
		t.Fatalf("task page requests = %d, want one coalesced reconciliation", got)
	}
}
