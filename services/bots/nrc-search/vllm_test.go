package main

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type vllmLocal struct {
	calls atomic.Int32
	fail  atomic.Bool
}

func (e *vllmLocal) Embed(string) ([]float32, error) {
	e.calls.Add(1)
	if e.fail.Load() {
		return nil, errors.New("local inference failed")
	}
	vec := make([]float32, 768)
	vec[0], vec[1] = 0.6, 0.8
	return vec, nil
}
func (e *vllmLocal) EmbedMedia(kind, path string, offset int) ([]float32, error) {
	return e.Embed("")
}
func (*vllmLocal) Close() {}

func writeVLLMVector(w http.ResponseWriter) {
	vec := make([]float32, 768)
	// Similar but not identical to local: prove that successful requests return
	// the normalized remote result, rather than silently always falling back.
	vec[0], vec[1] = 3, 4.1
	json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{"index": 0, "embedding": vec}}})
}

func testVLLM(local Embedder, endpoint string) *vllmEmbedder {
	return withVLLM(local, Config{VLLMURL: endpoint, VLLMModel: "google/embeddinggemma-2", VLLMTimeout: time.Second, VLLMMedia: true}).(*vllmEmbedder)
}

func assertRemoteVector(t *testing.T, vec []float32, err error) {
	t.Helper()
	if err != nil || len(vec) != 768 || math.Abs(float64(vec[0])-3/math.Sqrt(3*3+4.1*4.1)) > 1e-6 {
		t.Fatalf("expected normalized remote result, got %v (length %d)", err, len(vec))
	}
}

func TestVLLMTextFallbackRecoveryAndConcurrency(t *testing.T) {
	local := &vllmLocal{}
	var fail atomic.Bool
	var requests atomic.Int32
	query := format_query_for_embedding("Datenbank wiederherstellen?")
	document := format_document_for_embedding("Garden", "Plant tomatoes.")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		var req vllmRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Error(err)
		}
		if r.Method != "POST" || r.URL.Path != "/v1/embeddings" || req.Model != "google/embeddinggemma-2" || !req.AddSpecialTokens || req.EncodingFormat != "float" || len(req.Messages) != 0 || (req.Input != query && req.Input != document) {
			t.Errorf("unexpected request: %+v", req)
		}
		if fail.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		writeVLLMVector(w)
	}))
	defer server.Close()
	e := testVLLM(local, server.URL+"/v1/embeddings")
	defer e.Close()
	for _, text := range []string{query, document} {
		vec, err := e.Embed(text)
		assertRemoteVector(t, vec, err)
	}
	var wg sync.WaitGroup
	for range 20 {
		wg.Go(func() {
			vec, err := e.Embed(query)
			assertRemoteVector(t, vec, err)
		})
	}
	wg.Wait()
	if local.calls.Load() != 2 {
		t.Fatalf("local should only verify query and document once, got %d calls", local.calls.Load())
	}
	fail.Store(true)
	for range 2 {
		vec, err := e.Embed(query)
		if err != nil || vec[0] != 0.6 {
			t.Fatalf("expected local fallback: %v", err)
		}
	}
	if requests.Load() != 23 {
		t.Fatalf("cooldown failed: %d requests", requests.Load())
	}
	fail.Store(false)
	e.states["query"].retryAt = time.Time{}
	vec, err := e.Embed(query)
	assertRemoteVector(t, vec, err)
	if requests.Load() != 24 || local.calls.Load() != 5 {
		t.Fatal("recovery must recheck compatibility")
	}
}

