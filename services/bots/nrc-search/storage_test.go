package main

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/heavyhorst/nrc/protocol-go"
	"go.etcd.io/bbolt"
)

const testStorageWorkspace = "test-ws"

func newTestStorage(t *testing.T) *Storage {
	t.Helper()
	s, err := NewStorage(t.TempDir())
	if err != nil {
		t.Fatalf("NewStorage: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestNewStorageCreatesDirectoryAndDB(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "nested", "deep")
	s, err := NewStorage(dir)
	if err != nil {
		t.Fatalf("NewStorage: %v", err)
	}
	defer s.Close()

	dbPath := filepath.Join(dir, "search.db")
	info, err := os.Stat(dbPath)
	if err != nil {
		t.Fatalf("expected DB file at %s: %v", dbPath, err)
	}
	if info.IsDir() {
		t.Fatal("DB path is a directory, expected a file")
	}
}

func TestEnqueueDequeueRoundTrip(t *testing.T) {
	s := newTestStorage(t)

	entry := QueueEntry{
		ConvID:    42,
		AssetType: protocol.AssetTypeComment,
		Content:   "hello world",
		Preview:   "hello...",
	}
	if err := s.EnqueueAsset(testStorageWorkspace, 100, entry); err != nil {
		t.Fatalf("EnqueueAsset: %v", err)
	}

	assetID, got, ok, err := s.DequeueAsset(testStorageWorkspace)
	if err != nil {
		t.Fatalf("DequeueAsset: %v", err)
	}
	if !ok {
		t.Fatal("expected ok=true, got false")
	}
	if assetID != 100 {
		t.Errorf("assetID = %d, want 100", assetID)
	}
	if got.ConvID != entry.ConvID {
		t.Errorf("ConvID = %d, want %d", got.ConvID, entry.ConvID)
	}
	if got.AssetType != entry.AssetType {
		t.Errorf("AssetType = %d, want %d", got.AssetType, entry.AssetType)
	}
	if got.Content != entry.Content {
		t.Errorf("Content = %q, want %q", got.Content, entry.Content)
	}
	if got.Preview != entry.Preview {
		t.Errorf("Preview = %q, want %q", got.Preview, entry.Preview)
	}
}

func TestDequeueEmptyQueue(t *testing.T) {
	s := newTestStorage(t)

	_, _, ok, err := s.DequeueAsset(testStorageWorkspace)
	if err != nil {
		t.Fatalf("DequeueAsset: %v", err)
	}
	if ok {
		t.Fatal("expected ok=false for empty queue")
	}
}

func TestDequeueOrderIsBigEndianSorted(t *testing.T) {
	s := newTestStorage(t)

	// Enqueue in non-sorted order; big-endian key encoding should sort them.
	ids := []uint64{300, 100, 200}
	for _, id := range ids {
		err := s.EnqueueAsset(testStorageWorkspace, id, QueueEntry{ConvID: id, AssetType: protocol.AssetTypeDocument, Content: "c"})
		if err != nil {
			t.Fatalf("EnqueueAsset(%d): %v", id, err)
		}
	}

	want := []uint64{100, 200, 300}
	for i, wantID := range want {
		assetID, _, ok, err := s.DequeueAsset(testStorageWorkspace)
		if err != nil {
			t.Fatalf("DequeueAsset #%d: %v", i, err)
		}
		if !ok {
			t.Fatalf("DequeueAsset #%d: expected ok=true", i)
		}
		if assetID != wantID {
			t.Errorf("DequeueAsset #%d: assetID = %d, want %d", i, assetID, wantID)
		}
	}

	// Queue should now be empty.
	_, _, ok, err := s.DequeueAsset(testStorageWorkspace)
	if err != nil {
		t.Fatalf("DequeueAsset after drain: %v", err)
	}
	if ok {
		t.Fatal("expected ok=false after draining queue")
	}
}

func TestQueueSize(t *testing.T) {
	s := newTestStorage(t)

	size, err := s.QueueSize(testStorageWorkspace)
	if err != nil {
		t.Fatalf("QueueSize: %v", err)
	}
	if size != 0 {
		t.Errorf("initial QueueSize = %d, want 0", size)
	}

	for i := uint64(1); i <= 3; i++ {
		if err := s.EnqueueAsset(testStorageWorkspace, i, QueueEntry{ConvID: i}); err != nil {
			t.Fatalf("EnqueueAsset(%d): %v", i, err)
		}
	}

	size, err = s.QueueSize(testStorageWorkspace)
	if err != nil {
		t.Fatalf("QueueSize: %v", err)
	}
	if size != 3 {
		t.Errorf("QueueSize = %d, want 3", size)
	}

	// Dequeue one and check size decreases.
	if _, _, _, err := s.DequeueAsset(testStorageWorkspace); err != nil {
		t.Fatalf("DequeueAsset: %v", err)
	}
	size, err = s.QueueSize(testStorageWorkspace)
	if err != nil {
		t.Fatalf("QueueSize: %v", err)
	}
	if size != 2 {
		t.Errorf("QueueSize after dequeue = %d, want 2", size)
	}
}

func TestEnqueueOverwritesExistingKey(t *testing.T) {
	s := newTestStorage(t)

	entry1 := QueueEntry{ConvID: 1, Content: "first"}
	entry2 := QueueEntry{ConvID: 1, Content: "second"}

	if err := s.EnqueueAsset(testStorageWorkspace, 50, entry1); err != nil {
		t.Fatalf("EnqueueAsset: %v", err)
	}
	if err := s.EnqueueAsset(testStorageWorkspace, 50, entry2); err != nil {
		t.Fatalf("EnqueueAsset overwrite: %v", err)
	}

	size, _ := s.QueueSize(testStorageWorkspace)
	if size != 1 {
		t.Errorf("QueueSize = %d, want 1 after overwrite", size)
	}

	_, got, ok, err := s.DequeueAsset(testStorageWorkspace)
	if err != nil {
		t.Fatalf("DequeueAsset: %v", err)
	}
	if !ok {
		t.Fatal("expected ok=true")
	}
	if got.Content != "second" {
		t.Errorf("Content = %q, want %q", got.Content, "second")
	}
}

func TestStoreAndLoadAllEmbeddings(t *testing.T) {
	s := newTestStorage(t)

	embs := map[uint64]StoredEmbedding{
		10: {
			ConvID:      1,
			ContentHash: 111,
			Vector:      []float32{0.1, 0.2, 0.3},
			Chunks:      []StoredChunkEmbedding{{Index: 0, Vector: []float32{0.1, 0.2}}, {Index: 1, Vector: []float32{0.3, 0.4}}},
			AssetType:   protocol.AssetTypeComment,
			Preview:     "p1",
		},
		20: {ConvID: 2, ContentHash: 222, Vector: []float32{0.4, 0.5}, AssetType: protocol.AssetTypeAgenda, Preview: "p2"},
	}

	for id, emb := range embs {
		if err := s.StoreEmbedding(testStorageWorkspace, id, emb); err != nil {
			t.Fatalf("StoreEmbedding(%d): %v", id, err)
		}
	}

	loaded, err := s.LoadAllEmbeddings(testStorageWorkspace)
	if err != nil {
		t.Fatalf("LoadAllEmbeddings: %v", err)
	}
	if len(loaded) != len(embs) {
		t.Fatalf("LoadAllEmbeddings returned %d items, want %d", len(loaded), len(embs))
	}

	for id, want := range embs {
		got, ok := loaded[id]
		if !ok {
			t.Errorf("missing embedding for assetID %d", id)
			continue
		}
		if got.ConvID != want.ConvID {
			t.Errorf("assetID %d: ConvID = %d, want %d", id, got.ConvID, want.ConvID)
		}
		if got.ContentHash != want.ContentHash {
			t.Errorf("assetID %d: ContentHash = %d, want %d", id, got.ContentHash, want.ContentHash)
		}
		if got.AssetType != want.AssetType {
			t.Errorf("assetID %d: AssetType = %d, want %d", id, got.AssetType, want.AssetType)
		}
		if got.Preview != want.Preview {
			t.Errorf("assetID %d: Preview = %q, want %q", id, got.Preview, want.Preview)
		}
		if len(got.Vector) != len(want.Vector) {
			t.Errorf("assetID %d: Vector length = %d, want %d", id, len(got.Vector), len(want.Vector))
			continue
		}
		for i := range want.Vector {
			if math.Abs(float64(got.Vector[i]-want.Vector[i])) > 1e-6 {
				t.Errorf("assetID %d: Vector[%d] = %f, want %f", id, i, got.Vector[i], want.Vector[i])
			}
		}
		if len(got.Chunks) != len(want.Chunks) {
			t.Errorf("assetID %d: Chunks length = %d, want %d", id, len(got.Chunks), len(want.Chunks))
			continue
		}
		for i := range want.Chunks {
			if got.Chunks[i].Index != want.Chunks[i].Index {
				t.Errorf("assetID %d: Chunks[%d].Index = %d, want %d", id, i, got.Chunks[i].Index, want.Chunks[i].Index)
			}
			if len(got.Chunks[i].Vector) != len(want.Chunks[i].Vector) {
				t.Errorf("assetID %d: Chunks[%d].Vector length = %d, want %d", id, i, len(got.Chunks[i].Vector), len(want.Chunks[i].Vector))
				continue
			}
			for j := range want.Chunks[i].Vector {
				if math.Abs(float64(got.Chunks[i].Vector[j]-want.Chunks[i].Vector[j])) > 1e-6 {
					t.Errorf("assetID %d: Chunks[%d].Vector[%d] = %f, want %f", id, i, j, got.Chunks[i].Vector[j], want.Chunks[i].Vector[j])
				}
			}
		}
	}
}

func TestDeleteEmbedding(t *testing.T) {
	s := newTestStorage(t)

	if err := s.StoreEmbedding(testStorageWorkspace, 10, StoredEmbedding{ConvID: 1, Vector: []float32{1}}); err != nil {
		t.Fatalf("StoreEmbedding(10): %v", err)
	}
	if err := s.StoreEmbedding(testStorageWorkspace, 20, StoredEmbedding{ConvID: 2, Vector: []float32{2}}); err != nil {
		t.Fatalf("StoreEmbedding(20): %v", err)
	}

	if err := s.DeleteEmbedding(testStorageWorkspace, 10); err != nil {
		t.Fatalf("DeleteEmbedding: %v", err)
	}

	loaded, err := s.LoadAllEmbeddings(testStorageWorkspace)
	if err != nil {
		t.Fatalf("LoadAllEmbeddings: %v", err)
	}
	if len(loaded) != 1 {
		t.Fatalf("expected 1 embedding after delete, got %d", len(loaded))
	}
	if _, ok := loaded[20]; !ok {
		t.Error("expected assetID 20 to remain")
	}
	if _, ok := loaded[10]; ok {
		t.Error("expected assetID 10 to be deleted")
	}
}

func TestDeleteEmbeddingsByConvID(t *testing.T) {
	s := newTestStorage(t)

	// Two embeddings for convID 1, one for convID 2.
	if err := s.StoreEmbedding(testStorageWorkspace, 10, StoredEmbedding{ConvID: 1, Vector: []float32{1}}); err != nil {
		t.Fatal(err)
	}
	if err := s.StoreEmbedding(testStorageWorkspace, 20, StoredEmbedding{ConvID: 1, Vector: []float32{2}}); err != nil {
		t.Fatal(err)
	}
	if err := s.StoreEmbedding(testStorageWorkspace, 30, StoredEmbedding{ConvID: 2, Vector: []float32{3}}); err != nil {
		t.Fatal(err)
	}

	if err := s.DeleteEmbeddingsByConvID(testStorageWorkspace, 1); err != nil {
		t.Fatalf("DeleteEmbeddingsByConvID: %v", err)
	}

	loaded, err := s.LoadAllEmbeddings(testStorageWorkspace)
	if err != nil {
		t.Fatal(err)
	}
	if len(loaded) != 1 {
		t.Fatalf("expected 1 embedding remaining, got %d", len(loaded))
	}
	if _, ok := loaded[30]; !ok {
		t.Error("expected assetID 30 (convID=2) to remain")
	}
}

func TestGetRoomSyncMissingRoom(t *testing.T) {
	s := newTestStorage(t)

	_, found, err := s.GetRoomSync(testStorageWorkspace, 999)
	if err != nil {
		t.Fatalf("GetRoomSync: %v", err)
	}
	if found {
		t.Fatal("expected found=false for missing room")
	}
}

func TestSetAndGetRoomSync(t *testing.T) {
	s := newTestStorage(t)

	now := time.Now().Truncate(time.Second)
	state := RoomSyncState{LastFullSync: now}

	if err := s.SetRoomSync(testStorageWorkspace, 42, state); err != nil {
		t.Fatalf("SetRoomSync: %v", err)
	}

	got, found, err := s.GetRoomSync(testStorageWorkspace, 42)
	if err != nil {
		t.Fatalf("GetRoomSync: %v", err)
	}
	if !found {
		t.Fatal("expected found=true")
	}
	if !got.LastFullSync.Equal(now) {
		t.Errorf("LastFullSync = %v, want %v", got.LastFullSync, now)
	}

	// Verify a different convID is not found.
	_, found, err = s.GetRoomSync(testStorageWorkspace, 43)
	if err != nil {
		t.Fatalf("GetRoomSync(43): %v", err)
	}
	if found {
		t.Error("expected found=false for different convID")
	}
}

func TestEnsureEmbeddingSchemaMigratesLegacyEmbeddings(t *testing.T) {
	s := newTestStorage(t)

	if err := s.StoreEmbedding(testStorageWorkspace, 10, StoredEmbedding{ConvID: 1, Vector: []float32{1}}); err != nil {
		t.Fatal(err)
	}
	if err := s.EnqueueAsset(testStorageWorkspace, 20, QueueEntry{ConvID: 2, Content: "queued"}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetRoomSync(testStorageWorkspace, 42, RoomSyncState{LastFullSync: time.Now().Truncate(time.Second)}); err != nil {
		t.Fatal(err)
	}

	migrated, previous, err := s.EnsureEmbeddingSchema(default_embedding_schema)
	if err != nil {
		t.Fatalf("EnsureEmbeddingSchema: %v", err)
	}
	if !migrated {
		t.Fatal("expected legacy embeddings to be migrated")
	}
	if previous != "" {
		t.Errorf("previous = %q, want empty string for legacy data", previous)
	}

	loaded, err := s.LoadAllEmbeddings(testStorageWorkspace)
	if err != nil {
		t.Fatalf("LoadAllEmbeddings: %v", err)
	}
	if len(loaded) != 0 {
		t.Fatalf("expected embeddings to be cleared, got %d", len(loaded))
	}

	size, err := s.QueueSize(testStorageWorkspace)
	if err != nil {
		t.Fatalf("QueueSize: %v", err)
	}
	if size != 1 {
		t.Fatalf("expected queued assets to be preserved, got %d", size)
	}

	_, found, err := s.GetRoomSync(testStorageWorkspace, 42)
	if err != nil {
		t.Fatalf("GetRoomSync: %v", err)
	}
	if found {
		t.Fatal("expected room sync state to be cleared during migration")
	}

	migrated, previous, err = s.EnsureEmbeddingSchema(default_embedding_schema)
	if err != nil {
		t.Fatalf("EnsureEmbeddingSchema second call: %v", err)
	}
	if migrated {
		t.Fatal("expected schema check to be idempotent")
	}
	if previous != "" {
		t.Errorf("previous on second call = %q, want empty", previous)
	}
}

func TestEmbeddingGemma2SchemaRebuildsAssetAndTaskVectors(t *testing.T) {
	s := newTestStorage(t)
	oldSchema := "embeddinggemma-300m-v2-chunked"
	if _, _, err := s.EnsureEmbeddingSchema(oldSchema); err != nil {
		t.Fatal(err)
	}
	if err := s.StoreEmbedding(testStorageWorkspace, 10, StoredEmbedding{Vector: []float32{1}}); err != nil {
		t.Fatal(err)
	}
	identity := taskIdentity(testStorageWorkspace, 20, 0)
	if err := s.StoreEntityEmbedding(identity, StoredEmbedding{Vector: []float32{2}}); err != nil {
		t.Fatal(err)
	}
	if err := s.EnqueueEntity(identity, QueueEntry{Content: "pending task", Version: 3}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetRoomSync(testStorageWorkspace, 0, RoomSyncState{LastFullSync: time.Now()}); err != nil {
		t.Fatal(err)
	}

	migrated, previous, err := s.EnsureEmbeddingSchema(default_embedding_schema)
	if err != nil || !migrated || previous != oldSchema {
		t.Fatalf("schema change: migrated=%v previous=%q err=%v", migrated, previous, err)
	}
	legacy, err := s.LoadAllEmbeddings(testStorageWorkspace)
	if err != nil || len(legacy) != 0 {
		t.Fatalf("old asset vectors remain: %v err=%v", legacy, err)
	}
	entities, err := s.LoadAllEntityEmbeddings()
	if err != nil || len(entities) != 0 {
		t.Fatalf("old typed vectors remain: %v err=%v", entities, err)
	}
	if _, found, err := s.GetRoomSync(testStorageWorkspace, 0); err != nil || found {
		t.Fatalf("workspace must be resynced: found=%v err=%v", found, err)
	}
	queued, found, err := s.GetEntityQueueEntry(identity)
	if err != nil || !found || queued.Content != "pending task" || queued.Version != 3 {
		t.Fatalf("pending task must survive: entry=%+v found=%v err=%v", queued, found, err)
	}

	if err := s.StoreEntityEmbedding(identity, StoredEmbedding{Vector: []float32{3}}); err != nil {
		t.Fatal(err)
	}
	if migrated, _, err := s.EnsureEmbeddingSchema(default_embedding_schema); err != nil || migrated {
		t.Fatalf("same schema must not reset: migrated=%v err=%v", migrated, err)
	}
	entities, err = s.LoadAllEntityEmbeddings()
	if err != nil || len(entities) != 1 || entities[identity].Vector[0] != 3 {
		t.Fatalf("new vectors must survive restart: %v err=%v", entities, err)
	}
}

func TestLoadAllEmbeddingsEmpty(t *testing.T) {
	s := newTestStorage(t)

	loaded, err := s.LoadAllEmbeddings(testStorageWorkspace)
	if err != nil {
		t.Fatalf("LoadAllEmbeddings: %v", err)
	}
	if len(loaded) != 0 {
		t.Errorf("expected empty map, got %d entries", len(loaded))
	}
}

func TestDeleteEmbeddingNonExistent(t *testing.T) {
	s := newTestStorage(t)

	// Deleting a non-existent key should not error.
	if err := s.DeleteEmbedding(testStorageWorkspace, 999); err != nil {
		t.Fatalf("DeleteEmbedding non-existent: %v", err)
	}
}

func TestDeleteQueueEntry(t *testing.T) {
	s := newTestStorage(t)

	if err := s.EnqueueAsset(testStorageWorkspace, 100, QueueEntry{ConvID: 1, Content: "a"}); err != nil {
		t.Fatal(err)
	}
	if err := s.EnqueueAsset(testStorageWorkspace, 200, QueueEntry{ConvID: 2, Content: "b"}); err != nil {
		t.Fatal(err)
	}

	if err := s.DeleteQueueEntry(testStorageWorkspace, 100); err != nil {
		t.Fatalf("DeleteQueueEntry: %v", err)
	}

	size, _ := s.QueueSize(testStorageWorkspace)
	if size != 1 {
		t.Errorf("QueueSize = %d, want 1", size)
	}

	assetID, _, ok, err := s.DequeueAsset(testStorageWorkspace)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("expected ok=true")
	}
	if assetID != 200 {
		t.Errorf("assetID = %d, want 200", assetID)
	}
}

func TestPeekQueueEntry(t *testing.T) {
	s := newTestStorage(t)

	// Peek on empty queue
	_, _, ok, err := s.PeekQueueEntry(testStorageWorkspace)
	if err != nil {
		t.Fatalf("PeekQueueEntry empty: %v", err)
	}
	if ok {
		t.Fatal("expected ok=false for empty queue")
	}

	// Enqueue two items
	if err := s.EnqueueAsset(testStorageWorkspace, 100, QueueEntry{ConvID: 1, Content: "first"}); err != nil {
		t.Fatal(err)
	}
	if err := s.EnqueueAsset(testStorageWorkspace, 200, QueueEntry{ConvID: 2, Content: "second"}); err != nil {
		t.Fatal(err)
	}

	// Peek returns first item without removing it
	assetID, entry, ok, err := s.PeekQueueEntry(testStorageWorkspace)
	if err != nil {
		t.Fatalf("PeekQueueEntry: %v", err)
	}
	if !ok {
		t.Fatal("expected ok=true")
	}
	if assetID != 100 {
		t.Errorf("assetID = %d, want 100", assetID)
	}
	if entry.Content != "first" {
		t.Errorf("Content = %q, want %q", entry.Content, "first")
	}

	// Peek again returns same item (not consumed)
	assetID2, _, ok2, err := s.PeekQueueEntry(testStorageWorkspace)
	if err != nil {
		t.Fatalf("PeekQueueEntry second: %v", err)
	}
	if !ok2 || assetID2 != 100 {
		t.Errorf("second peek: assetID = %d, ok = %v, want 100/true", assetID2, ok2)
	}

	// Queue size unchanged
	size, _ := s.QueueSize(testStorageWorkspace)
	if size != 2 {
		t.Errorf("QueueSize = %d, want 2 after peek", size)
	}
}

func TestDeleteEmbeddingsByConvIDNoMatch(t *testing.T) {
	s := newTestStorage(t)

	if err := s.StoreEmbedding(testStorageWorkspace, 10, StoredEmbedding{ConvID: 1, Vector: []float32{1}}); err != nil {
		t.Fatal(err)
	}

	// Delete by a convID that doesn't match anything.
	if err := s.DeleteEmbeddingsByConvID(testStorageWorkspace, 999); err != nil {
		t.Fatalf("DeleteEmbeddingsByConvID: %v", err)
	}

	loaded, err := s.LoadAllEmbeddings(testStorageWorkspace)
	if err != nil {
		t.Fatal(err)
	}
	if len(loaded) != 1 {
		t.Errorf("expected 1 embedding to remain, got %d", len(loaded))
	}
}

func TestPreAttachmentQueueSchemaConditionalConsumption(t *testing.T) {
	// Exact field shapes before attachments were added, not the current schema.
	type oldMetadata struct {
		AssetType uint16
		Task      *TaskMetadata
	}
	type oldQueue struct {
		ConvID           uint64
		AssetType        uint16
		Content, Preview string
		Metadata         oldMetadata
		Version          uint64
	}
	for _, kind := range []EntityType{EntityTypeAsset, EntityTypeTask} {
		for _, commit := range []bool{false, true} {
			t.Run(string(kind)+fmt.Sprint(commit), func(t *testing.T) {
				s := newTestStorage(t)
				identity := EntityIdentity{Workspace: "ws", EntityType: kind, EntityID: 12, ConvID: 7}
				data, err := gobEncode(oldQueue{ConvID: 7, Content: "old content", Preview: "old title", Version: 1})
				if err != nil {
					t.Fatal(err)
				}
				var entry QueueEntry
				if err := gobDecode(data, &entry); err != nil {
					t.Fatal(err)
				}
				if err := s.db.Update(func(tx *bbolt.Tx) error {
					name := bucketEntityQueue
					key, _ := entityStorageKey(identity)
					if kind == EntityTypeAsset {
						name = bucketQueue
						key = uint64ToKey(12)
					}
					bucket, err := s.workspaceBucket(tx, name, "ws")
					if err != nil {
						return err
					}
					return bucket.Put(key, data)
				}); err != nil {
					t.Fatal(err)
				}
				consume := func(e QueueEntry) (bool, error) {
					if commit {
						return s.CommitEntityEmbedding(identity, e, StoredEmbedding{Vector: []float32{1}, Payload: e.Content})
					}
					return s.DeleteEntityQueueEntryIfCurrent(identity, e)
				}
				wrong := entry
				wrong.Content = "different content, same version"
				if consumed, err := consume(wrong); err != nil || consumed {
					t.Fatalf("superseded job consumed: %v %v", consumed, err)
				}
				if consumed, err := consume(entry); err != nil || !consumed {
					t.Fatalf("old-schema job not consumed: %v %v", consumed, err)
				}
				if consumed, err := consume(entry); err != nil || consumed {
					t.Fatalf("job consumed twice: %v %v", consumed, err)
				}
			})
		}
	}
}
