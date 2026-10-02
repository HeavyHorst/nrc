package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/heavyhorst/nrc/protocol-go"
)

var actionAssetRefPattern = regexp.MustCompile(`(?i)\[\s*(?:asset|comment|document|file|agenda|note|reminder)\s*:\s*(\d+)\s*\]`)

type askApplyRequest struct {
	Workspace      string   `json:"workspace"`
	AgentSessionID string   `json:"agent_session_id"`
	SessionID      string   `json:"session_id,omitempty"`
	PlanID         string   `json:"plan_id"`
	ActionIDs      []string `json:"action_ids,omitempty"`
}

type askApplyResponse struct {
	OK              bool                 `json:"ok"`
	Applied         []applyActionResult  `json:"applied"`
	Failed          []applyActionFailure `json:"failed"`
	CreatedEntities []applyCreatedEntity `json:"created_entities"`
	CreatedEdges    []applyCreatedEdge   `json:"created_edges,omitempty"`
	DeletedEntities []applyCreatedEntity `json:"deleted_entities,omitempty"`
	DeletedEdges    []applyCreatedEdge   `json:"deleted_edges,omitempty"`
}

type applyActionResult struct {
	ActionID       string              `json:"action_id"`
	Type           string              `json:"type"`
	Status         string              `json:"status"`
	AlreadyApplied bool                `json:"already_applied,omitempty"`
	Entity         *applyCreatedEntity `json:"entity,omitempty"`
	CreatedEntity  *applyCreatedEntity `json:"created_entity,omitempty"`
	CreatedEdge    *applyCreatedEdge   `json:"created_edge,omitempty"`
	DeletedEntity  *applyCreatedEntity `json:"deleted_entity,omitempty"`
	DeletedEdge    *applyCreatedEdge   `json:"deleted_edge,omitempty"`
}

type applyActionFailure struct {
	ActionID string `json:"action_id"`
	Type     string `json:"type"`
	Error    string `json:"error"`
}

type applyCreatedEntity struct {
	Type  string `json:"type"`
	ID    uint64 `json:"id"`
	Title string `json:"title,omitempty"`
}

type applyCreatedEdge struct {
	EdgeID     uint64 `json:"edge_id"`
	SourceType string `json:"source_type"`
	SourceID   uint64 `json:"source_id"`
	TargetType string `json:"target_type"`
	TargetID   uint64 `json:"target_id"`
	Relation   string `json:"relation"`
}

func (r *askApplyRequest) UnmarshalJSON(data []byte) error {
	type alias struct {
		Workspace      string          `json:"workspace"`
		AgentSessionID string          `json:"agent_session_id"`
		SessionID      string          `json:"session_id,omitempty"`
		PlanID         string          `json:"plan_id"`
		ActionIDs      json.RawMessage `json:"action_ids,omitempty"`
	}

	var raw alias
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}

	r.Workspace = raw.Workspace
	r.AgentSessionID = strings.TrimSpace(raw.AgentSessionID)
	r.SessionID = strings.TrimSpace(raw.SessionID)
	if r.AgentSessionID == "" {
		r.AgentSessionID = r.SessionID
	}
	r.PlanID = strings.TrimSpace(raw.PlanID)

	if len(raw.ActionIDs) > 0 && string(raw.ActionIDs) != "null" {
		var asStrings []string
		if err := json.Unmarshal(raw.ActionIDs, &asStrings); err == nil {
			r.ActionIDs = asStrings
			return nil
		}

		var asNumbers []json.Number
		if err := json.Unmarshal(raw.ActionIDs, &asNumbers); err == nil {
			r.ActionIDs = make([]string, 0, len(asNumbers))
			for _, n := range asNumbers {
				r.ActionIDs = append(r.ActionIDs, n.String())
			}
			return nil
		}

		return fmt.Errorf("action_ids must be an array of strings or numbers")
	}

	return nil
}

