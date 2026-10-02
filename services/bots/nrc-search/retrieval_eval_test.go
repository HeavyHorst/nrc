package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"

	"github.com/heavyhorst/nrc/protocol-go"
)

const (
	retrievalEvalWorkspace = "retrieval-eval-ws"
	retrievalEvalConvID    = 9001
	retrievalEvalTopN      = 1
)

type retrievalEvalDocument struct {
	assetID uint64
	title   string
	body    string
}

type retrievalEvalQuery struct {
	name        string
	query       string
	relevantIDs []uint64
}

type retrievalEvalCorpus struct {
	documents []retrievalEvalDocument
	queries   []retrievalEvalQuery
}

type retrievalEvalMetrics struct {
	RecallAtK float64
	MRR       float64
	N         int
}

type conceptVectorEmbedder struct{}

func (conceptVectorEmbedder) Embed(text string) ([]float32, error) {
	return conceptVector(text), nil
}

func (conceptVectorEmbedder) Close() {}

// This synthetic corpus models the long-document failure mode chunking is meant
// to fix: relevant sections appear after the single-vector truncation window,
// and queries do not exactly match the full payload as a contiguous substring.
// The deterministic concept embedder keeps this runnable in ordinary unit tests;
// later chunking implementations can reuse the same corpus/metrics with the real
// chunk index path and compare against this baseline.
func TestRetrievalEvalCorpus_ChunkingImprovesLongDocumentRecall(t *testing.T) {
	corpus := longDocumentRetrievalEvalCorpus()
	embedder := conceptVectorEmbedder{}

	singleIdx := buildSingleVectorEvalIndex(t, corpus, embedder, 90)
	singleMetrics, singleFailures := evaluateIndexSearch(singleIdx, corpus, embedder, retrievalEvalTopN)

	chunkedResults := buildChunkedEvalResults(t, corpus, embedder, 70, 15, retrievalEvalTopN)
	chunkedMetrics, chunkedFailures := evaluateResultSet(corpus, chunkedResults, retrievalEvalTopN)

	t.Logf("single-vector eval: recall@%d=%.2f mrr=%.2f failures=%v", retrievalEvalTopN, singleMetrics.RecallAtK, singleMetrics.MRR, singleFailures)
	t.Logf("chunked eval:       recall@%d=%.2f mrr=%.2f failures=%v", retrievalEvalTopN, chunkedMetrics.RecallAtK, chunkedMetrics.MRR, chunkedFailures)

	if chunkedMetrics.RecallAtK <= singleMetrics.RecallAtK {
		t.Fatalf("expected chunked recall@%d to improve: single=%.2f chunked=%.2f", retrievalEvalTopN, singleMetrics.RecallAtK, chunkedMetrics.RecallAtK)
	}
	if chunkedMetrics.MRR <= singleMetrics.MRR {
		t.Fatalf("expected chunked MRR to improve: single=%.2f chunked=%.2f", singleMetrics.MRR, chunkedMetrics.MRR)
	}
}

func TestRealEmbedderRetrievalEvalCorpus(t *testing.T) {
	embedder := newRealEvalEmbedder(t)
	defer embedder.Close()

	corpus := longDocumentRetrievalEvalCorpus()
	singleIdx := buildSingleVectorEvalIndex(t, corpus, embedder, 90)
	singleMetrics, singleFailures := evaluateIndexSearch(singleIdx, corpus, embedder, retrievalEvalTopN)

	chunkedResults := buildChunkedEvalResults(t, corpus, embedder, 70, 15, retrievalEvalTopN)
	chunkedMetrics, chunkedFailures := evaluateResultSet(corpus, chunkedResults, retrievalEvalTopN)

	t.Logf("real single-vector eval: recall@%d=%.2f mrr=%.2f failures=%v", retrievalEvalTopN, singleMetrics.RecallAtK, singleMetrics.MRR, singleFailures)
	t.Logf("real chunked eval:       recall@%d=%.2f mrr=%.2f failures=%v", retrievalEvalTopN, chunkedMetrics.RecallAtK, chunkedMetrics.MRR, chunkedFailures)

	if chunkedMetrics.RecallAtK < singleMetrics.RecallAtK {
		t.Fatalf("chunked recall@%d regressed: single=%.2f chunked=%.2f", retrievalEvalTopN, singleMetrics.RecallAtK, chunkedMetrics.RecallAtK)
	}
	if chunkedMetrics.MRR < singleMetrics.MRR {
		t.Fatalf("chunked MRR regressed: single=%.2f chunked=%.2f", singleMetrics.MRR, chunkedMetrics.MRR)
	}
}

