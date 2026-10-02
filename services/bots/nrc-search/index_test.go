package main

import (
	"fmt"
	"math"
	"math/rand"
	"strings"
	"sync"
	"testing"

	"github.com/heavyhorst/nrc/protocol-go"
)

const testWorkspace = "test-ws"

func makeEntry(convID uint64, preview string) *IndexEntry {
	return &IndexEntry{
		Vector:      []float32{0.1, 0.2, 0.3},
		ContentHash: 12345,
		AssetType:   protocol.AssetTypeComment,
		ConvID:      convID,
		Preview:     preview,
		Payload:     "payload " + preview,
	}
}

func TestAddAndGet(t *testing.T) {
	idx := NewIndex()
	entry := makeEntry(100, "hello")
	idx.Add(testWorkspace, 1, entry)

	got, ok := idx.Get(testWorkspace, 1)
	if !ok {
		t.Fatal("expected entry to exist")
	}
	if got != entry {
		t.Fatal("expected same entry pointer")
	}
	if got.Preview != "hello" {
		t.Errorf("Preview = %q, want %q", got.Preview, "hello")
	}
	if got.ConvID != 100 {
		t.Errorf("ConvID = %d, want %d", got.ConvID, 100)
	}
}

func TestGetMissing(t *testing.T) {
	idx := NewIndex()

	_, ok := idx.Get(testWorkspace, 999)
	if ok {
		t.Fatal("expected ok=false for missing key")
	}
}

func TestRemove(t *testing.T) {
	idx := NewIndex()
	idx.Add(testWorkspace, 1, makeEntry(100, "a"))
	idx.Add(testWorkspace, 2, makeEntry(100, "b"))

	idx.Remove(testWorkspace, 1)

	if _, ok := idx.Get(testWorkspace, 1); ok {
		t.Fatal("expected entry 1 to be removed")
	}
	if _, ok := idx.Get(testWorkspace, 2); !ok {
		t.Fatal("expected entry 2 to still exist")
	}
}

func TestRemoveNonExistent(t *testing.T) {
	idx := NewIndex()
	idx.Add(testWorkspace, 1, makeEntry(100, "a"))

	idx.Remove(testWorkspace, 999) // should not panic

	if idx.Count() != 1 {
		t.Errorf("Count = %d, want 1", idx.Count())
	}
}

func TestCount(t *testing.T) {
	idx := NewIndex()

	if idx.Count() != 0 {
		t.Errorf("empty index Count = %d, want 0", idx.Count())
	}

	idx.Add(testWorkspace, 1, makeEntry(100, "a"))
	idx.Add(testWorkspace, 2, makeEntry(200, "b"))
	idx.Add(testWorkspace, 3, makeEntry(100, "c"))

	if idx.Count() != 3 {
		t.Errorf("Count = %d, want 3", idx.Count())
	}
}

func TestCountForRoom(t *testing.T) {
	idx := NewIndex()
	idx.Add(testWorkspace, 1, makeEntry(100, "a"))
	idx.Add(testWorkspace, 2, makeEntry(200, "b"))
	idx.Add(testWorkspace, 3, makeEntry(100, "c"))
	idx.Add(testWorkspace, 4, makeEntry(300, "d"))

	tests := []struct {
		name   string
		convID uint64
		want   int
	}{
		{"room with 2 entries", 100, 2},
		{"room with 1 entry", 200, 1},
		{"room with 1 entry", 300, 1},
		{"room with 0 entries", 999, 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := idx.CountForRoom(testWorkspace, tt.convID)
			if got != tt.want {
				t.Errorf("CountForRoom(%d) = %d, want %d", tt.convID, got, tt.want)
			}
		})
	}
}

