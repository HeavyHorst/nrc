package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"

	"charm.land/fantasy"
)

type researchTestModel struct {
	fantasy.LanguageModel
	generate func(context.Context, fantasy.Call) (*fantasy.Response, error)
}

func (m researchTestModel) Generate(ctx context.Context, call fantasy.Call) (*fantasy.Response, error) {
	return m.generate(ctx, call)
}

func researchText(text string) *fantasy.Response {
	return &fantasy.Response{Content: fantasy.ResponseContent{fantasy.TextContent{Text: text}}, FinishReason: fantasy.FinishReasonStop}
}

func TestResearchGrowingContext(t *testing.T) {
	for _, tc := range []struct{ sol, failSummary bool }{{false, false}, {false, true}, {true, false}, {true, true}} {
		t.Run(fmt.Sprintf("sol=%t/summary-failure=%t", tc.sol, tc.failSummary), func(t *testing.T) {
			const request = "Check monitoring; do not approve or execute changes."
			const system = "Only report evidence."
			const scope = "Workspace and approval scope remain unchanged."
			const tail = "EXACT-TAIL-ä🙂"
			text := strings.Repeat("large untrusted measurement evidence\n", 2000) + tail
			var lookups atomic.Int32
			modelSteps, summaries := 0, 0
			provider := researchTestModel{generate: func(ctx context.Context, call fantasy.Call) (*fantasy.Response, error) {
				if len(call.Tools) == 0 {
					summaries++
					if tc.failSummary {
						return nil, errors.New("summary service unavailable")
					}
					return researchText("Source evidence is partial; exact measurements require reading the original reference."), nil
				}
				modelSteps++
				if call.Prompt[0].Content[0].(fantasy.TextPart).Text != system || call.Prompt[1].Content[0].(fantasy.TextPart).Text != scope {
					t.Fatal("system or scope changed")
				}
				foundRequest := false
				pending := map[string]bool{}
				var lastResult string
				for _, message := range call.Prompt {
					for _, part := range message.Content {
						if p, ok := fantasy.AsMessagePart[fantasy.TextPart](part); ok && p.Text == request {
							foundRequest = true
						}
						if p, ok := fantasy.AsMessagePart[fantasy.ToolCallPart](part); ok {
							pending[p.ToolCallID] = true
						}
						if p, ok := fantasy.AsMessagePart[fantasy.ToolResultPart](part); ok {
							if !pending[p.ToolCallID] {
								t.Fatal("orphan tool result", p.ToolCallID)
							}
							delete(pending, p.ToolCallID)
							if output, ok := fantasy.AsToolResultOutputType[fantasy.ToolResultOutputContentText](p.Output); ok {
								lastResult = output.Text
							}
						}
					}
				}
				if !foundRequest || len(pending) != 0 {
					t.Fatal("request lost or dangling tool call")
				}
				// Six growing rounds, followed by an exact read beyond every preview.
				if modelSteps <= 6 {
					return &fantasy.Response{Content: fantasy.ResponseContent{
						fantasy.ToolCallContent{ToolCallID: fmt.Sprintf("%d-a", modelSteps), ToolName: "lookup", Input: `{}`},
						fantasy.ToolCallContent{ToolCallID: fmt.Sprintf("%d-b", modelSteps), ToolName: "lookup", Input: `{}`},
					}, FinishReason: fantasy.FinishReasonToolCalls}, nil
				}
				if modelSteps == 7 {
					var page struct {
						Reference string `json:"reference"`
						HasMore   bool   `json:"has_more"`
					}
					if json.Unmarshal([]byte(lastResult), &page) != nil || page.Reference == "" || !page.HasMore {
						t.Fatalf("missing original continuation: %s", lastResult)
					}
					input, _ := json.Marshal(map[string]any{"reference": page.Reference, "offset": len(text) - len(tail), "limit": 128})
					return &fantasy.Response{Content: fantasy.ResponseContent{fantasy.ToolCallContent{ToolCallID: "tail-read", ToolName: "read_research_context", Input: string(input)}}, FinishReason: fantasy.FinishReasonToolCalls}, nil
				}
				var page struct {
					Text    string `json:"text"`
					HasMore bool   `json:"has_more"`
				}
				if json.Unmarshal([]byte(lastResult), &page) != nil || page.Text != tail || page.HasMore {
					t.Fatalf("original bytes lost: %s", lastResult)
				}
				return researchText(page.Text), nil
			}}
			lookup := fantasy.NewAgentTool("lookup", "Read evidence", func(context.Context, struct{}, fantasy.ToolCall) (fantasy.ToolResponse, error) {
				lookups.Add(1)
				return fantasy.NewTextResponse(text), nil
			})
			model := timedAskModel{LanguageModel: provider, maxContextTokens: 24000, maxOutputTokens: 1024}
			if tc.sol {
				model = configuredAskModel(provider, Config{LLMProvider: "openai", LLMModel: "gpt-6.1-sol", LLMMaxOutputTokens: 1024}, 16000)
			}
			agent := fantasy.NewAgent(model, fantasy.WithSystemPrompt(system), fantasy.WithTools(lookup, newResearchContextTool()), fantasy.WithMaxOutputTokens(1024), fantasy.WithStopConditions(fantasy.StepCountIs(10)))
			answer, attempts, err := runFantasyAskWithRetry(t.Context(), agent, request, fantasy.NewUserMessage(scope))
			if err != nil || answer != tail || attempts != 1 || lookups.Load() != 12 || modelSteps != 8 || summaries == 0 {
				t.Fatalf("answer=%q attempts=%d lookups=%d steps=%d summaries=%d err=%v", answer, attempts, lookups.Load(), modelSteps, summaries, err)
			}
		})
	}
}

