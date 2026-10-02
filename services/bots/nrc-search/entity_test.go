package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"

	"github.com/heavyhorst/nrc/protocol-go"
	"go.etcd.io/bbolt"
)

func TestWorkspaceScopeNeverFallsBackToLegacyRoomOrDM(t *testing.T) {
	for _, legacyScope := range []uint64{7, 1<<63 | 9} {
		idx := NewIndex()
		if err := idx.AddEntity(assetIdentity("ws", 42, legacyScope), &IndexEntry{ConvID: legacyScope, Vector: []float32{1, 0}, Preview: "private seed"}); err != nil {
			t.Fatal(err)
		}
		if _, err := idx.SimilarParallel("ws", 42, 0, 10, nil, 1); !errors.Is(err, ErrSeedNotIndexed) {
			t.Fatalf("scope 0 borrowed legacy seed from %d: %v", legacyScope, err)
		}
		if got := idx.CollectVectors("ws", 0, nil, []uint64{42}); len(got) != 0 {
			t.Fatalf("scope 0 collected legacy vectors: %#v", got)
		}
		if err := idx.AddEntity(assetIdentity("ws", 42, 0), &IndexEntry{ConvID: 0, Vector: []float32{0, 1}, Preview: "public seed"}); err != nil {
			t.Fatal(err)
		}
		got := idx.CollectVectors("ws", 0, nil, []uint64{42})
		if len(got) != 1 || got[0].vector[0] != 0 || got[0].vector[1] != 1 {
			t.Fatalf("scope 0 did not select canonical public vector: %#v", got)
		}
	}
}

func TestIndexSeparatesAssetAndTaskWithSameID(t *testing.T) {
	idx := NewIndex()
	asset := assetIdentity("ws", 42, 7)
	task := EntityIdentity{Workspace: "ws", EntityType: EntityTypeTask, EntityID: 42, ConvID: 7}
	idx.AddEntity(asset, &IndexEntry{ConvID: 7, Vector: []float32{1, 0}, AssetType: 5, Preview: "asset"})
	idx.AddEntity(task, &IndexEntry{ConvID: 7, Vector: []float32{0, 1}, Preview: "task"})

	if idx.Count() != 2 {
		t.Fatalf("Count() = %d, want 2", idx.Count())
	}
	if got, ok := idx.GetEntity(asset); !ok || got.Preview != "asset" {
		t.Fatalf("asset lookup = %#v, %v", got, ok)
	}
	if got, ok := idx.GetEntity(task); !ok || got.Preview != "task" {
		t.Fatalf("task lookup = %#v, %v", got, ok)
	}
}

func TestTypedIndexKeepsSameTaskIDInDifferentRooms(t *testing.T) {
	idx := NewIndex()
	room7 := EntityIdentity{Workspace: "ws", EntityType: EntityTypeTask, EntityID: 42, ConvID: 7}
	room8 := EntityIdentity{Workspace: "ws", EntityType: EntityTypeTask, EntityID: 42, ConvID: 8}
	if err := idx.AddEntity(room7, &IndexEntry{ConvID: 7, Vector: []float32{1}, Preview: "room7"}); err != nil {
		t.Fatal(err)
	}
	if err := idx.AddEntity(room8, &IndexEntry{ConvID: 8, Vector: []float32{1}, Preview: "room8"}); err != nil {
		t.Fatal(err)
	}
	if idx.Count() != 2 {
		t.Fatalf("Count() = %d, want 2", idx.Count())
	}
	if got, ok := idx.GetEntity(room7); !ok || got.Preview != "room7" {
		t.Fatalf("room7 = %#v, %v", got, ok)
	}
	if got, ok := idx.GetEntity(room8); !ok || got.Preview != "room8" {
		t.Fatalf("room8 = %#v, %v", got, ok)
	}
	for _, tc := range []struct {
		room    uint64
		preview string
	}{{7, "room7"}, {8, "room8"}} {
		results, err := idx.SearchEntitiesParallel("ws", "room", &mockEmbedderForTest{vec: []float32{1}}, tc.room, 10, SearchFilters{EntityTypes: []EntityType{EntityTypeTask}}, 1)
		if err != nil {
			t.Fatal(err)
		}
		if len(results) != 1 || results[0].Entity.ConvID != tc.room || results[0].Preview != tc.preview {
			t.Fatalf("room %d results = %#v", tc.room, results)
		}
	}
	idx.RemoveEntity(room7)
	if _, ok := idx.GetEntity(room7); ok {
		t.Fatal("room7 survived exact removal")
	}
	if _, ok := idx.GetEntity(room8); !ok {
		t.Fatal("exact removal deleted room8")
	}
	if err := idx.AddEntity(room7, &IndexEntry{ConvID: 8}); err == nil {
		t.Fatal("room mismatch was accepted")
	}
}

