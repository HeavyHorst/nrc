package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

type vllmRequest struct {
	Model            string        `json:"model"`
	Input            any           `json:"input,omitempty"`
	Messages         []vllmMessage `json:"messages,omitempty"`
	EncodingFormat   string        `json:"encoding_format"`
	AddSpecialTokens bool          `json:"add_special_tokens"`
}

type vllmMessage struct {
	Role    string           `json:"role"`
	Content []map[string]any `json:"content"`
}

type remoteModality struct {
	verified bool
	checking bool
	retryAt  time.Time
}

const vllmConcurrency = 4

type vllmEmbedder struct {
	local       Embedder
	client      *http.Client
	slots       chan struct{}
	endpoint    string
	model       string
	remoteMedia bool
	media       mediaWorker
	mu          sync.Mutex
	states      map[string]*remoteModality
}

func withVLLM(local Embedder, cfg Config) Embedder {
	if cfg.VLLMURL == "" {
		return local
	}
	u, err := url.Parse(cfg.VLLMURL)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || u.RawQuery != "" || u.Fragment != "" || u.User != nil {
		slog.Warn("invalid SEARCH_VLLM_URL; using local ONNX")
		return local
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.MaxIdleConnsPerHost = vllmConcurrency
	return &vllmEmbedder{
		local: local, endpoint: cfg.VLLMURL, model: cfg.VLLMModel,
		slots:       make(chan struct{}, vllmConcurrency),
		remoteMedia: cfg.VLLMMedia,
		states:      make(map[string]*remoteModality),
		client: &http.Client{Transport: transport, Timeout: cfg.VLLMTimeout, CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		}},
	}
}

func (e *vllmEmbedder) Embed(text string) ([]float32, error) {
	kind := "document"
	if strings.HasPrefix(text, embedding_gemma_query_prefix) {
		kind = "query"
	}
	return e.embed(kind, func() (*vllmRequest, error) {
		if tokenizer, ok := e.local.(interface{ Tokenize(string) []uint32 }); ok {
			return &vllmRequest{Input: tokenizer.Tokenize(text)}, nil
		}
		return &vllmRequest{Input: text}, nil
	}, func() ([]float32, error) { return e.local.Embed(text) })
}

func (e *vllmEmbedder) EmbedMedia(kind, path string, offset int) ([]float32, error) {
	local, ok := e.local.(mediaEmbedder)
	if !ok || (kind != "image" && kind != "audio") {
		return nil, fmt.Errorf("local model has no %s encoder", kind)
	}
	if !e.remoteMedia {
		return local.EmbedMedia(kind, path, offset)
	}
	return e.embed(kind, func() (*vllmRequest, error) {
		prepared, err := e.media.request(kind, path, offset, true)
		if err != nil {
			return nil, err
		}
		if prepared.LocalOnly {
			return nil, fmt.Errorf("prepared media exceeds remote transport limit")
		}
		// A segment beyond EOF is not an embedding failure.
		if kind == "audio" && prepared.Data == "" {
			return nil, nil
		}
		var part map[string]any
		if kind == "image" {
			part = map[string]any{"type": "image_url", "image_url": map[string]string{"url": "data:image/png;base64," + prepared.Data}}
		} else {
			part = map[string]any{"type": "input_audio", "input_audio": map[string]string{"data": prepared.Data, "format": "wav"}}
		}
		return &vllmRequest{Messages: []vllmMessage{{Role: "user", Content: []map[string]any{part}}}}, nil
	}, func() ([]float32, error) { return local.EmbedMedia(kind, path, offset) })
}

