package main

import (
	"context"
	"encoding/json"
	"fmt"
	"iter"
	"strings"

	"charm.land/fantasy"
	"charm.land/fantasy/providers/anthropic"
	"charm.land/fantasy/providers/openai"
	"charm.land/fantasy/providers/openaicompat"
	"charm.land/fantasy/providers/openrouter"
	adkagent "google.golang.org/adk/agent"
	"google.golang.org/adk/memory"
	"google.golang.org/adk/session"
	"google.golang.org/adk/tool"
	"google.golang.org/adk/tool/toolconfirmation"
	"google.golang.org/genai"
)

const fantasyAskAppName = "nrc-ai-ask"

type adkRunnableTool interface {
	tool.Tool
	Declaration() *genai.FunctionDeclaration
	Run(tool.Context, any) (map[string]any, error)
}

type fantasyADKTool struct {
	tool adkRunnableTool
	info fantasy.ToolInfo
}

func newFantasyLanguageModel(ctx context.Context, cfg Config) (fantasy.LanguageModel, error) {
	providerName := strings.ToLower(strings.TrimSpace(cfg.LLMProvider))
	modelName := strings.TrimSpace(cfg.LLMModel)
	if modelName == "" {
		return nil, fmt.Errorf("LLM_MODEL is required for ask engine")
	}

	provider, err := newFantasyProvider(providerName, cfg.LLMAPIKey, cfg.LLMBaseURL)
	if err != nil {
		return nil, err
	}
	return provider.LanguageModel(ctx, modelName)
}

func newFantasyProvider(providerName, apiKey, baseURL string) (fantasy.Provider, error) {
	switch providerName {
	case "openai", "":
		if apiKey == "" {
			return nil, fmt.Errorf("LLM_API_KEY is required for openai provider")
		}
		opts := []openai.Option{
			openai.WithAPIKey(apiKey),
			openai.WithUseResponsesAPI(),
			openai.WithResponsesAPIFunc(func(modelID string) bool {
				return modelID == "gpt-5.6" || strings.HasPrefix(modelID, "gpt-5.6-") ||
					modelID == "gpt-6" || strings.HasPrefix(modelID, "gpt-6-")
			}),
		}
		if baseURL != "" {
			opts = append(opts, openai.WithBaseURL(baseURL))
		}
		return openai.New(opts...)

	case "openai-compat", "openaicompat":
		if apiKey == "" {
			return nil, fmt.Errorf("LLM_API_KEY is required for openai-compat provider")
		}
		if baseURL == "" {
			return nil, fmt.Errorf("LLM_BASE_URL is required for openai-compat provider")
		}
		return openaicompat.New(openaicompat.WithAPIKey(apiKey), openaicompat.WithBaseURL(baseURL))

	case "deepseek":
		if apiKey == "" {
			return nil, fmt.Errorf("LLM_API_KEY is required for deepseek provider")
		}
		if baseURL == "" {
			baseURL = "https://api.deepseek.com/v1"
		}
		return openaicompat.New(openaicompat.WithAPIKey(apiKey), openaicompat.WithBaseURL(baseURL), openaicompat.WithName("deepseek"))

	case "mistral":
		if apiKey == "" {
			return nil, fmt.Errorf("LLM_API_KEY is required for mistral provider")
		}
		if baseURL == "" {
			baseURL = "https://api.mistral.ai/v1"
		}
		return openaicompat.New(openaicompat.WithAPIKey(apiKey), openaicompat.WithBaseURL(baseURL), openaicompat.WithName("mistral"))

	case "ollama":
		if baseURL == "" {
			baseURL = "http://localhost:11434/v1"
		}
		if apiKey == "" {
			apiKey = "ollama"
		}
		return openaicompat.New(openaicompat.WithAPIKey(apiKey), openaicompat.WithBaseURL(baseURL), openaicompat.WithName("ollama"))

	case "anthropic":
		if apiKey == "" {
			return nil, fmt.Errorf("LLM_API_KEY is required for anthropic provider")
		}
		opts := []anthropic.Option{anthropic.WithAPIKey(apiKey)}
		if baseURL != "" {
			opts = append(opts, anthropic.WithBaseURL(baseURL))
		}
		return anthropic.New(opts...)

	case "openrouter":
		if apiKey == "" {
			return nil, fmt.Errorf("LLM_API_KEY is required for openrouter provider")
		}
		return openrouter.New(openrouter.WithAPIKey(apiKey))

	default:
		return nil, fmt.Errorf("unknown ask LLM provider: %s (supported: openai, openai-compat, deepseek, mistral, ollama, anthropic, openrouter)", providerName)
	}
}

func wrapADKToolsForFantasy(tools ...tool.Tool) ([]fantasy.AgentTool, error) {
	wrapped := make([]fantasy.AgentTool, 0, len(tools))
	for _, t := range tools {
		runnable, ok := t.(adkRunnableTool)
		if !ok {
			return nil, fmt.Errorf("tool %s cannot be wrapped for fantasy", t.Name())
		}
		wrapped = append(wrapped, &fantasyADKTool{tool: runnable, info: fantasyToolInfo(runnable)})
	}
	return wrapped, nil
}

