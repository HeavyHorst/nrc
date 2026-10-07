//go:build !noembed

package main

import (
	"fmt"
	"log/slog"
	"math"
	"os"
	"sync"

	"github.com/daulet/tokenizers"
	ort "github.com/yalue/onnxruntime_go"
)

type Embedder interface {
	Embed(text string) ([]float32, error)
	Close()
}

type ONNXEmbedder struct {
	mu        sync.Mutex
	session   *ort.DynamicAdvancedSession
	tokenizer *tokenizers.Tokenizer
	maxSeqLen int
	dim       int
	media     mediaWorker
	legacy    bool
}

var runtimeMu sync.Mutex
var runtimeUsers int

func NewEmbedder(modelPath, tokenizerPath string) (*ONNXEmbedder, error) {
	return newGenerationEmbedder(modelPath, tokenizerPath, false)
}

func newGenerationEmbedder(modelPath, tokenizerPath string, legacy bool) (*ONNXEmbedder, error) {
	runtimeMu.Lock()
	defer runtimeMu.Unlock()
	ortPath := os.Getenv("ONNXRUNTIME_PATH")
	if ortPath == "" {
		ortPath = "/usr/local/lib/libonnxruntime.so"
	}
	if runtimeUsers == 0 {
		ort.SetSharedLibraryPath(ortPath)
		if err := ort.InitializeEnvironment(); err != nil {
			return nil, fmt.Errorf("initializing ONNX runtime: %w", err)
		}
	}
	defer func() {
		if runtimeUsers == 0 {
			ort.DestroyEnvironment()
		}
	}()

	// User text can mention media markers literally. Tokenize their spelling
	// as ordinary text instead of injecting placeholders for absent media.
	// Encode(text, true) still adds the model's BOS/EOS via post-processing.
	tokenizerData, err := os.ReadFile(tokenizerPath)
	if err != nil {
		return nil, fmt.Errorf("reading tokenizer from %s: %w", tokenizerPath, err)
	}
	var tok *tokenizers.Tokenizer
	if legacy {
		tok, err = tokenizers.FromBytes(tokenizerData)
	} else {
		tok, err = tokenizers.FromBytes(tokenizerData, tokenizers.WithEncodeSpecialTokens())
	}
	if err != nil {
		return nil, fmt.Errorf("loading tokenizer from %s: %w", tokenizerPath, err)
	}

	opts, err := ort.NewSessionOptions()
	if err != nil {
		tok.Close()
		return nil, fmt.Errorf("creating session options: %w", err)
	}

	inputNames := []string{"input_ids", "attention_mask", "image_features", "video_features", "audio_features"}
	maxSeqLen := 8192
	if legacy {
		inputNames = inputNames[:2]
		maxSeqLen = 2048
	}
	outputName := "sentence_embedding"
	slog.Info("using output", "name", outputName)

	session, err := ort.NewDynamicAdvancedSession(modelPath, inputNames, []string{outputName}, opts)
	if err != nil {
		opts.Destroy()
		tok.Close()
		return nil, fmt.Errorf("creating ONNX session from %s: %w", modelPath, err)
	}
	opts.Destroy()
	runtimeUsers++

	slog.Info("embedder initialized", "model", modelPath, "tokenizer", tokenizerPath)

	return &ONNXEmbedder{
		session:   session,
		tokenizer: tok,
		maxSeqLen: maxSeqLen,
		dim:       768,
		legacy:    legacy,
	}, nil
}

func (e *ONNXEmbedder) Embed(text string) ([]float32, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	tokenIDs, _ := e.tokenizer.Encode(text, true)

	seqLen := len(tokenIDs)
	if seqLen > e.maxSeqLen {
		seqLen = e.maxSeqLen
		tokenIDs = tokenIDs[:seqLen]
	}
	return e.run(tokenIDs, "", nil)
}

