package main

import (
	"encoding/json"
	"fmt"
	"html"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/heavyhorst/nrc/protocol-go"
)

const (
	agentModeAsk   = "ask"
	agentModePlan  = "plan"
	agentModeApply = "apply"

	actionTypeCreateTask = "create_task"
	actionTypeUpdateTask = "update_task"
	actionTypeCreateNote = "create_note"
	actionTypeUpdateNote = "update_note"
	actionTypeDeleteNote = "delete_note"
	actionTypeCreateEdge = "create_edge"
	actionTypeDeleteEdge = "delete_edge"

	actionStatusPending  = "pending"
	actionStatusApplying = "applying"
	actionStatusApplied  = "applied"
	actionStatusFailed   = "failed"

	actionPlanStatusPending = "pending"
	actionPlanStatusApplied = "applied"
	actionPlanStatusPartial = "partial"
)

type AgentSession struct {
	ID            string       `json:"id"`
	Workspace     string       `json:"workspace"`
	ContextConvID uint64       `json:"context_conv_id"`
	DisplayConvID uint64       `json:"display_conv_id"`
	Mode          string       `json:"mode"`
	Summary       string       `json:"summary,omitempty"`
	Turns         []AgentTurn  `json:"turns,omitempty"`
	PendingPlans  []ActionPlan `json:"pending_plans,omitempty"`
	CreatedAt     time.Time    `json:"created_at"`
	UpdatedAt     time.Time    `json:"updated_at"`
	ExpiresAt     time.Time    `json:"expires_at"`
}

type AgentTurn struct {
	UserText  string           `json:"user_text"`
	Answer    string           `json:"answer"`
	Sources   []askSource      `json:"sources,omitempty"`
	ToolTrace []ToolTraceEntry `json:"tool_trace,omitempty"`
	CreatedAt time.Time        `json:"created_at"`
}

type ToolTraceEntry struct {
	Tool          string         `json:"tool"`
	Workspace     string         `json:"workspace,omitempty"`
	ContextConvID uint64         `json:"context_conv_id,omitempty"`
	DurationMS    int64          `json:"duration_ms"`
	Args          map[string]any `json:"args,omitempty"`
	Outcome       map[string]any `json:"outcome,omitempty"`
	Status        string         `json:"status"`
	Error         string         `json:"error,omitempty"`
}

type ActionPlan struct {
	ID             string           `json:"id"`
	AgentSessionID string           `json:"agent_session_id"`
	Workspace      string           `json:"workspace"`
	ContextConvID  uint64           `json:"context_conv_id"`
	DisplayConvID  uint64           `json:"display_conv_id"`
	Status         string           `json:"status"`
	Actions        []ProposedAction `json:"actions"`
	CreatedAt      time.Time        `json:"created_at"`
	UpdatedAt      time.Time        `json:"updated_at"`
	ExpiresAt      time.Time        `json:"expires_at"`
}

type ProposedAction struct {
	ID                string    `json:"id"`
	Type              string    `json:"type"`
	Status            string    `json:"status"`
	TaskID            uint64    `json:"task_id,omitempty"`
	TaskStatus        string    `json:"task_status,omitempty"`
	Title             string    `json:"title,omitempty"`
	Description       string    `json:"description,omitempty"`
	Content           string    `json:"content,omitempty"`
	Format            string    `json:"format,omitempty"`
	Project           string    `json:"project,omitempty"`
	Tags              []string  `json:"tags,omitempty"`
	Priority          uint8     `json:"priority,omitempty"`
	BlockedBy         uint64    `json:"blocked_by,omitempty"`
	AssetID           uint64    `json:"asset_id,omitempty"`
	EdgeID            uint64    `json:"edge_id,omitempty"`
	CreatedTaskID     uint64    `json:"created_task_id,omitempty"`
	CreatedAssetID    uint64    `json:"created_asset_id,omitempty"`
	CreatedEdgeID     uint64    `json:"created_edge_id,omitempty"`
	ExpectedUpdatedAt int64     `json:"expected_updated_at,omitempty,string"`
	SourceType        string    `json:"source_type,omitempty"`
	SourceID          uint64    `json:"source_id,omitempty"`
	SourceActionID    string    `json:"source_action_id,omitempty"`
	TargetType        string    `json:"target_type,omitempty"`
	TargetID          uint64    `json:"target_id,omitempty"`
	TargetActionID    string    `json:"target_action_id,omitempty"`
	Relation          string    `json:"relation,omitempty"`
	AppliedAt         time.Time `json:"applied_at,omitempty"`
	Error             string    `json:"error,omitempty"`
}

type notePreviewJSON struct {
	Title   string   `json:"title"`
	Teaser  string   `json:"teaser"`
	Project string   `json:"project"`
	Tags    []string `json:"tags"`
	Format  string   `json:"format,omitempty"`
}

type actionToApply struct {
	SessionID string
	PlanID    string
	Action    ProposedAction
}

type AgentSessionStore struct {
	mu       sync.Mutex
	sessions map[string]*AgentSession
	ttl      time.Duration
	maxTurns int
}

func newAgentSessionStore(ttl time.Duration, maxTurns int) *AgentSessionStore {
	return &AgentSessionStore{
		sessions: make(map[string]*AgentSession),
		ttl:      ttl,
		maxTurns: maxTurns,
	}
}

func normalizeAgentMode(mode string) string {
	switch strings.ToLower(strings.TrimSpace(mode)) {
	case "", agentModeAsk, "read-only", "readonly", "read_only":
		return agentModeAsk
	case agentModePlan:
		return agentModePlan
	case agentModeApply:
		return agentModeApply
	default:
		return agentModeAsk
	}
}

func newAgentSessionID() string {
	return "ask_" + newAskSessionID()
}

func newActionPlanID() string {
	return "plan_" + newAskSessionID()
}

