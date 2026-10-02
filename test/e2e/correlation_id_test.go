package e2e

import (
	"errors"
	"fmt"
	"net"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestCorrelationIDEchoForRequestResponses(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-correlation-echo-%d", time.Now().UnixNano())
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "alice"))
	if err != nil {
		t.Fatalf("failed to connect websocket client: %v", err)
	}
	defer conn.Close()

	connDM, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "bob"))
	if err != nil {
		t.Fatalf("failed to connect dm partner websocket client: %v", err)
	}
	defer connDM.Close()

	mustSetReadDeadline(t, conn, 30*time.Second)
	mustExpectServerReady(t, conn)
	mustSetReadDeadline(t, connDM, 30*time.Second)
	mustExpectServerReady(t, connDM)

	const roomID int64 = protocol.WorkspaceDataConvID

	if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreateWithCorrelation(roomID, "corr-task", "corr task description", 1, 0xA1B2C3D4)); err != nil {
		t.Fatalf("failed to send correlated CreateTask: %v", err)
	}
	taskCreatedPayload := mustReadUntilOpcode(t, conn, protocol.S_TaskCreated, 12)
	taskCreated, err := protocol.DecodeTaskCreated(taskCreatedPayload)
	if err != nil {
		t.Fatalf("failed to decode S_TaskCreated payload: %v payload=%x", err, taskCreatedPayload)
	}
	if taskCreated.CorrelationID != 0xA1B2C3D4 {
		t.Fatalf("task create correlation_id mismatch: got 0x%08X want 0xA1B2C3D4", taskCreated.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_UpdateTask, protocol.EncodeTaskUpdateWithCorrelation(roomID, int64(taskCreated.Task.ID), "corr-task-upd", "desc-upd", int32(protocol.TaskStatusDone), 2, 0, 0xA1B2C3D5)); err != nil {
		t.Fatalf("failed to send correlated UpdateTask: %v", err)
	}
	taskUpdatedPayload := mustReadUntilOpcode(t, conn, protocol.S_TaskUpdated, 12)
	taskUpdated, err := protocol.DecodeTaskUpdated(taskUpdatedPayload)
	if err != nil {
		t.Fatalf("failed to decode S_TaskUpdated payload: %v payload=%x", err, taskUpdatedPayload)
	}
	if taskUpdated.CorrelationID != 0xA1B2C3D5 {
		t.Fatalf("task update correlation_id mismatch: got 0x%08X want 0xA1B2C3D5", taskUpdated.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_MoveTask, protocol.EncodeTaskMoveWithCorrelation(roomID, int64(taskCreated.Task.ID), protocol.TaskStatusInProgress, 1, 0xA1B2C3D6)); err != nil {
		t.Fatalf("failed to send correlated MoveTask: %v", err)
	}
	taskMovedPayload := mustReadUntilOpcode(t, conn, protocol.S_TaskMoved, 12)
	taskMoved, err := protocol.DecodeTaskMoved(taskMovedPayload)
	if err != nil {
		t.Fatalf("failed to decode S_TaskMoved payload: %v payload=%x", err, taskMovedPayload)
	}
	if taskMoved.CorrelationID != 0xA1B2C3D6 {
		t.Fatalf("task move correlation_id mismatch: got 0x%08X want 0xA1B2C3D6", taskMoved.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_GetTasks, protocol.EncodeGetTasksWithCorrelation(roomID, 0xA1B2C3D7)); err != nil {
		t.Fatalf("failed to send correlated GetTasks: %v", err)
	}
	taskListPayload := mustReadUntilOpcode(t, conn, protocol.S_TaskListResponse, 12)
	taskList, err := protocol.DecodeTaskListResponse(taskListPayload)
	if err != nil {
		t.Fatalf("failed to decode S_TaskListResponse payload: %v payload=%x", err, taskListPayload)
	}
	if taskList.CorrelationID != 0xA1B2C3D7 {
		t.Fatalf("task list correlation_id mismatch: got 0x%08X want 0xA1B2C3D7", taskList.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_CreateAsset, protocol.EncodeCreateAssetWithCorrelation(roomID, protocol.AssetTypeNote, protocol.ParentTypeNone, 0, mustNotePreviewJSON(t, "corr-asset", "corr", "corr-tag"), "corr asset payload", 0x01020304)); err != nil {
		t.Fatalf("failed to send correlated CreateAsset: %v", err)
	}
	assetCreatedPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetCreated, 12)
	assetCreated, err := protocol.DecodeAssetCreated(assetCreatedPayload)
	if err != nil {
		t.Fatalf("failed to decode S_AssetCreated payload: %v payload=%x", err, assetCreatedPayload)
	}
	if assetCreated.CorrelationID != 0x01020304 {
		t.Fatalf("asset create correlation_id mismatch: got 0x%08X want 0x01020304", assetCreated.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_UpdateAsset, protocol.EncodeUpdateAssetWithCorrelation(roomID, assetCreated.Asset.AssetID, mustNotePreviewJSON(t, "corr-asset-upd", "corr", "corr-tag"), "payload-upd", 0x01020305)); err != nil {
		t.Fatalf("failed to send correlated UpdateAsset: %v", err)
	}
	assetUpdatedPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetUpdated, 12)
	assetUpdated, err := protocol.DecodeAssetUpdated(assetUpdatedPayload)
	if err != nil {
		t.Fatalf("failed to decode S_AssetUpdated payload: %v payload=%x", err, assetUpdatedPayload)
	}
	if assetUpdated.CorrelationID != 0x01020305 {
		t.Fatalf("asset update correlation_id mismatch: got 0x%08X want 0x01020305", assetUpdated.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_GetAsset, protocol.EncodeGetAssetWithCorrelation(roomID, assetCreated.Asset.AssetID, 0x01020306)); err != nil {
		t.Fatalf("failed to send correlated GetAsset: %v", err)
	}
	assetFullPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetFull, 12)
	assetFull, err := protocol.DecodeAssetFullResponse(assetFullPayload)
	if err != nil {
		t.Fatalf("failed to decode S_AssetFull payload: %v payload=%x", err, assetFullPayload)
	}
	if assetFull.CorrelationID != 0x01020306 {
		t.Fatalf("asset full correlation_id mismatch: got 0x%08X want 0x01020306", assetFull.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_ListAssets, protocol.EncodeListAssetsWithCorrelation(roomID, false, 0, true, 0x01020307)); err != nil {
		t.Fatalf("failed to send correlated ListAssets: %v", err)
	}
	assetListPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetList, 12)
	assetList, err := protocol.DecodeAssetListResponse(assetListPayload)
	if err != nil {
		t.Fatalf("failed to decode S_AssetList payload: %v payload=%x", err, assetListPayload)
	}
	if assetList.CorrelationID != 0x01020307 {
		t.Fatalf("asset list correlation_id mismatch: got 0x%08X want 0x01020307", assetList.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_ListAssetsPaged, protocol.EncodeListAssetsPagedWithCorrelation(roomID, protocol.AssetTypeNote, false, 10, false, 0, 0, 0x01020308)); err != nil {
		t.Fatalf("failed to send correlated ListAssetsPaged: %v", err)
	}
	assetListPagePayload := mustReadUntilOpcode(t, conn, protocol.S_AssetListPage, 12)
	assetListPage, err := protocol.DecodeAssetListPage(assetListPagePayload)
	if err != nil {
		t.Fatalf("failed to decode S_AssetListPage payload: %v payload=%x", err, assetListPagePayload)
	}
	if assetListPage.CorrelationID != 0x01020308 {
		t.Fatalf("asset list page correlation_id mismatch: got 0x%08X want 0x01020308", assetListPage.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_ListAssetsPagedByProject, protocol.EncodeListAssetsPagedByProjectWithCorrelation(roomID, protocol.AssetTypeNote, false, 10, false, 0, 0, "corr", 0x0102030A)); err != nil {
		t.Fatalf("failed to send correlated ListAssetsPagedByProject: %v", err)
	}
	assetProjectPagePayload := mustReadUntilOpcode(t, conn, protocol.S_AssetListPage, 12)
	assetProjectPage, err := protocol.DecodeAssetListPage(assetProjectPagePayload)
	if err != nil {
		t.Fatalf("failed to decode project S_AssetListPage payload: %v payload=%x", err, assetProjectPagePayload)
	}
	if assetProjectPage.CorrelationID != 0x0102030A {
		t.Fatalf("asset project list page correlation_id mismatch: got 0x%08X want 0x0102030A", assetProjectPage.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_ListAssetsPagedByTag, protocol.EncodeListAssetsPagedByTagWithCorrelation(roomID, protocol.AssetTypeNote, false, 10, false, 0, 0, "corr-tag", 0x0102030B)); err != nil {
		t.Fatalf("failed to send correlated ListAssetsPagedByTag: %v", err)
	}
	assetTagPagePayload := mustReadUntilOpcode(t, conn, protocol.S_AssetListPage, 12)
	assetTagPage, err := protocol.DecodeAssetListPage(assetTagPagePayload)
	if err != nil {
		t.Fatalf("failed to decode tag S_AssetListPage payload: %v payload=%x", err, assetTagPagePayload)
	}
	if assetTagPage.CorrelationID != 0x0102030B {
		t.Fatalf("asset tag list page correlation_id mismatch: got 0x%08X want 0x0102030B", assetTagPage.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_ListNoteProjects, protocol.EncodeListNoteProjectsWithCorrelation(roomID, 0x0102030C)); err != nil {
		t.Fatalf("failed to send correlated ListNoteProjects: %v", err)
	}
	noteProjectListPayload := mustReadUntilOpcode(t, conn, protocol.S_NoteProjectList, 12)
	noteProjectList, err := protocol.DecodeNoteProjectList(noteProjectListPayload)
	if err != nil {
		t.Fatalf("failed to decode S_NoteProjectList payload: %v payload=%x", err, noteProjectListPayload)
	}
	if noteProjectList.CorrelationID != 0x0102030C {
		t.Fatalf("note project list correlation_id mismatch: got 0x%08X want 0x0102030C", noteProjectList.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_ListNoteTags, protocol.EncodeListNoteTagsWithCorrelation(roomID, 0x0102030D)); err != nil {
		t.Fatalf("failed to send correlated ListNoteTags: %v", err)
	}
	noteTagListPayload := mustReadUntilOpcode(t, conn, protocol.S_NoteTagList, 12)
	noteTagList, err := protocol.DecodeNoteTagList(noteTagListPayload)
	if err != nil {
		t.Fatalf("failed to decode S_NoteTagList payload: %v payload=%x", err, noteTagListPayload)
	}
	if noteTagList.CorrelationID != 0x0102030D {
		t.Fatalf("note tag list correlation_id mismatch: got 0x%08X want 0x0102030D", noteTagList.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_CreateEdge, protocol.EncodeCreateEdgeWithCorrelation(roomID, protocol.TargetTypeTask, taskCreated.Task.ID, protocol.TargetTypeAsset, assetCreated.Asset.AssetID, protocol.RelationRelatedTo, 0x0A0B0C01)); err != nil {
		t.Fatalf("failed to send correlated CreateEdge: %v", err)
	}
	edgeCreatedPayload := mustReadUntilOpcode(t, conn, protocol.S_EdgeCreated, 12)
	edgeCreated, err := protocol.DecodeEdgeCreated(edgeCreatedPayload)
	if err != nil {
		t.Fatalf("failed to decode S_EdgeCreated payload: %v payload=%x", err, edgeCreatedPayload)
	}
	if edgeCreated.CorrelationID != 0x0A0B0C01 {
		t.Fatalf("edge create correlation_id mismatch: got 0x%08X want 0x0A0B0C01", edgeCreated.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_ListEdges, protocol.EncodeListEdgesWithCorrelation(roomID, protocol.TargetTypeTask, taskCreated.Task.ID, 0x0A0B0C02)); err != nil {
		t.Fatalf("failed to send correlated ListEdges: %v", err)
	}
	edgeListPayload := mustReadUntilOpcode(t, conn, protocol.S_EdgeList, 12)
	edgeList, err := protocol.DecodeEdgeListResponse(edgeListPayload)
	if err != nil {
		t.Fatalf("failed to decode S_EdgeList payload: %v payload=%x", err, edgeListPayload)
	}
	if edgeList.CorrelationID != 0x0A0B0C02 {
		t.Fatalf("edge list correlation_id mismatch: got 0x%08X want 0x0A0B0C02", edgeList.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_ListAllEdges, protocol.EncodeListAllEdgesWithCorrelation(roomID, 0x0A0B0C03)); err != nil {
		t.Fatalf("failed to send correlated ListAllEdges: %v", err)
	}
	allEdgeListPayload := mustReadUntilOpcode(t, conn, protocol.S_AllEdgeList, 12)
	allEdgeList, err := protocol.DecodeAllEdgeListResponse(allEdgeListPayload)
	if err != nil {
		t.Fatalf("failed to decode S_AllEdgeList payload: %v payload=%x", err, allEdgeListPayload)
	}
	if allEdgeList.CorrelationID != 0x0A0B0C03 {
		t.Fatalf("all edge list correlation_id mismatch: got 0x%08X want 0x0A0B0C03", allEdgeList.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_GraphQuery, protocol.EncodeGraphQueryWithCorrelation(roomID, protocol.TargetTypeTask, taskCreated.Task.ID, 2, 0, 0, 0, 0x0D0E0F01)); err != nil {
		t.Fatalf("failed to send correlated GraphQuery: %v", err)
	}
	graphQueryPayload := mustReadUntilOpcode(t, conn, protocol.S_GraphQueryResult, 12)
	graphQuery, err := protocol.DecodeGraphQueryResult(graphQueryPayload)
	if err != nil {
		t.Fatalf("failed to decode S_GraphQueryResult payload: %v payload=%x", err, graphQueryPayload)
	}
	if graphQuery.CorrelationID != 0x0D0E0F01 {
		t.Fatalf("graph query correlation_id mismatch: got 0x%08X want 0x0D0E0F01", graphQuery.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_GraphShortestPath, protocol.EncodeGraphShortestPathWithCorrelation(roomID, protocol.TargetTypeTask, taskCreated.Task.ID, protocol.TargetTypeAsset, assetCreated.Asset.AssetID, 0, 0, 3, 0, 0x0D0E0F02)); err != nil {
		t.Fatalf("failed to send correlated GraphShortestPath: %v", err)
	}
	graphShortestPathPayload := mustReadUntilOpcode(t, conn, protocol.S_GraphShortestPathResult, 12)
	graphShortestPath, err := protocol.DecodeGraphShortestPathResult(graphShortestPathPayload)
	if err != nil {
		t.Fatalf("failed to decode S_GraphShortestPathResult payload: %v payload=%x", err, graphShortestPathPayload)
	}
	if graphShortestPath.CorrelationID != 0x0D0E0F02 {
		t.Fatalf("graph shortest path correlation_id mismatch: got 0x%08X want 0x0D0E0F02", graphShortestPath.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_GraphDegree, protocol.EncodeGraphDegreeWithCorrelation(roomID, 10, 0, 0, 0x0D0E0F03)); err != nil {
		t.Fatalf("failed to send correlated GraphDegree: %v", err)
	}
	graphDegreePayload := mustReadUntilOpcode(t, conn, protocol.S_GraphDegreeResult, 12)
	graphDegree, err := protocol.DecodeGraphDegreeResult(graphDegreePayload)
	if err != nil {
		t.Fatalf("failed to decode S_GraphDegreeResult payload: %v payload=%x", err, graphDegreePayload)
	}
	if graphDegree.CorrelationID != 0x0D0E0F03 {
		t.Fatalf("graph degree correlation_id mismatch: got 0x%08X want 0x0D0E0F03", graphDegree.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_GraphCommonNeighbors, protocol.EncodeGraphCommonNeighborsWithCorrelation(roomID, protocol.TargetTypeTask, taskCreated.Task.ID, protocol.TargetTypeAsset, assetCreated.Asset.AssetID, 0, 0, 0x0D0E0F04)); err != nil {
		t.Fatalf("failed to send correlated GraphCommonNeighbors: %v", err)
	}
	graphCommonNeighborsPayload := mustReadUntilOpcode(t, conn, protocol.S_GraphCommonNeighborsResult, 12)
	graphCommonNeighbors, err := protocol.DecodeGraphCommonNeighborsResult(graphCommonNeighborsPayload)
	if err != nil {
		t.Fatalf("failed to decode S_GraphCommonNeighborsResult payload: %v payload=%x", err, graphCommonNeighborsPayload)
	}
	if graphCommonNeighbors.CorrelationID != 0x0D0E0F04 {
		t.Fatalf("graph common neighbors correlation_id mismatch: got 0x%08X want 0x0D0E0F04", graphCommonNeighbors.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_StartDM, protocol.EncodeStartDMWithCorrelation("bob", 0x0F1E2D3C)); err != nil {
		t.Fatalf("failed to send correlated StartDM: %v", err)
	}
	dmStartedPayload := mustReadUntilOpcode(t, conn, protocol.S_DMStarted, 12)
	dmStarted, err := protocol.DecodeDMStarted(dmStartedPayload)
	if err != nil {
		t.Fatalf("failed to decode S_DMStarted payload: %v payload=%x", err, dmStartedPayload)
	}
	if dmStarted.CorrelationID != 0x0F1E2D3C {
		t.Fatalf("dm started correlation_id mismatch: got 0x%08X want 0x0F1E2D3C", dmStarted.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_ListDMs, protocol.EncodeListDMsWithCorrelation(0x0F1E2D3D)); err != nil {
		t.Fatalf("failed to send correlated ListDMs: %v", err)
	}
	dmListPayload := mustReadUntilOpcode(t, conn, protocol.S_DMList, 12)
	dmList, err := protocol.DecodeDMList(dmListPayload)
	if err != nil {
		t.Fatalf("failed to decode S_DMList payload: %v payload=%x", err, dmListPayload)
	}
	if dmList.CorrelationID != 0x0F1E2D3D {
		t.Fatalf("dm list correlation_id mismatch: got 0x%08X want 0x0F1E2D3D", dmList.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_LeaveDM, protocol.EncodeLeaveDMWithCorrelation(dmStarted.ConvID, 0x0F1E2D3E)); err != nil {
		t.Fatalf("failed to send correlated LeaveDM: %v", err)
	}
	dmLeftPayload := mustReadUntilOpcode(t, conn, protocol.S_DMLeft, 12)
	dmLeft, err := protocol.DecodeDMLeft(dmLeftPayload)
	if err != nil {
		t.Fatalf("failed to decode S_DMLeft payload: %v payload=%x", err, dmLeftPayload)
	}
	if dmLeft.CorrelationID != 0x0F1E2D3E {
		t.Fatalf("dm left correlation_id mismatch: got 0x%08X want 0x0F1E2D3E", dmLeft.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_DeleteEdge, protocol.EncodeDeleteEdgeWithCorrelation(roomID, edgeCreated.Edge.EdgeID, 0x0A0B0C04)); err != nil {
		t.Fatalf("failed to send correlated DeleteEdge: %v", err)
	}
	edgeDeletedPayload := mustReadUntilOpcode(t, conn, protocol.S_EdgeDeleted, 12)
	edgeDeleted, err := protocol.DecodeEdgeDeleted(edgeDeletedPayload)
	if err != nil {
		t.Fatalf("failed to decode S_EdgeDeleted payload: %v payload=%x", err, edgeDeletedPayload)
	}
	if edgeDeleted.CorrelationID != 0x0A0B0C04 {
		t.Fatalf("edge delete correlation_id mismatch: got 0x%08X want 0x0A0B0C04", edgeDeleted.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_DeleteAsset, protocol.EncodeDeleteAssetWithCorrelation(roomID, assetCreated.Asset.AssetID, 0x01020309)); err != nil {
		t.Fatalf("failed to send correlated DeleteAsset: %v", err)
	}
	assetDeletedPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetDeleted, 12)
	assetDeleted, err := protocol.DecodeAssetDeleted(assetDeletedPayload)
	if err != nil {
		t.Fatalf("failed to decode S_AssetDeleted payload: %v payload=%x", err, assetDeletedPayload)
	}
	if assetDeleted.CorrelationID != 0x01020309 {
		t.Fatalf("asset delete correlation_id mismatch: got 0x%08X want 0x01020309", assetDeleted.CorrelationID)
	}

	if err := sendProtocolMessage(conn, protocol.C_DeleteTask, protocol.EncodeTaskDeleteWithCorrelation(roomID, int64(taskCreated.Task.ID), 0xA1B2C3D8)); err != nil {
		t.Fatalf("failed to send correlated DeleteTask: %v", err)
	}
	taskDeletedPayload := mustReadUntilOpcode(t, conn, protocol.S_TaskDeleted, 12)
	taskDeleted, err := protocol.DecodeTaskDeleted(taskDeletedPayload)
	if err != nil {
		t.Fatalf("failed to decode S_TaskDeleted payload: %v payload=%x", err, taskDeletedPayload)
	}
	if taskDeleted.CorrelationID != 0xA1B2C3D8 {
		t.Fatalf("task delete correlation_id mismatch: got 0x%08X want 0xA1B2C3D8", taskDeleted.CorrelationID)
	}
}

func TestCorrelationIDErrorPathAndBroadcastZero(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-correlation-error-broadcast-%d", time.Now().UnixNano())
	connA, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "carol"))
	if err != nil {
		t.Fatalf("failed to connect websocket client A: %v", err)
	}
	defer connA.Close()

	connB, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "dave"))
	if err != nil {
		t.Fatalf("failed to connect websocket client B: %v", err)
	}
	defer connB.Close()

	mustSetReadDeadline(t, connA, 30*time.Second)
	mustExpectServerReady(t, connA)
	mustSetReadDeadline(t, connB, 30*time.Second)
	mustExpectServerReady(t, connB)

	const roomID int64 = protocol.WorkspaceDataConvID
	mustSubscribeWorkspaceData(t, connB)

	if err := sendProtocolMessage(connA, protocol.C_StartDM, protocol.EncodeStartDMWithCorrelation("nonexistent-user", 0xCAFEBABE)); err != nil {
		t.Fatalf("failed to send correlated StartDM error case: %v", err)
	}
	dmErrorPayload := mustReadUntilOpcode(t, connA, protocol.S_DMError, 12)
	dmError, err := protocol.DecodeDMError(dmErrorPayload)
	if err != nil {
		t.Fatalf("failed to decode S_DMError payload: %v payload=%x", err, dmErrorPayload)
	}
	if dmError.CorrelationID != 0xCAFEBABE {
		t.Fatalf("dm error correlation_id mismatch: got 0x%08X want 0xCAFEBABE", dmError.CorrelationID)
	}

	if err := sendProtocolMessage(connA, protocol.C_CreateTask, protocol.EncodeTaskCreateWithCorrelation(roomID, "broadcast-task", "broadcast description", 1, 0x55667788)); err != nil {
		t.Fatalf("failed to send correlated CreateTask: %v", err)
	}
	taskCreatedA := mustReadUntilOpcode(t, connA, protocol.S_TaskCreated, 12)
	taskCreatedRespA, err := protocol.DecodeTaskCreated(taskCreatedA)
	if err != nil {
		t.Fatalf("failed to decode sender S_TaskCreated payload: %v payload=%x", err, taskCreatedA)
	}
	if taskCreatedRespA.CorrelationID != 0x55667788 {
		t.Fatalf("sender task correlation_id mismatch: got 0x%08X want 0x55667788", taskCreatedRespA.CorrelationID)
	}

	taskCreatedB := mustReadUntilOpcode(t, connB, protocol.S_TaskCreated, 12)
	taskCreatedRespB, err := protocol.DecodeTaskCreated(taskCreatedB)
	if err != nil {
		t.Fatalf("failed to decode broadcast S_TaskCreated payload: %v payload=%x", err, taskCreatedB)
	}
	if taskCreatedRespB.CorrelationID != 0 {
		t.Fatalf("broadcast task correlation_id mismatch: got 0x%08X want 0x00000000", taskCreatedRespB.CorrelationID)
	}

	malformed := []byte{0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0xff, 0xff}
	if err := sendProtocolMessage(connA, protocol.C_SendMessage, malformed); err != nil {
		t.Fatalf("failed to send malformed C_SendMessage payload: %v", err)
	}

	if err := connA.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatalf("failed to set read deadline for malformed message check: %v", err)
	}
	frameType, wireData, err := connA.ReadMessage()
	if err != nil {
		if isCleanWebsocketClose(err) || isConnClosed(err) {
			return
		}
		var netErr net.Error
		if errors.As(err, &netErr) && netErr.Timeout() {
			t.Fatalf("timeout waiting for error response or close after malformed payload")
		}
		t.Fatalf("unexpected read error after malformed payload: %v", err)
	}
	if frameType != websocket.BinaryMessage {
		t.Fatalf("expected binary frame after malformed payload, got frame type %d", frameType)
	}
	msg, err := protocol.ReadMessage(wireData)
	if err != nil {
		t.Fatalf("failed to parse protocol message after malformed payload: %v", err)
	}
	if msg.Opcode != protocol.S_ErrorResponse {
		t.Fatalf("expected S_ErrorResponse (%d), got opcode %d payload=%x", protocol.S_ErrorResponse, msg.Opcode, msg.Data)
	}
	errResp, err := protocol.DecodeErrorResponse(msg.Data)
	if err != nil {
		t.Fatalf("failed to decode S_ErrorResponse payload: %v payload=%x", err, msg.Data)
	}
	if errResp.OriginOpcode != protocol.C_SendMessage {
		t.Fatalf("error response origin opcode mismatch: got %d want %d", errResp.OriginOpcode, protocol.C_SendMessage)
	}
	if errResp.CorrelationID != 0 {
		t.Fatalf("error response correlation_id mismatch: got 0x%08X want 0x00000000", errResp.CorrelationID)
	}
}