func (e *ONNXEmbedder) EmbedMedia(kind, path string, offset int) ([]float32, error) {
	if e.legacy {
		return nil, fmt.Errorf("legacy model has no media encoder")
	}
	features, count, err := e.media.features(kind, path, offset)
	if err != nil || count == 0 {
		return nil, err
	}
	begin, slot, end := uint32(255999), uint32(258880), uint32(258882)
	if kind == "audio" {
		begin, slot, end = 256000, 258881, 258883
	}
	// Media-only inputs have no search/document prompt. Delimiters and BOS/EOS
	// are hard tokens; only the feature slots are replaced by the model.
	ids := make([]uint32, count+4)
	ids[0], ids[1], ids[len(ids)-2], ids[len(ids)-1] = 2, begin, end, 1
	for i := 2; i < len(ids)-2; i++ {
		ids[i] = slot
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.run(ids, kind, features)
}

func (e *ONNXEmbedder) run(tokenIDs []uint32, kind string, features []float32) ([]float32, error) {
	seqLen := len(tokenIDs)
	inputIDs := make([]int64, seqLen)
	attentionMask := make([]int64, seqLen)
	for i, id := range tokenIDs {
		inputIDs[i] = int64(id)
		attentionMask[i] = 1
	}

	shape := ort.Shape{1, int64(seqLen)}

	inputIDsTensor, err := ort.NewTensor(shape, inputIDs)
	if err != nil {
		return nil, fmt.Errorf("creating input_ids tensor: %w", err)
	}
	defer inputIDsTensor.Destroy()

	attentionMaskTensor, err := ort.NewTensor(shape, attentionMask)
	if err != nil {
		return nil, fmt.Errorf("creating attention_mask tensor: %w", err)
	}
	defer attentionMaskTensor.Destroy()

	// EmbeddingGemma 2's text model accepts features from separate modality
	// encoders. Text-only inference supplies no media tokens.
	mediaFeatures, err := ort.NewEmptyTensor[float32](ort.Shape{0, 512})
	if err != nil {
		return nil, fmt.Errorf("creating empty media features tensor: %w", err)
	}
	defer mediaFeatures.Destroy()
	mediaInputs := []ort.Value{mediaFeatures, mediaFeatures, mediaFeatures}
	if len(features) > 0 {
		featureTensor, err := ort.NewTensor(ort.Shape{int64(len(features) / 512), 512}, features)
		if err != nil {
			return nil, fmt.Errorf("creating media features: %w", err)
		}
		defer featureTensor.Destroy()
		if kind == "image" {
			mediaInputs[0] = featureTensor
		} else {
			mediaInputs[2] = featureTensor
		}
	}

	outputTensor, err := ort.NewEmptyTensor[float32](ort.Shape{1, int64(e.dim)})
	if err != nil {
		return nil, fmt.Errorf("creating output tensor: %w", err)
	}
	defer outputTensor.Destroy()

	inputs := []ort.Value{inputIDsTensor, attentionMaskTensor}
	if !e.legacy {
		inputs = append(inputs, mediaInputs...)
	}
	err = e.session.Run(
		inputs,
		[]ort.Value{outputTensor},
	)
	if err != nil {
		return nil, fmt.Errorf("running ONNX session: %w", err)
	}

	data := outputTensor.GetData()
	if len(data) != e.dim {
		return nil, fmt.Errorf("unexpected output size: got %d, expected %d", len(data), e.dim)
	}

	embedding := make([]float32, e.dim)
	copy(embedding, data)
	for _, value := range embedding {
		if math.IsNaN(float64(value)) || math.IsInf(float64(value), 0) {
			return nil, fmt.Errorf("non-finite embedding")
		}
	}
	normalize(embedding)
	return embedding, nil
}

func (e *ONNXEmbedder) Close() {
	e.media.Close()
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.session != nil {
		e.session.Destroy()
	}
	if e.tokenizer != nil {
		e.tokenizer.Close()
	}
	runtimeMu.Lock()
	runtimeUsers--
	if runtimeUsers == 0 {
		ort.DestroyEnvironment()
	}
	runtimeMu.Unlock()
	slog.Info("embedder closed")
}
