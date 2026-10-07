package main

import (
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/viterin/vek/vek32"
)

var ErrSeedNotIndexed = errors.New("seed entity not indexed")

type Index struct {
	mu       sync.RWMutex
	entries  map[string]map[entityKey]*IndexEntry
	byConvID map[string]map[uint64]map[entityKey]struct{}
	storage  *Storage
}

func NewIndex() *Index {
	return &Index{
		entries:  make(map[string]map[entityKey]*IndexEntry),
		byConvID: make(map[string]map[uint64]map[entityKey]struct{}),
	}
}

func (idx *Index) Add(workspace string, assetID uint64, entry *IndexEntry) {
	identity := assetIdentity(workspace, assetID, entry.ConvID)
	idx.Remove(workspace, assetID)
	_ = idx.AddEntity(identity, entry)
}

func (idx *Index) AddEntity(identity EntityIdentity, entry *IndexEntry) error {
	if err := identity.Validate(); err != nil {
		return err
	}
	if entry == nil {
		return fmt.Errorf("index entry is required")
	}
	if identity.ConvID != entry.ConvID {
		return fmt.Errorf("entity conv_id %d conflicts with entry conv_id %d", identity.ConvID, entry.ConvID)
	}
	if entry.PreviewLower == "" && entry.Preview != "" {
		entry.PreviewLower = strings.ToLower(entry.Preview)
	}
	if entry.PayloadLower == "" && entry.Payload != "" {
		entry.PayloadLower = strings.ToLower(searchableAssetContent(entry.AssetType, entry.Preview, entry.Payload))
	}
	entry.Bloom = BigramBloom(entry.PayloadLower) | BigramBloom(entry.PreviewLower)
	idx.mu.Lock()
	defer idx.mu.Unlock()
	ws := idx.entries[identity.Workspace]
	if ws == nil {
		ws = make(map[entityKey]*IndexEntry)
		idx.entries[identity.Workspace] = ws
	}
	key := identity.key()
	ws[key] = entry

	// Maintain secondary index.
	wsConv := idx.byConvID[identity.Workspace]
	if wsConv == nil {
		wsConv = make(map[uint64]map[entityKey]struct{})
		idx.byConvID[identity.Workspace] = wsConv
	}
	convSet := wsConv[entry.ConvID]
	if convSet == nil {
		convSet = make(map[entityKey]struct{})
		wsConv[entry.ConvID] = convSet
	}
	convSet[key] = struct{}{}
	return nil
}

func (idx *Index) Remove(workspace string, assetID uint64) {
	idx.mu.Lock()
	defer idx.mu.Unlock()
	ws := idx.entries[workspace]
	for key, entry := range ws {
		if key.EntityType != EntityTypeAsset || key.EntityID != assetID {
			continue
		}
		if convSet := idx.byConvID[workspace][entry.ConvID]; convSet != nil {
			delete(convSet, key)
			if len(convSet) == 0 {
				delete(idx.byConvID[workspace], entry.ConvID)
			}
		}
		delete(ws, key)
	}
}

func (idx *Index) RemoveEntity(identity EntityIdentity) {
	idx.mu.Lock()
	defer idx.mu.Unlock()
	if ws := idx.entries[identity.Workspace]; ws != nil {
		key := identity.key()
		if entry, ok := ws[key]; ok {
			if convSet := idx.byConvID[identity.Workspace][entry.ConvID]; convSet != nil {
				delete(convSet, key)
				if len(convSet) == 0 {
					delete(idx.byConvID[identity.Workspace], entry.ConvID)
				}
			}
			delete(ws, key)
		}
	}
}

func (idx *Index) Get(workspace string, assetID uint64) (*IndexEntry, bool) {
	idx.mu.RLock()
	defer idx.mu.RUnlock()
	for key, entry := range idx.entries[workspace] {
		if key.EntityType == EntityTypeAsset && key.EntityID == assetID {
			return entry, true
		}
	}
	return nil, false
}

func (idx *Index) GetEntity(identity EntityIdentity) (*IndexEntry, bool) {
	idx.mu.RLock()
	defer idx.mu.RUnlock()
	ws := idx.entries[identity.Workspace]
	if ws == nil {
		return nil, false
	}
	entry, ok := ws[identity.key()]
	return entry, ok
}

