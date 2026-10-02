package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"
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

		ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
		defer cancel()

		client, err := wm.GetOrCreateClient(req.Workspace)
		if err != nil {
			slog.Error("failed to get NRC client for ask ready", "workspace", req.Workspace, "error", err)
			http.Error(w, `{"error":"failed to connect to workspace"}`, http.StatusInternalServerError)
			return
		}

		subscribedContext := req.ContextConvID == 0
		if req.ContextConvID != 0 {
			subscribedContext = client.IsSubscribed(req.ContextConvID)
			if !subscribedContext {
				if err := client.SubscribeRoom(req.ContextConvID); err != nil {
					slog.Warn("failed to subscribe context conversation during ask ready", "workspace", req.Workspace, "conv_id", req.ContextConvID, "error", err)
					http.Error(w, `{"error":"failed to subscribe context conversation"}`, http.StatusInternalServerError)
					return
				}
				subscribedContext = true

				if err := client.WaitForTasks(ctx, req.ContextConvID); err != nil {
					slog.Warn("ask ready wait for tasks failed", "workspace", req.Workspace, "conv_id", req.ContextConvID, "error", err)
				}
			}
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
			SubscribedContext: subscribedContext,
		})
	}
}
