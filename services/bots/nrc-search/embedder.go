//go:build !noembed

package main

import (
	"fmt"
	"log/slog"
	"os"

	"github.com/daulet/tokenizers"
	ort "github.com/yalue/onnxruntime_go"
)

type Embedder interface {
	Embed(text string) ([]float32, error)
	Close()
}

type ONNXEmbedder struct {
	session   *ort.DynamicAdvancedSession
	tokenizer *tokenizers.Tokenizer
	maxSeqLen int
	dim       int
}

func NewEmbedder(modelPath, tokenizerPath string) (*ONNXEmbedder, error) {
	ortPath := os.Getenv("ONNXRUNTIME_PATH")
	if ortPath == "" {
		ortPath = "/usr/local/lib/libonnxruntime.so"
	}
	ort.SetSharedLibraryPath(ortPath)
	if err := ort.InitializeEnvironment(); err != nil {
		return nil, fmt.Errorf("initializing ONNX runtime: %w", err)
	}

	// User text can mention media markers literally. Tokenize their spelling
	// as ordinary text instead of injecting placeholders for absent media.
	// Encode(text, true) still adds the model's BOS/EOS via post-processing.
	tokenizerData, err := os.ReadFile(tokenizerPath)
	if err != nil {
		ort.DestroyEnvironment()
		return nil, fmt.Errorf("reading tokenizer from %s: %w", tokenizerPath, err)
	}
	tok, err := tokenizers.FromBytes(tokenizerData, tokenizers.WithEncodeSpecialTokens())
	if err != nil {
		ort.DestroyEnvironment()
		return nil, fmt.Errorf("loading tokenizer from %s: %w", tokenizerPath, err)
	}

	opts, err := ort.NewSessionOptions()
	if err != nil {
		tok.Close()
		ort.DestroyEnvironment()
		return nil, fmt.Errorf("creating session options: %w", err)
	}

	inputNames := []string{"input_ids", "attention_mask", "image_features", "video_features", "audio_features"}
	outputName := "sentence_embedding"
	slog.Info("using output", "name", outputName)

	session, err := ort.NewDynamicAdvancedSession(modelPath, inputNames, []string{outputName}, opts)
	if err != nil {
		opts.Destroy()
		tok.Close()
		ort.DestroyEnvironment()
		return nil, fmt.Errorf("creating ONNX session from %s: %w", modelPath, err)
	}
	opts.Destroy()

	slog.Info("embedder initialized", "model", modelPath, "tokenizer", tokenizerPath)

	return &ONNXEmbedder{
		session:   session,
		tokenizer: tok,
		maxSeqLen: 8192,
		dim:       768,
	}, nil
}

func (e *ONNXEmbedder) Embed(text string) ([]float32, error) {
	tokenIDs, _ := e.tokenizer.Encode(text, true)

	seqLen := len(tokenIDs)
	if seqLen > e.maxSeqLen {
		seqLen = e.maxSeqLen
		tokenIDs = tokenIDs[:seqLen]
	}

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

	outputTensor, err := ort.NewEmptyTensor[float32](ort.Shape{1, int64(e.dim)})
	if err != nil {
		return nil, fmt.Errorf("creating output tensor: %w", err)
	}
	defer outputTensor.Destroy()

	err = e.session.Run(
		[]ort.Value{inputIDsTensor, attentionMaskTensor, mediaFeatures, mediaFeatures, mediaFeatures},
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
	normalize(embedding)
	return embedding, nil
}

func (e *ONNXEmbedder) Close() {
	if e.session != nil {
		e.session.Destroy()
	}
	if e.tokenizer != nil {
		e.tokenizer.Close()
	}
	ort.DestroyEnvironment()
	slog.Info("embedder closed")
}