func (idx *Index) UpdateEntityMetadata(identity EntityIdentity, metadata SearchMetadata, indexedAt time.Time) (*IndexEntry, bool) {
	idx.mu.Lock()
	defer idx.mu.Unlock()
	entry, ok := idx.entries[identity.Workspace][identity.key()]
	if !ok {
		return nil, false
	}
	updated := *entry
	updated.Metadata = metadata
	updated.IndexedAt = indexedAt
	idx.entries[identity.Workspace][identity.key()] = &updated
	return &updated, true
}

func (idx *Index) Count() int {
	idx.mu.RLock()
	defer idx.mu.RUnlock()
	total := 0
	for _, ws := range idx.entries {
		total += len(ws)
	}
	return total
}

func (idx *Index) CountForWorkspace(workspace string) int {
	idx.mu.RLock()
	defer idx.mu.RUnlock()
	return len(idx.entries[workspace])
}

func (idx *Index) CountForRoom(workspace string, convID uint64) int {
	idx.mu.RLock()
	defer idx.mu.RUnlock()
	return len(idx.byConvID[workspace][convID])
}

func (idx *Index) RemoveByConvID(workspace string, convID uint64) {
	idx.mu.Lock()
	defer idx.mu.Unlock()
	ws := idx.entries[workspace]
	convSet := idx.byConvID[workspace][convID]
	for key := range convSet {
		delete(ws, key)
	}
	delete(idx.byConvID[workspace], convID)
}

// StaleAssetIDs returns asset IDs for a given convID that are not in serverIDs
// and were indexed before the given cutoff time.
func (idx *Index) StaleAssetIDs(workspace string, convID uint64, serverIDs map[uint64]struct{}, indexedBefore time.Time) []uint64 {
	idx.mu.RLock()
	defer idx.mu.RUnlock()

	wsEntries := idx.entries[workspace]
	if wsEntries == nil {
		return nil
	}

	convSet := idx.byConvID[workspace][convID]
	var stale []uint64
	for key := range convSet {
		if key.EntityType != EntityTypeAsset {
			continue
		}
		e := wsEntries[key]
		if e == nil {
			continue
		}
		if !e.IndexedAt.IsZero() && e.IndexedAt.After(indexedBefore) {
			continue
		}
		if _, exists := serverIDs[key.EntityID]; !exists {
			stale = append(stale, key.EntityID)
		}
	}
	return stale
}

func (idx *Index) StaleEntityIdentities(workspace string, convID uint64, entityType EntityType, serverIDs map[uint64]struct{}, indexedBefore time.Time) []EntityIdentity {
	idx.mu.RLock()
	defer idx.mu.RUnlock()

	wsEntries := idx.entries[workspace]
	convSet := idx.byConvID[workspace][convID]
	var stale []EntityIdentity
	for key := range convSet {
		if key.EntityType != entityType {
			continue
		}
		entry := wsEntries[key]
		if entry == nil || (!indexedBefore.IsZero() && !entry.IndexedAt.IsZero() && entry.IndexedAt.After(indexedBefore)) {
			continue
		}
		if _, exists := serverIDs[key.EntityID]; !exists {
			stale = append(stale, EntityIdentity{Workspace: workspace, EntityType: entityType, EntityID: key.EntityID, ConvID: convID})
		}
	}
	return stale
}

type candidate struct {
	identity EntityIdentity
	assetID  uint64 // legacy asset-only algorithms and benchmarks
	entry    *IndexEntry
}

type vectorItem struct {
	assetID uint64
	vector  []float32
}

