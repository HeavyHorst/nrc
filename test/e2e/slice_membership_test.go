package e2e

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

const sliceRoomID int64 = protocol.WorkspaceDataConvID

func createSliceAsset(t *testing.T, conn *websocket.Conn, name, owner string, closed bool) protocol.Asset {
	t.Helper()
	preview := fmt.Sprintf(`{"version":1,"name":%q,"owner":%q,"outcome":"tested","closed":%t}`, name, owner, closed)
	return createAssetAndRead(t, conn, sliceRoomID, protocol.AssetTypeSlice, protocol.ParentTypeNone, 0, preview)
}

func createSliceMemberEdge(t *testing.T, conn *websocket.Conn, sourceType uint16, sourceID, sliceID uint64) protocol.Edge {
	t.Helper()
	if err := sendProtocolMessage(conn, protocol.C_CreateEdge, protocol.EncodeCreateEdge(sliceRoomID, sourceType, sourceID, protocol.TargetTypeAsset, sliceID, protocol.RelationMemberOf)); err != nil {
		t.Fatal(err)
	}
	payload := mustReadUntilOpcode(t, conn, protocol.S_EdgeCreated, 24)
	created, err := protocol.DecodeEdgeCreated(payload)
	if err != nil {
		t.Fatalf("decode membership edge: %v payload=%x", err, payload)
	}
	return created.Edge
}

func listSlices(t *testing.T, conn *websocket.Conn, query protocol.SliceQuery, correlation uint32) *protocol.TaskSliceList {
	t.Helper()
	if err := sendProtocolMessage(conn, protocol.C_ListTaskSlices, protocol.EncodeListTaskSlices(protocol.WorkspaceDataConvID, query, correlation)); err != nil {
		t.Fatal(err)
	}
	payload := mustReadUntilOpcode(t, conn, protocol.S_TaskSliceList, 24)
	result, err := protocol.DecodeTaskSliceList(payload)
	if err != nil {
		t.Fatalf("decode slice list: %v payload=%x", err, payload)
	}
	if !result.Success || result.CorrelationID != correlation {
		t.Fatalf("unsuccessful slice list: %+v", result)
	}
	return result
}

func sliceByID(t *testing.T, list *protocol.TaskSliceList, id uint64) protocol.TaskSlice {
	t.Helper()
	for _, item := range list.Slices {
		if item.SliceID == id {
			return item
		}
	}
	t.Fatalf("slice %d absent from %+v", id, list.Slices)
	return protocol.TaskSlice{}
}

