package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/heavyhorst/nrc/protocol-go"
)

type pasteNoteRequest struct {
	Workspace    string `json:"workspace"`
	ConvID       uint64 `json:"conv_id"`
	RawText      string `json:"raw_text"`
	ExtractTasks bool   `json:"extract_tasks"`
}

func (r *pasteNoteRequest) UnmarshalJSON(data []byte) error {
	type pasteNoteRequestAlias struct {
		Workspace    string          `json:"workspace"`
		ConvID       json.RawMessage `json:"conv_id"`
		RawText      string          `json:"raw_text"`
		ExtractTasks bool            `json:"extract_tasks"`
	}

	var raw pasteNoteRequestAlias
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
	r.ExtractTasks = raw.ExtractTasks
	return nil
}

type pasteNoteResponse struct {
	Note           extractedNote   `json:"note"`
	ExtractedTasks []extractedTask `json:"extracted_tasks,omitempty"`
	SuggestedLinks []suggestedLink `json:"suggested_links,omitempty"`
}

type extractedNote struct {
	Title   string   `json:"title"`
	Project string   `json:"project"`
	Tags    []string `json:"tags"`
	Content string   `json:"content"`
}

type suggestedLink struct {
	AssetID  uint64  `json:"asset_id"`
	Title    string  `json:"title"`
	Relation string  `json:"relation"`
	Score    float64 `json:"score"`
}

type classifyLinksResponse struct {
	Links []struct {
		AssetID  uint64 `json:"asset_id"`
		Relation string `json:"relation"`
	} `json:"links"`
}

func handlePasteToNote(llm LLM, search *SearchClient) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req pasteNoteRequest
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

		userContent := req.RawText
		if req.ExtractTasks {
			userContent = fmt.Sprintf("extract_tasks: true\n\n%s", req.RawText)
		}

		ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
		defer cancel()

		// Run LLM extraction and search in parallel
		var parsed pasteNoteResponse
		var llmErr error
		var searchResults []SearchResult
		var searchErr error

		var wg sync.WaitGroup
		wg.Add(2)

		go func() {
			defer wg.Done()
			resp, err := llm.Complete(ctx, CompletionRequest{
				System: PasteToNotePrompt,
				Messages: []LLMMessage{
					{Role: "user", Content: userContent},
				},
				JSON: true,
			})
			if err != nil {
				llmErr = err
				return
			}

			slog.Info("LLM paste-to-note response",
				"content_length", len(resp.Content),
				"raw_content", resp.Content,
			)

			if err := json.Unmarshal([]byte(resp.Content), &parsed); err != nil {
				llmErr = fmt.Errorf("failed to parse LLM response: %w (content: %s)", err, resp.Content)
			}
		}()

		go func() {
			defer wg.Done()
			// Search for similar notes (asset_type 5 = Note)
			searchResults, searchErr = search.Search(ctx, req.Workspace, req.RawText, req.ConvID, 5, false, 5)
		}()

		wg.Wait()

		if llmErr != nil {
			slog.Error("LLM completion failed", "error", llmErr)
			http.Error(w, `{"error":"LLM request failed"}`, http.StatusInternalServerError)
			return
		}

		slog.Info("parsed paste-to-note result",
			"note_title", parsed.Note.Title,
			"note_content_length", len(parsed.Note.Content),
			"extracted_tasks_count", len(parsed.ExtractedTasks),
		)

		if parsed.Note.Title == "" {
			slog.Warn("LLM returned empty note title")
			parsed.Note.Title = "Untitled Note"
		}
		parsed.Note.Project = strings.TrimSpace(parsed.Note.Project)
		parsed.Note.Tags = normalizeNoteTags(parsed.Note.Tags)

		for i := range parsed.ExtractedTasks {
			if err := validateTask(&parsed.ExtractedTasks[i]); err != nil {
				slog.Warn("extracted task validation", "index", i, "error", err)
			}
		}

		// Classify search results if we got any
		if searchErr != nil {
			slog.Warn("search failed, continuing without suggested links", "error", searchErr)
		} else if len(searchResults) > 0 {
			suggested := classifyLinks(ctx, llm, parsed.Note, searchResults)
			if len(suggested) > 0 {
				parsed.SuggestedLinks = suggested
			}
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(parsed)
	}
}

func classifyLinks(ctx context.Context, llm LLM, note extractedNote, results []SearchResult) []suggestedLink {
	// Build context for the classification LLM call
	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("== NEW NOTE ==\nTitle: %s\nContent: %s\n\n", note.Title, truncate(note.Content, 500)))
	sb.WriteString("== EXISTING NOTES ==\n")

	// Build a lookup for score and title by asset ID
	type candidate struct {
		title string
		score float64
	}
	candidates := make(map[uint64]candidate, len(results))

	for _, r := range results {
		title := r.Preview
		preview := parseNotePreviewJSON(r.Preview)
		if preview.Title != "" {
			title = preview.Title
			metadata := ""
			if preview.Project != "" {
				metadata += " project:" + preview.Project
			}
			if len(preview.Tags) > 0 {
				metadata += " tags:" + strings.Join(preview.Tags, ",")
			}
			sb.WriteString(fmt.Sprintf("[ID:%d] %s — %s%s\n", r.AssetID, preview.Title, preview.Teaser, metadata))
		} else {
			sb.WriteString(fmt.Sprintf("[ID:%d] %s\n", r.AssetID, r.Preview))
		}
		candidates[r.AssetID] = candidate{title: title, score: r.Score}
	}

	resp, err := llm.Complete(ctx, CompletionRequest{
		System: ClassifyLinksPrompt,
		Messages: []LLMMessage{
			{Role: "user", Content: sb.String()},
		},
		JSON: true,
	})
	if err != nil {
		slog.Warn("link classification LLM call failed", "error", err)
		return nil
	}

	var classified classifyLinksResponse
	if err := json.Unmarshal([]byte(resp.Content), &classified); err != nil {
		slog.Warn("failed to parse link classification response", "error", err, "content", resp.Content)
		return nil
	}

	validRelations := map[string]bool{
		"references":   true,
		"related-to":   true,
		"depends-on":   true,
		"blocks":       true,
		"derived-from": true,
		"supersedes":   true,
	}

	var links []suggestedLink
	for _, l := range classified.Links {
		c, ok := candidates[l.AssetID]
		if !ok {
			continue
		}
		if !validRelations[l.Relation] {
			slog.Warn("LLM returned invalid relation, skipping", "relation", l.Relation, "asset_id", l.AssetID)
			continue
		}
		links = append(links, suggestedLink{
			AssetID:  l.AssetID,
			Title:    c.title,
			Relation: l.Relation,
			Score:    c.score,
		})
	}

	slog.Info("link classification complete",
		"candidates", len(results),
		"suggested", len(links),
	)

	return links
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "…"
}
