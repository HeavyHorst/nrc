package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/heavyhorst/nrc/protocol-go"
)

type recordingEmbedder struct {
	mu    sync.Mutex
	calls []string
}

type blockingEmbedder struct {
	started chan struct{}
	release chan struct{}
	once    sync.Once
}

func (e *blockingEmbedder) Embed(string) ([]float32, error) {
	e.once.Do(func() { close(e.started) })
	<-e.release
	return []float32{1, 0}, nil
}
func (e *blockingEmbedder) Close() {}

type flakyEmbedder struct {
	mu       sync.Mutex
	failures int
	attempts int
}

func (e *flakyEmbedder) Embed(string) ([]float32, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.attempts++
	if e.attempts <= e.failures {
		return nil, fmt.Errorf("transient embedding failure")
	}
	return []float32{1, 0}, nil
}
func (e *flakyEmbedder) Close() {}

func (e *recordingEmbedder) Embed(text string) ([]float32, error) {
	e.mu.Lock()
	e.calls = append(e.calls, text)
	e.mu.Unlock()
	return []float32{1, 0}, nil
}
func (e *recordingEmbedder) Close() {}
func (e *recordingEmbedder) count() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return len(e.calls)
}

func newTaskClient(t *testing.T, storage *Storage, embedder Embedder) *NRCClient {
	t.Helper()
	client, err := NewNRCClient(Config{EmbedTasks: true}, "ws", storage, embedder, NewIndex())
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func writeTestString(buf *bytes.Buffer, value string) {
	binary.Write(buf, binary.BigEndian, uint16(len(value)))
	buf.WriteString(value)
}

func encodeTestTask(task *protocol.Task) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, task.ID)
	binary.Write(buf, binary.BigEndian, task.ConvID)
	writeTestString(buf, task.Title)
	writeTestString(buf, task.Description)
	buf.WriteByte(task.Status)
	binary.Write(buf, binary.BigEndian, task.OrderIndex)
	writeTestString(buf, task.Assignee)
	buf.WriteByte(task.Priority)
	buf.WriteByte(task.Color)
	writeTestString(buf, task.CreatedBy)
	binary.Write(buf, binary.BigEndian, task.CreatedAt)
	binary.Write(buf, binary.BigEndian, task.UpdatedAt)
	writeTestString(buf, task.ExternalRef)
	binary.Write(buf, binary.BigEndian, task.DueAt)
	binary.Write(buf, binary.BigEndian, task.BlockedBy)
	binary.Write(buf, binary.BigEndian, task.CompletedAt)
	writeTestString(buf, task.CompletedBy)
	writeTestString(buf, task.Project)
	buf.Write(protocol.EncodeAttachments(task.Attachments))
	return buf.Bytes()
}

func encodeTaskEvent(task *protocol.Task) []byte {
	payload := encodeTestTask(task)
	return binary.BigEndian.AppendUint32(payload, 0)
}