func TestWorkspaceOverviewSnapshot(t *testing.T) {
	server := startServerInWorkDir(t, t.TempDir())
	defer server.stop(t)
	workspace := fmt.Sprintf("e2e-overview-%d", time.Now().UnixNano())
	conn := workspaceDataClient(t, workspace, "alice", 31)
	defer conn.Close()
	read := func(c *websocket.Conn, correlation uint32) *protocol.WorkspaceOverview {
		t.Helper()
		if err := sendProtocolMessage(c, protocol.C_GetWorkspaceOverview, protocol.EncodeListTaskProjects(protocol.WorkspaceDataConvID, correlation)); err != nil {
			t.Fatal(err)
		}
		payload := mustReadUntilOpcode(t, c, protocol.S_WorkspaceOverview, 24)
		if len(payload) != 103 {
			t.Fatalf("overview response grew beyond its fixed size: %d", len(payload))
		}
		result, err := protocol.DecodeWorkspaceOverview(payload)
		if err != nil || !result.Success || result.CorrelationID != correlation || result.ConvID != 0 || result.SampledAt <= 0 {
			t.Fatalf("overview response: %+v, err=%v", result, err)
		}
		return result
	}
	if got := read(conn, 100); got.OpenSlices != 0 || got.StatusCounts != [4]uint32{} {
		t.Fatalf("empty overview: %+v", got)
	}
	// Durable scope validation happens before collecting any workspace data.
	if err := sendProtocolMessage(conn, protocol.C_GetWorkspaceOverview, protocol.EncodeListTaskProjects(31, 101)); err != nil {
		t.Fatal(err)
	}
	mustReadErrorResponse(t, conn, protocol.C_GetWorkspaceOverview, 0)
	if err := sendProtocolMessage(conn, protocol.C_GetWorkspaceOverview, append(protocol.EncodeListTaskProjects(0, 102), 1)); err != nil {
		t.Fatal(err)
	}
	mustReadErrorResponse(t, conn, protocol.C_GetWorkspaceOverview, 0)
	empty := createSliceAsset(t, conn, "Empty", "", false)
	active := createSliceAsset(t, conn, "Active", "alice", false)
	closed := createSliceAsset(t, conn, "Closed", "", true)
	_ = empty
	backlog := createQueryTask(t, conn, sliceRoomID, "backlog")
	done := createQueryTask(t, conn, sliceRoomID, "done")
	moveQueryTask(t, conn, sliceRoomID, done, protocol.TaskStatusDone)
	closedOnly := createQueryTask(t, conn, sliceRoomID, "closed only")
	moveQueryTask(t, conn, sliceRoomID, closedOnly, protocol.TaskStatusTodo)
	createQueryTask(t, conn, sliceRoomID, "unassigned")
	createSliceMemberEdge(t, conn, protocol.TargetTypeTask, backlog.ID, active.AssetID)
	createSliceMemberEdge(t, conn, protocol.TargetTypeTask, done.ID, active.AssetID)
	createSliceMemberEdge(t, conn, protocol.TargetTypeTask, backlog.ID, closed.AssetID)
	createSliceMemberEdge(t, conn, protocol.TargetTypeTask, closedOnly.ID, closed.AssetID)
	got := read(conn, 103)
	if got.StatusCounts != [4]uint32{2, 1, 0, 1} || got.AssignedTasks != 3 || got.UnassignedTasks != 1 || got.OpenSlices != 2 ||
		got.SizeBuckets != [5]uint32{1, 1, 0, 0, 0} || got.BlockedBuckets != [3]uint32{2, 0, 0} || got.AgeBuckets != [5]uint32{1, 0, 0, 0, 1} {
		t.Fatalf("complete aggregate with shared and closed memberships: %+v", got)
	}
	isolated := workspaceDataClient(t, workspace+"-isolated", "alice", 32)
	defer isolated.Close()
	if got := read(isolated, 104); got.OpenSlices != 0 || got.StatusCounts != [4]uint32{} {
		t.Fatalf("overview leaked another workspace: %+v", got)
	}
}

