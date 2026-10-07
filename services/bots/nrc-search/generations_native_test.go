//go:build !noembed

package main

import (
	"math"
	"os"
	"testing"
)

func TestRealOldAndNewModelsOverlapAndRetireIndependently(t *testing.T) {
	oldPath := os.Getenv("TEST_PREVIOUS_MODEL_PATH")
	if oldPath == "" {
		t.Skip("set TEST_PREVIOUS_MODEL_PATH and TEST_PREVIOUS_TOKENIZER_PATH")
	}
	old, err := newGenerationEmbedder(oldPath, os.Getenv("TEST_PREVIOUS_TOKENIZER_PATH"), true)
	if err != nil {
		t.Fatal(err)
	}
	oldClosed := false
	defer func() {
		if !oldClosed {
			old.Close()
		}
	}()
	current, err := NewEmbedder(os.Getenv("TEST_MODEL_PATH"), os.Getenv("TEST_TOKENIZER_PATH"))
	if err != nil {
		t.Fatal(err)
	}
	defer current.Close()
	query := format_query_for_embedding("restore database backup")
	oldVector, err := old.Embed(query)
	if err != nil {
		t.Fatal(err)
	}
	newVector, err := current.Embed(query)
	if err != nil {
		t.Fatal(err)
	}
	var difference float64
	for i, value := range oldVector {
		difference += math.Abs(float64(value - newVector[i]))
	}
	if difference < 1e-3 {
		t.Fatal("old and new models unexpectedly used the same vector space")
	}
	old.Close()
	oldClosed = true
	after, err := current.Embed(query)
	if err != nil {
		t.Fatalf("retiring old model destroyed new runtime: %v", err)
	}
	for i, value := range after {
		if math.Abs(float64(value-newVector[i])) > 1e-5 {
			t.Fatal("new model changed after retirement")
		}
	}
	if _, err := newGenerationEmbedder("missing-model", "missing-tokenizer", true); err == nil {
		t.Fatal("failed constructor must report error")
	}
	if _, err := current.Embed(query); err != nil {
		t.Fatalf("failed constructor destroyed active runtime: %v", err)
	}
}
