package e2e

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func createAssetAndRead(t *testing.T, conn *websocket.Conn, roomID int64, assetType, parentType uint16, parentID uint64, preview string) protocol.Asset {
	t.Helper()

	if err := sendProtocolMessage(conn, protocol.C_CreateAsset, protocol.EncodeCreateAsset(roomID, assetType, parentType, parentID, preview, preview+"-payload")); err != nil {
		t.Fatalf("failed to send CreateAsset %q: %v", preview, err)
	}
	payload := mustReadUntilOpcode(t, conn, protocol.S_AssetCreated, 24)
	created, err := protocol.DecodeAssetCreated(payload)
	if err != nil {
		t.Fatalf("failed to decode S_AssetCreated for %q: %v payload=%x", preview, err, payload)
	}

	return created.Asset
}

func createEdgeAndRead(t *testing.T, conn *websocket.Conn, roomID int64, sourceID, targetID uint64, relation uint16) protocol.Edge {
	t.Helper()

	if err := sendProtocolMessage(conn, protocol.C_CreateEdge, protocol.EncodeCreateEdge(roomID, protocol.TargetTypeAsset, sourceID, protocol.TargetTypeAsset, targetID, relation)); err != nil {
		t.Fatalf("failed to send CreateEdge (%d -> %d): %v", sourceID, targetID, err)
	}
	payload := mustReadUntilOpcode(t, conn, protocol.S_EdgeCreated, 24)
	created, err := protocol.DecodeEdgeCreated(payload)
	if err != nil {
		t.Fatalf("failed to decode S_EdgeCreated: %v payload=%x", err, payload)
	}

	return created.Edge
}

func listAssetsFull(t *testing.T, conn *websocket.Conn, roomID int64) []protocol.Asset {
	t.Helper()

	if err := sendProtocolMessage(conn, protocol.C_ListAssets, protocol.EncodeListAssets(roomID, false, 0, true)); err != nil {
		t.Fatalf("failed to send ListAssets: %v", err)
	}
	payload := mustReadUntilOpcode(t, conn, protocol.S_AssetList, 24)
	assets, err := protocol.DecodeAssetList(payload, true)
	if err != nil {
		t.Fatalf("failed to decode S_AssetList: %v payload=%x", err, payload)
	}

	return assets
}

func listAllEdges(t *testing.T, conn *websocket.Conn, roomID int64) []protocol.Edge {
	t.Helper()

	if err := sendProtocolMessage(conn, protocol.C_ListAllEdges, protocol.EncodeListAllEdges(roomID)); err != nil {
		t.Fatalf("failed to send ListAllEdges: %v", err)
	}
	payload := mustReadUntilOpcode(t, conn, protocol.S_AllEdgeList, 24)
	_, edges, err := protocol.DecodeAllEdgeList(payload)
	if err != nil {
		t.Fatalf("failed to decode S_AllEdgeList: %v payload=%x", err, payload)
	}

	return edges
}

func listTasks(t *testing.T, conn *websocket.Conn, roomID int64) *protocol.TaskListResponse {
	t.Helper()

	if err := sendProtocolMessage(conn, protocol.C_GetTasks, protocol.EncodeGetTasks(roomID)); err != nil {
		t.Fatalf("failed to send GetTasks: %v", err)
	}
	payload := mustReadUntilOpcode(t, conn, protocol.S_TaskListResponse, 24)
	resp, err := protocol.DecodeTaskListResponse(payload)
	if err != nil {
		t.Fatalf("failed to decode S_TaskListResponse: %v payload=%x", err, payload)
	}

	return resp
}

func assertAssetMissing(t *testing.T, assets []protocol.Asset, assetID uint64) {
	t.Helper()

	for _, asset := range assets {
		if asset.AssetID == assetID {
			t.Fatalf("asset id %d should be deleted, but is still present", assetID)
		}
	}
}

func assertAssetPresent(t *testing.T, assets []protocol.Asset, assetID uint64) {
	t.Helper()

	for _, asset := range assets {
		if asset.AssetID == assetID {
			return
		}
	}

	t.Fatalf("asset id %d should still exist, but is missing", assetID)
}

func assertNoIncidentEdges(t *testing.T, edges []protocol.Edge, deletedEntityIDs map[uint64]struct{}, deletedEdgeIDs map[uint64]struct{}) {
	t.Helper()

	for _, edge := range edges {
		if _, ok := deletedEdgeIDs[edge.EdgeID]; ok {
			t.Fatalf("edge id %d should be deleted, but is still present", edge.EdgeID)
		}
		if _, ok := deletedEntityIDs[edge.SourceID]; ok {
			t.Fatalf("edge id %d still references deleted source entity %d", edge.EdgeID, edge.SourceID)
		}
		if _, ok := deletedEntityIDs[edge.TargetID]; ok {
			t.Fatalf("edge id %d still references deleted target entity %d", edge.EdgeID, edge.TargetID)
		}
	}
}