func fantasyToolInfo(t adkRunnableTool) fantasy.ToolInfo {
	info := fantasy.ToolInfo{Name: t.Name(), Description: t.Description(), Required: []string{}}
	decl := t.Declaration()
	if decl == nil {
		info.Parameters = map[string]any{}
		return info
	}
	if decl.Parameters != nil {
		if decl.Parameters.Required != nil {
			info.Required = append([]string(nil), decl.Parameters.Required...)
		}
		if decl.Parameters.Properties == nil {
			info.Parameters = map[string]any{}
			return info
		}
		data, err := json.Marshal(decl.Parameters.Properties)
		if err != nil {
			info.Parameters = map[string]any{}
			return info
		}
		if err := json.Unmarshal(data, &info.Parameters); err != nil {
			info.Parameters = map[string]any{}
		}
		return info
	}
	if decl.ParametersJsonSchema == nil {
		info.Parameters = map[string]any{}
		return info
	}
	data, err := json.Marshal(decl.ParametersJsonSchema)
	if err != nil {
		info.Parameters = map[string]any{}
		return info
	}
	var schema struct {
		Properties map[string]any `json:"properties"`
		Required   []string       `json:"required"`
	}
	if err := json.Unmarshal(data, &schema); err != nil {
		info.Parameters = map[string]any{}
		return info
	}
	if schema.Properties != nil {
		info.Parameters = schema.Properties
	} else {
		info.Parameters = map[string]any{}
	}
	if schema.Required != nil {
		info.Required = schema.Required
	}
	return info
}

func (t *fantasyADKTool) Info() fantasy.ToolInfo {
	return t.info
}

func (t *fantasyADKTool) ProviderOptions() fantasy.ProviderOptions {
	return nil
}

func (t *fantasyADKTool) SetProviderOptions(fantasy.ProviderOptions) {}

func (t *fantasyADKTool) Run(ctx context.Context, call fantasy.ToolCall) (fantasy.ToolResponse, error) {
	var input map[string]any
	if strings.TrimSpace(call.Input) != "" {
		if err := json.Unmarshal([]byte(call.Input), &input); err != nil {
			return fantasy.NewTextErrorResponse("invalid parameters: " + err.Error()), nil
		}
	}
	if input == nil {
		input = map[string]any{}
	}

	result, err := t.tool.Run(newFantasyADKToolContext(ctx, call.ID), input)
	if err != nil {
		return fantasy.NewTextErrorResponse(err.Error()), nil
	}
	data, err := json.Marshal(result)
	if err != nil {
		return fantasy.NewTextErrorResponse("failed to encode tool result: " + err.Error()), nil
	}
	return fantasy.NewTextResponse(string(data)), nil
}

type fantasyADKToolContext struct {
	context.Context
	state          fantasyADKState
	functionCallID string
	actions        session.EventActions
}

func newFantasyADKToolContext(ctx context.Context, functionCallID string) *fantasyADKToolContext {
	state := fantasyADKState{
		"workspace":        contextString(ctx, workspaceContextKey{}),
		"conv_id":          contextUint64(ctx, convIDContextKey{}),
		"mode":             contextString(ctx, agentModeContextKey{}),
		"agent_session_id": contextString(ctx, agentSessionContextKey{}),
		"action_plan_id":   contextString(ctx, actionPlanContextKey{}),
	}
	return &fantasyADKToolContext{Context: ctx, state: state, functionCallID: functionCallID}
}

func (c *fantasyADKToolContext) FunctionCallID() string                               { return c.functionCallID }
func (c *fantasyADKToolContext) Actions() *session.EventActions                       { return &c.actions }
func (c *fantasyADKToolContext) ToolConfirmation() *toolconfirmation.ToolConfirmation { return nil }
func (c *fantasyADKToolContext) RequestConfirmation(string, any) error {
	return fmt.Errorf("tool confirmation is not supported by the fantasy ask engine")
}
func (c *fantasyADKToolContext) SearchMemory(context.Context, string) (*memory.SearchResponse, error) {
	return nil, fmt.Errorf("memory search is not configured")
}
func (c *fantasyADKToolContext) UserContent() *genai.Content          { return nil }
func (c *fantasyADKToolContext) InvocationID() string                 { return c.functionCallID }
func (c *fantasyADKToolContext) AgentName() string                    { return "nrc_ask_agent" }
func (c *fantasyADKToolContext) ReadonlyState() session.ReadonlyState { return c.state }
func (c *fantasyADKToolContext) UserID() string                       { return "" }
func (c *fantasyADKToolContext) AppName() string                      { return fantasyAskAppName }
func (c *fantasyADKToolContext) SessionID() string                    { return "" }
func (c *fantasyADKToolContext) Branch() string                       { return "" }
func (c *fantasyADKToolContext) Artifacts() adkagent.Artifacts        { return nil }
func (c *fantasyADKToolContext) State() session.State                 { return c.state }

type fantasyADKState map[string]any

func (s fantasyADKState) Get(key string) (any, error) {
	value, ok := s[key]
	if !ok {
		return nil, session.ErrStateKeyNotExist
	}
	return value, nil
}

func (s fantasyADKState) Set(key string, value any) error {
	s[key] = value
	return nil
}

func (s fantasyADKState) All() iter.Seq2[string, any] {
	return func(yield func(string, any) bool) {
		for key, value := range s {
			if !yield(key, value) {
				return
			}
		}
	}
}

type workspaceContextKey struct{}
type convIDContextKey struct{}

func contextString(ctx context.Context, key any) string {
	value, _ := ctx.Value(key).(string)
	return value
}

func contextUint64(ctx context.Context, key any) uint64 {
	value, _ := ctx.Value(key).(uint64)
	return value
}
