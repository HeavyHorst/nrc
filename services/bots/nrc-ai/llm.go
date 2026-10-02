package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

type LLM interface {
	Complete(ctx context.Context, req CompletionRequest) (CompletionResponse, error)
}

type CompletionRequest struct {
	System   string
	Messages []LLMMessage
	JSON     bool
}

type LLMMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type CompletionResponse struct {
	Content string
}

func NewLLM(provider, model, apiKey, baseURL string) (LLM, error) {
	client := &http.Client{Timeout: 120 * time.Second}

	switch provider {
	case "openai":
		if apiKey == "" {
			return nil, fmt.Errorf("LLM_API_KEY is required for openai provider")
		}
		url := "https://api.openai.com/v1/chat/completions"
		if baseURL != "" {
			url = baseURL + "/chat/completions"
		}
		return &OpenAILLM{client: client, apiKey: apiKey, model: model, url: url}, nil

	case "openai-compat", "openaicompat":
		if apiKey == "" {
			return nil, fmt.Errorf("LLM_API_KEY is required for openai-compat provider")
		}
		if baseURL == "" {
			return nil, fmt.Errorf("LLM_BASE_URL is required for openai-compat provider")
		}
		return &OpenAILLM{client: client, apiKey: apiKey, model: model, url: baseURL + "/chat/completions"}, nil

	case "openrouter":
		if apiKey == "" {
			return nil, fmt.Errorf("LLM_API_KEY is required for openrouter provider")
		}
		url := "https://openrouter.ai/api/v1/chat/completions"
		if baseURL != "" {
			url = baseURL + "/chat/completions"
		}
		return &OpenAILLM{client: client, apiKey: apiKey, model: model, url: url}, nil

	case "deepseek":
		if apiKey == "" {
			return nil, fmt.Errorf("LLM_API_KEY is required for deepseek provider")
		}
		url := "https://api.deepseek.com/v1/chat/completions"
		if baseURL != "" {
			url = baseURL + "/chat/completions"
		}
		return &OpenAILLM{client: client, apiKey: apiKey, model: model, url: url}, nil

	case "mistral":
		if apiKey == "" {
			return nil, fmt.Errorf("LLM_API_KEY is required for mistral provider")
		}
		url := "https://api.mistral.ai/v1/chat/completions"
		if baseURL != "" {
			url = baseURL + "/chat/completions"
		}
		return &OpenAILLM{client: client, apiKey: apiKey, model: model, url: url}, nil

	case "anthropic":
		if apiKey == "" {
			return nil, fmt.Errorf("LLM_API_KEY is required for anthropic provider")
		}
		url := "https://api.anthropic.com/v1/messages"
		if baseURL != "" {
			url = baseURL + "/messages"
		}
		return &AnthropicLLM{client: client, apiKey: apiKey, model: model, url: url}, nil

	case "ollama":
		// NOTE: In Docker, set LLM_BASE_URL=http://host.docker.internal:11434
		// since localhost refers to the container itself.
		url := "http://localhost:11434/api/chat"
		if baseURL != "" {
			url = baseURL + "/api/chat"
		}
		return &OllamaLLM{client: client, model: model, url: url}, nil

	default:
		return nil, fmt.Errorf("unknown LLM provider: %s (supported: openai, openai-compat, openrouter, deepseek, mistral, anthropic, ollama)", provider)
	}
}

// OpenAI

type OpenAILLM struct {
	client *http.Client
	apiKey string
	model  string
	url    string
}

type openAIRequest struct {
	Model          string         `json:"model"`
	Messages       []openAIMsg    `json:"messages"`
	ResponseFormat *openAIRespFmt `json:"response_format,omitempty"`
}

type openAIMsg struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type openAIRespFmt struct {
	Type string `json:"type"`
}

type openAIResponse struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
	Error *struct {
		Message string `json:"message"`
	} `json:"error"`
}