func (idx *Index) CollectVectors(workspace string, convID uint64, assetTypes []uint16, assetIDs []uint64) []vectorItem {
	typeFilter := make(map[uint16]struct{}, len(assetTypes))
	for _, t := range assetTypes {
		typeFilter[t] = struct{}{}
	}

	isZeroNorm := func(v []float32) bool {
		var sum float32
		for _, x := range v {
			sum += x * x
		}
		return sum == 0
	}

	idx.mu.RLock()
	defer idx.mu.RUnlock()

	wsEntries := idx.entries[workspace]
	if wsEntries == nil {
		return nil
	}

	out := make([]vectorItem, 0, 256)

	// Explicit asset list: use it (stable + bounded from client graph).
	if len(assetIDs) > 0 {
		out = make([]vectorItem, 0, len(assetIDs))
		for _, assetID := range assetIDs {
			e := wsEntries[assetIdentity(workspace, assetID, convID).key()]
			if e == nil {
				continue
			}
			if len(typeFilter) > 0 {
				if _, ok := typeFilter[e.AssetType]; !ok {
					continue
				}
			}
			if len(e.Vector) == 0 {
				continue
			}
			if isZeroNorm(e.Vector) {
				continue
			}
			out = append(out, vectorItem{assetID: assetID, vector: e.Vector})
		}
		return out
	}

	// No explicit list: walk the room set.
	convSet := idx.byConvID[workspace][convID]
	if len(convSet) == 0 {
		return nil
	}
	out = make([]vectorItem, 0, len(convSet))
	for key := range convSet {
		if key.EntityType != EntityTypeAsset {
			continue
		}
		e := wsEntries[key]
		if e == nil {
			continue
		}
		if len(typeFilter) > 0 {
			if _, ok := typeFilter[e.AssetType]; !ok {
				continue
			}
		}
		if len(e.Vector) == 0 {
			continue
		}
		if isZeroNorm(e.Vector) {
			continue
		}
		out = append(out, vectorItem{assetID: key.EntityID, vector: e.Vector})
	}
	return out
}

type scoredCandidate struct {
	identity   EntityIdentity
	assetID    uint64
	similarity float32
	preview    string
	assetType  uint16
	payload    string
	metadata   SearchMetadata
}

func indexChunksFromStored(chunks []StoredChunkEmbedding) []IndexChunk {
	if len(chunks) == 0 {
		return nil
	}
	out := make([]IndexChunk, len(chunks))
	for i, chunk := range chunks {
		out[i] = IndexChunk{Index: chunk.Index, Vector: chunk.Vector}
	}
	return out
}

func storedChunksFromIndex(chunks []IndexChunk) []StoredChunkEmbedding {
	if len(chunks) == 0 {
		return nil
	}
	out := make([]StoredChunkEmbedding, len(chunks))
	for i, chunk := range chunks {
		out[i] = StoredChunkEmbedding{Index: chunk.Index, Vector: chunk.Vector}
	}
	return out
}

func aggregateChunkVectors(chunks []IndexChunk) []float32 {
	if len(chunks) == 0 || len(chunks[0].Vector) == 0 {
		return nil
	}
	dim := len(chunks[0].Vector)
	vec := make([]float32, dim)
	count := 0
	for _, chunk := range chunks {
		if len(chunk.Vector) != dim {
			continue
		}
		for i, v := range chunk.Vector {
			vec[i] += v
		}
		count++
	}
	if count == 0 {
		return nil
	}
	inv := float32(1.0 / float64(count))
	for i := range vec {
		vec[i] *= inv
	}
	normalize(vec)
	return vec
}

func bestVectorSimilarity(queryVec []float32, entry *IndexEntry) float32 {
	if entry == nil {
		return 0
	}
	if len(entry.Chunks) == 0 {
		return vek32.CosineSimilarity(queryVec, entry.Vector)
	}
	best := float32(-2)
	for _, chunk := range entry.Chunks {
		if len(chunk.Vector) == 0 {
			continue
		}
		sim := vek32.CosineSimilarity(queryVec, chunk.Vector)
		if sim > best {
			best = sim
		}
	}
	if best == -2 {
		return vek32.CosineSimilarity(queryVec, entry.Vector)
	}
	return best
}

type textCandidate struct {
	identity  EntityIdentity
	assetID   uint64
	count     int
	exact     bool
	preview   string
	assetType uint16
	payload   string
	metadata  SearchMetadata
}

type fusedResult struct {
	identity   EntityIdentity
	assetID    uint64
	score      float64
	similarity float32
	preview    string
	assetType  uint16
	payload    string
	metadata   SearchMetadata
}

func containsUint8(values []uint8, value uint8) bool {
	for _, candidate := range values {
		if candidate == value {
			return true
		}
	}
	return false
}

func containsUint64(values []uint64, value uint64) bool {
	for _, candidate := range values {
		if candidate == value {
			return true
		}
	}
	return false
}

func containsFold(values []string, value string) bool {
	value = strings.TrimSpace(value)
	for _, candidate := range values {
		if strings.EqualFold(strings.TrimSpace(candidate), value) {
			return true
		}
	}
	return false
}

