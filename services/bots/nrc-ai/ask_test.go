package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/heavyhorst/nrc/protocol-go"
)

func TestExtractTaskRefs(t *testing.T) {
	ids := extractTaskRefs("Check #42 and #7, then #42 again")
	if len(ids) != 2 {
		t.Fatalf("expected 2 ids, got %d", len(ids))
	}
	if ids[0] != 42 || ids[1] != 7 {
		t.Fatalf("unexpected ids: %#v", ids)
	}
}

func TestClassifyAskIntent(t *testing.T) {
	if got := classifyAskIntent("What's blocking release?"); got != askIntentPlanning {
		t.Fatalf("expected planning intent, got %v", got)
	}
	if got := classifyAskIntent("What did we decide about search indexing?"); got != askIntentKnowledge {
		t.Fatalf("expected knowledge intent, got %v", got)
	}
	if got := classifyAskIntent("hello there"); got != askIntentGeneric {
		t.Fatalf("expected generic intent, got %v", got)
	}
}

func TestRelationMaskForIntent(t *testing.T) {
	if got := relationMaskForIntent(askIntentPlanning); got != 44 {
		t.Fatalf("planning mask mismatch: got %d want %d", got, 44)
	}
	if got := relationMaskForIntent(askIntentKnowledge); got != 51 {
		t.Fatalf("knowledge mask mismatch: got %d want %d", got, 51)
	}
	if got := relationMaskForIntent(askIntentGeneric); got != 63 {
		t.Fatalf("generic mask mismatch: got %d want %d", got, 63)
	}
}

func TestFormatRetrievePathOrientsMixedDirectionsFromAnchor(t *testing.T) {
	path := protocol.RetrievePath{
		Anchor:  protocol.RetrieveEntityRef{Type: protocol.SearchEntityAsset, ID: 1},
		Depth:   2,
		EdgeIDs: protocol.SearchIDs{10, 20},
	}
	edges := map[uint64]protocol.RetrieveEdge{
		10: {ID: 10, From: protocol.RetrieveEntityRef{Type: protocol.SearchEntityAsset, ID: 1}, To: protocol.RetrieveEntityRef{Type: protocol.SearchEntityTask, ID: 2}, Relation: "references"},
		20: {ID: 20, From: protocol.RetrieveEntityRef{Type: protocol.SearchEntityAsset, ID: 3}, To: protocol.RetrieveEntityRef{Type: protocol.SearchEntityTask, ID: 2}, Relation: "depends-on"},
	}
	got, ok := formatRetrievePath(path, protocol.RetrieveEntityRef{Type: protocol.SearchEntityAsset, ID: 3}, edges)
	if !ok {
		t.Fatal("expected continuous mixed-direction path")
	}
	want := "asset:1 --references--> task:2 | task:2 <--depends-on-- asset:3"
	if got != want {
		t.Fatalf("path = %q, want %q", got, want)
	}
}

func TestRetrieveContextPayloadBudgetCapsLargeContexts(t *testing.T) {
	if got := retrieveContextPayloadBudget(300_000); got != retrieveMaxPayloadBytes {
		t.Fatalf("large context payload budget = %d, want %d", got, retrieveMaxPayloadBytes)
	}
	if got := retrieveContextPayloadBudget(8_000); got != 32_000 {
		t.Fatalf("ordinary context payload budget = %d, want 32000", got)
	}
}

func TestFormatRetrieveContextExposesPerResultPayloadState(t *testing.T) {
	context, _ := formatRetrieveContext(protocol.RetrieveResponse{Results: []protocol.RetrieveResult{
		{Type: protocol.SearchEntityAsset, ID: 579, Rank: 1, Origins: []string{"search"}, Title: "Broad decision", Teaser: "Static preview", PayloadState: protocol.RetrievePayloadStateTruncated},
	}}, 1_000)
	if !strings.Contains(context, "[Asset:579] (rank=1 origins=search payload=truncated)") {
		t.Fatalf("context does not expose payload state: %q", context)
	}
}

func TestAskRequestNewAliases(t *testing.T) {
	var req askRequest
	err := json.Unmarshal([]byte(`{
		"workspace":"main",
		"context_conv_id":"123",
		"display_conv_id":"456",
		"message":"plan tasks",
		"agent_session_id":"ask_abc",
		"mode":"plan"
	}`), &req)
	if err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if req.Workspace != "main" || req.ConvID != 123 || req.DisplayConvID != 456 {
		t.Fatalf("unexpected scope: %+v", req)
	}
	if req.Question != "plan tasks" || req.SessionID != "ask_abc" || req.Mode != "plan" {
		t.Fatalf("unexpected request aliases: %+v", req)
	}
}