func TestRemoveByConvID(t *testing.T) {
	idx := NewIndex()
	idx.Add(testWorkspace, 1, makeEntry(100, "a"))
	idx.Add(testWorkspace, 2, makeEntry(200, "b"))
	idx.Add(testWorkspace, 3, makeEntry(100, "c"))
	idx.Add(testWorkspace, 4, makeEntry(300, "d"))

	idx.RemoveByConvID(testWorkspace, 100)

	if _, ok := idx.Get(testWorkspace, 1); ok {
		t.Fatal("entry 1 (convID=100) should be removed")
	}
	if _, ok := idx.Get(testWorkspace, 3); ok {
		t.Fatal("entry 3 (convID=100) should be removed")
	}
	if _, ok := idx.Get(testWorkspace, 2); !ok {
		t.Fatal("entry 2 (convID=200) should still exist")
	}
	if _, ok := idx.Get(testWorkspace, 4); !ok {
		t.Fatal("entry 4 (convID=300) should still exist")
	}
	if idx.Count() != 2 {
		t.Errorf("Count = %d, want 2", idx.Count())
	}
}

func TestRemoveByConvIDNoMatch(t *testing.T) {
	idx := NewIndex()
	idx.Add(testWorkspace, 1, makeEntry(100, "a"))
	idx.Add(testWorkspace, 2, makeEntry(200, "b"))

	idx.RemoveByConvID(testWorkspace, 999)

	if idx.Count() != 2 {
		t.Errorf("Count = %d, want 2 after removing non-existent convID", idx.Count())
	}
}

func TestAddOverwrite(t *testing.T) {
	idx := NewIndex()
	idx.Add(testWorkspace, 1, makeEntry(100, "original"))
	idx.Add(testWorkspace, 1, makeEntry(200, "updated"))

	got, ok := idx.Get(testWorkspace, 1)
	if !ok {
		t.Fatal("expected entry to exist")
	}
	if got.Preview != "updated" {
		t.Errorf("Preview = %q, want %q", got.Preview, "updated")
	}
	if got.ConvID != 200 {
		t.Errorf("ConvID = %d, want %d", got.ConvID, 200)
	}
	if idx.Count() != 1 {
		t.Errorf("Count = %d, want 1 after overwrite", idx.Count())
	}
}

func TestLoadFromStorage(t *testing.T) {
	dir := t.TempDir()
	storage, err := NewStorage(dir)
	if err != nil {
		t.Fatalf("NewStorage: %v", err)
	}
	defer storage.Close()

	ws := "load-test-ws"
	embeddings := []struct {
		assetID uint64
		emb     StoredEmbedding
	}{
		{
			assetID: 10,
			emb: StoredEmbedding{
				ConvID:      100,
				ContentHash: 111,
				Vector:      []float32{0.1, 0.2, 0.3},
				AssetType:   protocol.AssetTypeComment,
				Preview:     "first",
			},
		},
		{
			assetID: 20,
			emb: StoredEmbedding{
				ConvID:      200,
				ContentHash: 222,
				Vector:      []float32{0.4, 0.5, 0.6},
				AssetType:   protocol.AssetTypeDocument,
				Preview:     "second",
			},
		},
		{
			assetID: 30,
			emb: StoredEmbedding{
				ConvID:      100,
				ContentHash: 333,
				Vector:      []float32{0.7, 0.8, 0.9},
				AssetType:   protocol.AssetTypeFile,
				Preview:     "third",
			},
		},
	}

	for _, e := range embeddings {
		if err := storage.StoreEmbedding(ws, e.assetID, e.emb); err != nil {
			t.Fatalf("StoreEmbedding(%d): %v", e.assetID, err)
		}
	}

	idx := NewIndex()
	allEmbs, err := storage.LoadAllEmbeddingsAllWorkspaces()
	if err != nil {
		t.Fatalf("LoadAllEmbeddingsAllWorkspaces: %v", err)
	}
	for w, embs := range allEmbs {
		for assetID, emb := range embs {
			idx.Add(w, assetID, &IndexEntry{
				Vector:      emb.Vector,
				ContentHash: emb.ContentHash,
				AssetType:   emb.AssetType,
				ConvID:      emb.ConvID,
				Preview:     emb.Preview,
			})
		}
	}

	if idx.Count() != 3 {
		t.Errorf("Count = %d, want 3", idx.Count())
	}

	for _, e := range embeddings {
		got, ok := idx.Get(ws, e.assetID)
		if !ok {
			t.Errorf("missing entry for assetID %d", e.assetID)
			continue
		}
		if got.ConvID != e.emb.ConvID {
			t.Errorf("assetID %d: ConvID = %d, want %d", e.assetID, got.ConvID, e.emb.ConvID)
		}
		if got.ContentHash != e.emb.ContentHash {
			t.Errorf("assetID %d: ContentHash = %d, want %d", e.assetID, got.ContentHash, e.emb.ContentHash)
		}
		if got.AssetType != e.emb.AssetType {
			t.Errorf("assetID %d: AssetType = %d, want %d", e.assetID, got.AssetType, e.emb.AssetType)
		}
		if got.Preview != e.emb.Preview {
			t.Errorf("assetID %d: Preview = %q, want %q", e.assetID, got.Preview, e.emb.Preview)
		}
		if len(got.Vector) != len(e.emb.Vector) {
			t.Errorf("assetID %d: Vector len = %d, want %d", e.assetID, len(got.Vector), len(e.emb.Vector))
		}
	}

	if idx.CountForRoom(ws, 100) != 2 {
		t.Errorf("CountForRoom(100) = %d, want 2", idx.CountForRoom(ws, 100))
	}
	if idx.CountForRoom(ws, 200) != 1 {
		t.Errorf("CountForRoom(200) = %d, want 1", idx.CountForRoom(ws, 200))
	}
}