func TestSliceMembershipRealServerLifecycleAndPersistence(t *testing.T) {
	workDir := t.TempDir()
	workspace := fmt.Sprintf("e2e-slices-%d", time.Now().UnixNano())
	server := startServerInWorkDir(t, workDir)
	defer func() { server.stop(t) }()
	conn := workspaceDataClient(t, workspace, "alice", 31)

	// Display records must decode; names may repeat and change without changing IDs.
	for i, preview := range []string{`not json`, `{"version":1,"name":""}`} {
		correlation := uint32(0x51000000 + i)
		if err := sendProtocolMessage(conn, protocol.C_CreateAsset, protocol.EncodeCreateAssetWithCorrelation(sliceRoomID, protocol.AssetTypeSlice, protocol.ParentTypeNone, 0, preview, "", correlation)); err != nil {
			t.Fatal(err)
		}
		mustReadErrorResponse(t, conn, protocol.C_CreateAsset, correlation)
	}
	alpha := createSliceAsset(t, conn, "Alpha", "alice", false)
	beta := createSliceAsset(t, conn, "Alpha", "", false)
	if err := sendProtocolMessage(conn, protocol.C_UpdateAsset, protocol.EncodeUpdateAssetWithCorrelation(sliceRoomID, alpha.AssetID, `{"version":1,"name":"Renamed","owner":"alice","closed":false}`, "", 0x51000003)); err != nil {
		t.Fatal(err)
	}
	mustReadUntilOpcode(t, conn, protocol.S_AssetUpdated, 16)

	tasks := make([]*protocol.Task, 5)
	for i := range tasks {
		tasks[i] = createQueryTask(t, conn, sliceRoomID, fmt.Sprintf("slice-task-%d", i))
	}
	moveQueryTask(t, conn, sliceRoomID, tasks[1], protocol.TaskStatusTodo)
	moveQueryTask(t, conn, sliceRoomID, tasks[2], protocol.TaskStatusInProgress)
	moveQueryTask(t, conn, sliceRoomID, tasks[3], protocol.TaskStatusDone)
	note := createAssetAndRead(t, conn, sliceRoomID, protocol.AssetTypeNote, protocol.ParentTypeNone, 0, `{"title":"slice-note","project":"NRC"}`)
	file := createAssetAndRead(t, conn, sliceRoomID, protocol.AssetTypeFile, protocol.ParentTypeNone, 0, "slice-file")
	edges := []protocol.Edge{
		createSliceMemberEdge(t, conn, protocol.TargetTypeTask, tasks[0].ID, alpha.AssetID),
		createSliceMemberEdge(t, conn, protocol.TargetTypeTask, tasks[1].ID, alpha.AssetID),
		createSliceMemberEdge(t, conn, protocol.TargetTypeTask, tasks[2].ID, alpha.AssetID),
		createSliceMemberEdge(t, conn, protocol.TargetTypeTask, tasks[3].ID, alpha.AssetID),
		createSliceMemberEdge(t, conn, protocol.TargetTypeAsset, note.AssetID, alpha.AssetID),
		createSliceMemberEdge(t, conn, protocol.TargetTypeAsset, file.AssetID, alpha.AssetID),
		createSliceMemberEdge(t, conn, protocol.TargetTypeTask, tasks[0].ID, beta.AssetID), // shared across slices
	}
	// Direction is presentation only: reverse membership is counted, while the
	// same unordered member/slice pair is rejected as a duplicate.
	if err := sendProtocolMessage(conn, protocol.C_CreateEdge, protocol.EncodeCreateEdge(sliceRoomID, protocol.TargetTypeAsset, beta.AssetID, protocol.TargetTypeTask, tasks[2].ID, protocol.RelationMemberOf)); err != nil {
		t.Fatal(err)
	}
	reversePayload := mustReadUntilOpcode(t, conn, protocol.S_EdgeCreated, 24)
	reverseCreated, err := protocol.DecodeEdgeCreated(reversePayload)
	if err != nil {
		t.Fatalf("decode reverse membership: %v payload=%x", err, reversePayload)
	}
	reverse := reverseCreated.Edge
	edges = append(edges, reverse)
	if err := sendProtocolMessage(conn, protocol.C_CreateEdge, protocol.EncodeCreateEdgeWithCorrelation(sliceRoomID, protocol.TargetTypeAsset, alpha.AssetID, protocol.TargetTypeTask, tasks[0].ID, protocol.RelationMemberOf, 0x51000004)); err != nil {
		t.Fatal(err)
	}
	mustReadErrorResponse(t, conn, protocol.C_CreateEdge, 0x51000004)

	all := listSlices(t, conn, protocol.SliceQuery{Limit: 20}, 101)
	if all.TotalCount != 2 || all.AssignedTasks != 4 || all.UnassignedTasks != 1 {
		t.Fatalf("workspace counters: got total=%d assigned=%d unassigned=%d", all.TotalCount, all.AssignedTasks, all.UnassignedTasks)
	}
	a := sliceByID(t, all, alpha.AssetID)
	if a.Backlog != 1 || a.Todo != 1 || a.InProgress != 1 || a.Done != 1 || a.Blocked != 0 || a.Notes != 1 || a.Files != 1 || a.TaskCount() != 4 || a.MemberCount() != 6 {
		t.Fatalf("Alpha independent counters: %+v", a)
	}
	b := sliceByID(t, all, beta.AssetID)
	if b.Backlog != 1 || b.Todo != 0 || b.InProgress != 1 || b.Done != 0 || b.Blocked != 0 || b.Notes != 0 || b.Files != 0 || b.TaskCount() != 2 || b.MemberCount() != 2 {
		t.Fatalf("Beta shared/reverse counters: %+v", b)
	}
	if got := listSlices(t, conn, protocol.SliceQuery{Project: "NRC", Limit: 1}, 111); got.TotalCount != 1 || got.HasMore || got.AssignedTasks != 0 || got.UnassignedTasks != 0 || len(got.Slices) != 1 || got.Slices[0] != a {
		t.Fatalf("note project filter must preserve the full Alpha slice: %+v", got)
	}
	if got := listSlices(t, conn, protocol.SliceQuery{Project: "nrc", Limit: 1}, 112); got.TotalCount != 0 || len(got.Slices) != 0 {
		t.Fatalf("project matching must be exact: %+v", got)
	}
	if got := listSlices(t, conn, protocol.SliceQuery{HasOwner: true, Owner: "alice", Limit: 10}, 102); got.TotalCount != 1 || got.Slices[0].SliceID != alpha.AssetID || got.AssignedTasks != 0 || got.UnassignedTasks != 0 {
		t.Fatalf("owner filter: %+v", got)
	}
	if got := listSlices(t, conn, protocol.SliceQuery{HasOwner: true, Owner: "", Limit: 10}, 103); got.TotalCount != 1 || got.Slices[0].SliceID != beta.AssetID {
		t.Fatalf("unowned filter: %+v", got)
	}
	if got := listSlices(t, conn, protocol.SliceQuery{HasName: true, Name: "lPh", Limit: 10}, 104); got.TotalCount != 1 || got.Slices[0].SliceID != beta.AssetID {
		t.Fatalf("name filter: %+v", got)
	}
	page1 := listSlices(t, conn, protocol.SliceQuery{Limit: 1}, 105)
	page2 := listSlices(t, conn, protocol.SliceQuery{Limit: 1, Cursor: &page1.NextCursor}, 106)
	if !page1.HasMore || page1.TotalCount != 2 || len(page1.Slices) != 1 || page2.HasMore || page2.TotalCount != 2 || len(page2.Slices) != 1 || page1.Slices[0].SliceID == page2.Slices[0].SliceID {
		t.Fatalf("small-limit pagination: first=%+v second=%+v", page1, page2)
	}

	// Movement and close/reopen are reflected immediately and persisted.
	moveQueryTask(t, conn, sliceRoomID, tasks[0], protocol.TaskStatusDone)
	closedPreview := `{"version":1,"name":"Alpha","owner":"alice","outcome":"tested","closed":true,"closed_at":1,"closed_by":"alice"}`
	if err := sendProtocolMessage(conn, protocol.C_UpdateAsset, protocol.EncodeUpdateAsset(sliceRoomID, alpha.AssetID, closedPreview, "")); err != nil {
		t.Fatal(err)
	}
	mustReadUntilOpcode(t, conn, protocol.S_AssetUpdated, 16)
	if got := listSlices(t, conn, protocol.SliceQuery{Limit: 10}, 107); got.TotalCount != 1 || got.Slices[0].SliceID != beta.AssetID {
		t.Fatalf("closed filter: %+v", got)
	}
	withClosed := listSlices(t, conn, protocol.SliceQuery{IncludeClosed: true, Limit: 10}, 108)
	closedAlpha := sliceByID(t, withClosed, alpha.AssetID)
	if !closedAlpha.IsClosed() || closedAlpha.Backlog != 0 || closedAlpha.Done != 2 {
		t.Fatalf("closed/status-updated Alpha: %+v", closedAlpha)
	}
	openPreview := `{"version":1,"name":"Alpha","owner":"alice","outcome":"tested","closed":false}`
	if err := sendProtocolMessage(conn, protocol.C_UpdateAsset, protocol.EncodeUpdateAsset(sliceRoomID, alpha.AssetID, openPreview, "")); err != nil {
		t.Fatal(err)
	}
	mustReadUntilOpcode(t, conn, protocol.S_AssetUpdated, 16)

	_ = conn.Close()
	server.stop(t)
	server = startServerInWorkDir(t, workDir)
	conn = workspaceDataClient(t, workspace, "alice", 31)
	restored := listSlices(t, conn, protocol.SliceQuery{IncludeClosed: true, Limit: 10}, 109)
	if restored.TotalCount != 2 || restored.AssignedTasks != 4 || restored.UnassignedTasks != 1 || sliceByID(t, restored, alpha.AssetID).Done != 2 || sliceByID(t, restored, alpha.AssetID).IsClosed() || sliceByID(t, restored, alpha.AssetID).Name != sliceByID(t, restored, beta.AssetID).Name {
		t.Fatalf("restored slice semantics: %+v", restored)
	}

	// Explicit unassignment and deleting the slice remove memberships, never members.
	if err := sendProtocolMessage(conn, protocol.C_DeleteEdge, protocol.EncodeDeleteEdge(sliceRoomID, edges[0].EdgeID)); err != nil {
		t.Fatal(err)
	}
	mustReadUntilOpcode(t, conn, protocol.S_EdgeDeleted, 16)
	unassigned := listSlices(t, conn, protocol.SliceQuery{Limit: 10}, 111)
	if sliceByID(t, unassigned, alpha.AssetID).Done != 1 || unassigned.AssignedTasks != 4 || unassigned.UnassignedTasks != 1 {
		t.Fatalf("unassign must update Alpha but preserve Beta's shared membership: %+v", unassigned)
	}
	if err := sendProtocolMessage(conn, protocol.C_DeleteAsset, protocol.EncodeDeleteAsset(sliceRoomID, alpha.AssetID)); err != nil {
		t.Fatal(err)
	}
	mustReadUntilOpcode(t, conn, protocol.S_AssetDeleted, 16)
	_ = conn.Close()
	server.stop(t)
	server = startServerInWorkDir(t, workDir)
	conn = workspaceDataClient(t, workspace, "alice", 31)
	final := listSlices(t, conn, protocol.SliceQuery{IncludeClosed: true, Limit: 10}, 110)
	if final.TotalCount != 1 || final.Slices[0].SliceID != beta.AssetID || final.AssignedTasks != 2 || final.UnassignedTasks != 3 || len(listTasks(t, conn, sliceRoomID).Tasks) != 5 {
		t.Fatalf("slice deletion removed members or register is wrong: slices=%+v tasks=%+v", final, listTasks(t, conn, sliceRoomID).Tasks)
	}
	assets := listAssetsFull(t, conn, sliceRoomID)
	seenNote, seenFile, seenAlpha := false, false, false
	for _, asset := range assets {
		seenNote = seenNote || asset.AssetID == note.AssetID
		seenFile = seenFile || asset.AssetID == file.AssetID
		seenAlpha = seenAlpha || asset.AssetID == alpha.AssetID
	}
	if !seenNote || !seenFile || seenAlpha {
		t.Fatalf("member/slice assets after delete: note=%t file=%t alpha=%t", seenNote, seenFile, seenAlpha)
	}
	remainingEdges := listAllEdges(t, conn, sliceRoomID)
	if len(remainingEdges) != 2 || sliceByID(t, final, beta.AssetID).Done != 1 || sliceByID(t, final, beta.AssetID).InProgress != 1 {
		t.Fatalf("deleting Alpha changed Beta's memberships: edges=%+v slices=%+v", remainingEdges, final)
	}
	for _, edge := range remainingEdges {
		touchesAlpha := (edge.SourceType == protocol.TargetTypeAsset && edge.SourceID == alpha.AssetID) ||
			(edge.TargetType == protocol.TargetTypeAsset && edge.TargetID == alpha.AssetID)
		if edge.EdgeID == edges[0].EdgeID || touchesAlpha {
			t.Fatalf("removed membership/slice edge survived restart: %+v", edge)
		}
	}
}