func handleAskApply(wm *WorkspaceManager, store *AgentSessionStore) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req askApplyRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
			return
		}

		if strings.TrimSpace(req.Workspace) == "" {
			http.Error(w, `{"error":"workspace is required"}`, http.StatusBadRequest)
			return
		}
		if strings.TrimSpace(req.AgentSessionID) == "" {
			http.Error(w, `{"error":"agent_session_id is required"}`, http.StatusBadRequest)
			return
		}

		sessionSnapshot, ok := store.get(req.AgentSessionID)
		if !ok {
			http.Error(w, `{"error":"agent session expired or not found"}`, http.StatusNotFound)
			return
		}
		if sessionSnapshot.Workspace != req.Workspace {
			http.Error(w, `{"error":"agent session workspace mismatch"}`, http.StatusBadRequest)
			return
		}

		planID := req.PlanID
		if planID == "" {
			latest, ok := store.latestPendingPlan(req.AgentSessionID)
			if !ok {
				http.Error(w, `{"error":"no pending action plan"}`, http.StatusNotFound)
				return
			}
			planID = latest.ID
		}

		if sessionSnapshot.ContextConvID != protocol.WorkspaceDataConvID {
			http.Error(w, `{"error":"context_conv_id must be 0 (workspace scope)"}`, http.StatusBadRequest)
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()

		client, err := wm.GetOrCreateClient(req.Workspace)
		if err != nil {
			slog.Error("failed to get NRC client for ask apply", "workspace", req.Workspace, "error", err)
			http.Error(w, `{"error":"failed to connect to workspace"}`, http.StatusInternalServerError)
			return
		}

		if sessionSnapshot.DisplayConvID != 0 && !client.IsSubscribed(sessionSnapshot.DisplayConvID) {
			if err := client.SubscribeConversation(sessionSnapshot.DisplayConvID); err != nil {
				slog.Warn("failed to subscribe apply display conversation", "conv_id", sessionSnapshot.DisplayConvID, "error", err)
			}
		}

		if !client.IsSubscribed(sessionSnapshot.ContextConvID) {
			if err := client.SubscribeRoom(sessionSnapshot.ContextConvID); err != nil {
				http.Error(w, `{"error":"failed to subscribe to context room"}`, http.StatusInternalServerError)
				return
			}
			if err := client.WaitForTasks(ctx, sessionSnapshot.ContextConvID); err != nil {
				slog.Warn("ask apply wait for tasks failed", "conv_id", sessionSnapshot.ContextConvID, "error", err)
			}
		}

		_, _, toApply, alreadyApplied, earlyFailures, err := store.prepareApply(req.AgentSessionID, planID, req.ActionIDs)
		if err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusNotFound)
			return
		}

		result := askApplyResponse{
			Applied: append([]applyActionResult(nil), alreadyApplied...),
			Failed:  append([]applyActionFailure(nil), earlyFailures...),
		}

		for _, pending := range toApply {
			switch pending.Action.Type {
			case actionTypeCreateTask:
				applyCreateTaskAction(ctx, client, store, sessionSnapshot.ContextConvID, pending, &result)
			case actionTypeUpdateTask:
				applyUpdateTaskAction(ctx, client, store, sessionSnapshot.ContextConvID, pending, &result)
			case actionTypeCreateNote:
				applyCreateNoteAction(ctx, client, store, sessionSnapshot.ContextConvID, pending, &result)
			case actionTypeUpdateNote:
				applyUpdateNoteAction(ctx, client, store, sessionSnapshot.ContextConvID, pending, &result)
			case actionTypeDeleteNote:
				applyDeleteNoteAction(ctx, client, store, sessionSnapshot.ContextConvID, pending, &result)
			case actionTypeCreateEdge:
				applyCreateEdgeAction(ctx, client, store, sessionSnapshot.ContextConvID, pending, &result)
			case actionTypeDeleteEdge:
				applyDeleteEdgeAction(ctx, client, store, sessionSnapshot.ContextConvID, pending, &result)
			default:
				applyErr := fmt.Errorf("unsupported action type %q", pending.Action.Type)
				completed, _ := store.completeFailedAction(pending.SessionID, pending.PlanID, pending.Action.ID, applyErr)
				result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
			}
		}

		for _, applied := range result.Applied {
			if applied.CreatedEntity != nil {
				result.CreatedEntities = append(result.CreatedEntities, *applied.CreatedEntity)
			}
			if applied.CreatedEdge != nil && !applied.AlreadyApplied {
				result.CreatedEdges = append(result.CreatedEdges, *applied.CreatedEdge)
			}
			if applied.DeletedEntity != nil {
				result.DeletedEntities = append(result.DeletedEntities, *applied.DeletedEntity)
			}
			if applied.DeletedEdge != nil {
				result.DeletedEdges = append(result.DeletedEdges, *applied.DeletedEdge)
			}
		}
		result.OK = len(result.Failed) == 0

		audit := buildApplyAuditMessage(result)
		emitAskProgress(client, sessionSnapshot.DisplayConvID, audit)

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(result)
	}
}