func TestLoadFromStorageEmpty(t *testing.T) {
	dir := t.TempDir()
	storage, err := NewStorage(dir)
	if err != nil {
		t.Fatalf("NewStorage: %v", err)
	}
	defer storage.Close()

	idx := NewIndex()
	allEmbs, err := storage.LoadAllEmbeddingsAllWorkspaces()
	if err != nil {
		t.Fatalf("LoadAllEmbeddingsAllWorkspaces: %v", err)
	}
	for w, embs := range allEmbs {
		for assetID, emb := range embs {
			idx.Add(w, assetID, &IndexEntry{
				Vector:      emb.Vector,
				ContentHash: emb.ContentHash,
				AssetType:   emb.AssetType,
				ConvID:      emb.ConvID,
				Preview:     emb.Preview,
			})
		}
	}

	if idx.Count() != 0 {
		t.Errorf("Count = %d, want 0", idx.Count())
	}
}

func TestConcurrentAccess(t *testing.T) {
	idx := NewIndex()
	const goroutines = 50
	const opsPerGoroutine = 100

	var wg sync.WaitGroup
	wg.Add(goroutines * 3)

	// Writers: Add entries
	for g := 0; g < goroutines; g++ {
		go func(base uint64) {
			defer wg.Done()
			for i := uint64(0); i < opsPerGoroutine; i++ {
				idx.Add(testWorkspace, base+i, makeEntry(base, "entry"))
			}
		}(uint64(g) * opsPerGoroutine)
	}

	// Readers: Get entries
	for g := 0; g < goroutines; g++ {
		go func(base uint64) {
			defer wg.Done()
			for i := uint64(0); i < opsPerGoroutine; i++ {
				idx.Get(testWorkspace, base+i)
			}
		}(uint64(g) * opsPerGoroutine)
	}

	// Removers: Remove entries
	for g := 0; g < goroutines; g++ {
		go func(base uint64) {
			defer wg.Done()
			for i := uint64(0); i < opsPerGoroutine; i++ {
				idx.Remove(testWorkspace, base+i)
			}
		}(uint64(g) * opsPerGoroutine)
	}

	wg.Wait()
}