func TestNRCRecipeMemoryRetrievalEval(t *testing.T) {
	if os.Getenv("NRC_RECIPE_EVAL") != "1" {
		t.Skip("set NRC_RECIPE_EVAL=1 to load live recipes from NRC room memory")
	}

	embedder := newRealEvalEmbedder(t)
	defer embedder.Close()

	limit := envIntOrDefault("NRC_RECIPE_EVAL_LIMIT", 20)
	corpus := loadNRCRecipeMemoryCorpus(t, limit)
	if len(corpus.documents) < 5 {
		t.Fatalf("loaded %d recipe documents, want at least 5", len(corpus.documents))
	}

	singleIdx := buildSingleVectorEvalIndex(t, corpus, embedder, 90)
	singleMetrics, singleFailures := evaluateIndexSearch(singleIdx, corpus, embedder, 3)

	chunkedResults := buildChunkedEvalResults(t, corpus, embedder, 70, 15, 3)
	chunkedMetrics, chunkedFailures := evaluateResultSet(corpus, chunkedResults, 3)

	t.Logf("recipe memory docs=%d queries=%d", len(corpus.documents), len(corpus.queries))
	t.Logf("recipe single-vector eval: recall@3=%.2f mrr=%.2f failures=%v", singleMetrics.RecallAtK, singleMetrics.MRR, singleFailures)
	t.Logf("recipe chunked eval:       recall@3=%.2f mrr=%.2f failures=%v", chunkedMetrics.RecallAtK, chunkedMetrics.MRR, chunkedFailures)

	if chunkedMetrics.RecallAtK < 0.50 {
		t.Fatalf("recipe chunked recall@3 too low: %.2f", chunkedMetrics.RecallAtK)
	}
	if chunkedMetrics.MRR < 0.50 {
		t.Fatalf("recipe chunked MRR too low: %.2f", chunkedMetrics.MRR)
	}
}

func longDocumentRetrievalEvalCorpus() retrievalEvalCorpus {
	return retrievalEvalCorpus{
		documents: []retrievalEvalDocument{
			{
				assetID: 101,
				title:   "Infrastructure Rotation Notes",
				body: strings.Join([]string{
					repeatSentence("General deployment checklist mentions logs, metrics, dashboards, release notes, and operator handoff.", 18),
					"Database backup section: snapshots, point in time recovery, wal archiving, restore drills, retention windows, replica promotion, and data safety verification.",
				}, "\n\n"),
			},
			{
				assetID: 102,
				title:   "Provider Migration",
				body: strings.Join([]string{
					repeatSentence("Frontend cleanup includes typography, keyboard shortcuts, modal behavior, palette updates, and layout consistency.", 18),
					"Authentication rollout section: oauth callback handling, oidc discovery, refresh token rotation, session cookie renewal, jwt validation, and login redirect safety.",
				}, "\n\n"),
			},
			{
				assetID: 103,
				title:   "Sidecar Plan",
				body: strings.Join([]string{
					repeatSentence("Room moderation procedures cover flags, review queues, user reports, escalation paths, and audit visibility.", 18),
					"Retrieval section: semantic embedding, vector similarity, cosine ranking, reciprocal rank fusion, query prompts, document vectors, and search relevance evaluation.",
				}, "\n\n"),
			},
			{
				assetID: 1,
				title:   "Incident Response Runbook",
				body: strings.Join([]string{
					"Outage handling covers paging, service ownership, rollback authority, status page updates, mitigation notes, and postmortem timelines.",
					repeatSentence("Follow up coordination mentions review meetings, action items, service health, and alert tuning.", 4),
				}, "\n\n"),
			},
			{
				assetID: 2,
				title:   "Design Palette Notes",
				body: strings.Join([]string{
					"Visual system notes discuss amber foregrounds, cyan accents, contrast rules, dark backgrounds, borders, and dense utility layout.",
					repeatSentence("Interaction notes mention panels, lists, selected rows, focus rings, and command affordances.", 4),
				}, "\n\n"),
			},
		},
		queries: []retrievalEvalQuery{
			{name: "recover database after data loss", query: "recover database after data loss", relevantIDs: []uint64{101}},
			{name: "login session security", query: "login session security", relevantIDs: []uint64{102}},
			{name: "semantic search quality", query: "semantic search quality", relevantIDs: []uint64{103}},
		},
	}
}