type askSessionResetRequest struct {
	Workspace      string `json:"workspace"`
	AgentSessionID string `json:"agent_session_id"`
	SessionID      string `json:"session_id,omitempty"`
}

func handleAskSessionReset(store *AgentSessionStore) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req askSessionResetRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
			return
		}
		sessionID := strings.TrimSpace(req.AgentSessionID)
		if sessionID == "" {
			sessionID = strings.TrimSpace(req.SessionID)
		}
		if sessionID == "" {
			http.Error(w, `{"error":"agent_session_id is required"}`, http.StatusBadRequest)
			return
		}

		if strings.TrimSpace(req.Workspace) != "" {
			if sessionSnapshot, ok := store.get(sessionID); ok && sessionSnapshot.Workspace != req.Workspace {
				http.Error(w, `{"error":"agent session workspace mismatch"}`, http.StatusBadRequest)
				return
			}
		}

		reset := store.reset(sessionID)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "reset": reset})
	}
}

func handleAskSessionGet(store *AgentSessionStore) http.HandlerFunc {
	config := os.Getenv("NRC_WORKSPACE_ACCESS")
	var policy map[string]json.RawMessage
	// Empty JSON objects, including whitespace, are the same as no policy.
	// Invalid configuration remains fail-closed (the proxy rejects startup).
	restricted := config != "" && (json.Unmarshal([]byte(config), &policy) != nil || policy == nil || len(policy) > 0)
	return func(w http.ResponseWriter, r *http.Request) {
		sessionID := strings.TrimSpace(r.PathValue("id"))
		if sessionID == "" {
			http.Error(w, `{"error":"agent_session_id is required"}`, http.StatusBadRequest)
			return
		}

		sessionSnapshot, ok := store.get(sessionID)
		if !ok {
			http.Error(w, `{"error":"agent session expired or not found"}`, http.StatusNotFound)
			return
		}

		// Only the trusted Tailscale proxy supplies this header. The session's
		// stored workspace, not a caller's query parameter, determines access.
		header := r.Header.Get("X-NRC-Denied-Workspaces")
		if restricted || header != "" {
			var denied []string
			if json.Unmarshal([]byte(header), &denied) != nil || denied == nil {
				http.Error(w, `{"error":"missing workspace authorization"}`, http.StatusForbidden)
				return
			}
			for _, workspace := range denied {
				if workspace == sessionSnapshot.Workspace {
					http.Error(w, `{"error":"workspace access denied"}`, http.StatusForbidden)
					return
				}
			}
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(sessionSnapshot)
	}
}

func applyCreateTaskAction(ctx context.Context, client *NRCClient, store *AgentSessionStore, convID uint64, pending actionToApply, result *askApplyResponse) {
	task, applyErr := client.CreateTask(ctx, convID, pending.Action.Title, pending.Action.Description, pending.Action.Priority)
	completed, _ := store.completeCreateTaskAction(pending.SessionID, pending.PlanID, pending.Action.ID, task, applyErr)
	if applyErr != nil {
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}

	createdEdges, edgeFailures := createTaskReferenceEdges(ctx, client, convID, completed, task)
	result.CreatedEdges = append(result.CreatedEdges, createdEdges...)
	result.Failed = append(result.Failed, edgeFailures...)
	entity := affectedActionEntity(completed)
	result.Applied = append(result.Applied, applyActionResult{
		ActionID:      completed.ID,
		Type:          completed.Type,
		Status:        completed.Status,
		Entity:        entity,
		CreatedEntity: createdActionEntity(completed),
	})
}

func applyUpdateTaskAction(ctx context.Context, client *NRCClient, store *AgentSessionStore, convID uint64, pending actionToApply, result *askApplyResponse) {
	current, ok := findTaskByID(client.GetTasks(convID), pending.Action.TaskID)
	if !ok {
		completed, _ := store.completeUpdateTaskAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, fmt.Errorf("task %d not found", pending.Action.TaskID))
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}
	if current.UpdatedAt != pending.Action.ExpectedUpdatedAt {
		completed, _ := store.completeUpdateTaskAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, fmt.Errorf("stale task precondition: expected updated_at %d got %d", pending.Action.ExpectedUpdatedAt, current.UpdatedAt))
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}
	_, taskStatus, err := normalizeActionTaskStatus(pending.Action.TaskStatus)
	if err != nil {
		completed, _ := store.completeUpdateTaskAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, err)
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}
	if pending.Action.BlockedBy != 0 {
		if _, ok := findTaskByID(client.GetTasks(convID), pending.Action.BlockedBy); !ok {
			completed, _ := store.completeUpdateTaskAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, fmt.Errorf("blocked_by task %d not found", pending.Action.BlockedBy))
			result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
			return
		}
	}

	task, applyErr := client.UpdateTask(ctx, convID, current, pending.Action.Title, pending.Action.Description, taskStatus, pending.Action.Priority, pending.Action.BlockedBy)
	completed, _ := store.completeUpdateTaskAction(pending.SessionID, pending.PlanID, pending.Action.ID, task, applyErr)
	if applyErr != nil {
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}

	result.Applied = append(result.Applied, applyActionResult{
		ActionID: completed.ID,
		Type:     completed.Type,
		Status:   completed.Status,
		Entity:   affectedActionEntity(completed),
	})
}