func TestConcurrentCountAndRemoveByConvID(t *testing.T) {
	idx := NewIndex()

	for i := uint64(0); i < 200; i++ {
		convID := i % 5
		idx.Add(testWorkspace, i, makeEntry(convID, "entry"))
	}

	var wg sync.WaitGroup
	wg.Add(3)

	go func() {
		defer wg.Done()
		for i := 0; i < 100; i++ {
			idx.Count()
		}
	}()

	go func() {
		defer wg.Done()
		for i := 0; i < 100; i++ {
			idx.CountForRoom(testWorkspace, uint64(i%5))
		}
	}()

	go func() {
		defer wg.Done()
		idx.RemoveByConvID(testWorkspace, 2)
	}()

	wg.Wait()
}

func TestSearchParallelEmpty(t *testing.T) {
	idx := NewIndex()

	results, err := idx.SearchParallel("test-ws", "query", nil, 100, 10, nil, 4)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(results) != 0 {
		t.Errorf("expected 0 results for empty index, got %d", len(results))
	}
}

func TestSearchParallelBasic(t *testing.T) {
	idx := NewIndex()

	vec := []float32{0.5, 0.5, 0.5, 0.5}
	for i := 0; i < 100; i++ {
		idx.Add("test-ws", uint64(i+1), &IndexEntry{
			Vector:    vec,
			ConvID:    100,
			AssetType: protocol.AssetTypeDocument,
			Preview:   "test document",
			Payload:   "test document content",
		})
	}

	_, err := idx.SearchParallel("test-ws", "test", nil, 100, 10, nil, 4)
	if err == nil {
		t.Fatal("expected error for nil embedder, got nil")
	}
}

func TestSearchParalleEquality(t *testing.T) {
	rng := rand.New(rand.NewSource(42))
	vectorDim := 768

	idx := NewIndex()
	for i := 0; i < 1000; i++ {
		vec := make([]float32, vectorDim)
		var sum float32
		for j := range vec {
			vec[j] = rng.Float32()*2 - 1
			sum += vec[j] * vec[j]
		}
		if sum > 0 {
			norm := float32(1.0 / float64(sum))
			for j := range vec {
				vec[j] *= norm
			}
		}

		text := fmt.Sprintf("document %d with some content about topics", i)
		idx.Add("test-ws", uint64(i+1), &IndexEntry{
			Vector:    vec,
			ConvID:    100,
			AssetType: protocol.AssetTypeDocument,
			Preview:   text,
			Payload:   text,
		})
	}

	queryVec := make([]float32, vectorDim)
	var sum float32
	for i := range queryVec {
		queryVec[i] = rng.Float32()*2 - 1
		sum += queryVec[i] * queryVec[i]
	}
	if sum > 0 {
		norm := float32(1.0 / float64(sum))
		for i := range queryVec {
			queryVec[i] *= norm
		}
	}

	mockEmb := &mockEmbedderForTest{vec: queryVec}

	seqResults, err := idx.Search("test-ws", "document", mockEmb, 100, 10, nil)
	if err != nil {
		t.Fatalf("sequential search error: %v", err)
	}

	parResults, err := idx.SearchParallel("test-ws", "document", mockEmb, 100, 10, nil, 4)
	if err != nil {
		t.Fatalf("parallel search error: %v", err)
	}

	if len(seqResults) != len(parResults) {
		t.Errorf("result count mismatch: seq=%d, par=%d", len(seqResults), len(parResults))
	}

	for i := range seqResults {
		if seqResults[i].AssetID != parResults[i].AssetID {
			t.Errorf("result %d: assetID mismatch seq=%d, par=%d", i, seqResults[i].AssetID, parResults[i].AssetID)
		}
		if math.Abs(seqResults[i].Score-parResults[i].Score) > 1e-10 {
			t.Errorf("result %d: score mismatch seq=%f, par=%f", i, seqResults[i].Score, parResults[i].Score)
		}
	}
}