func newRealEvalEmbedder(t testing.TB) Embedder {
	t.Helper()
	// ONNX Runtime environment setup/teardown is process-global; tests using this
	// helper must stay serial and must not use t.Parallel().

	modelPath := envOrDefault("TEST_MODEL_PATH", "./models/model.onnx")
	tokenizerPath := envOrDefault("TEST_TOKENIZER_PATH", "./models/tokenizer.json")
	if _, err := os.Stat(modelPath); err != nil {
		t.Skipf("model unavailable at %s: %v", modelPath, err)
	}
	if _, err := os.Stat(tokenizerPath); err != nil {
		t.Skipf("tokenizer unavailable at %s: %v", tokenizerPath, err)
	}

	embedder, err := NewEmbedder(modelPath, tokenizerPath)
	if err != nil {
		if strings.Contains(err.Error(), "built with noembed tag") {
			t.Skip(err)
		}
		t.Fatalf("NewEmbedder: %v", err)
	}
	return embedder
}

type nrcRecipeNoteList struct {
	Notes []struct {
		ID    uint64   `json:"id"`
		Title string   `json:"title"`
		Tags  []string `json:"tags"`
	} `json:"notes"`
}

type nrcRecipeNote struct {
	ID      uint64   `json:"id"`
	Title   string   `json:"title"`
	Content string   `json:"content"`
	Tags    []string `json:"tags"`
}

func loadNRCRecipeMemoryCorpus(t testing.TB, limit int) retrievalEvalCorpus {
	t.Helper()

	if limit <= 0 {
		limit = 20
	}

	listOut := runNRCJSON(t, "note", "list", "--room", "rezepte", "--limit", strconv.Itoa(limit))
	var list nrcRecipeNoteList
	if err := json.Unmarshal(listOut, &list); err != nil {
		t.Fatalf("decode nrc recipe note list: %v\n%s", err, string(listOut))
	}

	corpus := retrievalEvalCorpus{
		documents: make([]retrievalEvalDocument, 0, len(list.Notes)),
		queries:   make([]retrievalEvalQuery, 0, len(list.Notes)),
	}
	for _, item := range list.Notes {
		getOut := runNRCJSON(t, "note", "get", strconv.FormatUint(item.ID, 10), "--room", "rezepte", "--related=false")
		var note nrcRecipeNote
		if err := json.Unmarshal(getOut, &note); err != nil {
			t.Fatalf("decode nrc recipe note %d: %v\n%s", item.ID, err, string(getOut))
		}
		if strings.TrimSpace(note.Content) == "" {
			continue
		}
		title := strings.TrimSpace(note.Title)
		if title == "" {
			title = item.Title
		}

		corpus.documents = append(corpus.documents, retrievalEvalDocument{
			assetID: note.ID,
			title:   title,
			body:    note.Content,
		})
		corpus.queries = append(corpus.queries, retrievalEvalQuery{
			name:        fmt.Sprintf("%d %s", note.ID, title),
			query:       recipeEvalQuery(note),
			relevantIDs: []uint64{note.ID},
		})
	}
	return corpus
}

func recipeEvalQuery(note nrcRecipeNote) string {
	title := strings.TrimSpace(note.Title)
	ingredients := strings.TrimSpace(firstRecipeIngredientTerms(note.Content, 8))
	if title != "" && ingredients != "" {
		return title + " " + ingredients
	}
	if title == "" {
		return firstWords(note.Content, 8)
	}
	return title
}

func firstRecipeIngredientTerms(content string, limit int) string {
	lines := strings.Split(content, "\n")
	inIngredients := false
	terms := make([]string, 0, limit)
	for _, line := range lines {
		line = strings.TrimSpace(line)
		lower := strings.ToLower(line)
		if strings.HasPrefix(lower, "## ") {
			if strings.Contains(lower, "zutaten") {
				inIngredients = true
				continue
			}
			if inIngredients {
				break
			}
		}
		if !inIngredients || !strings.HasPrefix(line, "-") {
			continue
		}
		for _, field := range strings.Fields(strings.TrimLeft(line, "- ")) {
			field = strings.Trim(field, " .,;:()[]{}")
			if field == "" || isRecipeQuantityToken(field) {
				continue
			}
			terms = append(terms, field)
			if len(terms) >= limit {
				return strings.Join(terms, " ")
			}
		}
	}
	return strings.Join(terms, " ")
}

func isRecipeQuantityToken(token string) bool {
	lower := strings.ToLower(token)
	if _, err := strconv.ParseFloat(strings.ReplaceAll(lower, ",", "."), 64); err == nil {
		return true
	}
	switch lower {
	case "g", "kg", "ml", "l", "liter", "el", "tl", "prise", "prisen", "handvoll", "stück", "stk", "ca", "ca.":
		return true
	}
	return false
}