func TestEntitySearchReturnsCollidingIDsAndHonorsTypeFilter(t *testing.T) {
	idx := NewIndex()
	for _, typ := range []EntityType{EntityTypeAsset, EntityTypeTask} {
		text := string(typ) + " needle"
		idx.AddEntity(EntityIdentity{Workspace: "ws", EntityType: typ, EntityID: 42, ConvID: 7}, &IndexEntry{
			ConvID: 7, Vector: []float32{1, 0}, AssetType: 5,
			Preview: text, Payload: text, Bloom: BigramBloom(text),
		})
	}
	results, err := idx.SearchEntitiesParallel("ws", "needle", &mockEmbedderForTest{vec: []float32{1, 0}}, 7, 10, SearchFilters{EntityTypes: []EntityType{EntityTypeAsset, EntityTypeTask}}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 2 || results[0].Entity.EntityType == results[1].Entity.EntityType {
		t.Fatalf("colliding identity results = %#v", results)
	}
	tasks, err := idx.SearchEntitiesParallel("ws", "needle", &mockEmbedderForTest{vec: []float32{1, 0}}, 7, 10, SearchFilters{EntityTypes: []EntityType{EntityTypeTask}}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(tasks) != 1 || tasks[0].Entity.EntityType != EntityTypeTask || tasks[0].AssetID != 0 {
		t.Fatalf("task-filtered results = %#v", tasks)
	}
}

func TestTaskFiltersApplyBeforeTopNAndIncludeDoneHistory(t *testing.T) {
	idx := NewIndex()
	for id := uint64(1); id <= 20; id++ {
		idx.AddEntity(taskIdentity("ws", id, 7), &IndexEntry{ConvID: 7, Vector: []float32{1, 0}, Preview: "semantic match",
			Payload: "semantic match", Bloom: BigramBloom("semantic match"), Metadata: SearchMetadata{Task: &TaskMetadata{
				Status: protocol.TaskStatusTodo, Assignee: "alice", Project: "other", UpdatedAt: int64(id),
			}}})
	}
	idx.AddEntity(taskIdentity("ws", 27, 7), &IndexEntry{ConvID: 7, Vector: []float32{0, 1}, Preview: "unify search",
		Payload: "unify search", Bloom: BigramBloom("unify search"), Metadata: SearchMetadata{Task: &TaskMetadata{
			Status: protocol.TaskStatusDone, Assignee: "Bob", Project: "NRC", Priority: 3, ExternalRef: "NRC-27", UpdatedAt: 99,
		}}})

	filters := SearchFilters{EntityTypes: []EntityType{EntityTypeTask}, Task: &TaskFilters{
		Statuses: []uint8{protocol.TaskStatusDone}, Assignees: []string{"bob"}, Projects: []string{"nrc"}, Priorities: []uint8{3},
	}}
	results, err := idx.SearchEntitiesParallel("ws", "semantic match", &mockEmbedderForTest{vec: []float32{1, 0}}, 7, 1, filters, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 1 || results[0].Entity.EntityID != 27 || results[0].Metadata.Task.Status != protocol.TaskStatusDone {
		t.Fatalf("pre-ranked Done filters returned %#v", results)
	}
}

func TestTaskColorBlockedAndOverdueFiltersCombineBeforeTopN(t *testing.T) {
	idx := NewIndex()
	blocked := true
	cutoff := int64(100)
	for id := uint64(1); id <= 12; id++ {
		idx.AddEntity(taskIdentity("ws", id, 7), &IndexEntry{ConvID: 7, Vector: []float32{1, 0}, Preview: "strong semantic",
			Metadata: SearchMetadata{Task: &TaskMetadata{Status: protocol.TaskStatusTodo, Color: 2, BlockedBy: 55, DueAt: 150}}})
	}
	idx.AddEntity(taskIdentity("ws", 27, 7), &IndexEntry{ConvID: 7, Vector: []float32{0, 1}, Preview: "weak semantic",
		Metadata: SearchMetadata{Task: &TaskMetadata{Status: protocol.TaskStatusTodo, Color: 4, BlockedBy: 99, DueAt: 80}}})
	filters := SearchFilters{EntityTypes: []EntityType{EntityTypeTask}, Task: &TaskFilters{
		Statuses: []uint8{protocol.TaskStatusTodo}, Colors: []uint8{4}, Blocked: &blocked, BlockedBy: []uint64{99}, OverdueBefore: &cutoff,
	}}
	results, err := idx.SearchEntitiesParallel("ws", "semantic", &mockEmbedderForTest{vec: []float32{1, 0}}, 7, 1, filters, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 1 || results[0].Entity.EntityID != 27 {
		t.Fatalf("combined pre-ranking filters returned %#v", results)
	}

	unblocked := false
	filters.Task = &TaskFilters{Blocked: &unblocked}
	if got := idx.collectCandidates("ws", 7, filters); len(got) != 0 {
		t.Fatalf("blocked=false matched blocked tasks: %#v", got)
	}
	filters.Task = &TaskFilters{OverdueBefore: &cutoff}
	idx.AddEntity(taskIdentity("ws", 28, 7), &IndexEntry{ConvID: 7, Vector: []float32{1}, Preview: "done",
		Metadata: SearchMetadata{Task: &TaskMetadata{Status: protocol.TaskStatusDone, DueAt: 50}}})
	if got := idx.collectCandidates("ws", 7, filters); len(got) != 1 || got[0].identity.EntityID != 27 {
		t.Fatalf("overdue semantics returned %#v", got)
	}
}

func TestTaskExactIDAndExternalReferenceRankFirstDeterministically(t *testing.T) {
	idx := NewIndex()
	for _, id := range []uint64{5, 27, 30} {
		ref := ""
		if id == 30 {
			ref = "EXT-WEB-30"
		}
		idx.AddEntity(taskIdentity("ws", id, 7), &IndexEntry{ConvID: 7, Vector: []float32{1, 0}, Preview: "same",
			Payload: "same", Bloom: BigramBloom("same"), Metadata: SearchMetadata{Task: &TaskMetadata{ExternalRef: ref}}})
	}
	filters := SearchFilters{EntityTypes: []EntityType{EntityTypeTask}}
	for query, want := range map[string]uint64{"#27": 27, "task:27": 27, "ext-web-30": 30} {
		results, err := idx.SearchEntitiesParallel("ws", query, &mockEmbedderForTest{vec: []float32{1, 0}}, 7, 1, filters, 2)
		if err != nil {
			t.Fatal(err)
		}
		if len(results) != 1 || results[0].Entity.EntityID != want {
			t.Fatalf("query %q returned %#v, want task %d", query, results, want)
		}
	}
}

func TestTaskFilterOnlySearchUsesStableUpdatedOrder(t *testing.T) {
	idx := NewIndex()
	for _, item := range []struct {
		id      uint64
		updated int64
	}{{9, 10}, {3, 10}, {7, 20}} {
		idx.AddEntity(taskIdentity("ws", item.id, 7), &IndexEntry{ConvID: 7, Vector: []float32{1}, Preview: "task",
			Metadata: SearchMetadata{Task: &TaskMetadata{Status: protocol.TaskStatusDone, UpdatedAt: item.updated}}})
	}
	results, err := idx.SearchEntitiesParallel("ws", "", nil, 7, 3, SearchFilters{EntityTypes: []EntityType{EntityTypeTask}}, 1)
	if err != nil {
		t.Fatal(err)
	}
	want := []uint64{7, 3, 9}
	for i := range want {
		if results[i].Entity.EntityID != want[i] {
			t.Fatalf("filter-only order = %#v, want %v", results, want)
		}
	}
}

func TestEntityStoragePersistenceAndLegacyMigration(t *testing.T) {
	dir := t.TempDir()
	s, err := NewStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.StoreEmbedding("ws", 42, StoredEmbedding{ConvID: 7, Vector: []float32{1}, Preview: "asset"}); err != nil {
		t.Fatal(err)
	}
	task := EntityIdentity{Workspace: "ws", EntityType: EntityTypeTask, EntityID: 42, ConvID: 7}
	if err := s.StoreEntityEmbedding(task, StoredEmbedding{Vector: []float32{2}, Preview: "task"}); err != nil {
		t.Fatal(err)
	}
	// Simulate an installation that only has the legacy asset record while
	// retaining an already-native task record in the entity bucket.
	if err := s.db.Update(func(tx *bbolt.Tx) error {
		bucket := tx.Bucket(bucketEntityEmbeddings).Bucket([]byte("ws"))
		key, err := entityStorageKey(assetIdentity("ws", 42, 7))
		if err != nil {
			return err
		}
		return bucket.Delete(key)
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}

	s, err = NewStorage(filepath.Dir(filepath.Join(dir, "search.db")))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	loaded, err := s.LoadAllEntityEmbeddings()
	if err != nil {
		t.Fatal(err)
	}
	if len(loaded) != 2 {
		t.Fatalf("loaded %d entities, want 2", len(loaded))
	}
	if loaded[assetIdentity("ws", 42, 7)].Preview != "asset" {
		t.Fatal("legacy asset was not retained")
	}
	if loaded[task].Preview != "task" {
		t.Fatal("task was not retained")
	}
}

func TestTypedStorageKeepsSameTaskIDInDifferentRooms(t *testing.T) {
	s := newTestStorage(t)
	room7 := EntityIdentity{Workspace: "ws", EntityType: EntityTypeTask, EntityID: 42, ConvID: 7}
	room8 := EntityIdentity{Workspace: "ws", EntityType: EntityTypeTask, EntityID: 42, ConvID: 8}
	if err := s.StoreEntityEmbedding(room7, StoredEmbedding{Preview: "room7"}); err != nil {
		t.Fatal(err)
	}
	if err := s.StoreEntityEmbedding(room8, StoredEmbedding{Preview: "room8"}); err != nil {
		t.Fatal(err)
	}
	loaded, err := s.LoadAllEntityEmbeddings()
	if err != nil {
		t.Fatal(err)
	}
	if loaded[room7].Preview != "room7" || loaded[room8].Preview != "room8" {
		t.Fatalf("loaded = %#v", loaded)
	}
	if err := s.DeleteEntityEmbedding(room7); err != nil {
		t.Fatal(err)
	}
	loaded, err = s.LoadAllEntityEmbeddings()
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := loaded[room7]; ok {
		t.Fatal("room7 survived exact delete")
	}
	if loaded[room8].Preview != "room8" {
		t.Fatal("exact delete removed room8")
	}
	if err := s.StoreEntityEmbedding(room7, StoredEmbedding{ConvID: 8}); err == nil {
		t.Fatal("room mismatch was accepted")
	}
}

func TestLegacyMigrationExactKeyIdempotenceAndConflict(t *testing.T) {
	dir := t.TempDir()
	s, err := NewStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	legacy := StoredEmbedding{ConvID: 7, Vector: []float32{1}, Preview: "legacy"}
	legacyBytes, _ := gobEncode(legacy)
	otherRoom := StoredEmbedding{ConvID: 8, Vector: []float32{2}, Preview: "other-room"}
	otherBytes, _ := gobEncode(otherRoom)
	if err := s.db.Update(func(tx *bbolt.Tx) error {
		legacyWS, _ := tx.Bucket(bucketEmbeddings).CreateBucketIfNotExists([]byte("ws"))
		if err := legacyWS.Put(uint64ToKey(42), legacyBytes); err != nil {
			return err
		}
		entityWS, _ := tx.Bucket(bucketEntityEmbeddings).CreateBucketIfNotExists([]byte("ws"))
		otherKey, _ := entityStorageKey(assetIdentity("ws", 42, 8))
		return entityWS.Put(otherKey, otherBytes)
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = NewStorage(dir)
	if err != nil {
		t.Fatalf("same ID in another room blocked migration: %v", err)
	}
	loaded, err := s.LoadAllEntityEmbeddings()
	if err != nil {
		t.Fatal(err)
	}
	if len(loaded) != 2 || loaded[assetIdentity("ws", 42, 7)].Preview != "legacy" || loaded[assetIdentity("ws", 42, 8)].Preview != "other-room" {
		t.Fatalf("loaded = %#v", loaded)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := NewStorage(dir)
	if err != nil {
		t.Fatalf("idempotent reopen: %v", err)
	}
	reopened.Close()

	conflictDir := t.TempDir()
	conflict, err := NewStorage(conflictDir)
	if err != nil {
		t.Fatal(err)
	}
	if err := conflict.db.Update(func(tx *bbolt.Tx) error {
		legacyWS, _ := tx.Bucket(bucketEmbeddings).CreateBucketIfNotExists([]byte("ws"))
		if err := legacyWS.Put(uint64ToKey(42), legacyBytes); err != nil {
			return err
		}
		entityWS, _ := tx.Bucket(bucketEntityEmbeddings).CreateBucketIfNotExists([]byte("ws"))
		key, _ := entityStorageKey(assetIdentity("ws", 42, 7))
		return entityWS.Put(key, otherBytes)
	}); err != nil {
		t.Fatal(err)
	}
	conflict.Close()
	if _, err := NewStorage(conflictDir); err == nil {
		t.Fatal("conflicting exact migration record was accepted")
	}
}

func TestEntityStorageRejectsMalformedRecords(t *testing.T) {
	s := newTestStorage(t)
	if err := s.db.Update(func(tx *bbolt.Tx) error {
		bucket, _ := tx.Bucket(bucketEntityEmbeddings).CreateBucketIfNotExists([]byte("ws"))
		return bucket.Put([]byte("bad-key"), []byte("bad-value"))
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.LoadAllEntityEmbeddings(); err == nil {
		t.Fatal("malformed typed record was skipped")
	}

	legacyDir := t.TempDir()
	legacy, err := NewStorage(legacyDir)
	if err != nil {
		t.Fatal(err)
	}
	if err := legacy.db.Update(func(tx *bbolt.Tx) error {
		bucket, _ := tx.Bucket(bucketEmbeddings).CreateBucketIfNotExists([]byte("ws"))
		return bucket.Put(uint64ToKey(1), bytes.Repeat([]byte{0xff}, 8))
	}); err != nil {
		t.Fatal(err)
	}
	legacy.Close()
	if _, err := NewStorage(legacyDir); err == nil {
		t.Fatal("corrupt legacy migration record was skipped")
	}

	malformedDir := t.TempDir()
	malformed, err := NewStorage(malformedDir)
	if err != nil {
		t.Fatal(err)
	}
	valid, _ := gobEncode(StoredEmbedding{ConvID: 7})
	if err := malformed.db.Update(func(tx *bbolt.Tx) error {
		bucket, _ := tx.Bucket(bucketEmbeddings).CreateBucketIfNotExists([]byte("ws"))
		return bucket.Put([]byte("short"), valid)
	}); err != nil {
		t.Fatal(err)
	}
	malformed.Close()
	if _, err := NewStorage(malformedDir); err == nil {
		t.Fatal("malformed legacy key was skipped")
	}
}

func TestSearchRequestBackwardCompatibilityAndConflicts(t *testing.T) {
	var legacy searchRequest
	if err := json.Unmarshal([]byte(`{"workspace":"ws","query":"needle","conv_id":"0","asset_types":[5]}`), &legacy); err != nil {
		t.Fatal(err)
	}
	if err := legacy.normalize(); err != nil {
		t.Fatalf("legacy request: %v", err)
	}
	if len(legacy.Filters.EntityTypes) != 1 || legacy.Filters.EntityTypes[0] != EntityTypeAsset || len(legacy.Filters.AssetTypes) != 1 || legacy.Filters.AssetTypes[0] != 5 {
		t.Fatalf("legacy filters normalized incorrectly: %#v", legacy.Filters)
	}

	var modern searchRequest
	if err := json.Unmarshal([]byte(`{"workspace":"ws","similar_entity":{"type":"task","id":"42","conv_id":"0"},"filters":{"entity_types":["task"]}}`), &modern); err != nil {
		t.Fatal(err)
	}
	if err := modern.normalize(); err != nil {
		t.Fatalf("modern request: %v", err)
	}
	if modern.SimilarEntity.EntityType != EntityTypeTask || modern.SimilarEntity.EntityID != 42 {
		t.Fatalf("modern seed = %#v", modern.SimilarEntity)
	}
	if modern.ConvID != 0 {
		t.Fatalf("modern top-level conv_id = %d, want 0", modern.ConvID)
	}
	var legacySimilar searchRequest
	if err := json.Unmarshal([]byte(`{"workspace":"ws","similar_asset_id":"42","conv_id":"0"}`), &legacySimilar); err != nil {
		t.Fatal(err)
	}
	if err := legacySimilar.normalize(); err != nil {
		t.Fatalf("legacy similarity request: %v", err)
	}
	if legacySimilar.SimilarEntity.EntityType != EntityTypeAsset || legacySimilar.SimilarEntity.EntityID != 42 || legacySimilar.SimilarEntity.ConvID != 0 {
		t.Fatalf("legacy seed = %#v", legacySimilar.SimilarEntity)
	}

	cases := []string{
		`{"workspace":"ws","query":"x","similar_asset_id":"1"}`,
		`{"workspace":"ws","similar_asset_id":"1","similar_entity":{"type":"asset","id":"1"}}`,
		`{"workspace":"ws","similar_asset_id":"0","similar_entity":{"type":"asset","id":"1"}}`,
		`{"workspace":"ws","query":"x","asset_types":[5],"filters":{"asset_types":[4]}}`,
		`{"workspace":"ws","query":"x","filters":{"entity_types":["bogus"]}}`,
		`{"workspace":"ws","similar_entity":{"workspace":"other","type":"task","id":"1"}}`,
		`{"workspace":"ws","conv_id":"7","similar_entity":{"type":"task","id":"1","conv_id":"8"}}`,
		`{"workspace":"ws","similar_entity":{"type":"task","id":"1","conv_id":"9223372036854775810"}}`,
		`{"workspace":"ws","query":"x","conv_id":"7"}`,
	}
	for _, raw := range cases {
		var req searchRequest
		if err := json.Unmarshal([]byte(raw), &req); err != nil {
			t.Fatalf("unmarshal %s: %v", raw, err)
		}
		if err := req.normalize(); err == nil {
			t.Errorf("normalize(%s) succeeded, want error", raw)
		}
	}
	var nestedRoom searchRequest
	if err := json.Unmarshal([]byte(`{"workspace":"ws","similar_entity":{"type":"task","id":"1"}}`), &nestedRoom); err != nil {
		t.Fatal(err)
	}
	if err := nestedRoom.normalize(); err != nil {
		t.Fatal(err)
	}
	if nestedRoom.ConvID != 0 {
		t.Fatalf("top-level conv_id = %d, want 0", nestedRoom.ConvID)
	}
}

func TestSearchRequestAllowsTaskFilterOnlyButKeepsLegacyQueryRequirement(t *testing.T) {
	taskOnly := searchRequest{Workspace: "ws", ConvID: 0, Filters: SearchFilters{EntityTypes: []EntityType{EntityTypeTask}, Task: &TaskFilters{Statuses: []uint8{protocol.TaskStatusDone}}}}
	if err := taskOnly.normalize(); err != nil {
		t.Fatalf("task filter-only request rejected: %v", err)
	}
	if len(taskOnly.Filters.Task.Statuses) != 1 || taskOnly.Filters.Task.Statuses[0] != protocol.TaskStatusDone {
		t.Fatalf("explicit Done status changed: %#v", taskOnly.Filters.Task)
	}
	defaultTask := searchRequest{Workspace: "ws", Query: "x", ConvID: 0, Filters: SearchFilters{EntityTypes: []EntityType{EntityTypeTask}}}
	if err := defaultTask.normalize(); err != nil {
		t.Fatal(err)
	}
	if len(defaultTask.Filters.Task.Statuses) != 4 || containsUint8(defaultTask.Filters.Task.Statuses, protocol.TaskStatusNote) {
		t.Fatalf("default task statuses should be active+Done only: %#v", defaultTask.Filters.Task.Statuses)
	}
	legacy := searchRequest{Workspace: "ws", ConvID: 0}
	if err := legacy.normalize(); err == nil {
		t.Fatal("legacy empty query unexpectedly accepted")
	}
	assetWithTaskFilter := searchRequest{Workspace: "ws", Query: "x", ConvID: 0, Filters: SearchFilters{
		EntityTypes: []EntityType{EntityTypeAsset}, Task: &TaskFilters{Statuses: []uint8{protocol.TaskStatusDone}},
	}}
	if err := assetWithTaskFilter.normalize(); err == nil {
		t.Fatal("task filters without task entity unexpectedly accepted")
	}
}

func TestSearchResultKeepsLegacyAssetFields(t *testing.T) {
	result := SearchResult{Entity: assetIdentity("ws", 9, 7), Metadata: SearchMetadata{AssetType: 5}, AssetID: 9, AssetType: 5, Preview: "note"}
	data, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["asset_id"] != "9" || decoded["asset_type"] != float64(5) {
		t.Fatalf("legacy fields missing: %s", data)
	}
	entity := decoded["entity"].(map[string]any)
	if entity["type"] != "asset" || entity["id"] != "9" || entity["workspace"] != "ws" {
		t.Fatalf("entity fields missing: %s", data)
	}
}

func TestTaskSearchResultOmitsLegacyAssetIdentityFields(t *testing.T) {
	result := SearchResult{Entity: taskIdentity("ws", 27, 7), Metadata: SearchMetadata{Task: &TaskMetadata{Status: protocol.TaskStatusDone}}, Preview: "task"}
	data, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if _, ok := decoded["asset_id"]; ok {
		t.Fatalf("task result contains asset_id: %s", data)
	}
	if _, ok := decoded["asset_type"]; ok {
		t.Fatalf("task result contains asset_type: %s", data)
	}
}
