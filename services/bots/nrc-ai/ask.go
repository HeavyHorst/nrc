package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/heavyhorst/nrc/protocol-go"
)

type askRequest struct {
	Workspace     string `json:"workspace"`
	ConvID        uint64 `json:"conv_id"`
	DisplayConvID uint64 `json:"display_conv_id,omitempty"`
	Question      string `json:"question"`
	SessionID     string `json:"session_id,omitempty"`
	Mode          string `json:"mode,omitempty"`
	FollowUp      bool   `json:"follow_up,omitempty"`
}

func (r *askRequest) UnmarshalJSON(data []byte) error {
	type askRequestAlias struct {
		Workspace      string          `json:"workspace"`
		ConvID         json.RawMessage `json:"conv_id"`
		ContextConvID  json.RawMessage `json:"context_conv_id,omitempty"`
		DisplayConvID  json.RawMessage `json:"display_conv_id,omitempty"`
		Question       string          `json:"question"`
		Message        string          `json:"message"`
		SessionID      string          `json:"session_id,omitempty"`
		AgentSessionID string          `json:"agent_session_id,omitempty"`
		Mode           string          `json:"mode,omitempty"`
		FollowUp       bool            `json:"follow_up,omitempty"`
	}

	var raw askRequestAlias
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}

	convIDRaw := raw.ConvID
	if len(raw.ContextConvID) > 0 {
		convIDRaw = raw.ContextConvID
	}
	convID, err := parseConvIDRaw(convIDRaw)
	if err != nil {
		return fmt.Errorf("invalid context_conv_id: %w", err)
	}

	displayConvID, err := parseOptionalConvIDRaw(raw.DisplayConvID)
	if err != nil {
		return fmt.Errorf("invalid display_conv_id: %w", err)
	}

	r.Workspace = raw.Workspace
	r.ConvID = convID
	r.DisplayConvID = displayConvID
	r.Question = raw.Question
	if strings.TrimSpace(r.Question) == "" {
		r.Question = raw.Message
	}
	r.SessionID = raw.SessionID
	if strings.TrimSpace(r.SessionID) == "" {
		r.SessionID = raw.AgentSessionID
	}
	r.Mode = raw.Mode
	r.FollowUp = raw.FollowUp
	return nil
}

func parseOptionalConvIDRaw(raw json.RawMessage) (uint64, error) {
	if len(raw) == 0 {
		return 0, nil
	}

	var asString string
	if err := json.Unmarshal(raw, &asString); err == nil {
		asString = strings.TrimSpace(asString)
		if asString == "" {
			return 0, nil
		}
		return strconv.ParseUint(asString, 10, 64)
	}

	var asNumber json.Number
	if err := json.Unmarshal(raw, &asNumber); err == nil {
		return strconv.ParseUint(asNumber.String(), 10, 64)
	}

	return 0, fmt.Errorf("must be a string or integer")
}

func parseConvIDRaw(raw json.RawMessage) (uint64, error) {
	if len(raw) == 0 {
		return 0, nil
	}

	var asString string
	if err := json.Unmarshal(raw, &asString); err == nil {
		asString = strings.TrimSpace(asString)
		if asString == "" {
			return 0, fmt.Errorf("empty string")
		}
		return strconv.ParseUint(asString, 10, 64)
	}

	var asNumber json.Number
	if err := json.Unmarshal(raw, &asNumber); err == nil {
		return strconv.ParseUint(asNumber.String(), 10, 64)
	}

	return 0, fmt.Errorf("must be a string or integer")
}

type askResponse struct {
	Answer             string           `json:"answer"`
	Sources            []askSource      `json:"sources"`
	SessionID          string           `json:"session_id,omitempty"`
	AgentSessionID     string           `json:"agent_session_id,omitempty"`
	Mode               string           `json:"mode,omitempty"`
	PlanID             string           `json:"plan_id,omitempty"`
	ToolTrace          []ToolTraceEntry `json:"tool_trace,omitempty"`
	ProposedActions    []ProposedAction `json:"proposed_actions,omitempty"`
	PendingActionCount int              `json:"pending_action_count"`
	HistoryTurns       int              `json:"history_turns"`
	SessionTurns       int              `json:"session_turns"`
}