func matchesTaskFilters(key entityKey, entry *IndexEntry, filters *TaskFilters) bool {
	if filters == nil || filters.Empty() {
		return true
	}
	if entry == nil || entry.Metadata.Task == nil {
		return false
	}
	task := entry.Metadata.Task
	return (len(filters.Statuses) == 0 || containsUint8(filters.Statuses, task.Status)) &&
		(len(filters.Assignees) == 0 || containsFold(filters.Assignees, task.Assignee)) &&
		(len(filters.Projects) == 0 || containsFold(filters.Projects, task.Project)) &&
		(len(filters.Priorities) == 0 || containsUint8(filters.Priorities, task.Priority)) &&
		(len(filters.Colors) == 0 || containsUint8(filters.Colors, task.Color)) &&
		(len(filters.CreatedBy) == 0 || containsFold(filters.CreatedBy, task.CreatedBy)) &&
		(len(filters.CompletedBy) == 0 || containsFold(filters.CompletedBy, task.CompletedBy)) &&
		(len(filters.TaskIDs) == 0 || containsUint64(filters.TaskIDs, key.EntityID)) &&
		(len(filters.ExternalRefs) == 0 || containsFold(filters.ExternalRefs, task.ExternalRef)) &&
		(filters.Blocked == nil || *filters.Blocked == (task.BlockedBy != 0)) &&
		(len(filters.BlockedBy) == 0 || containsUint64(filters.BlockedBy, task.BlockedBy)) &&
		(filters.OverdueBefore == nil || (task.DueAt > 0 && task.Status != protocol.TaskStatusDone && task.DueAt < *filters.OverdueBefore))
}

func (idx *Index) collectCandidates(workspace string, convID uint64, filters SearchFilters) []candidate {
	idx.mu.RLock()
	storage := idx.storage
	var customerIDs []uint64
	for key := range idx.byConvID[workspace][convID] {
		if key.EntityType != EntityTypeAsset || (len(filters.EntityTypes) > 0 && !slices.Contains(filters.EntityTypes, EntityTypeAsset)) {
			continue
		}
		entry := idx.entries[workspace][key]
		if entry.AssetType != protocol.AssetTypeCustomerCompany || (len(filters.AssetTypes) > 0 && !slices.Contains(filters.AssetTypes, entry.AssetType)) {
			continue
		}
		customerIDs = append(customerIDs, key.EntityID)
	}
	idx.mu.RUnlock()
	var inventory customerInventory
	if storage != nil && len(customerIDs) > 0 {
		var err error
		inventory.Assets, err = storage.customerAssets(workspace, convID, customerIDs)
		if err != nil {
			slog.Error("read customer inventory", "error", err)
		}
	}
	idx.mu.RLock()
	defer idx.mu.RUnlock()

	convSet := idx.byConvID[workspace][convID]
	if len(convSet) == 0 {
		return nil
	}
	wsEntries := idx.entries[workspace]
	candidates := make([]candidate, 0, len(convSet))
	entityTypes := make(map[EntityType]struct{}, len(filters.EntityTypes))
	for _, typ := range filters.EntityTypes {
		entityTypes[typ] = struct{}{}
	}
	assetTypes := make(map[uint16]struct{}, len(filters.AssetTypes))
	for _, typ := range filters.AssetTypes {
		assetTypes[typ] = struct{}{}
	}
	for key := range convSet {
		if len(entityTypes) > 0 {
			if _, ok := entityTypes[key.EntityType]; !ok {
				continue
			}
		}
		e := wsEntries[key]
		if key.EntityType == EntityTypeAsset && e.AssetType == protocol.AssetTypeCustomerCompany {
			updated := *e
			if asset, ok := inventory.Assets[key.EntityID]; ok {
				updated.Preview, updated.Payload = asset.Preview, asset.Payload
				updated.PreviewLower = strings.ToLower(asset.Preview)
				updated.PayloadLower = strings.ToLower(customerText(asset.Preview, asset.Payload) + "\n" + e.SearchText)
				updated.Bloom = BigramBloom(updated.PreviewLower) | BigramBloom(updated.PayloadLower)
			}
			updated.Metadata.Customer = customerPreview(updated.Preview)
			e = &updated
		}
		if key.EntityType == EntityTypeAsset && len(assetTypes) > 0 {
			if _, ok := assetTypes[e.AssetType]; !ok {
				continue
			}
		}
		if key.EntityType == EntityTypeTask && !matchesTaskFilters(key, e, filters.Task) {
			continue
		}
		identity := EntityIdentity{Workspace: workspace, EntityType: key.EntityType, EntityID: key.EntityID, ConvID: key.ConvID}
		candidates = append(candidates, candidate{identity: identity, assetID: key.EntityID, entry: e})
	}
	return candidates
}

