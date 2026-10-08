package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"charm.land/fantasy"
)

// Exercise the provider used by NRC, not a converter helper: provider overrides
// can otherwise hide dropped media or an invalid multi-tool message sequence.
func TestFantasyMediaToolResultsRemainContiguous(t *testing.T) {
	for _, provider := range []string{"openai", "openai-compat"} {
		t.Run(provider, func(t *testing.T) {
			imageData := base64.StdEncoding.EncodeToString([]byte("image fixture bytes"))
			audioData := base64.StdEncoding.EncodeToString([]byte("audio fixture bytes"))
			calls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.URL.Path != "/chat/completions" {
					t.Errorf("unexpected API path: %s", r.URL.Path)
				}
				var request struct {
					Messages []struct {
						Role       string          `json:"role"`
						ToolCallID string          `json:"tool_call_id"`
						Content    json.RawMessage `json:"content"`
					} `json:"messages"`
				}
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Error(err)
					w.WriteHeader(400)
					return
				}
				wantRoles := []string{"user", "assistant", "tool", "tool", "tool", "user", "user"}
				if len(request.Messages) != len(wantRoles) {
					t.Errorf("wrong message count: %+v", request.Messages)
					w.WriteHeader(400)
					return
				}
				for i, role := range wantRoles {
					if request.Messages[i].Role != role {
						t.Errorf("message %d role=%s, want %s", i, request.Messages[i].Role, role)
					}
				}
				for i, id := range []string{"image-read", "audio-read", "metadata-read"} {
					if request.Messages[i+2].ToolCallID != id {
						t.Errorf("tool response order lost: %+v", request.Messages)
					}
				}
				var images []struct {
					Type     string `json:"type"`
					ImageURL struct {
						URL string `json:"url"`
					} `json:"image_url"`
				}
				if err := json.Unmarshal(request.Messages[5].Content, &images); err != nil || len(images) != 1 || images[0].Type != "image_url" || images[0].ImageURL.URL != "data:image/png;base64,"+imageData {
					t.Errorf("lost image: %s (%v)", request.Messages[5].Content, err)
				}
				var audio []struct {
					Type  string `json:"type"`
					Audio struct {
						Data   string `json:"data"`
						Format string `json:"format"`
					} `json:"input_audio"`
				}
				if err := json.Unmarshal(request.Messages[6].Content, &audio); err != nil || len(audio) != 1 || audio[0].Type != "input_audio" || audio[0].Audio.Data != audioData || audio[0].Audio.Format != "wav" {
					t.Errorf("lost audio: %s (%v)", request.Messages[6].Content, err)
				}
				w.Header().Set("Content-Type", "application/json")
				w.Write([]byte(`{"id":"fixture","object":"chat.completion","created":0,"model":"gpt-4o","choices":[{"index":0,"message":{"role":"assistant","content":"media received"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`))
			}))
			defer server.Close()
			model, err := newFantasyLanguageModel(t.Context(), Config{LLMProvider: provider, LLMModel: "gpt-4o", LLMAPIKey: "test-only", LLMBaseURL: server.URL})
			if err != nil {
				t.Fatal(err)
			}
			prompt := fantasy.Prompt{
				fantasy.NewUserMessage("Inspect these attachments"),
				{Role: fantasy.MessageRoleAssistant, Content: []fantasy.MessagePart{
					fantasy.ToolCallPart{ToolCallID: "image-read", ToolName: "read_attachment", Input: `{"mode":"media"}`},
					fantasy.ToolCallPart{ToolCallID: "audio-read", ToolName: "read_attachment", Input: `{"mode":"media"}`},
					fantasy.ToolCallPart{ToolCallID: "metadata-read", ToolName: "list_attachments", Input: `{}`},
				}},
				{Role: fantasy.MessageRoleTool, Content: []fantasy.MessagePart{fantasy.ToolResultPart{ToolCallID: "image-read", Output: fantasy.ToolResultOutputContentMedia{Data: imageData, MediaType: "image/png", Text: "Image evidence"}}}},
				{Role: fantasy.MessageRoleTool, Content: []fantasy.MessagePart{fantasy.ToolResultPart{ToolCallID: "audio-read", Output: fantasy.ToolResultOutputContentMedia{Data: audioData, MediaType: "audio/wav", Text: "Audio evidence"}}}},
				{Role: fantasy.MessageRoleTool, Content: []fantasy.MessagePart{fantasy.ToolResultPart{ToolCallID: "metadata-read", Output: fantasy.ToolResultOutputContentText{Text: "Attachment metadata"}}}},
			}
			if _, err := model.Generate(t.Context(), fantasy.Call{Prompt: prompt}); err != nil {
				t.Fatal(err)
			}
			if calls != 1 {
				t.Fatalf("unexpected request count %d", calls)
			}
		})
	}
}