func TestAskRequestOldShapeStillWorks(t *testing.T) {
	var req askRequest
	err := json.Unmarshal([]byte(`{
		"workspace":"main",
		"conv_id":123,
		"question":"what is next",
		"session_id":"legacy"
	}`), &req)
	if err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if req.ConvID != 123 || req.Question != "what is next" || req.SessionID != "legacy" {
		t.Fatalf("unexpected legacy request: %+v", req)
	}
}

func TestNormalizeAgentModeReadOnlyAliases(t *testing.T) {
	for _, mode := range []string{"read-only", "readonly", "read_only"} {
		if got := normalizeAgentMode(mode); got != agentModeAsk {
			t.Fatalf("expected %q to normalize to ask, got %q", mode, got)
		}
	}
}

func TestAgentSessionPlanApplyIdempotencyState(t *testing.T) {
	store := newAgentSessionStore(time.Hour, 5)
	session, _ := store.getOrCreate("main", 10, 20, "", agentModePlan)
	plan, ok := store.startPlan(session.ID)
	if !ok {
		t.Fatal("expected plan")
	}

	_, action, err := store.addCreateTaskAction(session.ID, plan.ID, "Add confirmed mutation mode", "", 128)
	if err != nil {
		t.Fatalf("add action failed: %v", err)
	}
	duplicatePlan, duplicateAction, err := store.addCreateTaskAction(session.ID, plan.ID, "Add confirmed mutation mode", "", 128)
	if err != nil {
		t.Fatalf("add duplicate action failed: %v", err)
	}
	if duplicateAction.ID != action.ID || len(duplicatePlan.Actions) != 1 {
		t.Fatalf("expected duplicate proposal to reuse action, got action=%+v plan=%+v", duplicateAction, duplicatePlan)
	}

	_, _, toApply, already, failures, err := store.prepareApply(session.ID, plan.ID, []string{action.ID})
	if err != nil {
		t.Fatalf("prepare apply failed: %v", err)
	}
	if len(toApply) != 1 || len(already) != 0 || len(failures) != 0 {
		t.Fatalf("unexpected first prepare: toApply=%d already=%d failures=%d", len(toApply), len(already), len(failures))
	}

	completed, ok := store.completeCreateTaskAction(session.ID, plan.ID, action.ID, &protocol.Task{ID: 230, Title: action.Title}, nil)
	if !ok || completed.Status != actionStatusApplied {
		t.Fatalf("expected applied action, got %+v ok=%v", completed, ok)
	}

	_, _, toApply, already, failures, err = store.prepareApply(session.ID, plan.ID, []string{action.ID})
	if err != nil {
		t.Fatalf("second prepare failed: %v", err)
	}
	if len(toApply) != 0 || len(already) != 1 || len(failures) != 0 {
		t.Fatalf("unexpected second prepare: toApply=%d already=%d failures=%d", len(toApply), len(already), len(failures))
	}
	if already[0].CreatedEntity == nil || already[0].CreatedEntity.ID != 230 {
		t.Fatalf("expected idempotent created entity, got %+v", already[0])
	}
}