func fuseAndRank(semantic []scoredCandidate, textMatches []textCandidate, topN int) []SearchResult {
	const k = 60.0
	n := len(semantic)

	// Build fused results from semantic pass (contains all candidates).
	// Start with semantic RRF contribution based on rank.
	results := make([]fusedResult, n)
	for i, s := range semantic {
		identity := resultIdentity(s.identity, s.assetID)
		results[i] = fusedResult{
			identity:   identity,
			assetID:    s.assetID,
			score:      1.0 / (k + float64(i+1)),
			similarity: s.similarity,
			preview:    s.preview,
			assetType:  s.assetType,
			payload:    s.payload,
			metadata:   s.metadata,
		}
	}

	// Sort by full identity for binary search lookup.
	sort.Slice(results, func(i, j int) bool {
		return identityLess(results[i].identity, results[j].identity)
	})

	// Add text RRF contributions via binary search.
	for i, t := range textMatches {
		identity := resultIdentity(t.identity, t.assetID)
		textScore := 1.0 / (k + float64(i+1))
		idx := sort.Search(n, func(j int) bool {
			return !identityLess(results[j].identity, identity)
		})
		if idx < n && results[idx].identity.key() == identity.key() {
			results[idx].score += textScore
			if t.exact {
				results[idx].score += 1
			}
		}
	}

	// Sort by score descending, break ties by assetID.
	sort.Slice(results, func(i, j int) bool {
		if results[i].score != results[j].score {
			return results[i].score > results[j].score
		}
		return identityLess(results[i].identity, results[j].identity)
	})

	if topN > n {
		topN = n
	}

	out := make([]SearchResult, topN)
	for i := 0; i < topN; i++ {
		out[i] = SearchResult{
			Entity:     results[i].identity,
			Metadata:   results[i].metadata,
			AssetID:    results[i].assetID,
			Score:      results[i].score,
			Similarity: results[i].similarity,
			Preview:    results[i].preview,
			AssetType:  results[i].assetType,
			Payload:    results[i].payload,
		}
		if results[i].identity.EntityType != EntityTypeAsset {
			out[i].AssetID = 0
			out[i].AssetType = 0
		} else {
			out[i].Metadata.AssetType = results[i].assetType
		}
	}

	return out
}

func (idx *Index) Search(workspace string, query string, embedder Embedder, convID uint64, topN int, assetTypes []uint16) ([]SearchResult, error) {
	return idx.SearchParallel(workspace, query, embedder, convID, topN, assetTypes, 1)
}

// Similar returns the most semantically similar assets to seedAssetID within a room.
//
// Unlike Search, this does not embed any query text. It reuses the already-indexed
// vector for seedAssetID.
func (idx *Index) Similar(workspace string, seedAssetID uint64, convID uint64, topN int, assetTypes []uint16) ([]SearchResult, error) {
	return idx.SimilarParallel(workspace, seedAssetID, convID, topN, assetTypes, 1)
}

func (idx *Index) SimilarParallel(workspace string, seedAssetID uint64, convID uint64, topN int, assetTypes []uint16, workers int) ([]SearchResult, error) {
	return idx.SimilarEntityParallel(assetIdentity(workspace, seedAssetID, convID), topN, SearchFilters{EntityTypes: []EntityType{EntityTypeAsset}, AssetTypes: assetTypes}, workers)
}