func applyCreateNoteAction(ctx context.Context, client *NRCClient, store *AgentSessionStore, convID uint64, pending actionToApply, result *askApplyResponse) {
	asset, applyErr := client.CreateNote(ctx, convID, pending.Action.Title, pending.Action.Content, pending.Action.Project, pending.Action.Tags)
	completed, _ := store.completeCreateNoteAction(pending.SessionID, pending.PlanID, pending.Action.ID, asset, applyErr)
	if applyErr != nil {
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}

	entity := affectedActionEntity(completed)
	result.Applied = append(result.Applied, applyActionResult{
		ActionID:      completed.ID,
		Type:          completed.Type,
		Status:        completed.Status,
		Entity:        entity,
		CreatedEntity: createdActionEntity(completed),
	})
}

func applyUpdateNoteAction(ctx context.Context, client *NRCClient, store *AgentSessionStore, convID uint64, pending actionToApply, result *askApplyResponse) {
	current, err := client.GetAsset(ctx, convID, pending.Action.AssetID)
	if err != nil {
		completed, _ := store.completeUpdateNoteAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, fmt.Errorf("note precheck failed: %w", err))
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}
	if current.AssetType != protocol.AssetTypeNote {
		completed, _ := store.completeUpdateNoteAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, fmt.Errorf("asset %d is %s, not Note", pending.Action.AssetID, assetTypeName(current.AssetType)))
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}
	if current.UpdatedAt != pending.Action.ExpectedUpdatedAt {
		completed, _ := store.completeUpdateNoteAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, fmt.Errorf("stale note precondition: expected updated_at %d got %d", pending.Action.ExpectedUpdatedAt, current.UpdatedAt))
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}

	currentFormat := parseNotePreviewJSON(current.Preview).Format
	if pending.Action.Format != currentFormat {
		completed, _ := store.completeUpdateNoteAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, fmt.Errorf("note format changed before apply: expected %s got %s", pending.Action.Format, currentFormat))
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}
	asset, applyErr := client.UpdateNote(ctx, convID, pending.Action.AssetID, pending.Action.Title, pending.Action.Content, pending.Action.Project, pending.Action.Tags, pending.Action.Format)
	completed, _ := store.completeUpdateNoteAction(pending.SessionID, pending.PlanID, pending.Action.ID, asset, applyErr)
	if applyErr != nil {
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}

	result.Applied = append(result.Applied, applyActionResult{
		ActionID: completed.ID,
		Type:     completed.Type,
		Status:   completed.Status,
		Entity:   affectedActionEntity(completed),
	})
}