func TestAgentSessionUpdateTaskActions(t *testing.T) {
	store := newAgentSessionStore(time.Hour, 5)
	session, _ := store.getOrCreate("main", 10, 20, "", agentModePlan)
	plan, ok := store.startPlan(session.ID)
	if !ok {
		t.Fatal("expected plan")
	}

	if _, _, err := store.addUpdateTaskAction(session.ID, plan.ID, 42, 0, "Close stale item", "", "done", 128, 0); err == nil {
		t.Fatal("expected missing expected_updated_at to fail")
	}

	plan, action, err := store.addUpdateTaskAction(session.ID, plan.ID, 42, 12345, "Close stale item", "Resolved by #43", "done", 128, 0)
	if err != nil {
		t.Fatalf("add update task action failed: %v", err)
	}
	if action.TaskID != 42 || action.TaskStatus != "Done" || action.ExpectedUpdatedAt != 12345 {
		t.Fatalf("unexpected task update action: %+v", action)
	}

	duplicatePlan, duplicateAction, err := store.addUpdateTaskAction(session.ID, plan.ID, 42, 12345, "Close stale item", "Resolved by #43", "closed", 128, 0)
	if err != nil {
		t.Fatalf("add duplicate update task action failed: %v", err)
	}
	if duplicateAction.ID != action.ID || len(duplicatePlan.Actions) != 1 {
		t.Fatalf("expected duplicate update action to reuse action, got action=%+v plan=%+v", duplicateAction, duplicatePlan)
	}

	completed, ok := store.completeUpdateTaskAction(session.ID, plan.ID, action.ID, &protocol.Task{ID: 42, Title: action.Title, Description: action.Description, Status: protocol.TaskStatusDone, Priority: 128}, nil)
	if !ok || completed.Status != actionStatusApplied || completed.TaskID != 42 || completed.TaskStatus != "Done" {
		t.Fatalf("expected applied update task action, got %+v ok=%v", completed, ok)
	}

	_, _, toApply, already, failures, err := store.prepareApply(session.ID, plan.ID, []string{action.ID})
	if err != nil {
		t.Fatalf("prepare after update failed: %v", err)
	}
	if len(toApply) != 0 || len(already) != 1 || len(failures) != 0 {
		t.Fatalf("unexpected prepare after update: toApply=%d already=%d failures=%d", len(toApply), len(already), len(failures))
	}
	if already[0].Entity == nil || already[0].Entity.ID != 42 {
		t.Fatalf("expected updated task entity, got %+v", already[0])
	}
}

func TestAgentSessionNoteAndEdgeActions(t *testing.T) {
	store := newAgentSessionStore(time.Hour, 5)
	session, _ := store.getOrCreate("main", 10, 20, "", agentModePlan)
	plan, ok := store.startPlan(session.ID)
	if !ok {
		t.Fatal("expected plan")
	}

	plan, noteAction, err := store.addCreateNoteAction(session.ID, plan.ID, "Canonical direction", "## Direction\n\nUse explicit apply.", "heavyhorst/nrc", []string{"memory", "agent"})
	if err != nil {
		t.Fatalf("add note action failed: %v", err)
	}
	if noteAction.Project != "heavyhorst/nrc" || !sameStringSlice(noteAction.Tags, []string{"memory", "agent"}) {
		t.Fatalf("unexpected note metadata: %+v", noteAction)
	}
	duplicatePlan, duplicateNote, err := store.addCreateNoteAction(session.ID, plan.ID, "Canonical direction", "## Direction\n\nUse explicit apply.", "heavyhorst/nrc", []string{"memory", "agent"})
	if err != nil {
		t.Fatalf("add duplicate note action failed: %v", err)
	}
	if duplicateNote.ID != noteAction.ID || len(duplicatePlan.Actions) != 1 {
		t.Fatalf("expected duplicate note action to reuse action, got action=%+v plan=%+v", duplicateNote, duplicatePlan)
	}

	plan, edgeAction, err := store.addCreateEdgeAction(session.ID, plan.ID, "Note", 0, noteAction.ID, "Task", 42, "", "references")
	if err != nil {
		t.Fatalf("add edge action failed: %v", err)
	}
	if edgeAction.SourceActionID != noteAction.ID || edgeAction.SourceID != 0 || edgeAction.SourceType != "Asset" || edgeAction.Relation != "references" {
		t.Fatalf("unexpected edge action: %+v", edgeAction)
	}

	_, _, toApply, already, failures, err := store.prepareApply(session.ID, plan.ID, nil)
	if err != nil {
		t.Fatalf("prepare apply failed: %v", err)
	}
	if len(toApply) != 2 || len(already) != 0 || len(failures) != 0 {
		t.Fatalf("unexpected prepare: toApply=%d already=%d failures=%d", len(toApply), len(already), len(failures))
	}

	preview, err := buildNotePreviewWithMetadata("Canonical direction", "## Direction\n\nUse explicit apply.", "heavyhorst/nrc", []string{"memory", "agent"})
	if err != nil {
		t.Fatalf("build note preview failed: %v", err)
	}
	completedNote, ok := store.completeCreateNoteAction(session.ID, plan.ID, noteAction.ID, &protocol.Asset{AssetID: 200, AssetType: protocol.AssetTypeNote, Preview: preview}, nil)
	if !ok || completedNote.CreatedAssetID != 200 || completedNote.Status != actionStatusApplied {
		t.Fatalf("expected applied note action, got %+v ok=%v", completedNote, ok)
	}
	if completedNote.Project != "heavyhorst/nrc" || !sameStringSlice(completedNote.Tags, []string{"memory", "agent"}) {
		t.Fatalf("expected applied note metadata, got %+v", completedNote)
	}
	refreshedPlan, ok := store.getPlan(session.ID, plan.ID)
	if !ok {
		t.Fatal("expected refreshed plan")
	}
	sourceType, sourceID, err := resolveActionEndpoint(edgeAction.SourceType, edgeAction.SourceID, edgeAction.SourceActionID, refreshedPlan)
	if err != nil {
		t.Fatalf("resolve source endpoint failed: %v", err)
	}
	if sourceType != protocol.TargetTypeAsset || sourceID != 200 {
		t.Fatalf("unexpected resolved source: type=%d id=%d", sourceType, sourceID)
	}

	completedEdge, ok := store.completeCreateEdgeAction(session.ID, plan.ID, edgeAction.ID, &protocol.Edge{EdgeID: 99, SourceType: protocol.TargetTypeAsset, SourceID: 200, TargetType: protocol.TargetTypeTask, TargetID: 42, Relation: protocol.RelationReferences}, nil)
	if !ok || completedEdge.CreatedEdgeID != 99 || completedEdge.Status != actionStatusApplied {
		t.Fatalf("expected applied edge action, got %+v ok=%v", completedEdge, ok)
	}

	_, _, toApply, already, failures, err = store.prepareApply(session.ID, plan.ID, []string{noteAction.ID, edgeAction.ID})
	if err != nil {
		t.Fatalf("second prepare failed: %v", err)
	}
	if len(toApply) != 0 || len(already) != 2 || len(failures) != 0 {
		t.Fatalf("unexpected second prepare: toApply=%d already=%d failures=%d", len(toApply), len(already), len(failures))
	}
}