func TestVLLMParallelIndexing(t *testing.T) {
	for _, mode := range []string{"queue", "chunks", "shutdown"} {
		t.Run(mode, func(t *testing.T) {
			var blocking, unavailable atomic.Bool
			var active, peak atomic.Int32
			entered := make(chan struct{}, 32)
			release := make(chan struct{})
			var releaseOnce sync.Once
			unblock := func() { releaseOnce.Do(func() { close(release) }) }
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if unavailable.Load() {
					w.WriteHeader(http.StatusServiceUnavailable)
					return
				}
				var req struct {
					Input string `json:"input"`
				}
				if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
					t.Error(err)
				}
				if blocking.Load() {
					n := active.Add(1)
					defer active.Add(-1)
					for old := peak.Load(); n > old; old = peak.Load() {
						if peak.CompareAndSwap(old, n) {
							break
						}
					}
					entered <- struct{}{}
					<-release
				}
				vec := make([]float32, 768)
				vec[0], vec[1], vec[2] = 3, 4.1, float32(len(req.Input)%17)/100
				json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{"index": 0, "embedding": vec}}})
			}))
			defer server.Close()
			defer unblock()
			e := testVLLM(&vllmLocal{}, server.URL)
			e.client.Timeout = 5 * time.Second
			defer e.Close()
			if _, err := e.Embed("warm document"); err != nil {
				t.Fatal(err)
			}
			blocking.Store(true)
			ctx, cancel := context.WithCancel(context.Background())
			var workers sync.WaitGroup
			defer func() { cancel(); unblock(); workers.Wait() }()
			storage := newTestStorage(t)
			client := newTaskClient(t, storage, e)
			drained := make(chan struct{})
			if mode != "chunks" {
				for id := uint64(1); id <= 8; id++ {
					entry := QueueEntry{ConvID: 7, Preview: fmt.Sprintf("original %d", id), Version: 1}
					var err error
					if id <= 4 {
						err = storage.EnqueueEntity(taskIdentity("ws", id, 7), entry)
					} else {
						err = storage.EnqueueAsset("ws", id, entry)
					}
					if err != nil {
						t.Fatal(err)
					}
				}
				workers.Go(func() { client.DrainEmbedQueue(ctx); close(drained) })
			} else {
				for doc := range 2 {
					workers.Go(func() {
						text := strings.Repeat(fmt.Sprintf("document%d ", doc), 4201+doc)
						chunks, _, err := embedDocumentChunks(e, "test", text)
						if err != nil {
							t.Error(err)
							return
						}
						expected := chunkDocumentForEmbedding(text)
						if len(chunks) != len(expected) || len(chunks) < 4 {
							t.Errorf("unexpected chunk count %d", len(chunks))
							return
						}
						for i, chunk := range chunks {
							x := float64(float32(len(format_document_for_embedding("test", expected[i].Text))%17) / 100)
							want := x / math.Sqrt(9+float64(float32(4.1))*float64(float32(4.1))+x*x)
							if chunk.Index != i || math.Abs(float64(chunk.Vector[2])-want) > 1e-6 {
								t.Errorf("chunk %d changed order/vector", i)
							}
						}
					})
				}
			}
			for range 4 {
				select {
				case <-entered:
				case <-time.After(2 * time.Second):
					t.Fatal("indexing did not issue four concurrent requests")
				}
			}
			select {
			case <-entered:
				t.Fatal("more than four requests in flight")
			case <-time.After(50 * time.Millisecond):
			}
			if mode == "queue" {
				if err := storage.EnqueueEntity(taskIdentity("ws", 1, 7), QueueEntry{ConvID: 7, Preview: "updated", Version: 2}); err != nil {
					t.Fatal(err)
				}
				if err := storage.DeleteEntityQueueEntry(taskIdentity("ws", 2, 7)); err != nil {
					t.Fatal(err)
				}
				client.signalPersistentQueue()
			}
			if mode == "shutdown" {
				cancel()
				select {
				case <-drained:
					t.Fatal("shutdown returned while indexing was active")
				case <-time.After(50 * time.Millisecond):
				}
			}
			unblock()
			if mode == "queue" {
				deadline := time.Now().Add(3 * time.Second)
				for {
					empty, err := storage.QueuesEmpty("ws")
					if err != nil {
						t.Fatal(err)
					}
					if empty {
						break
					}
					if time.Now().After(deadline) {
						t.Fatal("persistent queue did not drain")
					}
					time.Sleep(time.Millisecond)
				}
				cancel()
				workers.Wait()
				entry, ok := client.index.GetEntity(taskIdentity("ws", 1, 7))
				if !ok || entry.Preview != "updated" {
					t.Fatal("newer version was lost")
				}
				if _, ok := client.index.GetEntity(taskIdentity("ws", 2, 7)); ok {
					t.Fatal("deleted job was published")
				}
				for id := uint64(5); id <= 8; id++ {
					if _, ok := client.index.GetEntity(assetIdentity("ws", id, 7)); !ok {
						t.Fatal("legacy queue entry lost")
					}
				}
			} else {
				workers.Wait()
			}
			if mode == "shutdown" {
				if size, err := storage.QueueSize("ws"); err != nil || size != 4 {
					t.Fatalf("shutdown lost pending jobs: size=%d error=%v", size, err)
				}
			}
			if peak.Load() != 4 {
				t.Fatalf("peak concurrent requests = %d", peak.Load())
			}
			unavailable.Store(true)
			chunks, _, err := embedDocumentChunks(e, "fallback", strings.Repeat("word ", 3000))
			if err != nil || len(chunks) < 4 {
				t.Fatalf("parallel fallback failed: %v", err)
			}
			for _, chunk := range chunks {
				if chunk.Vector[0] != 0.6 {
					t.Fatal("missing ONNX fallback")
				}
			}
		})
	}
}

func TestVLLMIndexingRetriesLocalFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusServiceUnavailable) }))
	defer server.Close()
	local := &flakyEmbedder{failures: 2}
	e := testVLLM(local, server.URL)
	defer e.Close()
	storage := newTestStorage(t)
	client := newTaskClient(t, storage, e)
	identity := taskIdentity("ws", 99, 7)
	if err := storage.EnqueueEntity(identity, QueueEntry{ConvID: 7, Preview: "retry", Version: 1}); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { client.DrainEmbedQueue(ctx); close(done) }()
	defer func() { cancel(); <-done }()
	for deadline := time.Now().Add(3 * time.Second); ; {
		if _, ok := client.index.GetEntity(identity); ok {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("parallel queue did not retry without unrelated work")
		}
		time.Sleep(time.Millisecond)
	}
	local.mu.Lock()
	defer local.mu.Unlock()
	if local.attempts != 3 {
		t.Fatalf("attempts=%d, want 3", local.attempts)
	}
}

func TestVLLMQueuedRequestsDuringOutage(t *testing.T) {
	for _, mode := range []string{"cooldown", "deadline"} {
		t.Run(mode, func(t *testing.T) {
			var outage atomic.Bool
			var requests atomic.Int32
			entered := make(chan struct{}, 32)
			release := make(chan struct{})
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if !outage.Load() {
					writeVLLMVector(w)
					return
				}
				requests.Add(1)
				entered <- struct{}{}
				select {
				case <-release:
				case <-r.Context().Done():
				}
				w.WriteHeader(http.StatusServiceUnavailable)
			}))
			defer server.Close()
			var once sync.Once
			unblock := func() { once.Do(func() { close(release) }) }
			defer unblock()
			e := testVLLM(&vllmLocal{}, server.URL)
			e.client.Timeout = 800 * time.Millisecond
			defer e.Close()
			query := format_query_for_embedding("query")
			for _, text := range []string{"document", query} {
				vec, err := e.Embed(text)
				assertRemoteVector(t, vec, err)
			}
			outage.Store(true)
			var workers sync.WaitGroup
			defer func() { unblock(); workers.Wait() }()
			for range 4 {
				workers.Go(func() {
					vec, err := e.Embed("document")
					if err != nil || vec[0] != 0.6 {
						t.Error("missing fallback")
					}
				})
			}
			for range 4 {
				select {
				case <-entered:
				case <-time.After(2 * time.Second):
					t.Fatal("requests did not start")
				}
			}
			if mode == "deadline" {
				start := time.Now()
				vec, err := e.Embed(query)
				if err != nil || vec[0] != 0.6 {
					t.Fatal("query did not fall back")
				}
				if elapsed := time.Since(start); elapsed > 1200*time.Millisecond {
					t.Fatalf("queue wait plus HTTP exceeded one timeout: %s", elapsed)
				}
			} else {
				for range 12 {
					workers.Go(func() {
						vec, err := e.Embed("document")
						if err != nil || vec[0] != 0.6 {
							t.Error("missing queued fallback")
						}
					})
				}
				// Keep all four slots occupied while the remaining calls queue.
				time.Sleep(50 * time.Millisecond)
				unblock()
				workers.Wait()
				if requests.Load() != 4 {
					t.Fatalf("cooldown bypassed by queued requests: got %d HTTP calls, want 4", requests.Load())
				}
			}
		})
	}
}