type askSource struct {
	Type  string `json:"type"`
	ID    uint64 `json:"id"`
	Title string `json:"title"`
}

const (
	entityTypeAsset uint16 = 1
	entityTypeTask  uint16 = 2
)

type askIntent uint8

const (
	askIntentGeneric askIntent = iota
	askIntentPlanning
	askIntentKnowledge
)

var taskRefPattern = regexp.MustCompile(`#(\d+)`)

type askTurnSource struct {
	Type string
	ID   uint64
}

type askTurn struct {
	Question string
	Answer   string
	Sources  []askTurnSource
	At       time.Time
}

type askSessionKey struct {
	Workspace string
	ConvID    uint64
	SessionID string
}

type askSession struct {
	Turns     []askTurn
	UpdatedAt time.Time
}

type askSessionStore struct {
	mu       sync.Mutex
	sessions map[askSessionKey]*askSession
	ttl      time.Duration
	maxTurns int
}

func newAskSessionStore(ttl time.Duration, maxTurns int) *askSessionStore {
	return &askSessionStore{
		sessions: make(map[askSessionKey]*askSession),
		ttl:      ttl,
		maxTurns: maxTurns,
	}
}

func (s *askSessionStore) getHistory(workspace string, convID uint64, sessionID string) []askTurn {
	if sessionID == "" {
		return nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	s.pruneExpiredLocked(now)

	key := askSessionKey{Workspace: workspace, ConvID: convID, SessionID: sessionID}
	session, ok := s.sessions[key]
	if !ok {
		return nil
	}

	history := make([]askTurn, len(session.Turns))
	copy(history, session.Turns)
	return history
}

func (s *askSessionStore) appendTurn(workspace string, convID uint64, sessionID string, turn askTurn) int {
	if sessionID == "" {
		return 0
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	s.pruneExpiredLocked(now)

	key := askSessionKey{Workspace: workspace, ConvID: convID, SessionID: sessionID}
	session, ok := s.sessions[key]
	if !ok {
		session = &askSession{}
		s.sessions[key] = session
	}

	turn.At = now
	session.Turns = append(session.Turns, turn)
	if len(session.Turns) > s.maxTurns {
		start := len(session.Turns) - s.maxTurns
		session.Turns = append([]askTurn(nil), session.Turns[start:]...)
	}
	session.UpdatedAt = now
	return len(session.Turns)
}

func (s *askSessionStore) pruneExpiredLocked(now time.Time) {
	for key, session := range s.sessions {
		if now.Sub(session.UpdatedAt) > s.ttl {
			delete(s.sessions, key)
		}
	}
}

func newAskSessionID() string {
	raw := make([]byte, 12)
	if _, err := rand.Read(raw); err != nil {
		return fmt.Sprintf("ask-%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(raw)
}

func compactTurnSources(sources []askSource) []askTurnSource {
	if len(sources) == 0 {
		return nil
	}

	compact := make([]askTurnSource, 0, len(sources))
	for _, src := range sources {
		compact = append(compact, askTurnSource{Type: strings.ToLower(src.Type), ID: src.ID})
	}
	return compact
}

func buildContext(ctx context.Context, client *NRCClient, search *SearchClient, req askRequest, maxTokens int) (string, map[uint64]string) {
	if req.ConvID != protocol.WorkspaceDataConvID {
		return errWorkspaceDataScope.Error(), nil
	}
	response, err := retrieveRoom(ctx, client, search, protocol.RetrieveRequest{
		Workspace: req.Workspace, ConvID: protocol.WorkspaceDataConvID, Query: req.Question,
		TopN: 12, Depth: 1, Direction: "both", PayloadMode: protocol.RetrievePayloadAll,
		MaxPayloadBytes: retrieveContextPayloadBudget(maxTokens), PathMode: protocol.RetrievePathsBest,
	})
	if err == nil {
		return formatRetrieveContext(response, maxTokens)
	}
	slog.Warn("fused retrieval failed; using legacy context fallback", "error", err)
	return buildLegacyContext(ctx, client, search, req, maxTokens)
}

func retrieveContextPayloadBudget(maxTokens int) int {
	return min(maxTokens, retrieveMaxPayloadBytes/4) * 4
}

func buildLegacyContext(ctx context.Context, client *NRCClient, search *SearchClient, req askRequest, maxTokens int) (string, map[uint64]string) {
	// Approximate 1 token ≈ 4 characters
	maxChars := maxTokens * 4

	// Tasks are from local cache (no I/O)
	tasks := client.GetTasks(req.ConvID)

	searchResults, searchErr := search.Search(ctx, req.Workspace, req.Question, req.ConvID, 5, true)
	if searchErr != nil {
		slog.Warn("search failed, continuing without search context", "error", searchErr)
	}

	assetSourceTitles := make(map[uint64]string, len(searchResults))
	for _, r := range searchResults {
		title := extractAssetSourceTitle(r.Preview)
		if title == "" {
			title = extractAssetSourceTitle(r.Payload)
		}
		if title != "" {
			assetSourceTitles[r.AssetID] = title
		}
	}

	intent := classifyAskIntent(req.Question)
	explicitTaskRefs := extractTaskRefs(req.Question)
	useGraphExpansion := shouldExpandGraphContext(intent, explicitTaskRefs)

	taskByID := make(map[uint64]protocol.Task, len(tasks))
	for _, t := range tasks {
		taskByID[t.ID] = t
	}

	rankedTasks := rankTasksForContext(tasks, intent, req.Question)
	includedTaskIDs := make(map[uint64]struct{})
	includedAssetIDs := make(map[uint64]struct{})

	for _, id := range explicitTaskRefs {
		if _, ok := taskByID[id]; ok {
			includedTaskIDs[id] = struct{}{}
		}
	}
	for _, r := range searchResults {
		includedAssetIDs[r.AssetID] = struct{}{}
	}

	var edges []protocol.Edge
	if useGraphExpansion {
		assetSeeds := make(map[uint64]struct{})
		for i, r := range searchResults {
			if i >= 3 {
				break
			}
			assetSeeds[r.AssetID] = struct{}{}
		}
		if len(includedTaskIDs) == 0 {
			for _, t := range rankedTasks {
				includedTaskIDs[t.ID] = struct{}{}
				if len(includedTaskIDs) >= 2 {
					break
				}
			}
		}

		graphTaskIDs, graphAssetIDs, graphEdges := collectGraphContext(ctx, client, req.ConvID, includedTaskIDs, assetSeeds, intent)
		edges = graphEdges
		for id := range graphTaskIDs {
			if _, ok := taskByID[id]; ok {
				includedTaskIDs[id] = struct{}{}
			}
		}
		for id := range graphAssetIDs {
			includedAssetIDs[id] = struct{}{}
		}
	}

	if len(includedTaskIDs) == 0 {
		for _, t := range rankedTasks {
			includedTaskIDs[t.ID] = struct{}{}
			if len(includedTaskIDs) >= 30 {
				break
			}
		}
	} else {
		for _, t := range rankedTasks {
			if len(includedTaskIDs) >= 40 {
				break
			}
			if _, exists := includedTaskIDs[t.ID]; exists {
				continue
			}
			if t.Status == 1 || t.Status == 2 {
				includedTaskIDs[t.ID] = struct{}{}
			}
		}
	}

	assetContentByID := make(map[uint64]string, len(searchResults))
	assetTypeByID := make(map[uint64]uint16, len(searchResults))
	for _, r := range searchResults {
		content := r.Preview
		if r.Payload != "" {
			content = r.Payload
		}
		assetContentByID[r.AssetID] = content
		assetTypeByID[r.AssetID] = r.AssetType
	}

	var parts []string
	totalChars := 0

	if len(tasks) > 0 {
		var sb strings.Builder
		sb.WriteString("== Workspace Tasks ==\n")
		taskLines := 0
		for _, t := range rankedTasks {
			if _, include := includedTaskIDs[t.ID]; !include {
				continue
			}
			status := taskStatusName(t.Status)
			priority := taskPriorityName(t.Priority)
			color := taskColorName(t.Color)
			line := fmt.Sprintf("#%d [%s", t.ID, status)
			if priority != "" {
				line += ", " + priority
			}
			if color != "none" {
				line += ", " + color
			}
			line += fmt.Sprintf("] %q", t.Title)
			if t.Assignee != "" {
				line += fmt.Sprintf(" (assignee: %s)", t.Assignee)
			}
			if t.BlockedBy != 0 {
				line += fmt.Sprintf(" (blocked_by: #%d)", t.BlockedBy)
			}
			line += "\n"
			if totalChars+sb.Len()+len(line) > maxChars {
				break
			}
			sb.WriteString(line)
			taskLines += 1
			if taskLines >= 80 {
				break
			}
		}
		if taskLines > 0 {
			section := sb.String()
			totalChars += len(section)
			parts = append(parts, section)
		}
	}

	if len(includedAssetIDs) > 0 && totalChars < maxChars {
		var sb strings.Builder
		sb.WriteString("== Relevant Assets (from search) ==\n")
		assetLines := 0
		for _, r := range searchResults {
			if _, include := includedAssetIDs[r.AssetID]; !include {
				continue
			}
			content := r.Preview
			if r.Payload != "" {
				content = r.Payload
			}
			line := fmt.Sprintf("[%s:%d] %s\n", assetTypeName(r.AssetType), r.AssetID, content)
			if totalChars+sb.Len()+len(line) > maxChars {
				break
			}
			sb.WriteString(line)
			assetLines += 1
		}
		if assetLines < 12 {
			var unknownAssetIDs []uint64
			for id := range includedAssetIDs {
				if _, hasContent := assetContentByID[id]; !hasContent {
					unknownAssetIDs = append(unknownAssetIDs, id)
				}
			}
			sort.Slice(unknownAssetIDs, func(i, j int) bool { return unknownAssetIDs[i] < unknownAssetIDs[j] })
			for _, id := range unknownAssetIDs {
				if assetLines >= 12 {
					break
				}
				assetType := assetTypeName(assetTypeByID[id])
				if assetTypeByID[id] == 0 {
					assetType = "Asset"
				}
				line := fmt.Sprintf("[%s:%d] linked via graph\n", assetType, id)
				if totalChars+sb.Len()+len(line) > maxChars {
					break
				}
				sb.WriteString(line)
				if _, known := assetSourceTitles[id]; !known {
					assetSourceTitles[id] = fmt.Sprintf("[%s:%d]", assetType, id)
				}
				assetLines += 1
			}
		}
		if assetLines > 0 {
			section := sb.String()
			totalChars += len(section)
			parts = append(parts, section)
		}
	}

	if len(edges) > 0 && totalChars < maxChars {
		var sb strings.Builder
		sb.WriteString("== Edges ==\n")
		edgeCount := 0
		for _, e := range edges {
			if !edgeEndpointIncluded(e.SourceType, e.SourceID, includedAssetIDs, includedTaskIDs) ||
				!edgeEndpointIncluded(e.TargetType, e.TargetID, includedAssetIDs, includedTaskIDs) {
				continue
			}
			sourceType := targetTypeName(e.SourceType)
			targetType := targetTypeName(e.TargetType)
			relation := relationName(e.Relation)
			line := fmt.Sprintf("%s:%d --%s--> %s:%d\n", sourceType, e.SourceID, relation, targetType, e.TargetID)
			if totalChars+sb.Len()+len(line) > maxChars {
				break
			}
			sb.WriteString(line)
			edgeCount += 1
		}
		if edgeCount > 0 {
			section := sb.String()
			totalChars += len(section)
			parts = append(parts, section)
		}
	}

	if len(parts) == 0 {
		return "No context available for this workspace.", assetSourceTitles
	}

	return strings.Join(parts, "\n"), assetSourceTitles
}

func formatRetrieveContext(response protocol.RetrieveResponse, maxTokens int) (string, map[uint64]string) {
	maxChars := maxTokens * 4
	assetSourceTitles := make(map[uint64]string)
	var sb strings.Builder
	sb.WriteString("== Fused Workspace Retrieval ==\n")
	for _, result := range response.Results {
		assetLabel := "Asset"
		if result.Metadata != nil && result.Metadata.AssetType != 0 {
			assetLabel = assetTypeName(result.Metadata.AssetType)
		}
		entityLabel := fmt.Sprintf("[%s:%d]", assetLabel, result.ID)
		if result.Type == protocol.SearchEntityTask {
			entityLabel = fmt.Sprintf("#%d", result.ID)
		} else {
			title := result.Title
			if title != "" {
				assetSourceTitles[result.ID] = title
			}
		}

		meta := fmt.Sprintf("rank=%d origins=%s payload=%s", result.Rank, strings.Join(result.Origins, ","), result.PayloadState)
		if len(result.Evidence) > 0 {
			meta += fmt.Sprintf(" graph_depth=%d", result.Evidence[0].Depth)
		}
		content := strings.TrimSpace(result.Payload)
		if content == "" {
			content = strings.TrimSpace(result.Teaser)
		}
		if content == "" {
			content = strings.TrimSpace(result.Title)
		}
		line := fmt.Sprintf("%s (%s) %s\n", entityLabel, meta, content)
		if sb.Len()+len(line) > maxChars {
			break
		}
		sb.WriteString(line)
	}

	hasEvidence := false
	for _, result := range response.Results {
		hasEvidence = hasEvidence || len(result.Evidence) > 0
	}
	if hasEvidence && sb.Len() < maxChars {
		sb.WriteString("\n== Traversed Paths ==\n")
		edgeByID := make(map[uint64]protocol.RetrieveEdge, len(response.Edges))
		for _, edge := range response.Edges {
			edgeByID[edge.ID] = edge
		}
		for _, result := range response.Results {
			for _, path := range result.Evidence {
				line, ok := formatRetrievePath(path, protocol.RetrieveEntityRef{Type: result.Type, ID: result.ID}, edgeByID)
				if !ok {
					continue
				}
				line += "\n"
				if sb.Len()+len(line) > maxChars {
					break
				}
				sb.WriteString(line)
			}
		}
	}

	if len(response.Warnings) > 0 && sb.Len() < maxChars {
		line := "\nRetrieval warnings: " + strings.Join(response.Warnings, "; ") + "\n"
		if sb.Len()+len(line) <= maxChars {
			sb.WriteString(line)
		}
	}
	if len(response.Results) == 0 {
		return "No context available for this workspace.", assetSourceTitles
	}
	return sb.String(), assetSourceTitles
}

func formatRetrievePath(path protocol.RetrievePath, target protocol.RetrieveEntityRef, edgeByID map[uint64]protocol.RetrieveEdge) (string, bool) {
	currentType := string(path.Anchor.Type)
	currentID := path.Anchor.ID
	parts := make([]string, 0, len(path.EdgeIDs))
	for _, edgeID := range path.EdgeIDs {
		edge, ok := edgeByID[edgeID]
		if !ok {
			return "", false
		}
		switch {
		case strings.EqualFold(string(edge.From.Type), currentType) && edge.From.ID == currentID:
			parts = append(parts, fmt.Sprintf("%s:%d --%s--> %s:%d", edge.From.Type, edge.From.ID, edge.Relation, edge.To.Type, edge.To.ID))
			currentType, currentID = string(edge.To.Type), edge.To.ID
		case strings.EqualFold(string(edge.To.Type), currentType) && edge.To.ID == currentID:
			parts = append(parts, fmt.Sprintf("%s:%d <--%s-- %s:%d", edge.To.Type, edge.To.ID, edge.Relation, edge.From.Type, edge.From.ID))
			currentType, currentID = string(edge.From.Type), edge.From.ID
		default:
			return "", false
		}
	}
	if !strings.EqualFold(currentType, string(target.Type)) || currentID != target.ID {
		return "", false
	}
	return strings.Join(parts, " | "), len(parts) > 0
}

func edgeEndpointIncluded(entityType uint16, id uint64, includedAssetIDs map[uint64]struct{}, includedTaskIDs map[uint64]struct{}) bool {
	switch entityType {
	case entityTypeAsset:
		_, ok := includedAssetIDs[id]
		return ok
	case entityTypeTask:
		_, ok := includedTaskIDs[id]
		return ok
	default:
		return false
	}
}

func classifyAskIntent(question string) askIntent {
	q := strings.ToLower(question)
	if containsAny(q,
		"what's next", "what should i work on", "what should we work on", "blocking",
		"blocked", "depends", "dependency", "priorit", "status update", "unblock") {
		return askIntentPlanning
	}

	if containsAny(q,
		"what did we decide", "decision", "plan for", "context", "summary", "why",
		"when did", "who said", "what happened") {
		return askIntentKnowledge
	}

	return askIntentGeneric
}

func shouldExpandGraphContext(intent askIntent, explicitTaskRefs []uint64) bool {
	return len(explicitTaskRefs) > 0 || intent != askIntentGeneric
}

func containsAny(s string, terms ...string) bool {
	for _, t := range terms {
		if strings.Contains(s, t) {
			return true
		}
	}
	return false
}

func extractTaskRefs(question string) []uint64 {
	matches := taskRefPattern.FindAllStringSubmatch(question, -1)
	if len(matches) == 0 {
		return nil
	}

	seen := make(map[uint64]struct{}, len(matches))
	ids := make([]uint64, 0, len(matches))
	for _, m := range matches {
		if len(m) < 2 {
			continue
		}
		id, err := strconv.ParseUint(m[1], 10, 64)
		if err != nil {
			continue
		}
		if _, exists := seen[id]; exists {
			continue
		}
		seen[id] = struct{}{}
		ids = append(ids, id)
	}
	return ids
}

func relationAllowedForIntent(relation uint16, intent askIntent) bool {
	switch intent {
	case askIntentPlanning:
		return relation == 3 || relation == 4 || relation == 6
	case askIntentKnowledge:
		return relation == 1 || relation == 2 || relation == 5 || relation == 6
	default:
		return true
	}
}

func relationMaskForIntent(intent askIntent) uint16 {
	var mask uint16
	for relation := uint16(1); relation <= 6; relation++ {
		if relationAllowedForIntent(relation, intent) {
			mask |= 1 << (relation - 1)
		}
	}
	return mask
}

func collectGraphContext(ctx context.Context, client *NRCClient, convID uint64, taskSeeds map[uint64]struct{}, assetSeeds map[uint64]struct{}, intent askIntent) (map[uint64]struct{}, map[uint64]struct{}, []protocol.Edge) {
	resultTaskIDs := make(map[uint64]struct{})
	resultAssetIDs := make(map[uint64]struct{})
	if len(taskSeeds) == 0 && len(assetSeeds) == 0 {
		return resultTaskIDs, resultAssetIDs, nil
	}

	type seed struct {
		entityType uint16
		id         uint64
	}
	seeds := make([]seed, 0, len(taskSeeds)+len(assetSeeds))
	for id := range taskSeeds {
		seeds = append(seeds, seed{entityType: entityTypeTask, id: id})
		resultTaskIDs[id] = struct{}{}
	}
	for id := range assetSeeds {
		seeds = append(seeds, seed{entityType: entityTypeAsset, id: id})
		resultAssetIDs[id] = struct{}{}
	}

	depth := uint8(2)
	if intent == askIntentGeneric {
		depth = 1
	}
	relationMask := relationMaskForIntent(intent)

	var mu sync.Mutex
	edgeByID := make(map[uint64]protocol.Edge)

	var wg sync.WaitGroup
	for _, s := range seeds {
		wg.Add(1)
		go func(s seed) {
			defer wg.Done()
			resp, err := client.GetGraphNeighborhood(ctx, convID, s.entityType, s.id, depth, relationMask, 0, 0)
			if err != nil {
				slog.Warn("graph query failed", "conv_id", convID, "start_type", s.entityType, "start_id", s.id, "error", err)
				return
			}

			mu.Lock()
			for _, node := range resp.Nodes {
				switch node.Type {
				case entityTypeTask:
					resultTaskIDs[node.ID] = struct{}{}
				case entityTypeAsset:
					resultAssetIDs[node.ID] = struct{}{}
				}
			}
			for _, edge := range resp.Edges {
				edgeByID[edge.EdgeID] = edge
			}
			mu.Unlock()
		}(s)
	}
	wg.Wait()

	edges := make([]protocol.Edge, 0, len(edgeByID))
	for _, edge := range edgeByID {
		edges = append(edges, edge)
	}

	return resultTaskIDs, resultAssetIDs, edges
}

func rankTasksForContext(tasks []protocol.Task, intent askIntent, question string) []protocol.Task {
	ranked := append([]protocol.Task(nil), tasks...)
	q := strings.ToLower(question)

	score := func(t protocol.Task) int {
		s := 0
		switch t.Status {
		case 2: // InProgress
			s += 50
		case 1: // Todo
			s += 40
		case 0: // Backlog
			s += 20
		case 4: // Note
			s += 10
		case 3: // Done
			s += 0
		}

		if intent == askIntentPlanning && t.Status == 3 {
			s -= 20
		}
		if t.Priority == 2 {
			s += 8
		} else if t.Priority == 1 {
			s += 4
		}
		if titleMatchesQuestion(strings.ToLower(t.Title), q) {
			s += 30
		}
		return s
	}

	sort.Slice(ranked, func(i, j int) bool {
		si := score(ranked[i])
		sj := score(ranked[j])
		if si == sj {
			return ranked[i].ID < ranked[j].ID
		}
		return si > sj
	})

	return ranked
}

func titleMatchesQuestion(title, question string) bool {
	for _, tok := range strings.Fields(question) {
		tok = strings.Trim(tok, "?!.,:;()[]{}\"'")
		if len(tok) < 4 {
			continue
		}
		if strings.Contains(title, tok) {
			return true
		}
	}
	return false
}

func taskStatusName(s uint8) string {
	switch s {
	case 0:
		return "Backlog"
	case 1:
		return "Todo"
	case 2:
		return "InProgress"
	case 3:
		return "Done"
	case 4:
		return "Note"
	default:
		return "Unknown"
	}
}

func taskPriorityName(p uint8) string {
	switch p {
	case 0:
		return ""
	case 1:
		return "P1"
	case 2:
		return "P2"
	default:
		return fmt.Sprintf("P%d", p)
	}
}

func taskColorName(c uint8) string {
	switch c {
	case 0:
		return "none"
	case 1:
		return "cyan"
	case 2:
		return "red"
	case 3:
		return "green"
	case 4:
		return "gray"
	case 5:
		return "gold"
	default:
		return "none"
	}
}

func assetTypeName(t uint16) string {
	switch t {
	case 1:
		return "Comment"
	case 2:
		return "Document"
	case 3:
		return "File"
	case 4:
		return "Agenda"
	case 5:
		return "Note"
	case 6:
		return "Reminder"
	case 7:
		return "RoomMapping"
	case 8:
		return "Company"
	case 9:
		return "Contact"
	case 10:
		return "Activity"
	case 11:
		return "Slice"
	case 12:
		return "Appointment"
	default:
		return fmt.Sprintf("Asset(%d)", t)
	}
}

func targetTypeName(t uint16) string {
	switch t {
	case 1:
		return "Asset"
	case 2:
		return "Task"
	default:
		return fmt.Sprintf("Type%d", t)
	}
}

func relationName(r uint16) string {
	switch r {
	case 1:
		return "references"
	case 2:
		return "related-to"
	case 3:
		return "depends-on"
	case 4:
		return "blocks"
	case 5:
		return "derived-from"
	case 6:
		return "supersedes"
	case 7:
		return "member-of"
	default:
		return fmt.Sprintf("rel%d", r)
	}
}