func TestCreateEdgeConcreteIDsOverrideActionIDs(t *testing.T) {
	store := newAgentSessionStore(time.Hour, 5)
	session, _ := store.getOrCreate("main", 10, 20, "", agentModePlan)
	plan, ok := store.startPlan(session.ID)
	if !ok {
		t.Fatal("expected plan")
	}

	_, edgeAction, err := store.addCreateEdgeAction(session.ID, plan.ID, "Asset", 203, "1", "Asset", 146, "2", "references")
	if err != nil {
		t.Fatalf("add edge action with concrete IDs failed: %v", err)
	}
	if edgeAction.SourceID != 203 || edgeAction.TargetID != 146 {
		t.Fatalf("expected concrete IDs to be preserved, got %+v", edgeAction)
	}
	if edgeAction.SourceActionID != "" || edgeAction.TargetActionID != "" {
		t.Fatalf("expected concrete IDs to override action IDs, got %+v", edgeAction)
	}
}

func TestUpdateNoteRequiresExpectedUpdatedAt(t *testing.T) {
	store := newAgentSessionStore(time.Hour, 5)
	session, _ := store.getOrCreate("main", 10, 20, "", agentModePlan)
	plan, ok := store.startPlan(session.ID)
	if !ok {
		t.Fatal("expected plan")
	}

	if _, _, err := store.addUpdateNoteAction(session.ID, plan.ID, 200, 0, "Title", "Content", "", nil, "markdown"); err == nil {
		t.Fatal("expected missing expected_updated_at to fail")
	}
	if _, action, err := store.addUpdateNoteAction(session.ID, plan.ID, 200, 12345, "Title", "Content", "heavyhorst/nrc", []string{"ops, memory", "ops"}, "html"); err != nil || action.AssetID != 200 || action.Project != "heavyhorst/nrc" || !sameStringSlice(action.Tags, []string{"ops", "memory"}) || action.Format != "html" {
		t.Fatalf("expected update note action, action=%+v err=%v", action, err)
	}
}

func TestNoteFormatDefaultAndHTMLTeaser(t *testing.T) {
	if got := parseNotePreviewJSON(`{"title":"legacy"}`).Format; got != "markdown" {
		t.Fatalf("legacy format = %q", got)
	}
	preview, err := buildNotePreviewWithFormat("HTML", `<p>Hello <b>world</b> &amp; friends</p>`, "", nil, "html")
	if err != nil {
		t.Fatal(err)
	}
	parsed := parseNotePreviewJSON(preview)
	if parsed.Format != "html" || parsed.Teaser != "Hello world & friends" {
		t.Fatalf("preview = %#v", parsed)
	}
}