func (idx *Index) SimilarEntityParallel(seedIdentity EntityIdentity, topN int, filters SearchFilters, workers int) ([]SearchResult, error) {
	seed, ok := idx.GetEntity(seedIdentity)
	if !ok || seed == nil || len(seed.Vector) == 0 {
		return nil, fmt.Errorf("%w: %s/%d", ErrSeedNotIndexed, seedIdentity.EntityType, seedIdentity.EntityID)
	}
	candidates := idx.collectCandidates(seedIdentity.Workspace, seedIdentity.ConvID, filters)
	if len(candidates) == 0 {
		return nil, nil
	}

	if workers <= 0 {
		workers = 1
	}
	if workers > len(candidates) {
		workers = len(candidates)
	}

	chunkSize := (len(candidates) + workers - 1) / workers
	semanticResults := make([][]scoredCandidate, workers)

	var wg sync.WaitGroup
	wg.Add(workers)

	for w := 0; w < workers; w++ {
		start := w * chunkSize
		end := start + chunkSize
		if end > len(candidates) {
			end = len(candidates)
		}
		if start >= len(candidates) {
			wg.Done()
			continue
		}

		go func(workerID, start, end int) {
			defer wg.Done()

			chunk := candidates[start:end]
			semanticLocal := make([]scoredCandidate, 0, len(chunk))
			for _, c := range chunk {
				if c.identity.EntityType == seedIdentity.EntityType && c.identity.EntityID == seedIdentity.EntityID {
					continue
				}
				sim := vek32.CosineSimilarity(seed.Vector, c.entry.Vector)
				semanticLocal = append(semanticLocal, scoredCandidate{
					identity:   c.identity,
					assetID:    c.assetID,
					similarity: sim,
					preview:    c.entry.Preview,
					assetType:  c.entry.AssetType,
					payload:    c.entry.Payload,
					metadata:   c.entry.Metadata,
				})
			}

			semanticResults[workerID] = semanticLocal
		}(w, start, end)
	}

	wg.Wait()

	semantic := make([]scoredCandidate, 0, len(candidates))
	for _, r := range semanticResults {
		semantic = append(semantic, r...)
	}

	sort.Slice(semantic, func(i, j int) bool {
		if semantic[i].similarity != semantic[j].similarity {
			return semantic[i].similarity > semantic[j].similarity
		}
		return identityLess(semantic[i].identity, semantic[j].identity)
	})

	if topN > len(semantic) {
		topN = len(semantic)
	}

	out := make([]SearchResult, topN)
	for i := 0; i < topN; i++ {
		out[i] = SearchResult{
			Entity:   semantic[i].identity,
			Metadata: semantic[i].metadata,
			AssetID:  semantic[i].assetID,
			// In similar-mode we expose the cosine similarity as both `similarity`
			// and `score` so clients that only look at one field still work.
			Score:      float64(semantic[i].similarity),
			Similarity: semantic[i].similarity,
			Preview:    semantic[i].preview,
			AssetType:  semantic[i].assetType,
			Payload:    semantic[i].payload,
		}
		if semantic[i].identity.EntityType != EntityTypeAsset {
			out[i].AssetID = 0
			out[i].AssetType = 0
		} else {
			out[i].Metadata.AssetType = semantic[i].assetType
		}
	}

	return out, nil
}

func (idx *Index) SearchParallel(workspace string, query string, embedder Embedder, convID uint64, topN int, assetTypes []uint16, workers int) ([]SearchResult, error) {
	return idx.SearchEntitiesParallel(workspace, query, embedder, convID, topN, SearchFilters{EntityTypes: []EntityType{EntityTypeAsset}, AssetTypes: assetTypes}, workers)
}