func encodeTaskPage(convID uint64, tasks []*protocol.Task, hasMore bool, cursor protocol.TaskPageCursor, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	buf.WriteByte(1)
	binary.Write(buf, binary.BigEndian, uint16(len(tasks)))
	for _, task := range tasks {
		buf.Write(encodeTestTask(task))
	}
	if hasMore {
		buf.WriteByte(1)
	} else {
		buf.WriteByte(0)
	}
	binary.Write(buf, binary.BigEndian, cursor.SortAt)
	binary.Write(buf, binary.BigEndian, cursor.TaskID)
	binary.Write(buf, binary.BigEndian, uint32(len(tasks)))
	writeTestString(buf, "")
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

func encodeTaskFull(task *protocol.Task, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint64(task.ConvID))
	buf.WriteByte(1)
	buf.WriteByte(1)
	buf.Write(encodeTestTask(task))
	writeTestString(buf, "")
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

func drainOneTask(t *testing.T, client *NRCClient) {
	t.Helper()
	identity, entry, ok, err := client.storage.PeekEntityQueueEntry(client.workspace)
	if err != nil || !ok {
		t.Fatalf("peek task queue: ok=%v err=%v", ok, err)
	}
	if !client.processEmbedJob(EmbedJob{Workspace: client.workspace, Identity: identity, Entry: entry}) {
		t.Fatal("task embedding was not consumed")
	}
}

func TestTaskEventContentHashAndMetadataOnlyUpdate(t *testing.T) {
	storage := newTestStorage(t)
	embedder := &recordingEmbedder{}
	client := newTaskClient(t, storage, embedder)
	task := &protocol.Task{ID: 25, ConvID: 7, Title: "Fix Search Display", Description: "Index Tasks", Status: protocol.TaskStatusTodo, Assignee: "alice", Priority: 2, Project: "nrc", ExternalRef: "#25"}

	client.handleTaskCreated(encodeTaskEvent(task))
	drainOneTask(t, client)
	initialCalls := embedder.count()
	identity := taskIdentity("ws", 25, 7)
	entry, ok := client.index.GetEntity(identity)
	if !ok || entry.Metadata.Task == nil {
		t.Fatal("created task not indexed with metadata")
	}
	if entry.Preview != "Fix Search Display" || entry.Payload != "Index Tasks\nProject: nrc\nAssignee: alice\nExternal reference: #25" ||
		entry.PreviewLower != "fix search display" || entry.PayloadLower != "index tasks\nproject: nrc\nassignee: alice\nexternal reference: #25" {
		t.Fatalf("unexpected searchable task content: %q / %q", entry.Preview, entry.Payload)
	}
	searchEmbedder := &mockEmbedderForTest{vec: []float32{1, 0}}
	results, err := client.index.SearchEntitiesParallel("ws", "fIx SeArCh", searchEmbedder, 7, 1, SearchFilters{EntityTypes: []EntityType{EntityTypeTask}}, 1)
	if err != nil || len(results) != 1 || results[0].Preview != "Fix Search Display" {
		t.Fatalf("mixed-case live search = %#v, %v", results, err)
	}

	task.Status = protocol.TaskStatusDone
	task.Priority = 5
	task.Color = 4
	task.DueAt = 123
	task.BlockedBy = 88
	task.CompletedAt = 99
	task.CompletedBy = "bob"
	client.handleTaskUpdated(encodeTaskEvent(task))
	if embedder.count() != initialCalls {
		t.Fatal("metadata-only task update caused re-embedding")
	}
	entry, _ = client.index.GetEntity(identity)
	if entry.Metadata.Task.Status != protocol.TaskStatusDone || entry.Metadata.Task.Priority != 5 || entry.Metadata.Task.Color != 4 ||
		entry.Metadata.Task.DueAt != 123 || entry.Metadata.Task.BlockedBy != 88 || entry.Metadata.Task.CompletedAt != 99 {
		t.Fatalf("task metadata was not refreshed: %+v", entry.Metadata.Task)
	}
	stored, err := storage.LoadAllEntityEmbeddings()
	if err != nil {
		t.Fatal(err)
	}
	if stored[identity].Preview != "Fix Search Display" || stored[identity].Metadata.Task.Status != protocol.TaskStatusDone {
		t.Fatalf("atomic metadata update did not preserve content: %+v", stored[identity])
	}
	reloadedIndex := NewIndex()
	if err := reloadedIndex.AddEntity(identity, indexEntryFromStoredEmbedding(stored[identity])); err != nil {
		t.Fatal(err)
	}
	reloadedResults, err := reloadedIndex.SearchEntitiesParallel("ws", "FIX SEARCH", searchEmbedder, 7, 1, SearchFilters{EntityTypes: []EntityType{EntityTypeTask}}, 1)
	if err != nil || len(reloadedResults) != 1 || reloadedResults[0].Preview != "Fix Search Display" {
		t.Fatalf("mixed-case reloaded search = %#v, %v", reloadedResults, err)
	}

	task.Assignee = "carol"
	client.handleTaskUpdated(encodeTaskEvent(task))
	drainOneTask(t, client)
	if embedder.count() == initialCalls {
		t.Fatal("embedded assignee change did not cause re-embedding")
	}

	// A pending change followed by a reversion to indexed content must cancel
	// the pending entry instead of embedding the now-stale intermediate value.
	task.Description = "intermediate"
	client.handleTaskUpdated(encodeTaskEvent(task))
	task.Description = "Index Tasks"
	client.handleTaskUpdated(encodeTaskEvent(task))
	if _, queued, err := storage.GetEntityQueueEntry(identity); err != nil || queued {
		t.Fatalf("reverted update left stale queue entry: queued=%v err=%v", queued, err)
	}
}

func TestTaskMoveAndExactDeletionPreserveIdentityCollisions(t *testing.T) {
	storage := newTestStorage(t)
	client := newTaskClient(t, storage, &recordingEmbedder{})
	room7 := taskIdentity("ws", 42, 7)
	room8 := taskIdentity("ws", 42, 8)
	asset := assetIdentity("ws", 42, 7)
	for _, identity := range []EntityIdentity{room7, room8, asset} {
		metadata := SearchMetadata{}
		if identity.EntityType == EntityTypeTask {
			metadata.Task = &TaskMetadata{Status: protocol.TaskStatusTodo}
		} else {
			metadata.AssetType = protocol.AssetTypeNote
		}
		entry := &IndexEntry{ConvID: identity.ConvID, Vector: []float32{1}, ContentHash: 1, Metadata: metadata}
		if err := client.index.AddEntity(identity, entry); err != nil {
			t.Fatal(err)
		}
		if err := storage.StoreEntityEmbedding(identity, storedEmbeddingFromEntry(entry)); err != nil {
			t.Fatal(err)
		}
	}

	move := bytes.NewBuffer(nil)
	binary.Write(move, binary.BigEndian, uint64(42))
	binary.Write(move, binary.BigEndian, uint64(7))
	move.WriteByte(protocol.TaskStatusDone)
	binary.Write(move, binary.BigEndian, uint16(3))
	binary.Write(move, binary.BigEndian, int64(123))
	writeTestString(move, "alice")
	binary.Write(move, binary.BigEndian, uint32(0))
	client.handleTaskMoved(context.Background(), move.Bytes())
	got, _ := client.index.GetEntity(room7)
	if got.Metadata.Task.Status != protocol.TaskStatusDone || got.Metadata.Task.CompletedAt != 123 {
		t.Fatalf("move metadata not applied: %+v", got.Metadata.Task)
	}

	deleted := make([]byte, 20)
	binary.BigEndian.PutUint64(deleted[0:8], 42)
	binary.BigEndian.PutUint64(deleted[8:16], 7)
	client.handleTaskDeleted(deleted)
	if _, ok := client.index.GetEntity(room7); ok {
		t.Fatal("deleted room-scoped task remains indexed")
	}
	if _, ok := client.index.GetEntity(room8); !ok {
		t.Fatal("same-ID task in another room was deleted")
	}
	if _, ok := client.index.GetEntity(asset); !ok {
		t.Fatal("same-ID asset was deleted")
	}
	loaded, err := storage.LoadAllEntityEmbeddings()
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := loaded[room7]; ok {
		t.Fatal("deleted task embedding remains persisted")
	}
	if _, ok := loaded[room8]; !ok {
		t.Fatal("other-room task embedding was removed")
	}
	if _, ok := loaded[asset]; !ok {
		t.Fatal("asset embedding was removed")
	}
}

func TestTaskMoveRefreshesPartialCache(t *testing.T) {
	storage := newTestStorage(t)
	client := newTaskClient(t, storage, &recordingEmbedder{})
	client.sendMessage = func(opcode uint16, payload []byte) error {
		if opcode != protocol.C_GetTask {
			return fmt.Errorf("unexpected opcode %d", opcode)
		}
		correlationID := binary.BigEndian.Uint32(payload[16:20])
		client.handleTaskFull(encodeTaskFull(&protocol.Task{
			ID: 55, ConvID: 7, Title: "partially cached", Description: "loaded in full",
			Status: protocol.TaskStatusDone, CompletedAt: 100,
		}, correlationID))
		return nil
	}
	move := bytes.NewBuffer(nil)
	binary.Write(move, binary.BigEndian, uint64(55))
	binary.Write(move, binary.BigEndian, uint64(7))
	move.WriteByte(protocol.TaskStatusDone)
	binary.Write(move, binary.BigEndian, uint16(0))
	binary.Write(move, binary.BigEndian, int64(100))
	writeTestString(move, "alice")
	binary.Write(move, binary.BigEndian, uint32(0))
	client.handleTaskMoved(context.Background(), move.Bytes())

	deadline := time.Now().Add(time.Second)
	for {
		_, _, ok, err := storage.PeekEntityQueueEntry("ws")
		if err != nil {
			t.Fatal(err)
		}
		if ok {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("moved task missing from partial cache was not fetched")
		}
		time.Sleep(time.Millisecond)
	}
	drainOneTask(t, client)
	entry, ok := client.index.GetEntity(taskIdentity("ws", 55, 7))
	if !ok || entry.Metadata.Task.Status != protocol.TaskStatusDone || entry.Preview != "partially cached" {
		t.Fatalf("refreshed moved task mismatch: %+v", entry)
	}
}

func TestTaskDeleteDuringEmbeddingCannotResurrectTask(t *testing.T) {
	storage := newTestStorage(t)
	embedder := &blockingEmbedder{started: make(chan struct{}), release: make(chan struct{})}
	client := newTaskClient(t, storage, embedder)
	identity := taskIdentity("ws", 77, 7)
	client.ingestTask(&protocol.Task{ID: 77, ConvID: 7, Title: "delete while embedding"}, true, 0, true)
	entry, ok, err := storage.GetEntityQueueEntry(identity)
	if err != nil || !ok {
		t.Fatalf("queued task missing: ok=%v err=%v", ok, err)
	}
	done := make(chan struct{})
	go func() {
		client.processEmbedJob(EmbedJob{Workspace: "ws", Identity: identity, Entry: entry})
		close(done)
	}()
	<-embedder.started
	deleted := make([]byte, 20)
	binary.BigEndian.PutUint64(deleted[0:8], 77)
	binary.BigEndian.PutUint64(deleted[8:16], 7)
	client.handleTaskDeleted(deleted)
	close(embedder.release)
	<-done
	if _, ok := client.index.GetEntity(identity); ok {
		t.Fatal("in-flight embedding resurrected deleted task in index")
	}
	if embeddings, err := storage.LoadAllEntityEmbeddings(); err != nil {
		t.Fatal(err)
	} else if _, ok := embeddings[identity]; ok {
		t.Fatal("in-flight embedding resurrected deleted task in storage")
	}
}

func TestDelayedTaskRefreshCannotResurrectDeletion(t *testing.T) {
	storage := newTestStorage(t)
	client := newTaskClient(t, storage, &recordingEmbedder{})
	identity := taskIdentity("ws", 88, 7)
	client.taskMutationMu.Lock()
	expectedVersion := client.nextVersion.Add(1)
	client.taskMutations[identity.key()] = expectedVersion
	client.taskMutationMu.Unlock()
	requestStarted := make(chan struct{})
	releaseResponse := make(chan struct{})
	client.sendMessage = func(opcode uint16, payload []byte) error {
		if opcode != protocol.C_GetTask {
			return fmt.Errorf("unexpected opcode %d", opcode)
		}
		close(requestStarted)
		<-releaseResponse
		correlationID := binary.BigEndian.Uint32(payload[16:20])
		client.handleTaskFull(encodeTaskFull(&protocol.Task{ID: 88, ConvID: 7, Title: "stale full response"}, correlationID))
		return nil
	}
	refreshDone := make(chan struct{})
	go func() {
		client.refreshTask(context.Background(), identity, expectedVersion)
		close(refreshDone)
	}()
	<-requestStarted
	deleted := make([]byte, 20)
	binary.BigEndian.PutUint64(deleted[0:8], 88)
	binary.BigEndian.PutUint64(deleted[8:16], 7)
	client.handleTaskDeleted(deleted)
	close(releaseResponse)
	<-refreshDone
	if _, ok := client.index.GetEntity(identity); ok {
		t.Fatal("delayed full response resurrected deleted task")
	}
	if _, queued, err := storage.GetEntityQueueEntry(identity); err != nil || queued {
		t.Fatalf("delayed full response recreated queue entry: queued=%v err=%v", queued, err)
	}
}

func TestPersistentTaskQueueRetriesWithoutUnrelatedWork(t *testing.T) {
	storage := newTestStorage(t)
	embedder := &flakyEmbedder{failures: 2}
	client := newTaskClient(t, storage, embedder)
	identity := taskIdentity("ws", 99, 7)
	client.ingestTask(&protocol.Task{ID: 99, ConvID: 7, Title: "retry task"}, true, 0, true)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go client.DrainEmbedQueue(ctx)
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, ok := client.index.GetEntity(identity); ok {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("persistent task queue did not retry to success")
		}
		time.Sleep(10 * time.Millisecond)
	}
	embedder.mu.Lock()
	attempts := embedder.attempts
	embedder.mu.Unlock()
	if attempts != 3 {
		t.Fatalf("embedding attempts = %d, want 3", attempts)
	}
}

