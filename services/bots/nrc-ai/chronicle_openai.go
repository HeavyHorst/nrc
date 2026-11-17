package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
	"unicode/utf8"
)

const chronicleTerraModel = "gpt-6.1-terra"

// Separate profile in the existing sidecar, not Sullivan's chat model/client.
// Fixed endpoint and private credential prevent other provider keys/base URLs
// from silently being reused. Neither constructing this nor fake mode sends data.
type chronicleOpenAIProvider struct {
	client *http.Client
	key    string
}

func loadChronicleProvider(mode, keyFile string) (chronicleProvider, error) {
	switch mode {
	case "fake":
		return fakeChronicleProvider{}, nil
	case "terra":
		f, err := os.Open(keyFile)
		if err != nil {
			return nil, errors.New("cannot open chronicle API key file")
		}
		defer f.Close()
		info, err := f.Stat()
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
			return nil, errors.New("chronicle API key file must be private and regular")
		}
		data, err := io.ReadAll(io.LimitReader(f, 8193))
		key := strings.TrimSpace(string(data))
		if err != nil || len(data) > 8192 || key == "" || strings.IndexFunc(key, func(r rune) bool { return r < 33 || r > 126 }) != -1 {
			return nil, errors.New("invalid chronicle API key file")
		}
		return &chronicleOpenAIProvider{key: key, client: &http.Client{
			Timeout:       60 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		}}, nil
	default:
		return nil, errors.New("chronicle mode must be fake or terra")
	}
}

func (*chronicleOpenAIProvider) Model() string { return chronicleTerraModel }

// Identical text-only Responses profile to the synthetic p5 evaluation. Keep
// request construction shared by admission and send; schema, escaping, repeated
// instructions and envelope metadata all count, not just decoded note bodies.
func (*chronicleOpenAIProvider) request(payload []byte) []byte {
	schema := map[string]any{
		"type": "object", "additionalProperties": false,
		"properties": map[string]any{
			"outcome": map[string]any{"type": "string", "enum": []string{"result", "ack"}},
			"sources": map[string]any{"type": "array", "items": map[string]any{"type": "string"}},
			"summary": map[string]any{"type": "string"},
		},
		"required": []string{"outcome", "sources", "summary"},
	}
	// Only strings, booleans, integers and JSON-shaped constants are marshalled.
	data, _ := json.Marshal(map[string]any{
		"model": chronicleTerraModel, "instructions": chronicleInstructions, "input": string(payload),
		"reasoning": map[string]any{"effort": "none"}, "max_output_tokens": 1000,
		"store": false, "truncation": "disabled",
		"text": map[string]any{"format": map[string]any{"type": "json_schema", "name": "chronicle", "strict": true, "schema": schema}},
	})
	return data
}

func (p *chronicleOpenAIProvider) Bound(ctx context.Context, payload []byte) (int, error) {
	body := p.request(payload)
	bound := len(body) + 256
	if bound <= chronicleMaxInputTokens {
		return bound, nil
	}
	// Large serialized requests need not contain many tokens. Count the same
	// complete input/profile, including the output schema, without inference.
	// The counting endpoint does not accept storage or output-length options.
	var request map[string]json.RawMessage
	_ = json.Unmarshal(body, &request)
	delete(request, "store")
	delete(request, "max_output_tokens")
	body, _ = json.Marshal(request)
	data, err := p.post(ctx, "/responses/input_tokens", body)
	if err != nil {
		return 0, err
	}
	var count struct {
		Object string `json:"object"`
		Input  int    `json:"input_tokens"`
	}
	if len(data) > 64<<10 || !utf8.Valid(data) || json.Unmarshal(data, &count) != nil || count.Object != "response.input_tokens" || count.Input <= 0 || count.Input > bound {
		return 0, errors.New("invalid chronicle input token count")
	}
	return count.Input, nil
}

func (p *chronicleOpenAIProvider) post(ctx context.Context, path string, body []byte) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.openai.com/v1"+path, bytes.NewReader(body))
	if err != nil {
		return nil, errors.New("invalid chronicle provider request")
	}
	req.Header.Set("Authorization", "Bearer "+p.key)
	req.Header.Set("Content-Type", "application/json")
	// No application/SDK HTTP retries. Inference needs a durable reservation;
	// the free input-token count runs before reservation and consumes no attempt.
	resp, err := p.client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if errors.Is(err, context.DeadlineExceeded) {
			return nil, context.DeadlineExceeded
		}
		return nil, chronicleTemporaryError{}
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, (64<<10)+1))
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, chronicleTemporaryError{}
	}
	if resp.StatusCode != http.StatusOK {
		var failure struct {
			Error struct {
				Code string `json:"code"`
			} `json:"error"`
		}
		// Only a bounded error code is inspected; bodies/transport errors never
		// escape into worker logs, which may otherwise expose notes or keys.
		_ = json.Unmarshal(data, &failure)
		if resp.StatusCode == 429 && (failure.Error.Code == "insufficient_quota" || failure.Error.Code == "billing_hard_limit_reached") {
			return nil, errors.New("chronicle provider quota unavailable")
		}
		if resp.StatusCode == 408 || resp.StatusCode == 429 || resp.StatusCode >= 500 && resp.StatusCode <= 599 {
			return nil, chronicleTemporaryError{}
		}
		return nil, errors.New("chronicle provider request rejected")
	}
	return data, nil
}

func (p *chronicleOpenAIProvider) Complete(ctx context.Context, payload []byte) (chronicleCompletion, error) {
	body := p.request(payload)
	data, err := p.post(ctx, "/responses", body)
	if err != nil {
		return chronicleCompletion{}, err
	}
	invalid := chronicleCompletion{Truncated: true}
	if len(data) > 64<<10 || !utf8.Valid(data) {
		return invalid, nil
	}
	var result struct {
		Status string          `json:"status"`
		Error  json.RawMessage `json:"error"`
		Usage  *struct {
			Input  int `json:"input_tokens"`
			Output int `json:"output_tokens"`
		} `json:"usage"`
		Output []struct {
			Type    string `json:"type"`
			Status  string `json:"status"`
			Role    string `json:"role"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"output"`
	}
	if json.Unmarshal(data, &result) != nil || (result.Status != "completed" && result.Status != "incomplete") || (len(result.Error) != 0 && string(result.Error) != "null") {
		return invalid, nil
	}
	if result.Usage == nil || result.Usage.Input <= 0 || result.Usage.Output <= 0 || result.Usage.Input > len(body)+256 || result.Usage.Output > 1000 {
		// Never publish a response that contradicts the configured accounting
		// profile. Its reservation remains spent; deterministic failure parks it.
		return chronicleCompletion{}, errors.New("chronicle provider usage violates profile")
	}
	completion := chronicleCompletion{
		Truncated:   true,
		InputTokens: uint32(result.Usage.Input), OutputTokens: uint32(result.Usage.Output),
	}
	if result.Status != "completed" {
		return completion, nil
	}
	if len(result.Output) != 1 {
		return completion, nil
	}
	message := result.Output[0]
	if message.Type != "message" || message.Status != "completed" || message.Role != "assistant" || len(message.Content) != 1 {
		return completion, nil
	}
	if message.Content[0].Type == "refusal" {
		return completion, errors.New("chronicle provider refused request")
	}
	if message.Content[0].Type != "output_text" {
		return completion, nil
	}
	completion.JSON, completion.Truncated = []byte(message.Content[0].Text), false
	return completion, nil
}
