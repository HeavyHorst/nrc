package e2e

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestAssetAndEdgePersistenceAcrossRestart(t *testing.T) {
	serverWorkDir := t.TempDir()
	workspace := fmt.Sprintf("e2e-asset-edge-persist-%d", time.Now().UnixNano())

	server := startServerInWorkDir(t, serverWorkDir)

	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		server.stop(t)
		t.Fatalf("failed to connect websocket client before restart: %v", err)
	}

	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID
	const asset1Preview = "asset one preview"
	const asset1Payload = "asset one payload"
	const asset2Preview = "asset two preview"
	const asset2Payload = "asset two payload"

	if err := sendProtocolMessage(conn, protocol.C_CreateAsset, protocol.EncodeCreateAsset(roomID, protocol.AssetTypeNote, protocol.ParentTypeNone, 0, asset1Preview, asset1Payload)); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send first CreateAsset: %v", err)
	}
	created1Payload := mustReadUntilOpcode(t, conn, protocol.S_AssetCreated, 12)
	assetCreated1, err := protocol.DecodeAssetCreated(created1Payload)
	if err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to decode first S_AssetCreated payload: %v payload=%x", err, created1Payload)
	}
	if assetCreated1.Asset.AssetID == 0 {
		_ = conn.Close()
		server.stop(t)
		t.Fatal("first created asset id is zero")
	}

	if err := sendProtocolMessage(conn, protocol.C_CreateAsset, protocol.EncodeCreateAsset(roomID, protocol.AssetTypeDocument, protocol.ParentTypeNone, 0, asset2Preview, asset2Payload)); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send second CreateAsset: %v", err)
	}
	created2Payload := mustReadUntilOpcode(t, conn, protocol.S_AssetCreated, 12)
	assetCreated2, err := protocol.DecodeAssetCreated(created2Payload)
	if err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to decode second S_AssetCreated payload: %v payload=%x", err, created2Payload)
	}
	if assetCreated2.Asset.AssetID == 0 {
		_ = conn.Close()
		server.stop(t)
		t.Fatal("second created asset id is zero")
	}

	if err := sendProtocolMessage(
		conn,
		protocol.C_CreateEdge,
		protocol.EncodeCreateEdge(
			roomID,
			protocol.TargetTypeAsset,
			assetCreated1.Asset.AssetID,
			protocol.TargetTypeAsset,
			assetCreated2.Asset.AssetID,
			protocol.RelationDependsOn,
		),
	); err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to send CreateEdge: %v", err)
	}
	createdEdgePayload := mustReadUntilOpcode(t, conn, protocol.S_EdgeCreated, 12)
	edgeCreated, err := protocol.DecodeEdgeCreated(createdEdgePayload)
	if err != nil {
		_ = conn.Close()
		server.stop(t)
		t.Fatalf("failed to decode S_EdgeCreated payload: %v payload=%x", err, createdEdgePayload)
	}

	_ = conn.Close()
	server.stop(t)

	server = startServerInWorkDir(t, serverWorkDir)
	defer server.stop(t)

	connAfterRestart, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("failed to connect websocket client after restart: %v", err)
	}
	defer connAfterRestart.Close()

	mustSetReadDeadline(t, connAfterRestart, 5*time.Second)
	mustExpectServerReady(t, connAfterRestart)

	if err := sendProtocolMessage(connAfterRestart, protocol.C_GetAsset, protocol.EncodeGetAsset(roomID, assetCreated1.Asset.AssetID)); err != nil {
		t.Fatalf("failed to send GetAsset after restart: %v", err)
	}
	assetFullPayload := mustReadUntilOpcode(t, connAfterRestart, protocol.S_AssetFull, 12)
	asset1AfterRestart, err := protocol.DecodeAssetFull(assetFullPayload)
	if err != nil {
		t.Fatalf("failed to decode S_AssetFull payload after restart: %v payload=%x", err, assetFullPayload)
	}
	if asset1AfterRestart.AssetID != assetCreated1.Asset.AssetID {
		t.Fatalf("asset id mismatch after restart: got %d want %d", asset1AfterRestart.AssetID, assetCreated1.Asset.AssetID)
	}
	if asset1AfterRestart.Preview != asset1Preview {
		t.Fatalf("asset preview mismatch after restart: got %q want %q", asset1AfterRestart.Preview, asset1Preview)
	}
	if asset1AfterRestart.Payload != asset1Payload {
		t.Fatalf("asset payload mismatch after restart: got %q want %q", asset1AfterRestart.Payload, asset1Payload)
	}

	if err := sendProtocolMessage(connAfterRestart, protocol.C_ListAssets, protocol.EncodeListAssets(roomID, false, 0, true)); err != nil {
		t.Fatalf("failed to send ListAssets after restart: %v", err)
	}
	assetsPayload := mustReadUntilOpcode(t, connAfterRestart, protocol.S_AssetList, 12)
	assets, err := protocol.DecodeAssetList(assetsPayload, true)
	if err != nil {
		t.Fatalf("failed to decode S_AssetList payload after restart: %v payload=%x", err, assetsPayload)
	}

	foundAsset1 := false
	foundAsset2 := false
	for _, asset := range assets {
		if asset.AssetID == assetCreated1.Asset.AssetID {
			foundAsset1 = true
		}
		if asset.AssetID == assetCreated2.Asset.AssetID {
			foundAsset2 = true
		}
	}
	if !foundAsset1 || !foundAsset2 {
		t.Fatalf("assets missing after restart: foundAsset1=%t foundAsset2=%t total=%d", foundAsset1, foundAsset2, len(assets))
	}

	if err := sendProtocolMessage(
		connAfterRestart,
		protocol.C_ListAllEdges,
		protocol.EncodeListAllEdges(roomID),
	); err != nil {
		t.Fatalf("failed to send ListAllEdges after restart: %v", err)
	}
	edgesPayload := mustReadUntilOpcode(t, connAfterRestart, protocol.S_AllEdgeList, 12)
	_, edges, err := protocol.DecodeAllEdgeList(edgesPayload)
	if err != nil {
		t.Fatalf("failed to decode S_AllEdgeList payload after restart: %v payload=%x", err, edgesPayload)
	}

	var restoredEdge *protocol.Edge
	for i := range edges {
		edge := &edges[i]
		if edge.EdgeID == edgeCreated.Edge.EdgeID {
			restoredEdge = edge
			break
		}
	}
	if restoredEdge == nil {
		t.Fatalf("edge id %d missing after restart; got %d edges", edgeCreated.Edge.EdgeID, len(edges))
	}
	if restoredEdge.SourceID != assetCreated1.Asset.AssetID {
		t.Fatalf("restored edge source id mismatch: got %d want %d", restoredEdge.SourceID, assetCreated1.Asset.AssetID)
	}
	if restoredEdge.TargetID != assetCreated2.Asset.AssetID {
		t.Fatalf("restored edge target id mismatch: got %d want %d", restoredEdge.TargetID, assetCreated2.Asset.AssetID)
	}
	if restoredEdge.Relation != protocol.RelationDependsOn {
		t.Fatalf("restored edge relation mismatch: got %d want %d", restoredEdge.Relation, protocol.RelationDependsOn)
	}
}