func TestPagedTaskReconciliationActiveDoneStaleAndMutationRace(t *testing.T) {
	storage := newTestStorage(t)
	client := newTaskClient(t, storage, &recordingEmbedder{})
	stale := taskIdentity("ws", 90, 7)
	otherRoom := taskIdentity("ws", 90, 8)
	for _, identity := range []EntityIdentity{stale, otherRoom} {
		entry := &IndexEntry{ConvID: identity.ConvID, Vector: []float32{1}, ContentHash: 1, IndexedAt: time.Now().Add(-time.Hour), Metadata: SearchMetadata{Task: &TaskMetadata{}}}
		client.index.AddEntity(identity, entry)
		storage.StoreEntityEmbedding(identity, storedEmbeddingFromEntry(entry))
	}
	staleQueued := taskIdentity("ws", 91, 7)
	if err := storage.EnqueueEntity(staleQueued, QueueEntry{ConvID: 7, Preview: "stale queued", Version: 1}); err != nil {
		t.Fatal(err)
	}
	activeSnapshot := &protocol.Task{ID: 1, ConvID: 7, Title: "stale snapshot", Status: protocol.TaskStatusTodo}
	done := &protocol.Task{ID: 2, ConvID: 7, Title: "done", Status: protocol.TaskStatusDone, CompletedAt: 50}
	requests := 0
	client.sendMessage = func(opcode uint16, payload []byte) error {
		if opcode != protocol.C_ListTasksPaged {
			return fmt.Errorf("unexpected opcode %d", opcode)
		}
		if payload[8] != allTaskStatusesMask {
			t.Fatalf("status mask = %#x, want %#x", payload[8], allTaskStatusesMask)
		}
		correlationID := binary.BigEndian.Uint32(payload[len(payload)-4:])
		requests++
		if requests == 1 {
			client.ingestTask(&protocol.Task{ID: 1, ConvID: 7, Title: "fresh live", Status: protocol.TaskStatusInProgress}, true, 0, true)
			client.handleTaskListPage(encodeTaskPage(7, []*protocol.Task{activeSnapshot}, true, protocol.TaskPageCursor{SortAt: 10, TaskID: 1}, correlationID))
		} else {
			client.handleTaskListPage(encodeTaskPage(7, []*protocol.Task{done}, false, protocol.TaskPageCursor{}, correlationID))
		}
		return nil
	}
	if err := client.Reconcile(context.Background(), 7); err != nil {
		t.Fatal(err)
	}
	// The concurrent live mutation remains on the normal asynchronous path;
	// reconciliation itself commits its snapshot tasks before returning.
	drainOneTask(t, client)
	if requests != 2 {
		t.Fatalf("task page requests = %d, want 2", requests)
	}
	fresh, ok := client.index.GetEntity(taskIdentity("ws", 1, 7))
	if !ok || fresh.Preview != "fresh live" {
		t.Fatalf("snapshot overwrote concurrent live task: %+v", fresh)
	}
	if completed, ok := client.index.GetEntity(taskIdentity("ws", 2, 7)); !ok || completed.Metadata.Task.Status != protocol.TaskStatusDone {
		t.Fatal("Done task was not reconciled")
	}
	if _, ok := client.index.GetEntity(stale); ok {
		t.Fatal("stale room task was not removed")
	}
	if _, ok := client.index.GetEntity(otherRoom); !ok {
		t.Fatal("stale cleanup crossed room boundary")
	}
	if _, queued, err := storage.GetEntityQueueEntry(staleQueued); err != nil || queued {
		t.Fatalf("stale recovered queue entry survived reconciliation: queued=%v err=%v", queued, err)
	}
}

