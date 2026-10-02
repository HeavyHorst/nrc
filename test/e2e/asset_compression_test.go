package e2e

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestAssetCompressionCreateUpdateGetListFlows(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-asset-compression-%d", time.Now().UnixNano())
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("failed to connect websocket client: %v", err)
	}
	defer conn.Close()

	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID
	const createCorrelationID uint32 = 0xAABBCCDD
	previewBefore := "compressed-preview-before"
	rawPayloadBefore := strings.Repeat("create-compressible-payload-", 128)

	createPayload, err := protocol.EncodeCreateAssetZstdWithCorrelation(
		roomID,
		protocol.AssetTypeNote,
		protocol.ParentTypeNone,
		0,
		previewBefore,
		rawPayloadBefore,
		createCorrelationID,
	)
	if err != nil {
		t.Fatalf("failed to encode compressed create asset payload: %v", err)
	}

	if err := sendProtocolMessage(conn, protocol.C_CreateAsset, createPayload); err != nil {
		t.Fatalf("failed to send compressed CreateAsset: %v", err)
	}

	createdPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetCreated, 12)
	createdAsset, createdCorrelationID := mustParseWireAssetWithCorrelation(t, createdPayload)
	if createdCorrelationID != createCorrelationID {
		t.Fatalf("create correlation_id mismatch: got 0x%08X want 0x%08X", createdCorrelationID, createCorrelationID)
	}
	if createdAsset.PayloadEncoding != protocol.AssetPayloadEncodingZstd {
		t.Fatalf("created payload encoding mismatch: got %d want %d", createdAsset.PayloadEncoding, protocol.AssetPayloadEncodingZstd)
	}
	if createdAsset.PayloadRawLen != uint32(len(rawPayloadBefore)) {
		t.Fatalf("created payload_raw_len mismatch: got %d want %d", createdAsset.PayloadRawLen, len(rawPayloadBefore))
	}
	decodedCreatedPayload, err := protocol.DecodeAssetPayload(createdAsset)
	if err != nil {
		t.Fatalf("failed to decode created compressed payload: %v", err)
	}
	if decodedCreatedPayload != rawPayloadBefore {
		t.Fatalf("created payload mismatch after decode")
	}

	previewAfter := "compressed-preview-after"
	rawPayloadAfter := strings.Repeat("update-compressible-payload-", 96)
	updatePayload, err := protocol.EncodeUpdateAssetZstd(roomID, createdAsset.AssetID, previewAfter, rawPayloadAfter)
	if err != nil {
		t.Fatalf("failed to encode compressed update asset payload: %v", err)
	}
	if err := sendProtocolMessage(conn, protocol.C_UpdateAsset, updatePayload); err != nil {
		t.Fatalf("failed to send compressed UpdateAsset: %v", err)
	}

	updatedPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetUpdated, 12)
	updatedAsset, _ := mustParseWireAssetWithCorrelation(t, updatedPayload)
	if updatedAsset.PayloadEncoding != protocol.AssetPayloadEncodingZstd {
		t.Fatalf("updated payload encoding mismatch: got %d want %d", updatedAsset.PayloadEncoding, protocol.AssetPayloadEncodingZstd)
	}
	if updatedAsset.PayloadRawLen != uint32(len(rawPayloadAfter)) {
		t.Fatalf("updated payload_raw_len mismatch: got %d want %d", updatedAsset.PayloadRawLen, len(rawPayloadAfter))
	}
	decodedUpdatedPayload, err := protocol.DecodeAssetPayload(updatedAsset)
	if err != nil {
		t.Fatalf("failed to decode updated compressed payload: %v", err)
	}
	if decodedUpdatedPayload != rawPayloadAfter {
		t.Fatalf("updated payload mismatch after decode")
	}

	if err := sendProtocolMessage(conn, protocol.C_GetAsset, protocol.EncodeGetAsset(roomID, createdAsset.AssetID)); err != nil {
		t.Fatalf("failed to send GetAsset: %v", err)
	}
	assetFullPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetFull, 12)
	assetFull, _ := mustParseWireAssetWithCorrelation(t, assetFullPayload)
	if assetFull.PayloadEncoding != protocol.AssetPayloadEncodingZstd {
		t.Fatalf("full payload encoding mismatch: got %d want %d", assetFull.PayloadEncoding, protocol.AssetPayloadEncodingZstd)
	}
	decodedFullPayload, err := protocol.DecodeAssetPayload(assetFull)
	if err != nil {
		t.Fatalf("failed to decode full compressed payload: %v", err)
	}
	if decodedFullPayload != rawPayloadAfter {
		t.Fatalf("full payload mismatch after decode")
	}

	if err := sendProtocolMessage(conn, protocol.C_ListAssets, protocol.EncodeListAssets(roomID, false, 0, true)); err != nil {
		t.Fatalf("failed to send ListAssets(full): %v", err)
	}
	listPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetList, 12)
	assets := mustParseWireAssetListFull(t, listPayload)

	var listedAsset *protocol.Asset
	for i := range assets {
		if assets[i].AssetID == createdAsset.AssetID {
			listedAsset = &assets[i]
			break
		}
	}
	if listedAsset == nil {
		t.Fatalf("updated asset id %d not found in full asset list", createdAsset.AssetID)
	}
	if listedAsset.PayloadEncoding != protocol.AssetPayloadEncodingZstd {
		t.Fatalf("list payload encoding mismatch: got %d want %d", listedAsset.PayloadEncoding, protocol.AssetPayloadEncodingZstd)
	}
	decodedListedPayload, err := protocol.DecodeAssetPayload(*listedAsset)
	if err != nil {
		t.Fatalf("failed to decode listed compressed payload: %v", err)
	}
	if decodedListedPayload != rawPayloadAfter {
		t.Fatalf("list payload mismatch after decode")
	}
}