func applyDeleteNoteAction(ctx context.Context, client *NRCClient, store *AgentSessionStore, convID uint64, pending actionToApply, result *askApplyResponse) {
	current, err := client.GetAsset(ctx, convID, pending.Action.AssetID)
	if err != nil {
		completed, _ := store.completeDeleteNoteAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, fmt.Errorf("note precheck failed: %w", err))
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}
	if current.AssetType != protocol.AssetTypeNote {
		completed, _ := store.completeDeleteNoteAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, fmt.Errorf("asset %d is %s, not Note", pending.Action.AssetID, assetTypeName(current.AssetType)))
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}
	if current.UpdatedAt != pending.Action.ExpectedUpdatedAt {
		completed, _ := store.completeDeleteNoteAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, fmt.Errorf("stale note precondition: expected updated_at %d got %d", pending.Action.ExpectedUpdatedAt, current.UpdatedAt))
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}

	applyErr := client.DeleteNote(ctx, convID, pending.Action.AssetID)
	completed, _ := store.completeDeleteNoteAction(pending.SessionID, pending.PlanID, pending.Action.ID, &current, applyErr)
	if applyErr != nil {
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}

	result.Applied = append(result.Applied, applyActionResult{
		ActionID:      completed.ID,
		Type:          completed.Type,
		Status:        completed.Status,
		DeletedEntity: deletedActionEntity(completed),
	})
}

func applyCreateEdgeAction(ctx context.Context, client *NRCClient, store *AgentSessionStore, convID uint64, pending actionToApply, result *askApplyResponse) {
	plan, ok := store.getPlan(pending.SessionID, pending.PlanID)
	if !ok {
		completed, _ := store.completeCreateEdgeAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, fmt.Errorf("pending action plan not found"))
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}

	sourceType, sourceID, err := resolveActionEndpoint(pending.Action.SourceType, pending.Action.SourceID, pending.Action.SourceActionID, plan)
	if err != nil {
		completed, _ := store.completeCreateEdgeAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, fmt.Errorf("source endpoint invalid: %w", err))
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}
	targetType, targetID, err := resolveActionEndpoint(pending.Action.TargetType, pending.Action.TargetID, pending.Action.TargetActionID, plan)
	if err != nil {
		completed, _ := store.completeCreateEdgeAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, fmt.Errorf("target endpoint invalid: %w", err))
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}
	relationName, relation, err := normalizeActionRelation(pending.Action.Relation)
	if err != nil {
		completed, _ := store.completeCreateEdgeAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, err)
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}

	if err := precheckActionEndpointExists(ctx, client, convID, sourceType, sourceID); err != nil {
		completed, _ := store.completeCreateEdgeAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, fmt.Errorf("source precheck failed: %w", err))
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}
	if err := precheckActionEndpointExists(ctx, client, convID, targetType, targetID); err != nil {
		completed, _ := store.completeCreateEdgeAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, fmt.Errorf("target precheck failed: %w", err))
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}

	existingEdges, err := client.GetEdges(ctx, convID)
	if err != nil {
		completed, _ := store.completeCreateEdgeAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, fmt.Errorf("edge precheck failed: %w", err))
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}
	if existing := findEquivalentEdge(existingEdges, sourceType, sourceID, targetType, targetID, relation); existing != nil {
		completed, _ := store.completeCreateEdgeAction(pending.SessionID, pending.PlanID, pending.Action.ID, existing, nil)
		result.Applied = append(result.Applied, applyActionResult{
			ActionID:       completed.ID,
			Type:           completed.Type,
			Status:         completed.Status,
			AlreadyApplied: true,
			CreatedEdge:    createdActionEdge(completed),
		})
		return
	}

	edge, applyErr := client.CreateEdge(ctx, convID, sourceType, sourceID, targetType, targetID, relation)
	completed, _ := store.completeCreateEdgeAction(pending.SessionID, pending.PlanID, pending.Action.ID, edge, applyErr)
	if applyErr != nil {
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}
	if completed.Relation == "" {
		completed.Relation = relationName
	}

	result.Applied = append(result.Applied, applyActionResult{
		ActionID:    completed.ID,
		Type:        completed.Type,
		Status:      completed.Status,
		CreatedEdge: createdActionEdge(completed),
	})
}