func TestVLLMRejectsInvalidResponses(t *testing.T) {
	for _, mode := range []string{"status", "json", "count", "index", "dimension", "zero", "overflow", "oversized", "incompatible", "timeout", "disconnected"} {
		t.Run(mode, func(t *testing.T) {
			local := &vllmLocal{}
			release := make(chan struct{})
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch mode {
				case "status":
					w.WriteHeader(http.StatusInternalServerError)
					return
				case "json":
					w.Write([]byte("not json"))
					return
				case "overflow":
					w.Write([]byte(`{"data":[{"embedding":[1e100]}]}`))
					return
				case "oversized":
					w.Write([]byte(strings.Repeat(" ", (1<<20)+1)))
					return
				case "timeout":
					<-release
					return
				}
				vec := make([]float32, 768)
				vec[0], vec[1] = 3, 4.1
				index := 0
				switch mode {
				case "dimension":
					vec = vec[:767]
				case "index":
					index = 1
				case "zero":
					clear(vec)
				case "incompatible":
					vec[0], vec[1] = -3, -4.1
				}
				data := []any{map[string]any{"index": index, "embedding": vec}}
				if mode == "count" {
					data = append(data, data[0])
				}
				json.NewEncoder(w).Encode(map[string]any{"data": data})
			}))
			defer server.Close()
			defer close(release)
			if mode == "disconnected" {
				server.Close()
			}
			e := testVLLM(local, server.URL)
			if mode == "timeout" {
				e.client.Timeout = 30 * time.Millisecond
			}
			defer e.Close()
			vec, err := e.Embed("actual document")
			if err != nil || len(vec) != 768 || vec[0] != 0.6 {
				t.Fatalf("fallback must hide remote failure: %v", err)
			}
			local.fail.Store(true)
			if _, err := e.Embed("actual document"); err == nil {
				t.Fatal("local inference error must remain visible")
			}
		})
	}
}

func TestVLLMConfiguration(t *testing.T) {
	local := &vllmLocal{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("media must not leave the process without explicit opt-in")
	}))
	defer server.Close()
	defaultBackend := withVLLM(local, Config{VLLMURL: server.URL, VLLMModel: "google/embeddinggemma-2", VLLMTimeout: time.Second})
	defer defaultBackend.Close()
	vec, err := defaultBackend.(mediaEmbedder).EmbedMedia("image", "unused", 0)
	if err != nil || len(vec) != 768 || vec[0] != 0.6 {
		t.Fatal("media must remain local by default")
	}
	for _, endpoint := range []string{"", ":invalid", "ftp://gpu/model", "http://user:pass@gpu/v1/embeddings"} {
		if withVLLM(local, Config{VLLMURL: endpoint}) != local {
			t.Fatal("absent or invalid endpoint must keep ONNX")
		}
	}
	t.Setenv("SEARCH_VLLM_URL", "http://gpu:18080/v1/embeddings")
	t.Setenv("SEARCH_VLLM_MODEL", "google/embeddinggemma-2")
	t.Setenv("SEARCH_VLLM_TIMEOUT", "750ms")
	t.Setenv("SEARCH_VLLM_MEDIA", "true")
	cfg := loadConfig()
	if cfg.VLLMURL != "http://gpu:18080/v1/embeddings" || cfg.VLLMModel != "google/embeddinggemma-2" || cfg.VLLMTimeout != 750*time.Millisecond || !cfg.VLLMMedia {
		t.Fatal("vLLM configuration not loaded")
	}
	for _, value := range []string{"", "invalid", "0s", "-1s"} {
		t.Setenv("SEARCH_VLLM_TIMEOUT", value)
		if loadConfig().VLLMTimeout != 3*time.Second {
			t.Fatalf("invalid timeout %q did not retain default", value)
		}
	}
}