func TestTaskQueueRecoveryAndReload(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "search")
	storage, err := NewStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	client := newTaskClient(t, storage, &recordingEmbedder{})
	client.ingestTask(&protocol.Task{ID: 5, ConvID: 7, Title: "recover me", Status: protocol.TaskStatusBacklog, Priority: 4}, true, 0, true)
	if err := storage.Close(); err != nil {
		t.Fatal(err)
	}

	reopened, err := NewStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	recoveryClient := newTaskClient(t, reopened, &recordingEmbedder{})
	drainOneTask(t, recoveryClient)
	embeddings, err := reopened.LoadAllEntityEmbeddings()
	if err != nil {
		t.Fatal(err)
	}
	embedding, ok := embeddings[taskIdentity("ws", 5, 7)]
	if !ok || embedding.Metadata.Task == nil || embedding.Metadata.Task.Priority != 4 {
		t.Fatalf("task did not recover with metadata: %+v", embedding)
	}
	index := NewIndex()
	for identity, stored := range embeddings {
		if err := index.AddEntity(identity, &IndexEntry{ConvID: stored.ConvID, Vector: stored.Vector, ContentHash: stored.ContentHash, Preview: stored.Preview, Payload: stored.Payload, Metadata: stored.Metadata}); err != nil {
			t.Fatal(err)
		}
	}
	if _, ok := index.GetEntity(taskIdentity("ws", 5, 7)); !ok {
		t.Fatal("persisted task did not reload into typed index")
	}
}