func TestSliceRegisterDiscriminatesCustomerMembership(t *testing.T) {
	workDir := t.TempDir()
	workspace := fmt.Sprintf("e2e-slice-customers-%d", time.Now().UnixNano())
	server := startServerInWorkDir(t, workDir)
	defer func() { server.stop(t) }()
	conn := workspaceDataClient(t, workspace, "owner", 41)
	company := createAssetAndRead(t, conn, sliceRoomID, protocol.AssetTypeCustomerCompany, protocol.ParentTypeNone, 0, `{"version":1,"title":"Acme"}`)
	unrelated := createAssetAndRead(t, conn, sliceRoomID, protocol.AssetTypeCustomerCompany, protocol.ParentTypeNone, 0, `{"version":1,"title":"Other"}`)
	contact := createAssetAndRead(t, conn, sliceRoomID, protocol.AssetTypeCustomerContact, protocol.ParentTypeNone, 0, `{"version":1,"title":"Ada"}`)
	createSliceMemberEdge(t, conn, protocol.TargetTypeAsset, contact.AssetID, company.AssetID)
	createEdgeAndRead(t, conn, sliceRoomID, unrelated.AssetID, contact.AssetID, protocol.RelationRelatedTo)
	checkSearch := func() {
		t.Helper()
		payload, err := protocol.EncodeSearchCustomers(sliceRoomID, 1, 0, false, "Ada", 203)
		if err != nil {
			t.Fatal(err)
		}
		if err := sendProtocolMessage(conn, protocol.C_SearchCustomers, payload); err != nil {
			t.Fatal(err)
		}
		page, err := protocol.DecodeCustomerSearchPage(mustReadUntilOpcode(t, conn, protocol.S_CustomerSearchPage, 16))
		if err != nil || len(page.Assets) != 1 || page.Assets[0].AssetID != company.AssetID || page.TotalCount != 1 || page.HasMore {
			t.Fatalf("contact search must follow MemberOf, never RelatedTo: page=%+v err=%v", page, err)
		}
	}
	checkSearch()
	if got := listSlices(t, conn, protocol.SliceQuery{IncludeClosed: true, Limit: 10}, 201); got.TotalCount != 0 || len(got.Slices) != 0 || got.AssignedTasks != 0 || got.UnassignedTasks != 0 {
		t.Fatalf("customer MemberOf/RelatedTo leaked into slice register: %+v", got)
	}
	_ = conn.Close()
	server.stop(t)
	server = startServerInWorkDir(t, workDir)
	conn = workspaceDataClient(t, workspace, "owner", 41)
	checkSearch()
	if got := listSlices(t, conn, protocol.SliceQuery{IncludeClosed: true, Limit: 10}, 202); got.TotalCount != 0 || len(got.Slices) != 0 {
		t.Fatalf("restored customer membership leaked into slice register: %+v", got)
	}
	edges := listAllEdges(t, conn, sliceRoomID)
	memberOf, related := false, false
	for _, edge := range edges {
		memberOf = memberOf || edge.Relation == protocol.RelationMemberOf
		related = related || edge.Relation == protocol.RelationRelatedTo
	}
	if !memberOf || !related {
		t.Fatalf("customer relations not preserved through restart: %+v", edges)
	}
}