func applyDeleteEdgeAction(ctx context.Context, client *NRCClient, store *AgentSessionStore, convID uint64, pending actionToApply, result *askApplyResponse) {
	existingEdges, err := client.GetEdges(ctx, convID)
	if err != nil {
		completed, _ := store.completeDeleteEdgeAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, fmt.Errorf("edge precheck failed: %w", err))
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}
	edge := findEdgeByID(existingEdges, pending.Action.EdgeID)
	if edge == nil {
		completed, _ := store.completeDeleteEdgeAction(pending.SessionID, pending.PlanID, pending.Action.ID, nil, fmt.Errorf("edge %d not found", pending.Action.EdgeID))
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}

	applyErr := client.DeleteEdge(ctx, convID, pending.Action.EdgeID)
	completed, _ := store.completeDeleteEdgeAction(pending.SessionID, pending.PlanID, pending.Action.ID, edge, applyErr)
	if applyErr != nil {
		result.Failed = append(result.Failed, applyActionFailure{ActionID: pending.Action.ID, Type: pending.Action.Type, Error: completed.Error})
		return
	}

	result.Applied = append(result.Applied, applyActionResult{
		ActionID:    completed.ID,
		Type:        completed.Type,
		Status:      completed.Status,
		DeletedEdge: deletedActionEdge(completed),
	})
}

func resolveActionEndpoint(typeName string, id uint64, actionID string, plan ActionPlan) (uint16, uint64, error) {
	_, targetType, err := normalizeActionTargetType(typeName)
	if err != nil {
		return 0, 0, err
	}
	actionID = strings.TrimSpace(actionID)
	if actionID == "" {
		if id == 0 {
			return 0, 0, fmt.Errorf("endpoint id is required")
		}
		return targetType, id, nil
	}

	for _, action := range plan.Actions {
		if action.ID != actionID {
			continue
		}
		if action.Status != actionStatusApplied {
			return 0, 0, fmt.Errorf("dependency action %s is %s", actionID, action.Status)
		}
		switch targetType {
		case protocol.TargetTypeTask:
			if action.CreatedTaskID == 0 {
				return 0, 0, fmt.Errorf("dependency action %s has no task result", actionID)
			}
			return targetType, action.CreatedTaskID, nil
		case protocol.TargetTypeAsset:
			if action.CreatedAssetID != 0 {
				return targetType, action.CreatedAssetID, nil
			}
			if action.AssetID != 0 {
				return targetType, action.AssetID, nil
			}
			return 0, 0, fmt.Errorf("dependency action %s has no asset result", actionID)
		}
	}

	return 0, 0, fmt.Errorf("dependency action %s not found", actionID)
}