func (s *AgentSessionStore) getOrCreate(workspace string, contextConvID, displayConvID uint64, requestedSessionID, mode string) (AgentSession, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	s.pruneExpiredLocked(now)

	mode = normalizeAgentMode(mode)
	requestedSessionID = strings.TrimSpace(requestedSessionID)
	if requestedSessionID != "" {
		if session, ok := s.sessions[requestedSessionID]; ok && session.Workspace == workspace && session.ContextConvID == contextConvID {
			session.DisplayConvID = displayConvID
			session.Mode = mode
			session.UpdatedAt = now
			session.ExpiresAt = now.Add(s.ttl)
			return cloneAgentSession(session), false
		}
	}

	session := &AgentSession{
		ID:            newAgentSessionID(),
		Workspace:     workspace,
		ContextConvID: contextConvID,
		DisplayConvID: displayConvID,
		Mode:          mode,
		CreatedAt:     now,
		UpdatedAt:     now,
		ExpiresAt:     now.Add(s.ttl),
	}
	s.sessions[session.ID] = session
	return cloneAgentSession(session), true
}

func (s *AgentSessionStore) get(sessionID string) (AgentSession, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	s.pruneExpiredLocked(now)
	session, ok := s.sessions[strings.TrimSpace(sessionID)]
	if !ok {
		return AgentSession{}, false
	}
	session.UpdatedAt = now
	session.ExpiresAt = now.Add(s.ttl)
	return cloneAgentSession(session), true
}

func (s *AgentSessionStore) reset(sessionID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return false
	}
	if _, ok := s.sessions[sessionID]; !ok {
		return false
	}
	delete(s.sessions, sessionID)
	return true
}

func (s *AgentSessionStore) appendTurn(sessionID string, turn AgentTurn) int {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	s.pruneExpiredLocked(now)
	session, ok := s.sessions[strings.TrimSpace(sessionID)]
	if !ok {
		return 0
	}

	turn.CreatedAt = now
	turn.Sources = cloneAskSources(turn.Sources)
	turn.ToolTrace = cloneToolTrace(turn.ToolTrace)
	session.Turns = append(session.Turns, turn)
	if s.maxTurns > 0 && len(session.Turns) > s.maxTurns {
		start := len(session.Turns) - s.maxTurns
		session.Turns = append([]AgentTurn(nil), session.Turns[start:]...)
	}
	session.UpdatedAt = now
	session.ExpiresAt = now.Add(s.ttl)
	return len(session.Turns)
}

func (s *AgentSessionStore) startPlan(sessionID string) (ActionPlan, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	s.pruneExpiredLocked(now)
	session, ok := s.sessions[strings.TrimSpace(sessionID)]
	if !ok {
		return ActionPlan{}, false
	}

	plan := ActionPlan{
		ID:             newActionPlanID(),
		AgentSessionID: session.ID,
		Workspace:      session.Workspace,
		ContextConvID:  session.ContextConvID,
		DisplayConvID:  session.DisplayConvID,
		Status:         actionPlanStatusPending,
		Actions:        []ProposedAction{},
		CreatedAt:      now,
		UpdatedAt:      now,
		ExpiresAt:      now.Add(s.ttl),
	}
	session.PendingPlans = append(session.PendingPlans, plan)
	session.UpdatedAt = now
	session.ExpiresAt = now.Add(s.ttl)
	return cloneActionPlan(plan), true
}