func TestAgentSessionDeleteNoteAndEdgeActions(t *testing.T) {
	store := newAgentSessionStore(time.Hour, 5)
	session, _ := store.getOrCreate("main", 10, 20, "", agentModePlan)
	plan, ok := store.startPlan(session.ID)
	if !ok {
		t.Fatal("expected plan")
	}

	if _, _, err := store.addDeleteNoteAction(session.ID, plan.ID, 200, 0, "Obsolete direction"); err == nil {
		t.Fatal("expected missing expected_updated_at to fail")
	}

	plan, noteAction, err := store.addDeleteNoteAction(session.ID, plan.ID, 200, 12345, "Obsolete direction")
	if err != nil {
		t.Fatalf("add delete note action failed: %v", err)
	}
	duplicatePlan, duplicateNote, err := store.addDeleteNoteAction(session.ID, plan.ID, 200, 12345, "Obsolete direction")
	if err != nil {
		t.Fatalf("add duplicate delete note action failed: %v", err)
	}
	if duplicateNote.ID != noteAction.ID || len(duplicatePlan.Actions) != 1 {
		t.Fatalf("expected duplicate delete note action to reuse action, got action=%+v plan=%+v", duplicateNote, duplicatePlan)
	}

	edge := protocol.Edge{EdgeID: 99, SourceType: protocol.TargetTypeAsset, SourceID: 200, TargetType: protocol.TargetTypeTask, TargetID: 42, Relation: protocol.RelationReferences}
	plan, edgeAction, err := store.addDeleteEdgeAction(session.ID, plan.ID, edge)
	if err != nil {
		t.Fatalf("add delete edge action failed: %v", err)
	}
	if edgeAction.EdgeID != 99 || edgeAction.SourceType != "Asset" || edgeAction.TargetType != "Task" || edgeAction.Relation != "references" {
		t.Fatalf("unexpected delete edge action: %+v", edgeAction)
	}

	_, _, toApply, already, failures, err := store.prepareApply(session.ID, plan.ID, nil)
	if err != nil {
		t.Fatalf("prepare apply failed: %v", err)
	}
	if len(toApply) != 2 || len(already) != 0 || len(failures) != 0 {
		t.Fatalf("unexpected prepare: toApply=%d already=%d failures=%d", len(toApply), len(already), len(failures))
	}

	completedNote, ok := store.completeDeleteNoteAction(session.ID, plan.ID, noteAction.ID, &protocol.Asset{AssetID: 200, AssetType: protocol.AssetTypeNote}, nil)
	if !ok || completedNote.Status != actionStatusApplied || completedNote.AssetID != 200 {
		t.Fatalf("expected applied delete note action, got %+v ok=%v", completedNote, ok)
	}
	completedEdge, ok := store.completeDeleteEdgeAction(session.ID, plan.ID, edgeAction.ID, &edge, nil)
	if !ok || completedEdge.Status != actionStatusApplied || completedEdge.EdgeID != 99 {
		t.Fatalf("expected applied delete edge action, got %+v ok=%v", completedEdge, ok)
	}

	_, _, toApply, already, failures, err = store.prepareApply(session.ID, plan.ID, []string{noteAction.ID, edgeAction.ID})
	if err != nil {
		t.Fatalf("second prepare failed: %v", err)
	}
	if len(toApply) != 0 || len(already) != 2 || len(failures) != 0 {
		t.Fatalf("unexpected second prepare: toApply=%d already=%d failures=%d", len(toApply), len(already), len(failures))
	}
	if already[0].DeletedEntity == nil || already[0].DeletedEntity.ID != 200 {
		t.Fatalf("expected deleted note entity, got %+v", already[0])
	}
	if already[1].DeletedEdge == nil || already[1].DeletedEdge.EdgeID != 99 {
		t.Fatalf("expected deleted edge, got %+v", already[1])
	}
}

func TestFormatProposedActionsTextMixedActions(t *testing.T) {
	text := formatProposedActionsText([]ProposedAction{
		{ID: "1", Type: actionTypeCreateTask, Title: "Add server sessions", Priority: 128},
		{ID: "2", Type: actionTypeUpdateTask, TaskID: 42, Title: "Close stale item", TaskStatus: "Done", Priority: 128},
		{ID: "3", Type: actionTypeCreateNote, Title: "Agent direction", Project: "heavyhorst/nrc", Tags: []string{"agent"}},
		{ID: "4", Type: actionTypeUpdateNote, AssetID: 200, Title: "Agent direction"},
		{ID: "5", Type: actionTypeCreateEdge, SourceType: "Asset", SourceActionID: "3", TargetType: "Task", TargetID: 42, Relation: "references"},
		{ID: "6", Type: actionTypeDeleteNote, AssetID: 200, Title: "Agent direction"},
		{ID: "7", Type: actionTypeDeleteEdge, EdgeID: 99, SourceType: "Asset", SourceID: 200, TargetType: "Task", TargetID: 42, Relation: "references"},
	})

	for _, want := range []string{"Create task: Add server sessions", "Update task #42", "Create note: Agent direction (project heavyhorst/nrc; tags agent)", "Update [Note:200]", "Create edge: Asset:@3 --references--> Task:42", "Delete [Note:200]", "Delete edge #99: Asset:200 --references--> Task:42"} {
		if !strings.Contains(text, want) {
			t.Fatalf("expected %q in proposed action text:\n%s", want, text)
		}
	}
}

