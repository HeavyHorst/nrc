package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/heavyhorst/nrc/protocol-go"
)

type pasteTaskRequest struct {
	Workspace string `json:"workspace"`
	ConvID    uint64 `json:"conv_id"`
	RawText   string `json:"raw_text"`
}

func (r *pasteTaskRequest) UnmarshalJSON(data []byte) error {
	type pasteTaskRequestAlias struct {
		Workspace string          `json:"workspace"`
		ConvID    json.RawMessage `json:"conv_id"`
		RawText   string          `json:"raw_text"`
	}

	var raw pasteTaskRequestAlias
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}

	convID, err := parseConvIDRaw(raw.ConvID)
	if err != nil {
		return fmt.Errorf("invalid conv_id: %w", err)
	}

	r.Workspace = raw.Workspace
	r.ConvID = convID
	r.RawText = raw.RawText
	return nil
}

type pasteTaskResponse struct {
	Task extractedTask `json:"task"`
}

type extractedTask struct {
	Title       string `json:"title"`
	Description string `json:"description"`
	Priority    int    `json:"priority"`
	Status      string `json:"status"`
	Color       string `json:"color"`
}

func handlePasteToTask(llm LLM) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req pasteTaskRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
			return
		}
		if req.RawText == "" {
			http.Error(w, `{"error":"raw_text is required"}`, http.StatusBadRequest)
			return
		}
		if req.Workspace == "" {
			http.Error(w, `{"error":"workspace is required"}`, http.StatusBadRequest)
			return
		}
		if req.ConvID != protocol.WorkspaceDataConvID {
			http.Error(w, `{"error":"conv_id must be 0 (workspace scope)"}`, http.StatusBadRequest)
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
		defer cancel()

		resp, err := llm.Complete(ctx, CompletionRequest{
			System: PasteToTaskPrompt,
			Messages: []LLMMessage{
				{Role: "user", Content: req.RawText},
			},
			JSON: true,
		})
		if err != nil {
			slog.Error("LLM completion failed", "error", err)
			http.Error(w, `{"error":"LLM request failed"}`, http.StatusInternalServerError)
			return
		}

		var task extractedTask
		if err := json.Unmarshal([]byte(resp.Content), &task); err != nil {
			slog.Error("failed to parse LLM response", "error", err, "content", resp.Content)
			http.Error(w, `{"error":"failed to parse LLM response"}`, http.StatusInternalServerError)
			return
		}

		if err := validateTask(&task); err != nil {
			slog.Warn("LLM returned invalid task fields, using defaults", "error", err)
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(pasteTaskResponse{Task: task})
	}
}

func validateTask(t *extractedTask) error {
	if t.Priority < 0 || t.Priority > 2 {
		t.Priority = 0
	}

	switch t.Status {
	case "backlog", "todo":
	default:
		t.Status = "backlog"
	}

	switch t.Color {
	case "none", "red", "green", "gray", "cyan", "gold":
	default:
		t.Color = "none"
	}

	if len(t.Title) > 256 {
		t.Title = t.Title[:256]
	}
	if len(t.Description) > 2048 {
		t.Description = t.Description[:2048]
	}

	if t.Title == "" {
		return fmt.Errorf("title is empty")
	}
	return nil
}