func TestResearchProviderOverflowRetriesOnlyModelStep(t *testing.T) {
	for _, tc := range []struct{ sol, alwaysReject bool }{{false, false}, {false, true}, {true, false}, {true, true}} {
		t.Run(fmt.Sprintf("sol=%t/always-reject=%t", tc.sol, tc.alwaysReject), func(t *testing.T) {
			calls, lookups := 0, 0
			provider := researchTestModel{generate: func(ctx context.Context, call fantasy.Call) (*fantasy.Response, error) {
				if len(call.Tools) == 0 {
					return researchText("Already read evidence; no action was approved."), nil
				}
				calls++
				if calls == 1 {
					return &fantasy.Response{Content: fantasy.ResponseContent{fantasy.ToolCallContent{ToolCallID: "one", ToolName: "lookup", Input: `{}`}}, FinishReason: fantasy.FinishReasonToolCalls}, nil
				}
				if calls == 2 || tc.alwaysReject {
					return nil, &fantasy.ProviderError{ContextTooLargeErr: true, StatusCode: 400}
				}
				return researchText("Continued without replay"), nil
			}}
			lookup := fantasy.NewAgentTool("lookup", "Read", func(context.Context, struct{}, fantasy.ToolCall) (fantasy.ToolResponse, error) {
				lookups++
				return fantasy.NewTextResponse(strings.Repeat("evidence ", 500)), nil
			})
			model := timedAskModel{LanguageModel: provider, maxContextTokens: 24000, maxOutputTokens: 1024}
			if tc.sol {
				model = configuredAskModel(provider, Config{LLMProvider: "openai", LLMModel: "gpt-6.1-sol", LLMMaxOutputTokens: 1024}, 24000)
			}
			agent := fantasy.NewAgent(model, fantasy.WithSystemPrompt("Instructions"), fantasy.WithTools(lookup), fantasy.WithMaxOutputTokens(1024))
			answer, attempts, err := runFantasyAskWithRetry(t.Context(), agent, "Current question")
			if calls != 3 || lookups != 1 || attempts != 1 || (tc.alwaysReject && err == nil) || (!tc.alwaysReject && (err != nil || answer != "Continued without replay")) {
				t.Fatalf("calls=%d lookups=%d attempts=%d answer=%q err=%v", calls, lookups, attempts, answer, err)
			}
		})
	}
}

func TestResearchContextIsolationAndUnchangedSmallInput(t *testing.T) {
	r := newResearchContext()
	id := r.retain("private original")
	input, _ := json.Marshal(map[string]any{"reference": id})
	for _, r := range []*researchContext{newResearchContext(), nil} {
		ctx := t.Context()
		if r != nil {
			ctx = context.WithValue(ctx, researchContextKey{}, r)
		}
		response, err := newResearchContextTool().Run(ctx, fantasy.ToolCall{Input: string(input)})
		if err != nil || !response.IsError {
			t.Fatalf("cross-request read allowed: %+v %v", response, err)
		}
	}
	call := fantasy.Call{Prompt: fantasy.Prompt{fantasy.NewSystemMessage("instructions"), fantasy.NewUserMessage("question")}}
	provider := researchTestModel{generate: func(_ context.Context, got fantasy.Call) (*fantasy.Response, error) {
		if !reflect.DeepEqual(call, got) {
			t.Fatal("small input changed")
		}
		return researchText("ok"), nil
	}}
	ctx := context.WithValue(t.Context(), researchContextKey{}, newResearchContext())
	_, err := (timedAskModel{LanguageModel: provider, maxContextTokens: 16000, maxOutputTokens: 1024}).Generate(ctx, call)
	if err != nil {
		t.Fatal(err)
	}
}

