package main

import (
	"math"
	"os"
	"strings"
	"testing"
)

func TestNormalize(t *testing.T) {
	tests := []struct {
		name     string
		input    []float32
		wantNorm float64
	}{
		{
			name:     "simple vector",
			input:    []float32{3.0, 4.0},
			wantNorm: 1.0,
		},
		{
			name:     "unit vector unchanged",
			input:    []float32{1.0, 0.0, 0.0},
			wantNorm: 1.0,
		},
		{
			name:     "negative values",
			input:    []float32{-3.0, -4.0},
			wantNorm: 1.0,
		},
		{
			name:     "mixed values",
			input:    []float32{1.0, 2.0, 2.0},
			wantNorm: 1.0,
		},
		{
			name:     "zeros remain zero",
			input:    []float32{0.0, 0.0, 0.0},
			wantNorm: 0.0,
		},
		{
			name:     "single element",
			input:    []float32{5.0},
			wantNorm: 1.0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			normalize(tt.input)

			var sum float64
			for _, v := range tt.input {
				sum += float64(v) * float64(v)
			}
			gotNorm := math.Sqrt(sum)

			if math.Abs(gotNorm-tt.wantNorm) > 1e-6 {
				t.Errorf("norm after normalize = %f, want %f", gotNorm, tt.wantNorm)
			}
		})
	}
}

func TestNormalizePreservesDirection(t *testing.T) {
	input := []float32{2.0, 3.0, 6.0}
	originalLen := math.Sqrt(4 + 9 + 36)

	normalize(input)

	ratio := float64(input[0]) / 2.0
	for i := range input {
		gotRatio := float64(input[i]) / float64([]float32{2.0, 3.0, 6.0}[i])
		if math.Abs(gotRatio-ratio) > 1e-6 {
			t.Errorf("direction changed at index %d: ratio=%f, expected %f", i, gotRatio, ratio)
		}
	}

	var sum float64
	for _, v := range input {
		sum += float64(v) * float64(v)
	}
	if math.Abs(math.Sqrt(sum)-1.0) > 1e-6 {
		t.Errorf("result is not unit vector, norm=%f", math.Sqrt(sum))
	}

	for i := range input {
		expected := float32([]float32{2.0, 3.0, 6.0}[i] / float32(originalLen))
		if math.Abs(float64(input[i]-expected)) > 1e-6 {
			t.Errorf("input[%d] = %f, expected %f", i, input[i], expected)
		}
	}
}

func TestNormalizeZeroVector(t *testing.T) {
	input := []float32{0.0, 0.0, 0.0}
	normalize(input)

	for i, v := range input {
		if v != 0.0 {
			t.Errorf("zero vector should remain zero, got input[%d] = %f", i, v)
		}
	}
}

func TestRealEmbedderSmoke(t *testing.T) {
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
	defer embedder.Close()

	vec, err := embedder.Embed(format_document_for_embedding("Database backup", "restore snapshots and verify point in time recovery"))
	if err != nil {
		t.Fatalf("Embed: %v", err)
	}
	if len(vec) != 768 {
		t.Fatalf("embedding dimension = %d, want 768", len(vec))
	}

	var norm float64
	for _, v := range vec {
		if math.IsNaN(float64(v)) || math.IsInf(float64(v), 0) {
			t.Fatalf("embedding contains non-finite value: %v", v)
		}
		norm += float64(v) * float64(v)
	}
	if math.Abs(math.Sqrt(norm)-1.0) > 1e-4 {
		t.Fatalf("embedding norm = %.6f, want unit vector", math.Sqrt(norm))
	}

	query, err := embedder.Embed(format_query_for_embedding("Wie kann ich meine Datenbank aus einer Sicherung wiederherstellen?"))
	if err != nil {
		t.Fatalf("Embed query: %v", err)
	}
	unrelated, err := embedder.Embed(format_document_for_embedding("Garden", "Plant tomatoes in sunny soil and water them regularly."))
	if err != nil {
		t.Fatalf("Embed unrelated document: %v", err)
	}
	var relevantScore, unrelatedScore float64
	for i, v := range query {
		if math.IsNaN(float64(v)) || math.IsInf(float64(v), 0) || math.IsNaN(float64(unrelated[i])) || math.IsInf(float64(unrelated[i]), 0) {
			t.Fatal("query or unrelated embedding contains non-finite values")
		}
		relevantScore += float64(v) * float64(vec[i])
		unrelatedScore += float64(v) * float64(unrelated[i])
	}
	if relevantScore <= unrelatedScore {
		t.Fatalf("cross-language retrieval failed: backup=%f garden=%f", relevantScore, unrelatedScore)
	}
	t.Logf("cross-language retrieval: backup=%.4f garden=%.4f", relevantScore, unrelatedScore)
}

func TestRealEmbedderReadsBeyondOldTokenLimit(t *testing.T) {
	embedder := newRealEvalEmbedder(t)
	defer embedder.Close()

	// "hello" is a single token; both documents are identical through the old
	// 2,048-token limit. Truncating there would produce identical embeddings.
	prefix := strings.Repeat("hello ", 2200)
	backup, err := embedder.Embed(format_document_for_embedding("", prefix+strings.Repeat("restore database backup ", 40)))
	if err != nil {
		t.Fatal(err)
	}
	garden, err := embedder.Embed(format_document_for_embedding("", prefix+strings.Repeat("plant tomatoes garden ", 40)))
	if err != nil {
		t.Fatal(err)
	}
	var difference float64
	for i, v := range backup {
		if math.IsNaN(float64(v)) || math.IsInf(float64(v), 0) || math.IsNaN(float64(garden[i])) || math.IsInf(float64(garden[i]), 0) {
			t.Fatal("long-text embedding contains non-finite values")
		}
		difference += math.Abs(float64(v - garden[i]))
	}
	if difference < 1e-5 {
		t.Fatalf("content beyond old token limit was ignored: difference=%g", difference)
	}
}

func TestRealEmbedderLiteralMediaMarkers(t *testing.T) {
	embedder := newRealEvalEmbedder(t)
	defer embedder.Close()

	var firstQuery []float32
	for _, marker := range []string{"<|image|>", "<|video|>", "<|audio|>", "<|image|><|audio|><|video|><|image|>"} {
		for _, kind := range []string{"query", "document"} {
			t.Run(kind+"/"+marker, func(t *testing.T) {
				text := format_query_for_embedding("Explain the " + marker + " marker.")
				if kind == "document" {
					text = format_document_for_embedding("Marker "+marker, "The "+marker+" marker represents a media input.")
				}
				vec, err := embedder.Embed(text)
				if err != nil {
					t.Fatalf("Embed literal marker: %v", err)
				}
				if len(vec) != 768 {
					t.Fatalf("embedding dimension = %d, want 768", len(vec))
				}
				var norm float64
				for _, v := range vec {
					if math.IsNaN(float64(v)) || math.IsInf(float64(v), 0) {
						t.Fatalf("embedding contains non-finite value: %v", v)
					}
					norm += float64(v) * float64(v)
				}
				if math.Abs(math.Sqrt(norm)-1) > 1e-4 {
					t.Fatalf("embedding norm = %.6f, want unit vector", math.Sqrt(norm))
				}
				if kind == "query" {
					if firstQuery == nil {
						firstQuery = vec
					} else {
						var difference float64
						for i, v := range vec {
							difference += math.Abs(float64(v - firstQuery[i]))
						}
						if difference < 1e-5 {
							t.Fatal("different literal markers must not be discarded into identical query embeddings")
						}
					}
				}
			})
		}
	}
}