func (o *OpenAILLM) Complete(ctx context.Context, req CompletionRequest) (CompletionResponse, error) {
	msgs := make([]openAIMsg, 0, len(req.Messages)+1)
	if req.System != "" {
		msgs = append(msgs, openAIMsg{Role: "system", Content: req.System})
	}
	for _, m := range req.Messages {
		msgs = append(msgs, openAIMsg{Role: m.Role, Content: m.Content})
	}

	body := openAIRequest{
		Model:    o.model,
		Messages: msgs,
	}
	if req.JSON {
		body.ResponseFormat = &openAIRespFmt{Type: "json_object"}
	}

	data, err := json.Marshal(body)
	if err != nil {
		return CompletionResponse{}, fmt.Errorf("marshal request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, "POST", o.url, bytes.NewReader(data))
	if err != nil {
		return CompletionResponse{}, fmt.Errorf("create request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Authorization", "Bearer "+o.apiKey)

	resp, err := o.client.Do(httpReq)
	if err != nil {
		return CompletionResponse{}, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return CompletionResponse{}, fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode != 200 {
		return CompletionResponse{}, fmt.Errorf("openai API error (status %d): %s", resp.StatusCode, string(respBody))
	}

	var result openAIResponse
	if err := json.Unmarshal(respBody, &result); err != nil {
		return CompletionResponse{}, fmt.Errorf("decode response: %w", err)
	}
	if result.Error != nil {
		return CompletionResponse{}, fmt.Errorf("openai error: %s", result.Error.Message)
	}
	if len(result.Choices) == 0 {
		return CompletionResponse{}, fmt.Errorf("openai returned no choices")
	}

	return CompletionResponse{Content: result.Choices[0].Message.Content}, nil
}

// Anthropic

type AnthropicLLM struct {
	client *http.Client
	apiKey string
	model  string
	url    string
}

type anthropicRequest struct {
	Model     string         `json:"model"`
	MaxTokens int            `json:"max_tokens"`
	System    string         `json:"system,omitempty"`
	Messages  []anthropicMsg `json:"messages"`
}

type anthropicMsg struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type anthropicResponse struct {
	Content []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"content"`
	Error *struct {
		Type    string `json:"type"`
		Message string `json:"message"`
	} `json:"error"`
}

func (a *AnthropicLLM) Complete(ctx context.Context, req CompletionRequest) (CompletionResponse, error) {
	system := req.System
	if req.JSON && system != "" {
		system += "\n\nIMPORTANT: You MUST respond with valid JSON only. No markdown fences, no commentary."
	}

	msgs := make([]anthropicMsg, 0, len(req.Messages))
	for _, m := range req.Messages {
		msgs = append(msgs, anthropicMsg{Role: m.Role, Content: m.Content})
	}

	body := anthropicRequest{
		Model:     a.model,
		MaxTokens: 4096,
		System:    system,
		Messages:  msgs,
	}

	data, err := json.Marshal(body)
	if err != nil {
		return CompletionResponse{}, fmt.Errorf("marshal request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, "POST", a.url, bytes.NewReader(data))
	if err != nil {
		return CompletionResponse{}, fmt.Errorf("create request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("x-api-key", a.apiKey)
	httpReq.Header.Set("anthropic-version", "2023-06-01")

	resp, err := a.client.Do(httpReq)
	if err != nil {
		return CompletionResponse{}, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return CompletionResponse{}, fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode != 200 {
		return CompletionResponse{}, fmt.Errorf("anthropic API error (status %d): %s", resp.StatusCode, string(respBody))
	}

	var result anthropicResponse
	if err := json.Unmarshal(respBody, &result); err != nil {
		return CompletionResponse{}, fmt.Errorf("decode response: %w", err)
	}
	if result.Error != nil {
		return CompletionResponse{}, fmt.Errorf("anthropic error: %s: %s", result.Error.Type, result.Error.Message)
	}
	if len(result.Content) == 0 {
		return CompletionResponse{}, fmt.Errorf("anthropic returned no content")
	}

	return CompletionResponse{Content: result.Content[0].Text}, nil
}

// Ollama

type OllamaLLM struct {
	client *http.Client
	model  string
	url    string
}

type ollamaRequest struct {
	Model    string      `json:"model"`
	Messages []ollamaMsg `json:"messages"`
	Stream   bool        `json:"stream"`
	Format   string      `json:"format,omitempty"`
}

type ollamaMsg struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type ollamaResponse struct {
	Message struct {
		Content string `json:"content"`
	} `json:"message"`
	Error string `json:"error,omitempty"`
}

func (o *OllamaLLM) Complete(ctx context.Context, req CompletionRequest) (CompletionResponse, error) {
	msgs := make([]ollamaMsg, 0, len(req.Messages)+1)
	if req.System != "" {
		msgs = append(msgs, ollamaMsg{Role: "system", Content: req.System})
	}
	for _, m := range req.Messages {
		msgs = append(msgs, ollamaMsg{Role: m.Role, Content: m.Content})
	}

	body := ollamaRequest{
		Model:    o.model,
		Messages: msgs,
		Stream:   false,
	}
	if req.JSON {
		body.Format = "json"
	}

	data, err := json.Marshal(body)
	if err != nil {
		return CompletionResponse{}, fmt.Errorf("marshal request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, "POST", o.url, bytes.NewReader(data))
	if err != nil {
		return CompletionResponse{}, fmt.Errorf("create request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := o.client.Do(httpReq)
	if err != nil {
		return CompletionResponse{}, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return CompletionResponse{}, fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode != 200 {
		return CompletionResponse{}, fmt.Errorf("ollama API error (status %d): %s", resp.StatusCode, string(respBody))
	}

	var result ollamaResponse
	if err := json.Unmarshal(respBody, &result); err != nil {
		return CompletionResponse{}, fmt.Errorf("decode response: %w", err)
	}
	if result.Error != "" {
		return CompletionResponse{}, fmt.Errorf("ollama error: %s", result.Error)
	}

	return CompletionResponse{Content: result.Message.Content}, nil
}
