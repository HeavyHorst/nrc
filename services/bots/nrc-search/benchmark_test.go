package main

import (
	"fmt"
	"math/rand"
	"sort"
	"strings"
	"testing"

	"github.com/heavyhorst/nrc/protocol-go"
	"github.com/viterin/vek/vek32"
)

type mockEmbedderBench struct {
	vec []float32
}

func (m *mockEmbedderBench) Embed(text string) ([]float32, error) {
	return m.vec, nil
}

func (m *mockEmbedderBench) Close() {}

func generateRandomVector(dim int, rng *rand.Rand) []float32 {
	vec := make([]float32, dim)
	var sum float32
	for i := range vec {
		vec[i] = rng.Float32()*2 - 1
		sum += vec[i] * vec[i]
	}
	if sum > 0 {
		norm := float32(1.0 / float64(sum))
		for i := range vec {
			vec[i] *= norm
		}
	}
	return vec
}

func generateRandomText(wordCount int, rng *rand.Rand) string {
	words := []string{"the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "code", "data", "search", "vector", "index", "query", "result", "document", "file", "system", "test", "benchmark"}
	var b strings.Builder
	for i := 0; i < wordCount; i++ {
		if i > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(words[rng.Intn(len(words))])
	}
	return b.String()
}

func setupBenchmarkIndex(docCount, vectorDim int, rng *rand.Rand) (*Index, []float32) {
	idx := NewIndex()
	queryVec := generateRandomVector(vectorDim, rng)

	for i := 0; i < docCount; i++ {
		vec := generateRandomVector(vectorDim, rng)
		text := strings.ToLower(generateRandomText(20+rng.Intn(30), rng))
		preview := text[:min(100, len(text))]
		idx.Add("bench-ws", uint64(i+1), &IndexEntry{
			Vector:    vec,
			ConvID:    100,
			AssetType: protocol.AssetTypeDocument,
			Preview:   preview,
			Payload:   text,
			Bloom:     BigramBloom(text) | BigramBloom(preview),
		})
	}
	return idx, queryVec
}

func searchWithInterface(idx *Index, workspace string, query string, emb Embedder, convID uint64, topN int, assetTypes []uint16) ([]SearchResult, error) {
	typeFilter := make(map[uint16]struct{}, len(assetTypes))
	for _, t := range assetTypes {
		typeFilter[t] = struct{}{}
	}

	idx.mu.RLock()
	convSet := idx.byConvID[workspace][convID]
	if len(convSet) == 0 {
		idx.mu.RUnlock()
		return nil, nil
	}
	wsEntries := idx.entries[workspace]
	var candidates []candidate
	for assetID := range convSet {
		e := wsEntries[assetID]
		if len(typeFilter) > 0 {
			if _, ok := typeFilter[e.AssetType]; !ok {
				continue
			}
		}
		candidates = append(candidates, candidate{assetID: assetID.EntityID, entry: e})
	}
	idx.mu.RUnlock()

	if len(candidates) == 0 {
		return nil, nil
	}

	queryVec, err := emb.Embed(query)
	if err != nil {
		return nil, err
	}

	semantic := make([]scoredCandidate, 0, len(candidates))
	for _, c := range candidates {
		sim := vek32.CosineSimilarity(queryVec, c.entry.Vector)
		semantic = append(semantic, scoredCandidate{
			assetID:    c.assetID,
			similarity: sim,
			preview:    c.entry.Preview,
		})
	}

	sort.Slice(semantic, func(i, j int) bool {
		return semantic[i].similarity > semantic[j].similarity
	})

	semanticRank := make(map[uint64]int, len(semantic))
	for i, s := range semantic {
		semanticRank[s.assetID] = i + 1
	}

	queryLower := strings.ToLower(query)
	var textMatches []textCandidate
	for _, c := range candidates {
		payloadMatch := strings.Contains(c.entry.Payload, queryLower)
		previewMatch := strings.Contains(c.entry.Preview, queryLower)

		if !payloadMatch && !previewMatch {
			continue
		}

		count := strings.Count(c.entry.Payload, queryLower)
		textMatches = append(textMatches, textCandidate{
			assetID: c.assetID,
			count:   count,
			preview: c.entry.Preview,
		})
	}

	sort.Slice(textMatches, func(i, j int) bool {
		return textMatches[i].count > textMatches[j].count
	})

	textRank := make(map[uint64]int, len(textMatches))
	for i, t := range textMatches {
		textRank[t.assetID] = i + 1
	}

	const k = 60.0
	allIDs := make(map[uint64]struct{}, len(candidates))
	for _, s := range semantic {
		allIDs[s.assetID] = struct{}{}
	}
	for _, t := range textMatches {
		allIDs[t.assetID] = struct{}{}
	}

	previewMap := make(map[uint64]string, len(candidates))
	for _, c := range candidates {
		previewMap[c.assetID] = c.entry.Preview
	}

	type fusedResult struct {
		assetID uint64
		score   float64
		preview string
	}

	results := make([]fusedResult, 0, len(allIDs))
	for id := range allIDs {
		var score float64
		if rank, ok := semanticRank[id]; ok {
			score += 1.0 / (k + float64(rank))
		}
		if rank, ok := textRank[id]; ok {
			score += 1.0 / (k + float64(rank))
		}
		results = append(results, fusedResult{
			assetID: id,
			score:   score,
			preview: previewMap[id],
		})
	}

	sort.Slice(results, func(i, j int) bool {
		return results[i].score > results[j].score
	})

	if topN > len(results) {
		topN = len(results)
	}

	out := make([]SearchResult, topN)
	for i := 0; i < topN; i++ {
		out[i] = SearchResult{
			AssetID: results[i].assetID,
			Score:   results[i].score,
			Preview: results[i].preview,
		}
	}

	return out, nil
}

func BenchmarkSimilarity(b *testing.B) {
	rng := rand.New(rand.NewSource(42))
	vectorDim := 768

	sizes := []int{100, 1000, 10000, 100000}
	for _, size := range sizes {
		b.Run(fmt.Sprintf("n=%d", size), func(b *testing.B) {
			idx, queryVec := setupBenchmarkIndex(size, vectorDim, rng)
			emb := &mockEmbedderBench{vec: queryVec}

			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				_, _ = searchWithInterface(idx, "bench-ws", "test query", emb, 100, 10, nil)
			}
		})
	}
}