func TestFantasyImageToolResultProviderFormats(t *testing.T) {
	for _, provider := range []string{"openai", "anthropic"} {
		t.Run(provider, func(t *testing.T) {
			data := base64.StdEncoding.EncodeToString([]byte("image fixture bytes"))
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var request map[string]json.RawMessage
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Error(err)
					w.WriteHeader(400)
					return
				}
				w.Header().Set("Content-Type", "application/json")
				if provider == "openai" {
					if r.URL.Path != "/responses" {
						t.Errorf("wrong API: %s", r.URL.Path)
					}
					var input []struct {
						Type    string `json:"type"`
						CallID  string `json:"call_id"`
						Content []struct {
							Type     string `json:"type"`
							ImageURL string `json:"image_url"`
						} `json:"content"`
					}
					if err := json.Unmarshal(request["input"], &input); err != nil {
						t.Error(err)
					}
					results, images := 0, 0
					for _, item := range input {
						if item.Type == "function_call_output" && item.CallID == "read-image" {
							results++
						}
						for _, part := range item.Content {
							if part.Type == "input_image" && part.ImageURL == "data:image/png;base64,"+data {
								images++
							}
						}
					}
					if results != 1 || images != 1 {
						t.Errorf("missing tool response or image: %s", request["input"])
					}
					w.Write([]byte(`{"id":"resp-fixture","object":"response","status":"completed","output":[{"type":"message","id":"msg-fixture","role":"assistant","status":"completed","content":[{"type":"output_text","text":"media received","annotations":[]}]}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}`))
				} else {
					if r.URL.Path != "/v1/messages" {
						t.Errorf("wrong API: %s", r.URL.Path)
					}
					var messages []struct {
						Content []struct {
							Type      string `json:"type"`
							ToolUseID string `json:"tool_use_id"`
							Content   []struct {
								Type   string `json:"type"`
								Source struct {
									Type      string `json:"type"`
									MediaType string `json:"media_type"`
									Data      string `json:"data"`
								} `json:"source"`
							} `json:"content"`
						} `json:"content"`
					}
					if err := json.Unmarshal(request["messages"], &messages); err != nil {
						t.Error(err)
					}
					images := 0
					for _, msg := range messages {
						for _, part := range msg.Content {
							if part.Type == "tool_result" && part.ToolUseID == "read-image" {
								for _, media := range part.Content {
									if media.Type == "image" && media.Source.Type == "base64" && media.Source.MediaType == "image/png" && media.Source.Data == data {
										images++
									}
								}
							}
						}
					}
					if images != 1 {
						t.Errorf("missing native tool image: %s", request["messages"])
					}
					w.Write([]byte(`{"id":"msg-fixture","type":"message","role":"assistant","model":"claude-sonnet-4","content":[{"type":"text","text":"media received"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}`))
				}
			}))
			defer server.Close()
			model, err := newFantasyLanguageModel(t.Context(), Config{LLMProvider: provider, LLMModel: "gpt-6", LLMAPIKey: "test-only", LLMBaseURL: server.URL})
			if err != nil {
				t.Fatal(err)
			}
			prompt := fantasy.Prompt{
				fantasy.NewUserMessage("Inspect this image"),
				{Role: fantasy.MessageRoleAssistant, Content: []fantasy.MessagePart{fantasy.ToolCallPart{ToolCallID: "read-image", ToolName: "read_attachment", Input: `{}`}}},
				{Role: fantasy.MessageRoleTool, Content: []fantasy.MessagePart{fantasy.ToolResultPart{ToolCallID: "read-image", Output: fantasy.ToolResultOutputContentMedia{Data: data, MediaType: "image/png", Text: "Image evidence"}}}},
			}
			if _, err := model.Generate(t.Context(), fantasy.Call{Prompt: prompt}); err != nil {
				t.Fatal(err)
			}
		})
	}
}