func precheckActionEndpointExists(ctx context.Context, client *NRCClient, convID uint64, targetType uint16, id uint64) error {
	switch targetType {
	case protocol.TargetTypeTask:
		for _, task := range client.GetTasks(convID) {
			if task.ID == id {
				return nil
			}
		}
		return fmt.Errorf("task %d not found", id)
	case protocol.TargetTypeAsset:
		asset, err := client.GetAsset(ctx, convID, id)
		if err != nil {
			return err
		}
		if asset.AssetID == 0 {
			return fmt.Errorf("asset %d not found", id)
		}
		return nil
	default:
		return fmt.Errorf("unsupported target type %d", targetType)
	}
}

func findEquivalentEdge(edges []protocol.Edge, sourceType uint16, sourceID uint64, targetType uint16, targetID uint64, relation uint16) *protocol.Edge {
	for i := range edges {
		edge := &edges[i]
		if edge.SourceType == sourceType && edge.SourceID == sourceID && edge.TargetType == targetType && edge.TargetID == targetID && edge.Relation == relation {
			return edge
		}
		if relation == protocol.RelationReferences && edge.Relation == relation && edge.SourceType == targetType && edge.SourceID == targetID && edge.TargetType == sourceType && edge.TargetID == sourceID {
			return edge
		}
	}
	return nil
}

func findEdgeByID(edges []protocol.Edge, edgeID uint64) *protocol.Edge {
	for i := range edges {
		if edges[i].EdgeID == edgeID {
			return &edges[i]
		}
	}
	return nil
}

func buildApplyAuditMessage(result askApplyResponse) string {
	lines := []string(nil)
	switch {
	case len(result.Failed) == 0:
		lines = append(lines, "APPLIED")
	case len(result.Applied) > 0:
		lines = append(lines, "PARTIAL APPLY")
	default:
		lines = append(lines, "APPLY FAILED")
	}

	for _, applied := range result.Applied {
		if applied.DeletedEntity != nil && applied.DeletedEntity.Type == "note" {
			verb := "Deleted"
			if applied.AlreadyApplied {
				verb = "Already deleted"
			}
			lines = append(lines, fmt.Sprintf("%s [Note:%d] %s", verb, applied.DeletedEntity.ID, applied.DeletedEntity.Title))
			continue
		}
		if applied.DeletedEdge != nil {
			verb := "Deleted edge"
			if applied.AlreadyApplied {
				verb = "Already deleted edge"
			}
			lines = append(lines, fmt.Sprintf("%s #%d %s:%d --%s--> %s:%d", verb, applied.DeletedEdge.EdgeID, applied.DeletedEdge.SourceType, applied.DeletedEdge.SourceID, applied.DeletedEdge.Relation, applied.DeletedEdge.TargetType, applied.DeletedEdge.TargetID))
			continue
		}
		entity := applied.Entity
		if entity == nil {
			entity = applied.CreatedEntity
		}
		if entity != nil && entity.Type == "task" {
			prefix := "#"
			if applied.Type == actionTypeUpdateTask {
				prefix = "Updated #"
			}
			if applied.AlreadyApplied {
				prefix = "ALREADY APPLIED #"
			}
			lines = append(lines, fmt.Sprintf("%s%d %s", prefix, entity.ID, entity.Title))
			continue
		}
		if entity != nil && entity.Type == "note" {
			prefix := "[Note:"
			suffix := "]"
			verb := "Updated"
			if applied.Type == actionTypeCreateNote {
				verb = "Created"
			}
			if applied.AlreadyApplied {
				verb = "Already applied"
			}
			lines = append(lines, fmt.Sprintf("%s %s%d%s %s", verb, prefix, entity.ID, suffix, entity.Title))
			continue
		}
		if applied.CreatedEdge != nil {
			verb := "Created edge"
			if applied.AlreadyApplied {
				verb = "Already linked"
			}
			lines = append(lines, fmt.Sprintf("%s %s:%d --%s--> %s:%d", verb, applied.CreatedEdge.SourceType, applied.CreatedEdge.SourceID, applied.CreatedEdge.Relation, applied.CreatedEdge.TargetType, applied.CreatedEdge.TargetID))
			continue
		}
		if applied.AlreadyApplied {
			lines = append(lines, fmt.Sprintf("Action %s already applied", applied.ActionID))
		} else {
			lines = append(lines, fmt.Sprintf("Action %s applied", applied.ActionID))
		}
	}

	for _, failed := range result.Failed {
		lines = append(lines, fmt.Sprintf("FAILED %s: %s", failed.ActionID, failed.Error))
	}

	if len(result.CreatedEdges) > 0 {
		lines = append(lines, fmt.Sprintf("LINKED %d EDGE(S)", len(result.CreatedEdges)))
	}

	return strings.Join(lines, "\n")
}