func TestSolContextConfigurationAndTokenEstimate(t *testing.T) {
	t.Setenv("LLM_PROVIDER", "openai")
	t.Setenv("LLM_MODEL", "gpt-6.1-sol")
	t.Setenv("MAX_CONTEXT_TOKENS", "")
	cfg := loadConfig()
	if cfg.MaxContextTokens != 240000 {
		t.Fatal(cfg.MaxContextTokens)
	}
	t.Setenv("MAX_CONTEXT_TOKENS", "2000000")
	cfg = loadConfig()
	m := configuredAskModel(nil, cfg, cfg.MaxContextTokens)
	if m.maxContextTokens != 922000+int64(cfg.LLMMaxOutputTokens) {
		t.Fatal("input ceiling ignored")
	}
	for _, text := range []string{strings.Repeat("monitoring is operational\n", 10000), strings.Repeat("Überwachung 世界🙂\n", 10000)} {
		call := fantasy.Call{Prompt: fantasy.Prompt{fantasy.NewUserMessage(text)}}
		// Inputs larger than the old byte ceiling must actually reach the provider.
		provider := &budgetTestModel{response: researchText("accepted")}
		m := configuredAskModel(provider, cfg, 240000)
		if _, err := m.Generate(t.Context(), call); err != nil || len(provider.calls) != 1 {
			t.Fatalf("valid long input refused: %v", err)
		}
	}
	t.Setenv("LLM_PROVIDER", "openai-compat")
	t.Setenv("MAX_CONTEXT_TOKENS", "")
	if cfg := loadConfig(); cfg.MaxContextTokens != 128000 || configuredAskModel(nil, cfg, cfg.MaxContextTokens).tokenizedInput {
		t.Fatal("unknown provider inherited Sol limits")
	}
}

func TestResearchVerboseSummaryCannotOverflowAdmissibleInput(t *testing.T) {
	call := fantasy.Call{Prompt: fantasy.Prompt{
		fantasy.NewSystemMessage(strings.Repeat("s", 10000)),
		fantasy.NewUserMessage("scope"),
		fantasy.NewUserMessage("current request: no action approval"),
	}}
	for i := 0; i < 2; i++ {
		call.Prompt = append(call.Prompt,
			fantasy.Message{Role: fantasy.MessageRoleAssistant, Content: []fantasy.MessagePart{fantasy.ToolCallPart{ToolCallID: fmt.Sprint(i), ToolName: "lookup", Input: `{}`}}},
			fantasy.Message{Role: fantasy.MessageRoleTool, Content: []fantasy.MessagePart{fantasy.ToolResultPart{ToolCallID: fmt.Sprint(i), Output: fantasy.ToolResultOutputContentText{Text: "small result"}}}},
		)
	}
	providerCalls := 0
	provider := researchTestModel{generate: func(_ context.Context, got fantasy.Call) (*fantasy.Response, error) {
		if len(got.Prompt) == 2 {
			return researchText(strings.Repeat("verbose summary ", 112)), nil
		}
		providerCalls++
		return researchText("accepted"), nil
	}}
	m := timedAskModel{LanguageModel: provider, maxContextTokens: 16000, maxOutputTokens: 1024}
	before, err := m.inputSize(call)
	if err != nil || before <= 13478 || before > 14976 {
		t.Fatalf("fixture must fit above high-water mark: size=%d err=%v", before, err)
	}
	ctx := context.WithValue(t.Context(), researchContextKey{}, newResearchContext())
	response, err := m.Generate(ctx, call)
	if err != nil || response == nil || response.Content.Text() != "accepted" || providerCalls != 1 {
		t.Fatalf("compaction rejected admissible input: calls=%d err=%v", providerCalls, err)
	}
}