func seedTaskSubtreeWithPeerAndEdges(t *testing.T, conn *websocket.Conn, roomID int64) (uint64, protocol.Asset, protocol.Asset, protocol.Asset, protocol.Asset, []protocol.Edge) {
	t.Helper()

	if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreate(roomID, "recursive-delete-task", "task-root", 1)); err != nil {
		t.Fatalf("failed to send CreateTask: %v", err)
	}
	taskPayload := mustReadUntilOpcode(t, conn, protocol.S_TaskCreated, 24)
	taskCreated, err := protocol.DecodeTaskCreated(taskPayload)
	if err != nil {
		t.Fatalf("failed to decode S_TaskCreated: %v payload=%x", err, taskPayload)
	}

	taskRoot := createAssetAndRead(t, conn, roomID, protocol.AssetTypeNote, protocol.ParentTypeTask, taskCreated.Task.ID, "task-root-asset")
	child := createAssetAndRead(t, conn, roomID, protocol.AssetTypeDocument, protocol.ParentTypeAsset, taskRoot.AssetID, "task-child-asset")
	grandChild := createAssetAndRead(t, conn, roomID, protocol.AssetTypeComment, protocol.ParentTypeAsset, child.AssetID, "task-grandchild-asset")
	peer := createAssetAndRead(t, conn, roomID, protocol.AssetTypeNote, protocol.ParentTypeNone, 0, "task-peer-asset")

	edges := []protocol.Edge{
		createEdgeAndRead(t, conn, roomID, taskRoot.AssetID, peer.AssetID, protocol.RelationReferences),
		createEdgeAndRead(t, conn, roomID, child.AssetID, peer.AssetID, protocol.RelationRelatedTo),
		createEdgeAndRead(t, conn, roomID, grandChild.AssetID, peer.AssetID, protocol.RelationDependsOn),
	}

	return taskCreated.Task.ID, taskRoot, child, grandChild, peer, edges
}

func seedAssetSubtreeWithPeerAndEdges(t *testing.T, conn *websocket.Conn, roomID int64) (protocol.Asset, protocol.Asset, protocol.Asset, protocol.Asset, []protocol.Edge) {
	t.Helper()

	root := createAssetAndRead(t, conn, roomID, protocol.AssetTypeNote, protocol.ParentTypeNone, 0, "asset-root")
	child := createAssetAndRead(t, conn, roomID, protocol.AssetTypeDocument, protocol.ParentTypeAsset, root.AssetID, "asset-child")
	grandChild := createAssetAndRead(t, conn, roomID, protocol.AssetTypeComment, protocol.ParentTypeAsset, child.AssetID, "asset-grandchild")
	peer := createAssetAndRead(t, conn, roomID, protocol.AssetTypeNote, protocol.ParentTypeNone, 0, "asset-peer")

	edges := []protocol.Edge{
		createEdgeAndRead(t, conn, roomID, root.AssetID, peer.AssetID, protocol.RelationReferences),
		createEdgeAndRead(t, conn, roomID, child.AssetID, peer.AssetID, protocol.RelationRelatedTo),
		createEdgeAndRead(t, conn, roomID, grandChild.AssetID, peer.AssetID, protocol.RelationDependsOn),
	}

	return root, child, grandChild, peer, edges
}

func assertTaskSubtreeDeletedAndPeerIntact(t *testing.T, conn *websocket.Conn, roomID int64, taskID uint64, taskRoot, child, grandChild, peer protocol.Asset, seededEdges []protocol.Edge) {
	t.Helper()

	tasks := listTasks(t, conn, roomID)
	for _, task := range tasks.Tasks {
		if task.ID == taskID {
			t.Fatalf("task id %d should be deleted, but is still present", taskID)
		}
	}

	assets := listAssetsFull(t, conn, roomID)
	assertAssetMissing(t, assets, taskRoot.AssetID)
	assertAssetMissing(t, assets, child.AssetID)
	assertAssetMissing(t, assets, grandChild.AssetID)
	assertAssetPresent(t, assets, peer.AssetID)

	edges := listAllEdges(t, conn, roomID)
	deletedEntityIDs := map[uint64]struct{}{
		taskRoot.AssetID:   {},
		child.AssetID:      {},
		grandChild.AssetID: {},
	}
	deletedEdgeIDs := map[uint64]struct{}{}
	for _, edge := range seededEdges {
		deletedEdgeIDs[edge.EdgeID] = struct{}{}
	}
	assertNoIncidentEdges(t, edges, deletedEntityIDs, deletedEdgeIDs)
}

func TestTaskDeleteRecursiveSubtreeInMemory(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-task-recursive-delete-memory-%d", time.Now().UnixNano())
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("failed to connect websocket client: %v", err)
	}
	defer conn.Close()

	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID
	taskID, taskRoot, child, grandChild, peer, edges := seedTaskSubtreeWithPeerAndEdges(t, conn, roomID)

	if err := sendProtocolMessage(conn, protocol.C_DeleteTask, protocol.EncodeTaskDelete(roomID, int64(taskID))); err != nil {
		t.Fatalf("failed to send DeleteTask: %v", err)
	}
	_ = mustReadUntilOpcode(t, conn, protocol.S_TaskDeleted, 32)

	assertTaskSubtreeDeletedAndPeerIntact(t, conn, roomID, taskID, taskRoot, child, grandChild, peer, edges)
}

