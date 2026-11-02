package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"charm.land/fantasy"
)

// Explicit workspace keys only: never route another workspace to a default slice.
func parseKnowledgeGapSlices(raw string) (map[string]string, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}
	var slices map[string]string
	if err := json.Unmarshal([]byte(raw), &slices); err != nil {
		return nil, fmt.Errorf("NRC_KNOWLEDGE_GAP_SLICES must map workspace names to decimal ID strings")
	}
	for workspace, id := range slices {
		n, err := strconv.ParseUint(id, 10, 64)
		if strings.TrimSpace(workspace) == "" || workspace != strings.TrimSpace(workspace) || err != nil || n == 0 || strconv.FormatUint(n, 10) != id {
			return nil, fmt.Errorf("invalid workspace or slice ID in NRC_KNOWLEDGE_GAP_SLICES")
		}
	}
	return slices, nil
}

func newKnowledgeGapTool() fantasy.AgentTool {
	return fantasy.NewAgentTool("report_knowledge_gap", "Offer a knowledge-gap task draft when a concrete question cannot be answered because workspace knowledge is missing. Call only after successful research. Never use for tool/search failures, permissions, incomplete scans, ambiguous questions or safety refusals. Does not create any records. The user reviews and confirms the draft separately.", func(ctx context.Context, input struct {
		MissingKnowledge string `json:"missing_knowledge" description:"Brief explanation of what knowledge is missing, without private conversation excerpts"`
	}, call fantasy.ToolCall) (fantasy.ToolResponse, error) {
		recordToolTrace(ctx, "report_knowledge_gap", time.Now(), "", 0, nil, map[string]any{"missing_knowledge": input.MissingKnowledge}, nil)
		return fantasy.NewTextResponse("Knowledge gap reported. No task has been created. The user can review a draft if a target slice is configured."), nil
	})
}

func knowledgeGapSlice(slices map[string]string, workspace string, trace []ToolTraceEntry) string {
	reported := false
	for _, entry := range trace {
		if entry.Status == "error" || entry.Outcome["stale"] == true {
			return ""
		}
		if entry.Tool == "report_knowledge_gap" && entry.Status == "ok" {
			reported = true
		}
	}
	if reported {
		return slices[workspace]
	}
	return ""
}