func runNRCJSON(t testing.TB, args ...string) []byte {
	t.Helper()

	cmd := exec.Command("nrc", args...)
	out, err := cmd.Output()
	if err != nil {
		stderr := ""
		if exitErr, ok := err.(*exec.ExitError); ok {
			stderr = string(exitErr.Stderr)
		}
		t.Fatalf("nrc %s: %v\n%s", strings.Join(args, " "), err, stderr)
	}
	return out
}

func envIntOrDefault(key string, fallback int) int {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	n, err := strconv.Atoi(value)
	if err != nil || n <= 0 {
		return fallback
	}
	return n
}

func buildSingleVectorEvalIndex(t testing.TB, corpus retrievalEvalCorpus, embedder Embedder, truncateWords int) *Index {
	t.Helper()

	idx := NewIndex()
	for _, doc := range corpus.documents {
		payload := strings.ToLower(doc.body)
		embeddedText := doc.title + " " + firstWords(doc.body, truncateWords)
		vec, err := embedder.Embed(format_document_for_embedding(doc.title, embeddedText))
		if err != nil {
			t.Fatalf("embed single-vector document %d: %v", doc.assetID, err)
		}
		idx.Add(retrievalEvalWorkspace, doc.assetID, &IndexEntry{
			Vector:    vec,
			ConvID:    retrievalEvalConvID,
			AssetType: protocol.AssetTypeDocument,
			Preview:   strings.ToLower(doc.title),
			Payload:   payload,
			Bloom:     BigramBloom(payload) | BigramBloom(strings.ToLower(doc.title)),
		})
	}
	return idx
}

func buildChunkedEvalResults(t testing.TB, corpus retrievalEvalCorpus, embedder Embedder, chunkWords, overlapWords, topN int) map[string][]SearchResult {
	t.Helper()

	idx := NewIndex()
	for _, doc := range corpus.documents {
		docChunks := chunkDocumentText(doc.body, chunkWords, chunkWords*2, overlapWords)
		chunks := make([]IndexChunk, 0, len(docChunks))
		for i, text := range docChunks {
			vec, err := embedder.Embed(format_document_for_embedding(doc.title, text))
			if err != nil {
				t.Fatalf("embed chunk for document %d: %v", doc.assetID, err)
			}
			chunks = append(chunks, IndexChunk{Index: i, Vector: vec})
		}
		payloadLower := strings.ToLower(doc.body)
		previewLower := strings.ToLower(doc.title)
		idx.Add(retrievalEvalWorkspace, doc.assetID, &IndexEntry{
			Vector:      aggregateChunkVectors(chunks),
			Chunks:      chunks,
			ConvID:      retrievalEvalConvID,
			AssetType:   protocol.AssetTypeDocument,
			Preview:     previewLower,
			Payload:     payloadLower,
			Bloom:       BigramBloom(payloadLower) | BigramBloom(previewLower),
			ContentHash: document_content_hash(doc.title, doc.body),
		})
	}

	resultsByQuery := make(map[string][]SearchResult, len(corpus.queries))
	for _, q := range corpus.queries {
		results, err := idx.SearchParallel(retrievalEvalWorkspace, q.query, embedder, retrievalEvalConvID, topN, []uint16{protocol.AssetTypeDocument}, 2)
		if err != nil {
			t.Fatalf("chunked eval search query %q: %v", q.query, err)
		}
		resultsByQuery[q.name] = results
	}
	return resultsByQuery
}

func evaluateIndexSearch(idx *Index, corpus retrievalEvalCorpus, embedder Embedder, topN int) (retrievalEvalMetrics, []string) {
	resultsByQuery := make(map[string][]SearchResult, len(corpus.queries))
	for _, q := range corpus.queries {
		results, err := idx.SearchParallel(retrievalEvalWorkspace, q.query, embedder, retrievalEvalConvID, topN, []uint16{protocol.AssetTypeDocument}, 2)
		if err != nil {
			panic(fmt.Sprintf("eval search query %q: %v", q.query, err))
		}
		resultsByQuery[q.name] = results
	}
	return evaluateResultSet(corpus, resultsByQuery, topN)
}