func (idx *Index) SearchEntitiesParallel(workspace string, query string, embedder Embedder, convID uint64, topN int, filters SearchFilters, workers int) ([]SearchResult, error) {
	if filters.Customer != nil {
		return idx.searchCustomers(workspace, query, embedder, convID, topN, filters, workers)
	}
	candidates := idx.collectCandidates(workspace, convID, filters)
	if len(candidates) == 0 {
		return nil, nil
	}
	if strings.TrimSpace(query) == "" {
		return rankFilteredCandidates(candidates, topN), nil
	}

	slog.Debug("search candidates", "count", len(candidates), "conv_id", convID)

	if embedder == nil {
		return nil, fmt.Errorf("embedder is nil")
	}

	start := time.Now()
	queryVec, err := embedder.Embed(format_query_for_embedding(query))
	if err != nil {
		return nil, err
	}
	slog.Debug("embedded query", "query", query, "duration", time.Since(start).Round(time.Millisecond))

	if workers <= 0 {
		workers = 1
	}
	if workers > len(candidates) {
		workers = len(candidates)
	}

	chunkSize := (len(candidates) + workers - 1) / workers

	semanticResults := make([][]scoredCandidate, workers)
	textResults := make([][]textCandidate, workers)
	queryLower := strings.ToLower(query)
	queryBloom := BigramBloom(queryLower)
	exactTaskID, hasExactTaskID := parseExactTaskID(query)

	var wg sync.WaitGroup
	wg.Add(workers)

	for w := 0; w < workers; w++ {
		start := w * chunkSize
		end := start + chunkSize
		if end > len(candidates) {
			end = len(candidates)
		}
		if start >= len(candidates) {
			wg.Done()
			continue
		}

		go func(workerID, start, end int) {
			defer wg.Done()

			chunk := candidates[start:end]
			semanticLocal := make([]scoredCandidate, 0, len(chunk))
			textLocal := make([]textCandidate, 0, len(chunk))

			for _, c := range chunk {
				sim := bestVectorSimilarity(queryVec, c.entry)
				semanticLocal = append(semanticLocal, scoredCandidate{
					identity:   c.identity,
					assetID:    c.assetID,
					similarity: sim,
					preview:    c.entry.Preview,
					assetType:  c.entry.AssetType,
					payload:    c.entry.Payload,
					metadata:   c.entry.Metadata,
				})

				exact := c.identity.EntityType == EntityTypeTask && ((hasExactTaskID && c.identity.EntityID == exactTaskID) ||
					(c.entry.Metadata.Task != nil && strings.EqualFold(strings.TrimSpace(c.entry.Metadata.Task.ExternalRef), strings.TrimSpace(query))))
				if exact || c.entry.Bloom&queryBloom == queryBloom {
					if exact || strings.Contains(c.entry.PayloadLower, queryLower) || strings.Contains(c.entry.PreviewLower, queryLower) {
						count := strings.Count(c.entry.PayloadLower, queryLower)
						textLocal = append(textLocal, textCandidate{
							identity:  c.identity,
							assetID:   c.assetID,
							count:     count,
							exact:     exact,
							preview:   c.entry.Preview,
							assetType: c.entry.AssetType,
							payload:   c.entry.Payload,
							metadata:  c.entry.Metadata,
						})
					}
				}
			}

			semanticResults[workerID] = semanticLocal
			textResults[workerID] = textLocal
		}(w, start, end)
	}

	wg.Wait()

	semantic := make([]scoredCandidate, 0, len(candidates))
	for _, r := range semanticResults {
		semantic = append(semantic, r...)
	}

	sort.Slice(semantic, func(i, j int) bool {
		if semantic[i].similarity != semantic[j].similarity {
			return semantic[i].similarity > semantic[j].similarity
		}
		return identityLess(semantic[i].identity, semantic[j].identity)
	})

	textCount := 0
	for _, r := range textResults {
		textCount += len(r)
	}
	textMatches := make([]textCandidate, 0, textCount)
	for _, r := range textResults {
		textMatches = append(textMatches, r...)
	}

	sort.Slice(textMatches, func(i, j int) bool {
		if textMatches[i].exact != textMatches[j].exact {
			return textMatches[i].exact
		}
		if textMatches[i].count != textMatches[j].count {
			return textMatches[i].count > textMatches[j].count
		}
		return identityLess(textMatches[i].identity, textMatches[j].identity)
	})

	slog.Debug("search complete", "results", min(topN, len(semantic)), "conv_id", convID)
	return fuseAndRank(semantic, textMatches, topN), nil
}

func parseExactTaskID(query string) (uint64, bool) {
	value := strings.ToLower(strings.TrimSpace(query))
	if strings.HasPrefix(value, "task") {
		value = strings.TrimSpace(strings.TrimLeft(strings.TrimPrefix(value, "task"), ":#"))
	} else {
		value = strings.TrimPrefix(value, "#")
	}
	id, err := strconv.ParseUint(value, 10, 64)
	return id, err == nil && id != 0
}

func rankFilteredCandidates(candidates []candidate, topN int) []SearchResult {
	sort.Slice(candidates, func(i, j int) bool {
		left, right := candidates[i].entry.Metadata.Task, candidates[j].entry.Metadata.Task
		if left != nil && right != nil && left.UpdatedAt != right.UpdatedAt {
			return left.UpdatedAt > right.UpdatedAt
		}
		return identityLess(candidates[i].identity, candidates[j].identity)
	})
	if topN > len(candidates) {
		topN = len(candidates)
	}
	results := make([]SearchResult, topN)
	for i := 0; i < topN; i++ {
		candidate := candidates[i]
		results[i] = SearchResult{Entity: candidate.identity, Metadata: candidate.entry.Metadata, Score: 1,
			Preview: candidate.entry.Preview, Payload: candidate.entry.Payload, AssetID: candidate.assetID, AssetType: candidate.entry.AssetType}
		if candidate.identity.EntityType != EntityTypeAsset {
			results[i].AssetID = 0
			results[i].AssetType = 0
		}
	}
	return results
}
