package main

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
)

type askReadyRequest struct {
	Workspace     string `json:"workspace"`
	ContextConvID uint64 `json:"context_conv_id,omitempty"`
}

func (r *askReadyRequest) UnmarshalJSON(data []byte) error {
	type askReadyRequestAlias struct {
		Workspace     string          `json:"workspace"`
		ContextConvID json.RawMessage `json:"context_conv_id,omitempty"`
	}

	var raw askReadyRequestAlias
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}

	contextConvID, err := parseOptionalConvIDRaw(raw.ContextConvID)
	if err != nil {
		return fmt.Errorf("invalid context_conv_id: %w", err)
	}

	r.Workspace = raw.Workspace
	r.ContextConvID = contextConvID
	return nil
}

type askReadyResponse struct {
	OK                bool   `json:"ok"`
	AIUsername        string `json:"ai_username"`
	SubscribedContext bool   `json:"subscribed_context"`
}

func handleAskReady(wm *WorkspaceManager) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req askReadyRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
			return
		}

		if strings.TrimSpace(req.Workspace) == "" {
			http.Error(w, `{"error":"workspace is required"}`, http.StatusBadRequest)
			return
		}

		if req.ContextConvID != 0 {
			http.Error(w, `{"error":"context_conv_id must be 0 (workspace scope)"}`, http.StatusBadRequest)
			return
		}

		client, err := wm.GetOrCreateClient(req.Workspace)
		if err != nil {
			slog.Error("failed to get NRC client for ask ready", "workspace", req.Workspace, "error", err)
			http.Error(w, `{"error":"failed to connect to workspace"}`, http.StatusInternalServerError)
			return
		}

		aiUsername := strings.TrimSpace(client.nickname)
		if aiUsername == "" {
			http.Error(w, `{"error":"ai username unavailable"}`, http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(askReadyResponse{
			OK:                true,
			AIUsername:        aiUsername,
			SubscribedContext: true,
		})
	}
}