func TestSearchParallelWorkerCount(t *testing.T) {
	idx := NewIndex()
	vec := []float32{0.5, 0.5}

	for i := 0; i < 10; i++ {
		idx.Add("test-ws", uint64(i+1), &IndexEntry{
			Vector:    vec,
			ConvID:    100,
			AssetType: protocol.AssetTypeDocument,
			Preview:   "test",
			Payload:   "test",
		})
	}

	queryVec := []float32{0.5, 0.5}
	mockEmb := &mockEmbedderForTest{vec: queryVec}

	tests := []struct {
		name    string
		workers int
	}{
		{"zero workers", 0},
		{"negative workers", -1},
		{"one worker", 1},
		{"two workers", 2},
		{"more workers than docs", 100},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			results, err := idx.SearchParallel("test-ws", "test", mockEmb, 100, 5, nil, tt.workers)
			if err != nil {
				t.Errorf("unexpected error: %v", err)
			}
			if len(results) == 0 {
				t.Errorf("expected results, got 0")
			}
		})
	}
}

func TestSearchParallelAssetTypeFilter(t *testing.T) {
	idx := NewIndex()
	vec := []float32{0.5, 0.5}

	idx.Add("test-ws", 1, &IndexEntry{Vector: vec, ConvID: 100, AssetType: protocol.AssetTypeComment, Preview: "comment", Payload: "comment"})
	idx.Add("test-ws", 2, &IndexEntry{Vector: vec, ConvID: 100, AssetType: protocol.AssetTypeDocument, Preview: "document", Payload: "document"})
	idx.Add("test-ws", 3, &IndexEntry{Vector: vec, ConvID: 100, AssetType: protocol.AssetTypeNote, Preview: "note", Payload: "note"})

	queryVec := []float32{0.5, 0.5}
	mockEmb := &mockEmbedderForTest{vec: queryVec}

	results, err := idx.SearchParallel("test-ws", "test", mockEmb, 100, 10, []uint16{protocol.AssetTypeDocument, protocol.AssetTypeNote}, 2)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	for _, r := range results {
		entry, _ := idx.Get("test-ws", r.AssetID)
		if entry.AssetType == protocol.AssetTypeComment {
			t.Errorf("comment should be filtered out, got asset %d", r.AssetID)
		}
	}
}

func TestSearchUsesBestChunkSimilarity(t *testing.T) {
	idx := NewIndex()
	queryVec := []float32{1, 0}

	idx.Add("test-ws", 1, &IndexEntry{
		Vector:    []float32{0, 1},
		Chunks:    []IndexChunk{{Index: 0, Vector: []float32{0, 1}}, {Index: 1, Vector: []float32{1, 0}}},
		ConvID:    100,
		AssetType: protocol.AssetTypeDocument,
		Preview:   "late relevant section",
		Payload:   "late relevant section",
	})
	idx.Add("test-ws", 2, &IndexEntry{
		Vector:    []float32{0.8, 0.2},
		ConvID:    100,
		AssetType: protocol.AssetTypeDocument,
		Preview:   "single vector competitor",
		Payload:   "single vector competitor",
	})

	results, err := idx.SearchParallel("test-ws", "semantic query", &mockEmbedderForTest{vec: queryVec}, 100, 2, nil, 1)
	if err != nil {
		t.Fatalf("SearchParallel: %v", err)
	}
	if len(results) == 0 {
		t.Fatal("expected results")
	}
	if results[0].AssetID != 1 {
		t.Fatalf("top result asset_id=%d, want 1; results=%+v", results[0].AssetID, results)
	}
}

type mockEmbedderForTest struct {
	vec []float32
}

func (m *mockEmbedderForTest) Embed(text string) ([]float32, error) {
	return m.vec, nil
}

func (m *mockEmbedderForTest) Close() {}

func TestBigramBloom_EmptyAndShort(t *testing.T) {
	if b := BigramBloom(""); b != 0 {
		t.Errorf("empty string: got %d, want 0", b)
	}
	if b := BigramBloom("x"); b != 0 {
		t.Errorf("single char: got %d, want 0", b)
	}
	if b := BigramBloom("ab"); b == 0 {
		t.Error("two chars: expected non-zero bloom")
	}
}