func TestAgentSessionDiscardEmptyPlan(t *testing.T) {
	store := newAgentSessionStore(time.Hour, 5)
	session, _ := store.getOrCreate("main", 10, 20, "", agentModePlan)
	plan, ok := store.startPlan(session.ID)
	if !ok {
		t.Fatal("expected plan")
	}

	if !store.discardPlan(session.ID, plan.ID) {
		t.Fatal("expected empty plan to be discarded")
	}
	if _, ok := store.getPlan(session.ID, plan.ID); ok {
		t.Fatal("discarded plan should not be retrievable")
	}
	if _, ok := store.latestPendingPlan(session.ID); ok {
		t.Fatal("discarded empty plan should not be pending")
	}
}

func TestExtractActionAssetRefs(t *testing.T) {
	action := ProposedAction{
		Title:       "Profile backend from [Note:175]",
		Description: "Use [Document:200], [note:175], [Task:45], and [Asset:0].",
	}

	ids := extractActionAssetRefs(action)
	if len(ids) != 2 || ids[0] != 175 || ids[1] != 200 {
		t.Fatalf("unexpected asset refs: %#v", ids)
	}
}

func TestHasTaskAssetReferenceEdge(t *testing.T) {
	edges := []protocol.Edge{
		{SourceType: protocol.TargetTypeAsset, SourceID: 175, TargetType: protocol.TargetTypeTask, TargetID: 45, Relation: protocol.RelationReferences},
		{SourceType: protocol.TargetTypeTask, SourceID: 45, TargetType: protocol.TargetTypeAsset, TargetID: 200, Relation: protocol.RelationRelatedTo},
	}

	if !hasTaskAssetReferenceEdge(edges, 45, 175) {
		t.Fatal("expected reverse reference edge to count as existing")
	}
	if hasTaskAssetReferenceEdge(edges, 45, 200) {
		t.Fatal("related-to edge should not count as an existing references edge")
	}
}

func TestADKRelatedNoteCandidatesFromEdges(t *testing.T) {
	edges := []protocol.Edge{
		{SourceType: protocol.TargetTypeAsset, SourceID: 10, TargetType: protocol.TargetTypeAsset, TargetID: 20, Relation: protocol.RelationReferences},
		{SourceType: protocol.TargetTypeAsset, SourceID: 30, TargetType: protocol.TargetTypeAsset, TargetID: 10, Relation: protocol.RelationRelatedTo},
		{SourceType: protocol.TargetTypeAsset, SourceID: 10, TargetType: protocol.TargetTypeAsset, TargetID: 20, Relation: protocol.RelationBlocks},
		{SourceType: protocol.TargetTypeAsset, SourceID: 10, TargetType: protocol.TargetTypeTask, TargetID: 40, Relation: protocol.RelationDependsOn},
		{SourceType: protocol.TargetTypeAsset, SourceID: 10, TargetType: protocol.TargetTypeAsset, TargetID: 50, Relation: protocol.RelationSupersedes},
	}

	got := adkRelatedNoteCandidatesFromEdges(edges, 10, 2)
	want := []adkRelatedNoteCandidate{
		{AssetID: 20, Relation: protocol.RelationReferences},
		{AssetID: 30, Relation: protocol.RelationRelatedTo},
	}
	if len(got) != len(want) {
		t.Fatalf("candidates = %#v, want %#v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("candidates = %#v, want %#v", got, want)
		}
	}
}

func TestADKRelatedNoteCandidatesFromEdgesRejectsNonPositiveLimit(t *testing.T) {
	edges := []protocol.Edge{{SourceType: protocol.TargetTypeAsset, SourceID: 10, TargetType: protocol.TargetTypeAsset, TargetID: 20}}
	if got := adkRelatedNoteCandidatesFromEdges(edges, 10, 0); got != nil {
		t.Fatalf("candidates = %#v, want nil", got)
	}
}
