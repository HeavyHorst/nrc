//go:build noembed

package main

import "fmt"

type Embedder interface {
	Embed(text string) ([]float32, error)
	Close()
}

type stubEmbedder struct{}

func NewEmbedder(modelPath, tokenizerPath string) (Embedder, error) {
	return nil, fmt.Errorf("embedder not available: built with noembed tag")
}

func (e *stubEmbedder) Embed(text string) ([]float32, error) {
	return nil, fmt.Errorf("embedder not available: built with noembed tag")
}

func (e *stubEmbedder) Close() {}