func createTaskReferenceEdges(ctx context.Context, client *NRCClient, convID uint64, action ProposedAction, task *protocol.Task) ([]applyCreatedEdge, []applyActionFailure) {
	if client == nil || task == nil {
		return nil, nil
	}

	assetIDs := extractActionAssetRefs(action)
	if len(assetIDs) == 0 {
		return nil, nil
	}

	existingEdges, err := client.GetEdges(ctx, convID)
	if err != nil {
		return nil, []applyActionFailure{{ActionID: action.ID, Type: "create_edge", Error: fmt.Sprintf("edge precheck failed: %v", err)}}
	}

	created := []applyCreatedEdge(nil)
	failures := []applyActionFailure(nil)
	for _, assetID := range assetIDs {
		if hasTaskAssetReferenceEdge(existingEdges, task.ID, assetID) {
			continue
		}

		edge, err := client.CreateEdge(ctx, convID, protocol.TargetTypeTask, task.ID, protocol.TargetTypeAsset, assetID, protocol.RelationReferences)
		if err != nil {
			failures = append(failures, applyActionFailure{ActionID: action.ID, Type: "create_edge", Error: fmt.Sprintf("edge Task:%d --references--> Asset:%d failed: %v", task.ID, assetID, err)})
			continue
		}
		if edge == nil {
			continue
		}

		existingEdges = append(existingEdges, *edge)
		created = append(created, applyCreatedEdge{
			EdgeID:     edge.EdgeID,
			SourceType: targetTypeName(edge.SourceType),
			SourceID:   edge.SourceID,
			TargetType: targetTypeName(edge.TargetType),
			TargetID:   edge.TargetID,
			Relation:   relationName(edge.Relation),
		})
	}

	return created, failures
}

func extractActionAssetRefs(action ProposedAction) []uint64 {
	text := action.Title + "\n" + action.Description
	matches := actionAssetRefPattern.FindAllStringSubmatch(text, -1)
	if len(matches) == 0 {
		return nil
	}

	seen := make(map[uint64]struct{}, len(matches))
	for _, match := range matches {
		if len(match) < 2 {
			continue
		}
		id, err := strconv.ParseUint(match[1], 10, 64)
		if err != nil || id == 0 {
			continue
		}
		seen[id] = struct{}{}
	}
	if len(seen) == 0 {
		return nil
	}

	ids := make([]uint64, 0, len(seen))
	for id := range seen {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	return ids
}

func hasTaskAssetReferenceEdge(edges []protocol.Edge, taskID uint64, assetID uint64) bool {
	for _, edge := range edges {
		if edge.Relation != protocol.RelationReferences {
			continue
		}
		if edge.SourceType == protocol.TargetTypeTask && edge.SourceID == taskID && edge.TargetType == protocol.TargetTypeAsset && edge.TargetID == assetID {
			return true
		}
		if edge.SourceType == protocol.TargetTypeAsset && edge.SourceID == assetID && edge.TargetType == protocol.TargetTypeTask && edge.TargetID == taskID {
			return true
		}
	}
	return false
}