type vllmTokenLocal struct{ vllmLocal }

func (*vllmTokenLocal) Tokenize(string) []uint32 { return []uint32{2, 123, 456, 1} }

func TestVLLMUsesLocalTokens(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Input            []uint32 `json:"input"`
			AddSpecialTokens bool     `json:"add_special_tokens"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Error(err)
		}
		if !reflect.DeepEqual(req.Input, []uint32{2, 123, 456, 1}) || req.AddSpecialTokens {
			t.Errorf("token IDs must be preserved without duplicate BOS/EOS: %+v", req)
		}
		writeVLLMVector(w)
	}))
	defer server.Close()
	e := testVLLM(&vllmTokenLocal{}, server.URL)
	defer e.Close()
	vec, err := e.Embed(format_query_for_embedding("literal <|image|> marker"))
	assertRemoteVector(t, vec, err)
}

// Real decoding and transport, without model weights. The image is asymmetric
// and the audio's second segment has different samples to catch offset loss.
func vllmMediaFixtures(t *testing.T) (string, string) {
	t.Helper()
	dir := t.TempDir()
	img := image.NewRGBA(image.Rect(0, 0, 48, 24))
	for y := range 24 {
		for x := range 48 {
			img.SetRGBA(x, y, color.RGBA{uint8(x * 5), uint8(y * 10), 91, 255})
		}
	}
	imagePath := filepath.Join(dir, "image.png")
	f, err := os.Create(imagePath)
	if err != nil {
		t.Fatal(err)
	}
	if err := png.Encode(f, img); err != nil {
		t.Fatal(err)
	}
	f.Close()
	wav := make([]byte, 44+31*16000*2)
	copy(wav, "RIFF")
	binary.LittleEndian.PutUint32(wav[4:], uint32(len(wav)-8))
	copy(wav[8:], "WAVEfmt ")
	binary.LittleEndian.PutUint32(wav[16:], 16)
	binary.LittleEndian.PutUint16(wav[20:], 1)
	binary.LittleEndian.PutUint16(wav[22:], 1)
	binary.LittleEndian.PutUint32(wav[24:], 16000)
	binary.LittleEndian.PutUint32(wav[28:], 32000)
	binary.LittleEndian.PutUint16(wav[32:], 2)
	binary.LittleEndian.PutUint16(wav[34:], 16)
	copy(wav[36:], "data")
	binary.LittleEndian.PutUint32(wav[40:], uint32(len(wav)-44))
	for i := range 31 * 16000 {
		value := uint16(8192)
		if i < 30*16000 {
			value = 16384
		}
		binary.LittleEndian.PutUint16(wav[44+i*2:], value)
	}
	audioPath := filepath.Join(dir, "audio.wav")
	if err := os.WriteFile(audioPath, wav, 0600); err != nil {
		t.Fatal(err)
	}
	return imagePath, audioPath
}

func TestVLLMOversizedImageDoesNotDisableRemote(t *testing.T) {
	if err := exec.Command("node", "--input-type=module", "-e", "await import('./media_worker.mjs')").Run(); err != nil {
		t.Skip("requires Node and npm ci")
	}
	small, _ := vllmMediaFixtures(t)
	large := filepath.Join(t.TempDir(), "noise.png")
	img := image.NewNRGBA(image.Rect(0, 0, 2048, 2048))
	seed := uint32(1234567)
	for i := range img.Pix {
		seed ^= seed << 13
		seed ^= seed >> 17
		seed ^= seed << 5
		img.Pix[i] = byte(seed)
		if i%4 == 3 {
			img.Pix[i] = 255
		}
	}
	f, err := os.Create(large)
	if err != nil {
		t.Fatal(err)
	}
	if err := png.Encode(f, img); err != nil {
		f.Close()
		t.Fatal(err)
	}
	f.Close()
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { requests.Add(1); writeVLLMVector(w) }))
	defer server.Close()
	local := &vllmLocal{}
	e := testVLLM(local, server.URL)
	defer e.Close()
	// Exercise both before and after the first image compatibility check.
	for round := range 2 {
		vec, err := e.EmbedMedia("image", large, 0)
		if err != nil || vec[0] != 0.6 {
			t.Fatalf("oversized image did not fall back: %v", err)
		}
		if requests.Load() != int32(round) {
			t.Fatal("oversized image reached remote")
		}
		vec, err = e.EmbedMedia("image", small, 0)
		assertRemoteVector(t, vec, err)
	}
	if requests.Load() != 2 || local.calls.Load() != 3 {
		t.Fatalf("requests=%d local calls=%d", requests.Load(), local.calls.Load())
	}
}

func TestVLLMMediaTransportAndFallback(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("requires FFmpeg")
	}
	if err := exec.Command("node", "--input-type=module", "-e", "await import('./media_worker.mjs')").Run(); err != nil {
		t.Skip("requires Node and npm ci")
	}
	imagePath, audioPath := vllmMediaFixtures(t)
	local := &vllmLocal{}
	var fail atomic.Bool
	var requests atomic.Int32
	var expectedSamples atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		var req vllmRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Error(err)
			return
		}
		if !req.AddSpecialTokens || req.Input != nil || len(req.Messages) != 1 || len(req.Messages[0].Content) != 1 || req.Messages[0].Role != "user" {
			t.Errorf("invalid multimodal request: %+v", req)
			return
		}
		part := req.Messages[0].Content[0]
		switch part["type"] {
		case "image_url":
			uri := part["image_url"].(map[string]any)["url"].(string)
			data, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(uri, "data:image/png;base64,"))
			if err != nil {
				t.Error(err)
			}
			img, err := png.Decode(strings.NewReader(string(data)))
			if err != nil || img.Bounds().Dx() != 48 || img.Bounds().Dy() != 24 {
				t.Errorf("image changed: %v", err)
				return
			}
			if pixel := color.NRGBAModel.Convert(img.At(47, 23)); pixel != (color.NRGBA{235, 230, 91, 255}) {
				t.Errorf("image pixels changed: %v", pixel)
			}
		case "input_audio":
			audio := part["input_audio"].(map[string]any)
			data, err := base64.StdEncoding.DecodeString(audio["data"].(string))
			if err != nil || len(data) != 44+int(expectedSamples.Load())*4 || audio["format"] != "wav" {
				t.Errorf("invalid audio segment: %v, %d bytes", err, len(data))
				return
			}
			value := float32(0.25)
			if expectedSamples.Load() == 480000 {
				value = 0.5
			}
			if string(data[:4]) != "RIFF" || binary.LittleEndian.Uint16(data[20:]) != 3 || math.Float32frombits(binary.LittleEndian.Uint32(data[44:])) != value {
				t.Error("audio samples or float WAV format changed")
			}
		default:
			t.Errorf("unexpected media part %v", part["type"])
		}
		if fail.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		writeVLLMVector(w)
	}))
	defer server.Close()
	e := testVLLM(local, server.URL)
	defer e.Close()
	for _, item := range []struct {
		kind, path string
		offset     int
	}{{"image", imagePath, 0}, {"audio", audioPath, 0}, {"audio", audioPath, 30}} {
		expectedSamples.Store(16000)
		if item.offset == 0 {
			expectedSamples.Store(480000)
		}
		for range 2 {
			vec, err := e.EmbedMedia(item.kind, item.path, item.offset)
			assertRemoteVector(t, vec, err)
		}
	}
	if local.calls.Load() != 2 {
		t.Fatal("expected only first-input parity checks locally")
	}
	vec, err := e.EmbedMedia("audio", audioPath, 60)
	if err != nil || len(vec) != 0 || requests.Load() != 6 {
		t.Fatal("EOF must return no vector without HTTP request")
	}
	fail.Store(true)
	vec, err = e.EmbedMedia("audio", audioPath, 30)
	if err != nil || len(vec) != 768 || !reflect.DeepEqual(vec[:2], []float32{0.6, 0.8}) {
		t.Fatalf("media fallback failed: %v", err)
	}
}

// Allow the initial ONNX compatibility check, then refuse local inference so
// the live test cannot pass by comparing ONNX with its own fallback output.
type parityLocal struct {
	local Embedder
	calls int
}

func (p *parityLocal) Tokenize(text string) []uint32 {
	return p.local.(interface{ Tokenize(string) []uint32 }).Tokenize(text)
}

func (p *parityLocal) Embed(text string) ([]float32, error) {
	p.calls++
	if p.calls > 1 {
		return nil, errors.New("unexpected local fallback in live vLLM test")
	}
	return p.local.Embed(text)
}

func (p *parityLocal) EmbedMedia(kind, path string, offset int) ([]float32, error) {
	p.calls++
	if p.calls > 1 {
		return nil, errors.New("unexpected local media fallback in live vLLM test")
	}
	return p.local.(mediaEmbedder).EmbedMedia(kind, path, offset)
}

func (*parityLocal) Close() {} // The test owns the shared ONNX model.

func TestVLLMLiveONNXParity(t *testing.T) {
	endpoint := os.Getenv("TEST_VLLM_URL")
	if endpoint == "" {
		t.Skip("set TEST_VLLM_URL and the native ONNX model paths")
	}
	for _, tc := range []struct{ name, text, kind, path string }{
		{name: "query", text: format_query_for_embedding("Wie stelle ich eine Datenbank aus einer Sicherung wieder her?")},
		{name: "document", text: format_document_for_embedding("Garden", "Plant tomatoes in sunny soil and water them regularly.")},
		{name: "long", text: format_document_for_embedding("Recovery", strings.Repeat("Restore the database backup and verify the snapshots. ", 280))},
		{name: "literal-marker", text: format_query_for_embedding("What does the literal <|image|> marker mean?")},
		{name: "image", kind: "image", path: os.Getenv("TEST_VLLM_IMAGE")},
		{name: "audio", kind: "audio", path: os.Getenv("TEST_VLLM_AUDIO")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if tc.kind != "" && tc.path == "" {
				t.Skip("set TEST_VLLM_IMAGE / TEST_VLLM_AUDIO for media parity")
			}
			local, err := NewEmbedder(os.Getenv("TEST_MODEL_PATH"), os.Getenv("TEST_TOKENIZER_PATH"))
			if err != nil {
				t.Fatal(err)
			}
			defer local.Close()
			e := withVLLM(&parityLocal{local: local}, Config{VLLMURL: endpoint, VLLMModel: "google/embeddinggemma-2", VLLMTimeout: 30 * time.Second, VLLMMedia: true})
			defer e.Close()
			var reference []float32
			if tc.kind == "" {
				reference, err = local.Embed(tc.text)
			} else {
				reference, err = any(local).(mediaEmbedder).EmbedMedia(tc.kind, tc.path, 0)
			}
			if err != nil {
				t.Fatal(err)
			}
			for round := range 2 {
				var vec []float32
				if tc.kind == "" {
					vec, err = e.Embed(tc.text)
				} else {
					vec, err = e.(mediaEmbedder).EmbedMedia(tc.kind, tc.path, 0)
				}
				if err != nil || len(vec) != 768 || len(reference) != 768 {
					t.Fatalf("live inference failed: %v", err)
				}
				var dot, a, b float64
				for i, value := range reference {
					x, y := float64(value), float64(vec[i])
					dot += x * y
					a += x * x
					b += y * y
				}
				similarity := dot / math.Sqrt(a*b)
				t.Logf("round=%d cosine=%.9f", round, similarity)
				if math.IsNaN(similarity) || similarity < 0.995 {
					t.Fatalf("ONNX/vLLM parity below threshold: %.9f", similarity)
				}
			}
		})
	}
}
