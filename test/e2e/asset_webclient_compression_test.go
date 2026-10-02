package e2e

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

// This test mirrors browser behavior during zstd rollout:
// a client can temporarily send plain payloads (codec not ready) and later switch to zstd.
func TestWebclientStyleAssetCompressionRoundtrip(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-webclient-asset-compression-%d", time.Now().UnixNano())
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("failed to connect websocket client: %v", err)
	}
	defer conn.Close()

	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID

	rawPayloadCreate := strings.Repeat("webclient-create-zstd-", 96)
	createPayload, err := protocol.EncodeCreateAssetZstdWithCorrelation(
		roomID,
		protocol.AssetTypeNote,
		protocol.ParentTypeNone,
		0,
		"webclient-create-preview",
		rawPayloadCreate,
		0x0BADB002,
	)
	if err != nil {
		t.Fatalf("failed to encode zstd create payload: %v", err)
	}
	if err := sendProtocolMessage(conn, protocol.C_CreateAsset, createPayload); err != nil {
		t.Fatalf("failed to send zstd create asset: %v", err)
	}

	createdPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetCreated, 12)
	createdAsset, _ := mustParseWireAssetWithCorrelation(t, createdPayload)
	if createdAsset.PayloadEncoding != protocol.AssetPayloadEncodingZstd {
		t.Fatalf("created payload encoding = %d, want %d", createdAsset.PayloadEncoding, protocol.AssetPayloadEncodingZstd)
	}
	decodedCreate, err := protocol.DecodeAssetPayload(createdAsset)
	if err != nil {
		t.Fatalf("failed to decode created payload: %v", err)
	}
	if decodedCreate != rawPayloadCreate {
		t.Fatalf("created payload mismatch after decode")
	}

	// Simulate browser fallback while codec is unavailable: plain update still valid.
	rawPayloadPlain := "webclient-plain-fallback-payload"
	if err := sendProtocolMessage(conn, protocol.C_UpdateAsset, protocol.EncodeUpdateAsset(roomID, createdAsset.AssetID, "webclient-plain-preview", rawPayloadPlain)); err != nil {
		t.Fatalf("failed to send plain update asset: %v", err)
	}
	updatedPlainPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetUpdated, 12)
	updatedPlain, _ := mustParseWireAssetWithCorrelation(t, updatedPlainPayload)
	if updatedPlain.PayloadEncoding != protocol.AssetPayloadEncodingPlain {
		t.Fatalf("plain update payload encoding = %d, want %d", updatedPlain.PayloadEncoding, protocol.AssetPayloadEncodingPlain)
	}
	decodedPlain, err := protocol.DecodeAssetPayload(updatedPlain)
	if err != nil {
		t.Fatalf("failed to decode plain update payload: %v", err)
	}
	if decodedPlain != rawPayloadPlain {
		t.Fatalf("plain update payload mismatch after decode")
	}

	// Browser has codec now: switch back to zstd updates.
	rawPayloadZstdUpdate := strings.Repeat("webclient-zstd-update-", 80)
	updateZstdPayload, err := protocol.EncodeUpdateAssetZstd(roomID, createdAsset.AssetID, "webclient-zstd-preview", rawPayloadZstdUpdate)
	if err != nil {
		t.Fatalf("failed to encode zstd update payload: %v", err)
	}
	if err := sendProtocolMessage(conn, protocol.C_UpdateAsset, updateZstdPayload); err != nil {
		t.Fatalf("failed to send zstd update asset: %v", err)
	}
	updatedZstdPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetUpdated, 12)
	updatedZstd, _ := mustParseWireAssetWithCorrelation(t, updatedZstdPayload)
	if updatedZstd.PayloadEncoding != protocol.AssetPayloadEncodingZstd {
		t.Fatalf("zstd update payload encoding = %d, want %d", updatedZstd.PayloadEncoding, protocol.AssetPayloadEncodingZstd)
	}
	decodedZstdUpdate, err := protocol.DecodeAssetPayload(updatedZstd)
	if err != nil {
		t.Fatalf("failed to decode zstd update payload: %v", err)
	}
	if decodedZstdUpdate != rawPayloadZstdUpdate {
		t.Fatalf("zstd update payload mismatch after decode")
	}

	if err := sendProtocolMessage(conn, protocol.C_GetAsset, protocol.EncodeGetAsset(roomID, createdAsset.AssetID)); err != nil {
		t.Fatalf("failed to send GetAsset: %v", err)
	}
	fullPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetFull, 12)
	fullAsset, _ := mustParseWireAssetWithCorrelation(t, fullPayload)
	decodedFull, err := protocol.DecodeAssetPayload(fullAsset)
	if err != nil {
		t.Fatalf("failed to decode S_AssetFull payload: %v", err)
	}
	if decodedFull != rawPayloadZstdUpdate {
		t.Fatalf("full payload mismatch after decode")
	}

	if err := sendProtocolMessage(conn, protocol.C_ListAssets, protocol.EncodeListAssets(roomID, false, 0, true)); err != nil {
		t.Fatalf("failed to send ListAssets(full): %v", err)
	}
	listPayload := mustReadUntilOpcode(t, conn, protocol.S_AssetList, 12)
	assets := mustParseWireAssetListFull(t, listPayload)

	found := false
	for i := range assets {
		if assets[i].AssetID != createdAsset.AssetID {
			continue
		}
		found = true
		if assets[i].PayloadEncoding != protocol.AssetPayloadEncodingZstd {
			t.Fatalf("list payload encoding = %d, want %d", assets[i].PayloadEncoding, protocol.AssetPayloadEncodingZstd)
		}
		decodedListPayload, decodeErr := protocol.DecodeAssetPayload(assets[i])
		if decodeErr != nil {
			t.Fatalf("failed to decode list payload: %v", decodeErr)
		}
		if decodedListPayload != rawPayloadZstdUpdate {
			t.Fatalf("list payload mismatch after decode")
		}
		break
	}
	if !found {
		t.Fatalf("asset id %d not found in full list", createdAsset.AssetID)
	}
}