func BenchmarkSimilarityParallel(b *testing.B) {
	rng := rand.New(rand.NewSource(42))
	vectorDim := 768
	idx, queryVec := setupBenchmarkIndex(10000, vectorDim, rng)
	emb := &mockEmbedderBench{vec: queryVec}

	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			_, _ = searchWithInterface(idx, "bench-ws", "test query", emb, 100, 10, nil)
		}
	})
}

func BenchmarkFullText(b *testing.B) {
	rng := rand.New(rand.NewSource(42))
	vectorDim := 768

	sizes := []int{100, 1000, 10000}
	for _, size := range sizes {
		b.Run(fmt.Sprintf("n=%d", size), func(b *testing.B) {
			idx, queryVec := setupBenchmarkIndex(size, vectorDim, rng)
			emb := &mockEmbedderBench{vec: queryVec}

			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				_, _ = searchWithInterface(idx, "bench-ws", "search query test", emb, 100, 10, nil)
			}
		})
	}
}

func BenchmarkFullTextWithMatch(b *testing.B) {
	rng := rand.New(rand.NewSource(42))
	vectorDim := 768

	const docCount = 1000
	idx := NewIndex()
	queryVec := generateRandomVector(vectorDim, rng)

	matchWord := "benchmark"
	for i := 0; i < docCount; i++ {
		vec := generateRandomVector(vectorDim, rng)
		var text string
		if i%10 == 0 {
			text = "this document contains the " + matchWord + " word for testing purposes"
		} else {
			text = generateRandomText(30, rng)
		}
		idx.Add("bench-ws", uint64(i+1), &IndexEntry{
			Vector:    vec,
			ConvID:    100,
			AssetType: protocol.AssetTypeDocument,
			Preview:   text[:min(100, len(text))],
			Payload:   text,
		})
	}

	emb := &mockEmbedderBench{vec: queryVec}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = searchWithInterface(idx, "bench-ws", matchWord, emb, 100, 10, nil)
	}
}

func BenchmarkSearchEndToEnd(b *testing.B) {
	rng := rand.New(rand.NewSource(42))
	vectorDim := 768

	sizes := []int{100, 1000, 10000}
	for _, size := range sizes {
		b.Run(fmt.Sprintf("n=%d", size), func(b *testing.B) {
			idx, queryVec := setupBenchmarkIndex(size, vectorDim, rng)
			emb := &mockEmbedderBench{vec: queryVec}

			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				results, _ := searchWithInterface(idx, "bench-ws", "search query document", emb, 100, 10, nil)
				_ = results
			}
		})
	}
}

func BenchmarkIndexAdd(b *testing.B) {
	rng := rand.New(rand.NewSource(42))
	vectorDim := 768

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		idx := NewIndex()
		for j := 0; j < 1000; j++ {
			vec := generateRandomVector(vectorDim, rng)
			text := generateRandomText(20, rng)
			idx.Add("bench-ws", uint64(j+1), &IndexEntry{
				Vector:    vec,
				ConvID:    100,
				AssetType: protocol.AssetTypeDocument,
				Preview:   text,
				Payload:   text,
			})
		}
	}
}

func BenchmarkIndexGet(b *testing.B) {
	rng := rand.New(rand.NewSource(42))
	vectorDim := 768

	idx := NewIndex()
	for i := 0; i < 10000; i++ {
		vec := generateRandomVector(vectorDim, rng)
		idx.Add("bench-ws", uint64(i+1), &IndexEntry{
			Vector:    vec,
			ConvID:    100,
			AssetType: protocol.AssetTypeDocument,
			Preview:   "test",
		})
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = idx.Get("bench-ws", uint64((i%10000)+1))
	}
}