func TestBigramBloom_Superset(t *testing.T) {
	tests := []struct {
		haystack string
		needle   string
	}{
		{"hello world", "hello"},
		{"hello world", "llo w"},
		{"hello world", "world"},
		{"abcdefghij", "cdef"},
		{"the quick brown fox", "quick brown"},
		{"the quick brown fox", "fox"},
	}

	for _, tt := range tests {
		hb := BigramBloom(tt.haystack)
		nb := BigramBloom(tt.needle)
		if hb&nb != nb {
			t.Errorf("BigramBloom(%q) & BigramBloom(%q) != BigramBloom(%q): haystack=%064b needle=%064b",
				tt.haystack, tt.needle, tt.needle, hb, nb)
		}
	}
}

func TestBigramBloom_Rejection(t *testing.T) {
	tests := []struct {
		text  string
		query string
	}{
		{"abcdef", "xyz"},
		{"aaaaaa", "zz"},
		{"hello", "qw"},
		{"mnopqr", "zy"},
	}

	for _, tt := range tests {
		tb := BigramBloom(tt.text)
		qb := BigramBloom(tt.query)
		if tb&qb == qb {
			t.Errorf("expected bloom rejection for text=%q query=%q but bloom passed", tt.text, tt.query)
		}
	}
}

func TestBigramBloom_NoFalseNegatives(t *testing.T) {
	rng := rand.New(rand.NewSource(12345))
	const iterations = 2000

	for i := 0; i < iterations; i++ {
		hLen := rng.Intn(50) + 4
		haystack := make([]byte, hLen)
		for j := range haystack {
			haystack[j] = byte('a' + rng.Intn(26))
		}

		nLen := rng.Intn(hLen-2) + 2 // [2, hLen-1] so hLen-nLen >= 1
		start := rng.Intn(hLen - nLen + 1)
		needle := string(haystack[start : start+nLen])

		hb := BigramBloom(string(haystack))
		nb := BigramBloom(needle)
		if hb&nb != nb {
			t.Fatalf("false negative: haystack=%q needle=%q (iter %d)", string(haystack), needle, i)
		}
	}
}

func TestSearchWithBloom(t *testing.T) {
	idx := NewIndex()
	vec := []float32{0.5, 0.5}

	entries := []struct {
		id      uint64
		preview string
		payload string
	}{
		{1, "meeting notes from monday", "meeting notes from monday morning standup"},
		{2, "grocery list for the week", "grocery list for the week with items"},
		{3, "project design document", "project design document with architecture details"},
		{4, "random unrelated text", "random unrelated text about nothing"},
	}

	for _, e := range entries {
		bloom := BigramBloom(strings.ToLower(e.payload)) | BigramBloom(strings.ToLower(e.preview))
		idx.Add("test-ws", e.id, &IndexEntry{
			Vector:    vec,
			ConvID:    100,
			AssetType: protocol.AssetTypeDocument,
			Preview:   strings.ToLower(e.preview),
			Payload:   strings.ToLower(e.payload),
			Bloom:     bloom,
		})
	}

	mockEmb := &mockEmbedderForTest{vec: vec}

	results, err := idx.SearchParallel("test-ws", "meeting", mockEmb, 100, 10, nil, 2)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	foundMeeting := false
	for _, r := range results {
		if r.AssetID == 1 {
			foundMeeting = true
		}
	}
	if !foundMeeting {
		t.Error("expected to find 'meeting' entry in results, bloom may have incorrectly filtered it")
	}

	results2, err := idx.SearchParallel("test-ws", "grocery", mockEmb, 100, 10, nil, 2)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	foundGrocery := false
	for _, r := range results2 {
		if r.AssetID == 2 {
			foundGrocery = true
		}
	}
	if !foundGrocery {
		t.Error("expected to find 'grocery' entry in results, bloom may have incorrectly filtered it")
	}
}