func (s *AgentSessionStore) addCreateTaskAction(sessionID, planID, title, description string, priority uint8) (ActionPlan, ProposedAction, error) {
	title = strings.TrimSpace(title)
	description = strings.TrimSpace(description)
	if title == "" {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("title is required")
	}
	if len(title) > protocol.MaxTaskTitleLength {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("title exceeds %d bytes", protocol.MaxTaskTitleLength)
	}
	if len(description) > protocol.MaxTaskDescriptionLength {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("description exceeds %d bytes", protocol.MaxTaskDescriptionLength)
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	s.pruneExpiredLocked(now)
	session, plan, ok := s.findPlanLocked(sessionID, planID)
	if !ok {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("pending action plan not found")
	}
	for _, existing := range plan.Actions {
		if existing.Type == actionTypeCreateTask && existing.Title == title && existing.Description == description && existing.Priority == priority {
			plan.UpdatedAt = now
			plan.ExpiresAt = now.Add(s.ttl)
			session.UpdatedAt = now
			session.ExpiresAt = now.Add(s.ttl)
			return cloneActionPlan(*plan), existing, nil
		}
	}

	action := ProposedAction{
		ID:          strconv.Itoa(len(plan.Actions) + 1),
		Type:        actionTypeCreateTask,
		Status:      actionStatusPending,
		Title:       title,
		Description: description,
		Priority:    priority,
	}
	plan.Actions = append(plan.Actions, action)
	plan.Status = actionPlanStatusPending
	plan.UpdatedAt = now
	plan.ExpiresAt = now.Add(s.ttl)
	session.UpdatedAt = now
	session.ExpiresAt = now.Add(s.ttl)

	return cloneActionPlan(*plan), action, nil
}

func (s *AgentSessionStore) addUpdateTaskAction(sessionID, planID string, taskID uint64, expectedUpdatedAt int64, title, description, taskStatus string, priority uint8, blockedBy uint64) (ActionPlan, ProposedAction, error) {
	if taskID == 0 {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("task_id is required")
	}
	if expectedUpdatedAt == 0 {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("expected_updated_at is required")
	}
	title = strings.TrimSpace(title)
	description = strings.TrimSpace(description)
	if title == "" {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("title is required")
	}
	if len(title) > protocol.MaxTaskTitleLength {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("title exceeds %d bytes", protocol.MaxTaskTitleLength)
	}
	if len(description) > protocol.MaxTaskDescriptionLength {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("description exceeds %d bytes", protocol.MaxTaskDescriptionLength)
	}
	canonicalStatus, _, err := normalizeActionTaskStatus(taskStatus)
	if err != nil {
		return ActionPlan{}, ProposedAction{}, err
	}
	if blockedBy == taskID {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("task cannot block itself")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	s.pruneExpiredLocked(now)
	session, plan, ok := s.findPlanLocked(sessionID, planID)
	if !ok {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("pending action plan not found")
	}
	for _, existing := range plan.Actions {
		if existing.Type == actionTypeUpdateTask && existing.TaskID == taskID && existing.ExpectedUpdatedAt == expectedUpdatedAt && existing.Title == title && existing.Description == description && existing.TaskStatus == canonicalStatus && existing.Priority == priority && existing.BlockedBy == blockedBy {
			plan.UpdatedAt = now
			plan.ExpiresAt = now.Add(s.ttl)
			session.UpdatedAt = now
			session.ExpiresAt = now.Add(s.ttl)
			return cloneActionPlan(*plan), existing, nil
		}
	}

	action := ProposedAction{
		ID:                strconv.Itoa(len(plan.Actions) + 1),
		Type:              actionTypeUpdateTask,
		Status:            actionStatusPending,
		TaskID:            taskID,
		Title:             title,
		Description:       description,
		TaskStatus:        canonicalStatus,
		Priority:          priority,
		BlockedBy:         blockedBy,
		ExpectedUpdatedAt: expectedUpdatedAt,
	}
	plan.Actions = append(plan.Actions, action)
	plan.Status = actionPlanStatusPending
	plan.UpdatedAt = now
	plan.ExpiresAt = now.Add(s.ttl)
	session.UpdatedAt = now
	session.ExpiresAt = now.Add(s.ttl)

	return cloneActionPlan(*plan), action, nil
}

func (s *AgentSessionStore) addCreateNoteAction(sessionID, planID, title, content, project string, tags []string) (ActionPlan, ProposedAction, error) {
	title, content, project, tags, _, err := validateNoteActionPayloadWithMetadata(title, content, project, tags)
	if err != nil {
		return ActionPlan{}, ProposedAction{}, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	s.pruneExpiredLocked(now)
	session, plan, ok := s.findPlanLocked(sessionID, planID)
	if !ok {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("pending action plan not found")
	}
	for _, existing := range plan.Actions {
		if existing.Type == actionTypeCreateNote && existing.Title == title && existing.Content == content && existing.Project == project && sameStringSlice(existing.Tags, tags) {
			plan.UpdatedAt = now
			plan.ExpiresAt = now.Add(s.ttl)
			session.UpdatedAt = now
			session.ExpiresAt = now.Add(s.ttl)
			return cloneActionPlan(*plan), existing, nil
		}
	}

	action := ProposedAction{
		ID:      strconv.Itoa(len(plan.Actions) + 1),
		Type:    actionTypeCreateNote,
		Status:  actionStatusPending,
		Title:   title,
		Content: content,
		Project: project,
		Tags:    cloneStringSlice(tags),
		Format:  "markdown",
	}
	plan.Actions = append(plan.Actions, action)
	plan.Status = actionPlanStatusPending
	plan.UpdatedAt = now
	plan.ExpiresAt = now.Add(s.ttl)
	session.UpdatedAt = now
	session.ExpiresAt = now.Add(s.ttl)

	return cloneActionPlan(*plan), action, nil
}

func (s *AgentSessionStore) addUpdateNoteAction(sessionID, planID string, assetID uint64, expectedUpdatedAt int64, title, content, project string, tags []string, format string) (ActionPlan, ProposedAction, error) {
	if assetID == 0 {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("asset_id is required")
	}
	if expectedUpdatedAt == 0 {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("expected_updated_at is required")
	}
	title, content, project, tags, _, err := validateNoteActionPayloadWithMetadata(title, content, project, tags)
	if err != nil {
		return ActionPlan{}, ProposedAction{}, err
	}
	format, err = normalizeNoteFormat(format)
	if err != nil {
		return ActionPlan{}, ProposedAction{}, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	s.pruneExpiredLocked(now)
	session, plan, ok := s.findPlanLocked(sessionID, planID)
	if !ok {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("pending action plan not found")
	}
	for _, existing := range plan.Actions {
		if existing.Type == actionTypeUpdateNote && existing.AssetID == assetID && existing.ExpectedUpdatedAt == expectedUpdatedAt && existing.Title == title && existing.Content == content && existing.Project == project && sameStringSlice(existing.Tags, tags) && existing.Format == format {
			plan.UpdatedAt = now
			plan.ExpiresAt = now.Add(s.ttl)
			session.UpdatedAt = now
			session.ExpiresAt = now.Add(s.ttl)
			return cloneActionPlan(*plan), existing, nil
		}
	}

	action := ProposedAction{
		ID:                strconv.Itoa(len(plan.Actions) + 1),
		Type:              actionTypeUpdateNote,
		Status:            actionStatusPending,
		Title:             title,
		Content:           content,
		Project:           project,
		Tags:              cloneStringSlice(tags),
		AssetID:           assetID,
		ExpectedUpdatedAt: expectedUpdatedAt,
		Format:            format,
	}
	plan.Actions = append(plan.Actions, action)
	plan.Status = actionPlanStatusPending
	plan.UpdatedAt = now
	plan.ExpiresAt = now.Add(s.ttl)
	session.UpdatedAt = now
	session.ExpiresAt = now.Add(s.ttl)

	return cloneActionPlan(*plan), action, nil
}

func (s *AgentSessionStore) addDeleteNoteAction(sessionID, planID string, assetID uint64, expectedUpdatedAt int64, title string) (ActionPlan, ProposedAction, error) {
	if assetID == 0 {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("asset_id is required")
	}
	if expectedUpdatedAt == 0 {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("expected_updated_at is required")
	}
	title = strings.TrimSpace(title)

	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	s.pruneExpiredLocked(now)
	session, plan, ok := s.findPlanLocked(sessionID, planID)
	if !ok {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("pending action plan not found")
	}
	for i := range plan.Actions {
		existing := &plan.Actions[i]
		if existing.Type == actionTypeDeleteNote && existing.AssetID == assetID && existing.ExpectedUpdatedAt == expectedUpdatedAt {
			if existing.Title == "" && title != "" {
				existing.Title = title
			}
			plan.UpdatedAt = now
			plan.ExpiresAt = now.Add(s.ttl)
			session.UpdatedAt = now
			session.ExpiresAt = now.Add(s.ttl)
			return cloneActionPlan(*plan), *existing, nil
		}
	}

	action := ProposedAction{
		ID:                strconv.Itoa(len(plan.Actions) + 1),
		Type:              actionTypeDeleteNote,
		Status:            actionStatusPending,
		Title:             title,
		AssetID:           assetID,
		ExpectedUpdatedAt: expectedUpdatedAt,
	}
	plan.Actions = append(plan.Actions, action)
	plan.Status = actionPlanStatusPending
	plan.UpdatedAt = now
	plan.ExpiresAt = now.Add(s.ttl)
	session.UpdatedAt = now
	session.ExpiresAt = now.Add(s.ttl)

	return cloneActionPlan(*plan), action, nil
}

func (s *AgentSessionStore) addCreateEdgeAction(sessionID, planID, sourceType string, sourceID uint64, sourceActionID, targetType string, targetID uint64, targetActionID, relation string) (ActionPlan, ProposedAction, error) {
	canonicalSourceType, _, err := normalizeActionTargetType(sourceType)
	if err != nil {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("invalid source_type: %w", err)
	}
	canonicalTargetType, _, err := normalizeActionTargetType(targetType)
	if err != nil {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("invalid target_type: %w", err)
	}
	canonicalRelation, _, err := normalizeActionRelation(relation)
	if err != nil {
		return ActionPlan{}, ProposedAction{}, err
	}
	sourceActionID = strings.TrimSpace(sourceActionID)
	targetActionID = strings.TrimSpace(targetActionID)
	if sourceID == 0 && sourceActionID == "" {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("source_id or source_action_id is required")
	}
	if targetID == 0 && targetActionID == "" {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("target_id or target_action_id is required")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	s.pruneExpiredLocked(now)
	session, plan, ok := s.findPlanLocked(sessionID, planID)
	if !ok {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("pending action plan not found")
	}
	if sourceActionID != "" {
		if sourceID != 0 {
			sourceActionID = ""
		} else if err := validateActionEndpointReference(plan.Actions, sourceActionID, canonicalSourceType); err != nil {
			return ActionPlan{}, ProposedAction{}, fmt.Errorf("invalid source_action_id: %w", err)
		}
	}
	if targetActionID != "" {
		if targetID != 0 {
			targetActionID = ""
		} else if err := validateActionEndpointReference(plan.Actions, targetActionID, canonicalTargetType); err != nil {
			return ActionPlan{}, ProposedAction{}, fmt.Errorf("invalid target_action_id: %w", err)
		}
	}
	for _, existing := range plan.Actions {
		if existing.Type == actionTypeCreateEdge && existing.SourceType == canonicalSourceType && existing.SourceID == sourceID && existing.SourceActionID == sourceActionID && existing.TargetType == canonicalTargetType && existing.TargetID == targetID && existing.TargetActionID == targetActionID && existing.Relation == canonicalRelation {
			plan.UpdatedAt = now
			plan.ExpiresAt = now.Add(s.ttl)
			session.UpdatedAt = now
			session.ExpiresAt = now.Add(s.ttl)
			return cloneActionPlan(*plan), existing, nil
		}
	}

	action := ProposedAction{
		ID:             strconv.Itoa(len(plan.Actions) + 1),
		Type:           actionTypeCreateEdge,
		Status:         actionStatusPending,
		SourceType:     canonicalSourceType,
		SourceID:       sourceID,
		SourceActionID: sourceActionID,
		TargetType:     canonicalTargetType,
		TargetID:       targetID,
		TargetActionID: targetActionID,
		Relation:       canonicalRelation,
	}
	plan.Actions = append(plan.Actions, action)
	plan.Status = actionPlanStatusPending
	plan.UpdatedAt = now
	plan.ExpiresAt = now.Add(s.ttl)
	session.UpdatedAt = now
	session.ExpiresAt = now.Add(s.ttl)

	return cloneActionPlan(*plan), action, nil
}

func (s *AgentSessionStore) addDeleteEdgeAction(sessionID, planID string, edge protocol.Edge) (ActionPlan, ProposedAction, error) {
	if edge.EdgeID == 0 {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("edge_id is required")
	}
	if edge.SourceID == 0 || edge.TargetID == 0 {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("edge endpoints are required")
	}
	sourceType := targetTypeName(edge.SourceType)
	targetType := targetTypeName(edge.TargetType)
	relation := relationName(edge.Relation)

	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	s.pruneExpiredLocked(now)
	session, plan, ok := s.findPlanLocked(sessionID, planID)
	if !ok {
		return ActionPlan{}, ProposedAction{}, fmt.Errorf("pending action plan not found")
	}
	for _, existing := range plan.Actions {
		if existing.Type == actionTypeDeleteEdge && existing.EdgeID == edge.EdgeID {
			plan.UpdatedAt = now
			plan.ExpiresAt = now.Add(s.ttl)
			session.UpdatedAt = now
			session.ExpiresAt = now.Add(s.ttl)
			return cloneActionPlan(*plan), existing, nil
		}
	}

	action := ProposedAction{
		ID:         strconv.Itoa(len(plan.Actions) + 1),
		Type:       actionTypeDeleteEdge,
		Status:     actionStatusPending,
		EdgeID:     edge.EdgeID,
		SourceType: sourceType,
		SourceID:   edge.SourceID,
		TargetType: targetType,
		TargetID:   edge.TargetID,
		Relation:   relation,
	}
	plan.Actions = append(plan.Actions, action)
	plan.Status = actionPlanStatusPending
	plan.UpdatedAt = now
	plan.ExpiresAt = now.Add(s.ttl)
	session.UpdatedAt = now
	session.ExpiresAt = now.Add(s.ttl)

	return cloneActionPlan(*plan), action, nil
}

func (s *AgentSessionStore) getPlan(sessionID, planID string) (ActionPlan, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	s.pruneExpiredLocked(now)
	session, plan, ok := s.findPlanLocked(sessionID, planID)
	if !ok {
		return ActionPlan{}, false
	}
	session.UpdatedAt = now
	session.ExpiresAt = now.Add(s.ttl)
	plan.ExpiresAt = now.Add(s.ttl)
	return cloneActionPlan(*plan), true
}

func (s *AgentSessionStore) discardPlan(sessionID, planID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	session, ok := s.sessions[strings.TrimSpace(sessionID)]
	if !ok {
		return false
	}
	planID = strings.TrimSpace(planID)
	for i := range session.PendingPlans {
		if session.PendingPlans[i].ID == planID {
			session.PendingPlans = append(session.PendingPlans[:i], session.PendingPlans[i+1:]...)
			session.UpdatedAt = time.Now()
			return true
		}
	}
	return false
}

func (s *AgentSessionStore) latestPendingPlan(sessionID string) (ActionPlan, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	s.pruneExpiredLocked(now)
	session, ok := s.sessions[strings.TrimSpace(sessionID)]
	if !ok {
		return ActionPlan{}, false
	}

	for i := len(session.PendingPlans) - 1; i >= 0; i-- {
		plan := &session.PendingPlans[i]
		if plan.Status == actionPlanStatusApplied || len(plan.Actions) == 0 {
			continue
		}
		return cloneActionPlan(*plan), true
	}
	return ActionPlan{}, false
}

func (s *AgentSessionStore) prepareApply(sessionID, planID string, actionIDs []string) (AgentSession, ActionPlan, []actionToApply, []applyActionResult, []applyActionFailure, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	s.pruneExpiredLocked(now)
	session, plan, ok := s.findPlanLocked(sessionID, planID)
	if !ok {
		return AgentSession{}, ActionPlan{}, nil, nil, nil, fmt.Errorf("pending action plan not found or expired")
	}

	selected := normalizeActionSelection(actionIDs, plan.Actions)
	if len(selected) == 0 {
		return AgentSession{}, ActionPlan{}, nil, nil, nil, fmt.Errorf("no matching actions selected")
	}

	alreadyApplied := []applyActionResult(nil)
	failures := []applyActionFailure(nil)
	toApply := []actionToApply(nil)
	matched := make(map[string]struct{}, len(selected))
	for i := range plan.Actions {
		action := &plan.Actions[i]
		if _, ok := selected[action.ID]; !ok {
			continue
		}
		matched[action.ID] = struct{}{}

		switch action.Status {
		case actionStatusApplied:
			alreadyApplied = append(alreadyApplied, applyActionResult{
				ActionID:       action.ID,
				Type:           action.Type,
				Status:         actionStatusApplied,
				AlreadyApplied: true,
				Entity:         affectedActionEntity(*action),
				CreatedEntity:  createdActionEntity(*action),
				CreatedEdge:    createdActionEdge(*action),
				DeletedEntity:  deletedActionEntity(*action),
				DeletedEdge:    deletedActionEdge(*action),
			})
		case actionStatusApplying:
			failures = append(failures, applyActionFailure{ActionID: action.ID, Type: action.Type, Error: "action is already applying"})
		case actionStatusPending, actionStatusFailed:
			action.Status = actionStatusApplying
			action.Error = ""
			toApply = append(toApply, actionToApply{SessionID: session.ID, PlanID: plan.ID, Action: *action})
		default:
			failures = append(failures, applyActionFailure{ActionID: action.ID, Type: action.Type, Error: "unsupported action status"})
		}
	}
	for id := range selected {
		if _, ok := matched[id]; !ok {
			failures = append(failures, applyActionFailure{ActionID: id, Error: "action not found"})
		}
	}

	plan.UpdatedAt = now
	plan.ExpiresAt = now.Add(s.ttl)
	session.UpdatedAt = now
	session.ExpiresAt = now.Add(s.ttl)

	return cloneAgentSession(session), cloneActionPlan(*plan), toApply, alreadyApplied, failures, nil
}

func (s *AgentSessionStore) completeCreateTaskAction(sessionID, planID, actionID string, task *protocol.Task, applyErr error) (ProposedAction, bool) {
	return s.completeAction(sessionID, planID, actionID, applyErr, func(action *ProposedAction) {
		if task != nil {
			action.CreatedTaskID = task.ID
		}
	})
}

func (s *AgentSessionStore) completeUpdateTaskAction(sessionID, planID, actionID string, task *protocol.Task, applyErr error) (ProposedAction, bool) {
	return s.completeAction(sessionID, planID, actionID, applyErr, func(action *ProposedAction) {
		if task != nil {
			action.TaskID = task.ID
			action.Title = task.Title
			action.Description = task.Description
			action.TaskStatus = taskStatusName(task.Status)
			action.Priority = task.Priority
			action.BlockedBy = task.BlockedBy
		}
	})
}

func (s *AgentSessionStore) completeCreateNoteAction(sessionID, planID, actionID string, asset *protocol.Asset, applyErr error) (ProposedAction, bool) {
	return s.completeAction(sessionID, planID, actionID, applyErr, func(action *ProposedAction) {
		if asset != nil {
			action.CreatedAssetID = asset.AssetID
			applyNotePreviewToAction(action, asset.Preview)
		}
	})
}

func (s *AgentSessionStore) completeUpdateNoteAction(sessionID, planID, actionID string, asset *protocol.Asset, applyErr error) (ProposedAction, bool) {
	return s.completeAction(sessionID, planID, actionID, applyErr, func(action *ProposedAction) {
		if asset != nil {
			action.AssetID = asset.AssetID
			applyNotePreviewToAction(action, asset.Preview)
		}
	})
}

func (s *AgentSessionStore) completeDeleteNoteAction(sessionID, planID, actionID string, asset *protocol.Asset, applyErr error) (ProposedAction, bool) {
	return s.completeAction(sessionID, planID, actionID, applyErr, func(action *ProposedAction) {
		if asset != nil {
			action.AssetID = asset.AssetID
			if action.Title == "" {
				action.Title = noteTitleFromAsset(asset)
			}
		}
	})
}

func applyNotePreviewToAction(action *ProposedAction, preview string) {
	parsed := parseNotePreviewJSON(preview)
	if parsed.Title != "" {
		action.Title = parsed.Title
	}
	action.Project = parsed.Project
	action.Tags = cloneStringSlice(parsed.Tags)
	action.Format = parsed.Format
}

func (s *AgentSessionStore) completeCreateEdgeAction(sessionID, planID, actionID string, edge *protocol.Edge, applyErr error) (ProposedAction, bool) {
	return s.completeAction(sessionID, planID, actionID, applyErr, func(action *ProposedAction) {
		if edge != nil {
			action.CreatedEdgeID = edge.EdgeID
			action.SourceType = targetTypeName(edge.SourceType)
			action.SourceID = edge.SourceID
			action.TargetType = targetTypeName(edge.TargetType)
			action.TargetID = edge.TargetID
			action.Relation = relationName(edge.Relation)
		}
	})
}

func (s *AgentSessionStore) completeDeleteEdgeAction(sessionID, planID, actionID string, edge *protocol.Edge, applyErr error) (ProposedAction, bool) {
	return s.completeAction(sessionID, planID, actionID, applyErr, func(action *ProposedAction) {
		if edge != nil {
			action.EdgeID = edge.EdgeID
			action.SourceType = targetTypeName(edge.SourceType)
			action.SourceID = edge.SourceID
			action.TargetType = targetTypeName(edge.TargetType)
			action.TargetID = edge.TargetID
			action.Relation = relationName(edge.Relation)
		}
	})
}

func (s *AgentSessionStore) completeFailedAction(sessionID, planID, actionID string, applyErr error) (ProposedAction, bool) {
	return s.completeAction(sessionID, planID, actionID, applyErr, nil)
}

func (s *AgentSessionStore) completeAction(sessionID, planID, actionID string, applyErr error, update func(*ProposedAction)) (ProposedAction, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	session, plan, ok := s.findPlanLocked(sessionID, planID)
	if !ok {
		return ProposedAction{}, false
	}

	for i := range plan.Actions {
		action := &plan.Actions[i]
		if action.ID != actionID {
			continue
		}
		if applyErr != nil {
			action.Status = actionStatusFailed
			action.Error = applyErr.Error()
		} else {
			action.Status = actionStatusApplied
			action.Error = ""
			action.AppliedAt = now
			if update != nil {
				update(action)
			}
		}
		plan.Status = deriveActionPlanStatus(plan.Actions)
		plan.UpdatedAt = now
		plan.ExpiresAt = now.Add(s.ttl)
		session.UpdatedAt = now
		session.ExpiresAt = now.Add(s.ttl)
		return *action, true
	}

	return ProposedAction{}, false
}

func (s *AgentSessionStore) findPlanLocked(sessionID, planID string) (*AgentSession, *ActionPlan, bool) {
	session, ok := s.sessions[strings.TrimSpace(sessionID)]
	if !ok {
		return nil, nil, false
	}
	planID = strings.TrimSpace(planID)
	for i := range session.PendingPlans {
		if session.PendingPlans[i].ID == planID {
			return session, &session.PendingPlans[i], true
		}
	}
	return nil, nil, false
}

func (s *AgentSessionStore) pruneExpiredLocked(now time.Time) {
	for id, session := range s.sessions {
		if !session.ExpiresAt.IsZero() && now.After(session.ExpiresAt) {
			delete(s.sessions, id)
			continue
		}

		kept := session.PendingPlans[:0]
		for _, plan := range session.PendingPlans {
			if !plan.ExpiresAt.IsZero() && now.After(plan.ExpiresAt) {
				continue
			}
			kept = append(kept, plan)
		}
		session.PendingPlans = kept
	}
}

func normalizeActionSelection(actionIDs []string, actions []ProposedAction) map[string]struct{} {
	selected := make(map[string]struct{})
	if len(actionIDs) == 0 {
		for _, action := range actions {
			selected[action.ID] = struct{}{}
		}
		return selected
	}

	for _, raw := range actionIDs {
		id := strings.TrimSpace(raw)
		if id == "" {
			continue
		}
		if strings.EqualFold(id, "all") {
			for _, action := range actions {
				selected[action.ID] = struct{}{}
			}
			continue
		}
		selected[id] = struct{}{}
	}
	return selected
}

func deriveActionPlanStatus(actions []ProposedAction) string {
	if len(actions) == 0 {
		return actionPlanStatusPending
	}

	applied := 0
	failed := 0
	for _, action := range actions {
		switch action.Status {
		case actionStatusApplied:
			applied++
		case actionStatusFailed:
			failed++
		}
	}
	if applied == len(actions) {
		return actionPlanStatusApplied
	}
	if applied > 0 || failed > 0 {
		return actionPlanStatusPartial
	}
	return actionPlanStatusPending
}

func cloneAgentSession(session *AgentSession) AgentSession {
	if session == nil {
		return AgentSession{}
	}
	clone := *session
	clone.Turns = make([]AgentTurn, len(session.Turns))
	for i, turn := range session.Turns {
		clone.Turns[i] = turn
		clone.Turns[i].Sources = cloneAskSources(turn.Sources)
		clone.Turns[i].ToolTrace = cloneToolTrace(turn.ToolTrace)
	}
	clone.PendingPlans = make([]ActionPlan, len(session.PendingPlans))
	for i, plan := range session.PendingPlans {
		clone.PendingPlans[i] = cloneActionPlan(plan)
	}
	return clone
}

func cloneActionPlan(plan ActionPlan) ActionPlan {
	clone := plan
	clone.Actions = make([]ProposedAction, len(plan.Actions))
	for i, action := range plan.Actions {
		clone.Actions[i] = action
		clone.Actions[i].Tags = cloneStringSlice(action.Tags)
	}
	return clone
}

func cloneStringSlice(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	return append([]string(nil), values...)
}

func sameStringSlice(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func cloneAskSources(sources []askSource) []askSource {
	if len(sources) == 0 {
		return nil
	}
	return append([]askSource(nil), sources...)
}

func cloneToolTrace(entries []ToolTraceEntry) []ToolTraceEntry {
	if len(entries) == 0 {
		return nil
	}
	clone := make([]ToolTraceEntry, len(entries))
	for i, entry := range entries {
		clone[i] = entry
		clone[i].Args = cloneAnyMap(entry.Args)
		clone[i].Outcome = cloneAnyMap(entry.Outcome)
	}
	return clone
}

func cloneAnyMap(m map[string]any) map[string]any {
	if len(m) == 0 {
		return nil
	}
	clone := make(map[string]any, len(m))
	for k, v := range m {
		clone[k] = v
	}
	return clone
}

func sortProposedActions(actions []ProposedAction) {
	sort.Slice(actions, func(i, j int) bool {
		left, leftErr := strconv.Atoi(actions[i].ID)
		right, rightErr := strconv.Atoi(actions[j].ID)
		if leftErr == nil && rightErr == nil && left != right {
			return left < right
		}
		return actions[i].ID < actions[j].ID
	})
}

func findTaskByID(tasks []protocol.Task, taskID uint64) (protocol.Task, bool) {
	for _, task := range tasks {
		if task.ID == taskID {
			return task, true
		}
	}
	return protocol.Task{}, false
}

func validateNoteActionPayload(title, content string) (string, string, string, error) {
	title, content, _, _, preview, err := validateNoteActionPayloadWithMetadata(title, content, "", nil)
	return title, content, preview, err
}

func validateNoteActionPayloadWithMetadata(title, content, project string, tags []string) (string, string, string, []string, string, error) {
	title = strings.TrimSpace(title)
	content = strings.TrimSpace(content)
	project = strings.TrimSpace(project)
	tags = normalizeNoteTags(tags)
	if title == "" {
		return "", "", "", nil, "", fmt.Errorf("title is required")
	}
	if len(content) >= protocol.MaxPayloadLength {
		return "", "", "", nil, "", fmt.Errorf("content exceeds %d bytes", protocol.MaxPayloadLength)
	}
	preview, err := buildNotePreviewWithMetadata(title, content, project, tags)
	if err != nil {
		return "", "", "", nil, "", err
	}
	return title, content, project, tags, preview, nil
}

func buildNotePreview(title, content string) (string, error) {
	return buildNotePreviewWithMetadata(title, content, "", nil)
}

func buildNotePreviewWithMetadata(title, content, project string, tags []string) (string, error) {
	return buildNotePreviewWithFormat(title, content, project, tags, "markdown")
}

func normalizeNoteFormat(format string) (string, error) {
	format = strings.ToLower(strings.TrimSpace(format))
	if format == "" {
		return "markdown", nil
	}
	if format != "markdown" && format != "html" {
		return "", fmt.Errorf("format must be markdown or html")
	}
	return format, nil
}

func buildNotePreviewWithFormat(title, content, project string, tags []string, format string) (string, error) {
	format, err := normalizeNoteFormat(format)
	if err != nil {
		return "", err
	}
	preview := notePreviewJSON{
		Title:   strings.TrimSpace(title),
		Teaser:  noteTeaser(content, format),
		Project: strings.TrimSpace(project),
		Tags:    normalizeNoteTags(tags),
		Format:  format,
	}
	encoded, err := json.Marshal(preview)
	if err != nil {
		return "", err
	}
	if len(encoded) > protocol.MaxPreviewLength {
		return "", fmt.Errorf("note preview exceeds %d bytes", protocol.MaxPreviewLength)
	}
	return string(encoded), nil
}

func normalizeNoteTags(values []string) []string {
	tags := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		for _, part := range strings.Split(value, ",") {
			tag := strings.TrimSpace(part)
			if tag == "" {
				continue
			}
			if _, ok := seen[tag]; ok {
				continue
			}
			seen[tag] = struct{}{}
			tags = append(tags, tag)
		}
	}
	return tags
}

func parseNotePreviewJSON(preview string) notePreviewJSON {
	var parsed notePreviewJSON
	if err := json.Unmarshal([]byte(strings.TrimSpace(preview)), &parsed); err != nil {
		return notePreviewJSON{}
	}
	parsed.Title = strings.TrimSpace(parsed.Title)
	parsed.Teaser = strings.TrimSpace(parsed.Teaser)
	parsed.Project = strings.TrimSpace(parsed.Project)
	parsed.Tags = normalizeNoteTags(parsed.Tags)
	parsed.Format, _ = normalizeNoteFormat(parsed.Format)
	return parsed
}

func noteTitleFromAsset(asset *protocol.Asset) string {
	if asset == nil {
		return ""
	}
	preview := parseNotePreviewJSON(asset.Preview)
	return strings.TrimSpace(preview.Title)
}

func noteTeaser(content, format string) string {
	if format == "html" {
		content = html.UnescapeString(content)
		var out strings.Builder
		inTag := false
		for _, r := range content {
			if r == '<' {
				inTag = true
				continue
			}
			if r == '>' {
				inTag = false
				out.WriteByte(' ')
				continue
			}
			if !inTag {
				out.WriteRune(r)
			}
		}
		content = out.String()
	}
	text := strings.Join(strings.Fields(content), " ")
	if text == "" {
		return ""
	}
	runes := []rune(text)
	if len(runes) <= 200 {
		return text
	}
	return string(runes[:197]) + "..."
}

func normalizeActionTargetType(value string) (string, uint16, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "task", "tasks", "2":
		return targetTypeName(protocol.TargetTypeTask), protocol.TargetTypeTask, nil
	case "asset", "assets", "note", "notes", "document", "documents", "1":
		return targetTypeName(protocol.TargetTypeAsset), protocol.TargetTypeAsset, nil
	default:
		return "", 0, fmt.Errorf("unsupported target type %q", value)
	}
}

func normalizeActionRelation(value string) (string, uint16, error) {
	switch strings.ToLower(strings.TrimSpace(strings.ReplaceAll(value, "_", "-"))) {
	case "references", "reference", "ref", "1":
		return relationName(protocol.RelationReferences), protocol.RelationReferences, nil
	case "related-to", "relatedto", "related", "relates-to", "relatesto", "rel", "2":
		return relationName(protocol.RelationRelatedTo), protocol.RelationRelatedTo, nil
	case "depends-on", "dependson", "depends", "dependency", "dependencies", "3":
		return relationName(protocol.RelationDependsOn), protocol.RelationDependsOn, nil
	case "blocks", "block", "blocking", "blocked-by", "blockedby", "4":
		return relationName(protocol.RelationBlocks), protocol.RelationBlocks, nil
	case "derived-from", "derivedfrom", "derived", "5":
		return relationName(protocol.RelationDerivedFrom), protocol.RelationDerivedFrom, nil
	case "supersedes", "supersede", "6":
		return relationName(protocol.RelationSupersedes), protocol.RelationSupersedes, nil
	default:
		return "", 0, fmt.Errorf("unsupported relation %q", value)
	}
}

func normalizeActionTaskStatus(value string) (string, uint8, error) {
	normalized := strings.ToLower(strings.TrimSpace(value))
	normalized = strings.ReplaceAll(normalized, "-", "")
	normalized = strings.ReplaceAll(normalized, "_", "")
	normalized = strings.ReplaceAll(normalized, " ", "")
	switch normalized {
	case "backlog", "0":
		return taskStatusName(protocol.TaskStatusBacklog), protocol.TaskStatusBacklog, nil
	case "todo", "1":
		return taskStatusName(protocol.TaskStatusTodo), protocol.TaskStatusTodo, nil
	case "inprogress", "progress", "doing", "2":
		return taskStatusName(protocol.TaskStatusInProgress), protocol.TaskStatusInProgress, nil
	case "done", "complete", "completed", "closed", "close", "3":
		return taskStatusName(protocol.TaskStatusDone), protocol.TaskStatusDone, nil
	case "note", "notes", "4":
		return taskStatusName(protocol.TaskStatusNote), protocol.TaskStatusNote, nil
	default:
		return "", 0, fmt.Errorf("unsupported task status %q", value)
	}
}

func validateActionEndpointReference(actions []ProposedAction, actionID, endpointType string) error {
	for _, action := range actions {
		if action.ID != actionID {
			continue
		}
		switch endpointType {
		case targetTypeName(protocol.TargetTypeTask):
			if action.Type == actionTypeCreateTask {
				return nil
			}
		case targetTypeName(protocol.TargetTypeAsset):
			if action.Type == actionTypeCreateNote || action.Type == actionTypeUpdateNote {
				return nil
			}
		}
		return fmt.Errorf("action %s does not produce %s", actionID, endpointType)
	}
	return fmt.Errorf("action %s not found", actionID)
}

func affectedActionEntity(action ProposedAction) *applyCreatedEntity {
	switch action.Type {
	case actionTypeCreateTask:
		if action.CreatedTaskID == 0 {
			return nil
		}
		return &applyCreatedEntity{Type: "task", ID: action.CreatedTaskID, Title: action.Title}
	case actionTypeUpdateTask:
		if action.TaskID == 0 {
			return nil
		}
		return &applyCreatedEntity{Type: "task", ID: action.TaskID, Title: action.Title}
	case actionTypeCreateNote:
		if action.CreatedAssetID == 0 {
			return nil
		}
		return &applyCreatedEntity{Type: "note", ID: action.CreatedAssetID, Title: action.Title}
	case actionTypeUpdateNote:
		if action.AssetID == 0 {
			return nil
		}
		return &applyCreatedEntity{Type: "note", ID: action.AssetID, Title: action.Title}
	case actionTypeDeleteNote:
		return deletedActionEntity(action)
	default:
		return nil
	}
}

func createdActionEntity(action ProposedAction) *applyCreatedEntity {
	switch action.Type {
	case actionTypeCreateTask, actionTypeCreateNote:
		return affectedActionEntity(action)
	default:
		return nil
	}
}

func createdActionEdge(action ProposedAction) *applyCreatedEdge {
	if action.Type != actionTypeCreateEdge || action.CreatedEdgeID == 0 {
		return nil
	}
	return &applyCreatedEdge{
		EdgeID:     action.CreatedEdgeID,
		SourceType: action.SourceType,
		SourceID:   action.SourceID,
		TargetType: action.TargetType,
		TargetID:   action.TargetID,
		Relation:   action.Relation,
	}
}

func deletedActionEntity(action ProposedAction) *applyCreatedEntity {
	if action.Type != actionTypeDeleteNote || action.AssetID == 0 {
		return nil
	}
	return &applyCreatedEntity{Type: "note", ID: action.AssetID, Title: action.Title}
}

func deletedActionEdge(action ProposedAction) *applyCreatedEdge {
	if action.Type != actionTypeDeleteEdge || action.EdgeID == 0 {
		return nil
	}
	return &applyCreatedEdge{
		EdgeID:     action.EdgeID,
		SourceType: action.SourceType,
		SourceID:   action.SourceID,
		TargetType: action.TargetType,
		TargetID:   action.TargetID,
		Relation:   action.Relation,
	}
}