func BenchmarkIndexCount(b *testing.B) {
	rng := rand.New(rand.NewSource(42))
	vectorDim := 768

	idx := NewIndex()
	for i := 0; i < 10000; i++ {
		vec := generateRandomVector(vectorDim, rng)
		idx.Add("bench-ws", uint64(i+1), &IndexEntry{
			Vector:    vec,
			ConvID:    100,
			AssetType: protocol.AssetTypeDocument,
		})
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = idx.Count()
	}
}

func BenchmarkRRFFusion(b *testing.B) {
	rng := rand.New(rand.NewSource(42))
	const docCount = 10000

	semanticRanks := make(map[uint64]int, docCount)
	textRanks := make(map[uint64]int, docCount/2)

	for i := 0; i < docCount; i++ {
		semanticRanks[uint64(i+1)] = rng.Intn(docCount) + 1
	}
	for i := 0; i < docCount/2; i++ {
		textRanks[uint64(i+1)] = rng.Intn(docCount/2) + 1
	}

	const k = 60.0

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		allIDs := make(map[uint64]struct{}, docCount)
		for id := range semanticRanks {
			allIDs[id] = struct{}{}
		}
		for id := range textRanks {
			allIDs[id] = struct{}{}
		}

		scores := make([]struct {
			id    uint64
			score float64
		}, 0, len(allIDs))

		for id := range allIDs {
			var score float64
			if rank, ok := semanticRanks[id]; ok {
				score += 1.0 / (k + float64(rank))
			}
			if rank, ok := textRanks[id]; ok {
				score += 1.0 / (k + float64(rank))
			}
			scores = append(scores, struct {
				id    uint64
				score float64
			}{id, score})
		}
	}
}

func BenchmarkCosineSimilarity(b *testing.B) {
	rng := rand.New(rand.NewSource(42))
	vectorDim := 768

	queryVec := generateRandomVector(vectorDim, rng)
	docs := make([][]float32, 10000)
	for i := range docs {
		docs[i] = generateRandomVector(vectorDim, rng)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		for _, doc := range docs {
			_ = vek32.CosineSimilarity(queryVec, doc)
		}
	}
}

func BenchmarkStringContains(b *testing.B) {
	rng := rand.New(rand.NewSource(42))

	const docCount = 10000
	query := "search"
	docs := make([]string, docCount)
	for i := range docs {
		if i%10 == 0 {
			docs[i] = "this document has the search term in it"
		} else {
			docs[i] = generateRandomText(30, rng)
		}
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		for _, doc := range docs {
			_ = strings.Contains(doc, query)
		}
	}
}

func BenchmarkStringContainsByLength(b *testing.B) {
	rng := rand.New(rand.NewSource(42))
	const docCount = 10000
	query := "search"

	for _, wordCount := range []int{10, 50, 200, 1000} {
		docs := make([]string, docCount)
		for i := range docs {
			docs[i] = generateRandomText(wordCount, rng)
		}

		b.Run(fmt.Sprintf("words=%d", wordCount), func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				for _, doc := range docs {
					_ = strings.Contains(doc, query)
				}
			}
		})
	}
}

func BenchmarkSearchVsParallel(b *testing.B) {
	rng := rand.New(rand.NewSource(42))
	vectorDim := 768

	sizes := []int{100, 1000, 10000, 100000}
	workers := []int{1, 2, 4, 8, 12}

	for _, size := range sizes {
		idx, queryVec := setupBenchmarkIndex(size, vectorDim, rng)
		emb := &mockEmbedderBench{vec: queryVec}

		b.Run(fmt.Sprintf("n=%d/sequential", size), func(b *testing.B) {
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				_, _ = idx.Search("bench-ws", "search query document", emb, 100, 10, nil)
			}
		})

		for _, w := range workers {
			b.Run(fmt.Sprintf("n=%d/parallel_w=%d", size, w), func(b *testing.B) {
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					_, _ = idx.SearchParallel("bench-ws", "search query document", emb, 100, 10, nil, w)
				}
			})
		}
	}
}

func BenchmarkSearchParallelScaling(b *testing.B) {
	rng := rand.New(rand.NewSource(42))
	vectorDim := 768
	const docCount = 100000

	idx, queryVec := setupBenchmarkIndex(docCount, vectorDim, rng)
	emb := &mockEmbedderBench{vec: queryVec}

	workers := []int{1, 2, 4, 8, 12, 16, 24, 32}
	for _, w := range workers {
		b.Run(fmt.Sprintf("workers=%d", w), func(b *testing.B) {
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				_, _ = idx.SearchParallel("bench-ws", "search query document", emb, 100, 10, nil, w)
			}
		})
	}
}

func BenchmarkSearchMillionDocs(b *testing.B) {
	rng := rand.New(rand.NewSource(42))
	vectorDim := 768
	const docCount = 1000000

	idx, queryVec := setupBenchmarkIndex(docCount, vectorDim, rng)
	emb := &mockEmbedderBench{vec: queryVec}

	workers := []int{1, 4, 8, 12, 16, 24, 32, 48, 64}
	for _, w := range workers {
		b.Run(fmt.Sprintf("workers=%d", w), func(b *testing.B) {
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				_, _ = idx.SearchParallel("bench-ws", "search query document", emb, 100, 10, nil, w)
			}
		})
	}
}