// Verify the first real input per modality against ONNX, including query and
// document prompts separately. This catches preprocessing/model mismatches, but
// does not replace pinning the same model and checking retrieval quality.
func (e *vllmEmbedder) embed(kind string, prepare func() (*vllmRequest, error), fallback func() ([]float32, error)) ([]float32, error) {
	e.mu.Lock()
	state := e.states[kind]
	if state == nil {
		state = &remoteModality{}
		e.states[kind] = state
	}
	if state.checking || time.Now().Before(state.retryAt) {
		e.mu.Unlock()
		return fallback()
	}
	verify := !state.verified
	state.checking = verify
	e.mu.Unlock()

	req, err := prepare()
	var remote, local []float32
	var localErr error
	var acquired, attempted bool
	if err == nil && req != nil {
		// Admission and HTTP share one budget; local preparation/inference do not.
		ctx, cancel := context.WithTimeout(context.Background(), e.client.Timeout)
		defer cancel()
		select {
		case e.slots <- struct{}{}:
			acquired = true
		case <-ctx.Done():
			err = ctx.Err()
		}
		if acquired {
			e.mu.Lock()
			cooldown := time.Now().Before(state.retryAt)
			e.mu.Unlock()
			if cooldown {
				err = fmt.Errorf("vLLM cooldown active")
			} else if ctx.Err() != nil {
				err = ctx.Err()
			} else {
				attempted = true
				remote, err = e.remote(ctx, req)
			}
		}
		if err == nil && verify {
			local, localErr = fallback()
			if localErr != nil || !compatibleVectors(local, remote) {
				err = fmt.Errorf("incompatible ONNX and vLLM embeddings")
			}
		}
	}
	e.mu.Lock()
	if verify {
		state.checking = false
	}
	// Per-input preparation failures and admission expiry say nothing about
	// endpoint health and must not start or extend its cooldown.
	if err != nil && attempted {
		if !time.Now().Before(state.retryAt) {
			// Never log document text, file paths, URL or remote response bodies.
			slog.Warn("vLLM unavailable or incompatible; using ONNX for 30s", "kind", kind)
		}
		state.verified = false
		state.retryAt = time.Now().Add(30 * time.Second)
	} else if err == nil && req != nil && verify && !time.Now().Before(state.retryAt) {
		state.verified = true
		slog.Info("vLLM/ONNX compatibility check passed", "kind", kind)
	}
	e.mu.Unlock()
	if acquired {
		// Publish failure state before waking the next waiter.
		<-e.slots
	}
	if err != nil {
		if local != nil || localErr != nil {
			return local, localErr
		}
		return fallback()
	}
	return remote, nil
}

func compatibleVectors(a, b []float32) bool {
	if len(a) != 768 || len(b) != 768 {
		return false
	}
	var dot, an, bn float64
	for i, v := range a {
		x, y := float64(v), float64(b[i])
		dot += x * y
		an += x * x
		bn += y * y
	}
	similarity := dot / math.Sqrt(an*bn)
	return !math.IsNaN(similarity) && !math.IsInf(similarity, 0) && similarity >= 0.995
}

func (e *vllmEmbedder) remote(ctx context.Context, req *vllmRequest) ([]float32, error) {
	req.Model, req.EncodingFormat, req.AddSpecialTokens = e.model, "float", true
	if _, tokenized := req.Input.([]uint32); tokenized {
		req.AddSpecialTokens = false // BOS/EOS are already present.
	}
	body, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, e.endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	resp, err := e.client.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("vLLM status %d", resp.StatusCode)
	}
	var result struct {
		Data []struct {
			Index     int       `json:"index"`
			Embedding []float32 `json:"embedding"`
		} `json:"data"`
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, (1<<20)+1))
	if err != nil {
		return nil, err
	}
	if len(data) > 1<<20 {
		return nil, fmt.Errorf("vLLM response exceeds limit")
	}
	if err := json.Unmarshal(data, &result); err != nil {
		return nil, err
	}
	if len(result.Data) != 1 || result.Data[0].Index != 0 || len(result.Data[0].Embedding) != 768 {
		return nil, fmt.Errorf("unexpected embedding shape")
	}
	vec := result.Data[0].Embedding
	var norm float64
	for _, v := range vec {
		norm += float64(v) * float64(v)
	}
	if norm == 0 || math.IsNaN(norm) || math.IsInf(norm, 0) {
		return nil, fmt.Errorf("invalid embedding")
	}
	norm = math.Sqrt(norm)
	for i := range vec {
		vec[i] = float32(float64(vec[i]) / norm)
	}
	return vec, nil
}

func (e *vllmEmbedder) Close() {
	e.client.CloseIdleConnections()
	e.media.Close()
	e.local.Close()
}
