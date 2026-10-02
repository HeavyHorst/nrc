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
		norm += float64(v) * float64(v)
	}
	if math.Abs(math.Sqrt(norm)-1.0) > 1e-4 {
		t.Fatalf("embedding norm = %.6f, want unit vector", math.Sqrt(norm))
	}
}