func TestTaskDeleteRecursiveSubtreePersistenceAcrossRestart(t *testing.T) {
	serverWorkDir := t.TempDir()
	workspace := fmt.Sprintf("e2e-task-recursive-delete-persist-%d", time.Now().UnixNano())

	server := startServerInWorkDir(t, serverWorkDir)
	defer func() {
		if server != nil {
			server.stop(t)
		}
	}()

	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		server.stop(t)
		t.Fatalf("failed to connect websocket client before restart: %v", err)
	}

	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID
	taskID, taskRoot, child, grandChild, peer, edges := seedTaskSubtreeWithPeerAndEdges(t, conn, roomID)

	if err := sendProtocolMessage(conn, protocol.C_DeleteTask, protocol.EncodeTaskDelete(roomID, int64(taskID))); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send DeleteTask before restart: %v", err)
	}
	_ = mustReadUntilOpcode(t, conn, protocol.S_TaskDeleted, 32)

	_ = conn.Close()
	server.stop(t)
	server = nil

	server = startServerInWorkDir(t, serverWorkDir)

	connAfterRestart, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("failed to connect websocket client after restart: %v", err)
	}
	defer connAfterRestart.Close()

	mustSetReadDeadline(t, connAfterRestart, 5*time.Second)
	mustExpectServerReady(t, connAfterRestart)

	assertTaskSubtreeDeletedAndPeerIntact(t, connAfterRestart, roomID, taskID, taskRoot, child, grandChild, peer, edges)
}

func TestAssetDeleteRecursiveSubtreeInMemory(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-asset-recursive-delete-memory-%d", time.Now().UnixNano())
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("failed to connect websocket client: %v", err)
	}
	defer conn.Close()

	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID
	root, child, grandChild, peer, seededEdges := seedAssetSubtreeWithPeerAndEdges(t, conn, roomID)

	if err := sendProtocolMessage(conn, protocol.C_DeleteAsset, protocol.EncodeDeleteAsset(roomID, root.AssetID)); err != nil {
		t.Fatalf("failed to send DeleteAsset: %v", err)
	}
	_ = mustReadUntilOpcode(t, conn, protocol.S_AssetDeleted, 32)

	assets := listAssetsFull(t, conn, roomID)
	assertAssetMissing(t, assets, root.AssetID)
	assertAssetMissing(t, assets, child.AssetID)
	assertAssetMissing(t, assets, grandChild.AssetID)
	assertAssetPresent(t, assets, peer.AssetID)

	edges := listAllEdges(t, conn, roomID)
	deletedEntityIDs := map[uint64]struct{}{
		root.AssetID:       {},
		child.AssetID:      {},
		grandChild.AssetID: {},
	}
	deletedEdgeIDs := map[uint64]struct{}{}
	for _, edge := range seededEdges {
		deletedEdgeIDs[edge.EdgeID] = struct{}{}
	}
	assertNoIncidentEdges(t, edges, deletedEntityIDs, deletedEdgeIDs)
}

func TestAssetDeleteRecursiveSubtreePersistenceAcrossRestart(t *testing.T) {
	serverWorkDir := t.TempDir()
	workspace := fmt.Sprintf("e2e-asset-recursive-delete-persist-%d", time.Now().UnixNano())

	server := startServerInWorkDir(t, serverWorkDir)
	defer func() {
		if server != nil {
			server.stop(t)
		}
	}()

	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		server.stop(t)
		t.Fatalf("failed to connect websocket client before restart: %v", err)
	}

	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID
	root, child, grandChild, peer, seededEdges := seedAssetSubtreeWithPeerAndEdges(t, conn, roomID)

	if err := sendProtocolMessage(conn, protocol.C_DeleteAsset, protocol.EncodeDeleteAsset(roomID, root.AssetID)); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send DeleteAsset before restart: %v", err)
	}
	_ = mustReadUntilOpcode(t, conn, protocol.S_AssetDeleted, 32)

	_ = conn.Close()
	server.stop(t)
	server = nil

	server = startServerInWorkDir(t, serverWorkDir)

	connAfterRestart, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("failed to connect websocket client after restart: %v", err)
	}
	defer connAfterRestart.Close()

	mustSetReadDeadline(t, connAfterRestart, 5*time.Second)
	mustExpectServerReady(t, connAfterRestart)

	assets := listAssetsFull(t, connAfterRestart, roomID)
	assertAssetMissing(t, assets, root.AssetID)
	assertAssetMissing(t, assets, child.AssetID)
	assertAssetMissing(t, assets, grandChild.AssetID)
	assertAssetPresent(t, assets, peer.AssetID)

	edges := listAllEdges(t, connAfterRestart, roomID)
	deletedEntityIDs := map[uint64]struct{}{
		root.AssetID:       {},
		child.AssetID:      {},
		grandChild.AssetID: {},
	}
	deletedEdgeIDs := map[uint64]struct{}{}
	for _, edge := range seededEdges {
		deletedEdgeIDs[edge.EdgeID] = struct{}{}
	}
	assertNoIncidentEdges(t, edges, deletedEntityIDs, deletedEdgeIDs)
}