func evaluateResultSet(corpus retrievalEvalCorpus, resultsByQuery map[string][]SearchResult, topN int) (retrievalEvalMetrics, []string) {
	metrics := retrievalEvalMetrics{N: len(corpus.queries)}
	failures := make([]string, 0)

	for _, q := range corpus.queries {
		relevant := make(map[uint64]struct{}, len(q.relevantIDs))
		for _, id := range q.relevantIDs {
			relevant[id] = struct{}{}
		}

		rank := 0
		results := resultsByQuery[q.name]
		for i, r := range results {
			if i >= topN {
				break
			}
			if _, ok := relevant[r.AssetID]; ok {
				rank = i + 1
				break
			}
		}

		if rank == 0 {
			failures = append(failures, q.name)
			continue
		}
		metrics.RecallAtK += 1
		metrics.MRR += 1.0 / float64(rank)
	}

	if metrics.N > 0 {
		metrics.RecallAtK /= float64(metrics.N)
		metrics.MRR /= float64(metrics.N)
	}
	return metrics, failures
}

func conceptVector(text string) []float32 {
	text = strings.ToLower(text)
	text = strings.ReplaceAll(text, embedding_gemma_query_prefix, "")
	text = strings.ReplaceAll(text, embedding_gemma_doc_prefix, "")
	text = strings.ReplaceAll(text, embedding_gemma_text_prefix, " ")
	vec := make([]float32, 6)
	concepts := [][]string{
		{"database", "backup", "snapshots", "restore", "recovery", "recover", "wal", "replica", "retention", "data loss", "data safety"},
		{"authentication", "oauth", "oidc", "login", "session", "jwt", "cookie", "token", "identity"},
		{"search", "semantic", "embedding", "vector", "cosine", "ranking", "retrieval", "relevance", "query"},
		{"incident", "outage", "paging", "rollback", "mitigation", "postmortem", "status page"},
		{"design", "palette", "amber", "cyan", "contrast", "layout", "visual", "borders"},
		{"frontend", "typography", "modal", "keyboard", "shortcuts", "panels", "focus"},
	}

	for i, terms := range concepts {
		for _, term := range terms {
			vec[i] += float32(strings.Count(text, term))
		}
	}

	var norm float32
	for _, v := range vec {
		norm += v * v
	}
	if norm == 0 {
		vec[len(vec)-1] = 1
		return vec
	}
	norm = float32(math.Sqrt(float64(norm)))
	for i := range vec {
		vec[i] /= norm
	}
	return vec
}

func repeatSentence(sentence string, count int) string {
	parts := make([]string, count)
	for i := range parts {
		parts[i] = sentence
	}
	return strings.Join(parts, " ")
}

func firstWords(text string, limit int) string {
	words := strings.Fields(text)
	if len(words) <= limit {
		return text
	}
	return strings.Join(words[:limit], " ")
}

func TestRetrievalEvalChunkerPreservesParagraphBoundaries(t *testing.T) {
	text := strings.Join([]string{
		"# Runbook",
		"Intro paragraph discusses ownership, dashboards, rotations, release notes, and operational handoff.",
		"## Database Recovery",
		repeatSentence("Database backup restore snapshots wal retention verification.", 3),
	}, "\n\n")

	chunks := chunkDocumentText(text, 16, 24, 0)
	if len(chunks) < 2 {
		t.Fatalf("chunks len=%d, want at least 2", len(chunks))
	}

	foundRecoveryChunk := false
	for _, chunk := range chunks {
		if strings.Contains(chunk, "Database Recovery") && strings.Contains(chunk, "backup restore") {
			foundRecoveryChunk = true
		}
		if strings.Contains(chunk, "operational handoff") && strings.Contains(chunk, "backup restore") {
			t.Fatalf("chunk crossed unrelated paragraph boundary: %q", chunk)
		}
	}
	if !foundRecoveryChunk {
		t.Fatalf("missing recovery section chunk: %#v", chunks)
	}
}

func TestRetrievalEvalChunkerSplitsOversizedSentenceWithOverlap(t *testing.T) {
	text := strings.Repeat("alpha beta gamma delta epsilon ", 8)
	chunks := chunkDocumentText(text, 8, 10, 2)
	if len(chunks) < 4 {
		t.Fatalf("chunks len=%d, want multiple fallback chunks", len(chunks))
	}

	firstWords := strings.Fields(chunks[0])
	secondWords := strings.Fields(chunks[1])
	if len(firstWords) < 2 || len(secondWords) < 2 {
		t.Fatalf("unexpected short chunks: %#v", chunks)
	}
	firstTail := strings.Join(firstWords[len(firstWords)-2:], " ")
	secondHead := strings.Join(secondWords[:2], " ")
	if firstTail != secondHead {
		t.Fatalf("missing overlap: first tail %q second head %q", firstTail, secondHead)
	}
}
