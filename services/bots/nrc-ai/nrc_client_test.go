package main

import (
	"bytes"
	"encoding/binary"
	"testing"

	"github.com/heavyhorst/nrc/protocol-go"
)

func TestResetReadyClosesPreviousGeneration(t *testing.T) {
	client := NewNRCClient(Config{}, "workspace1")

	previousReady, previousGeneration := client.ReadyState()
	client.resetReady()

	select {
	case <-previousReady:
	default:
		t.Fatal("expected previous ready generation to be closed on reset")
	}

	currentReady, currentGeneration := client.ReadyState()
	if currentGeneration == previousGeneration {
		t.Fatal("expected ready generation to advance on reset")
	}

	select {
	case <-currentReady:
		t.Fatal("expected current ready generation to remain open before server ready")
	default:
	}

	client.closeReady()
	select {
	case <-currentReady:
	default:
		t.Fatal("expected current ready generation to close when marked ready")
	}
}

func TestDecodeGraphQueryResultPayload(t *testing.T) {
	payload := makeGraphQueryPayload(99, 555)

	key, result, err := decodeGraphQueryResultPayload(payload)
	if err != nil {
		t.Fatalf("decode failed: %v", err)
	}

	if key.convID != 99 || key.startType != entityTypeTask || key.startID != 1234 {
		t.Fatalf("unexpected key: %+v", key)
	}
	if !result.Truncated {
		t.Fatal("expected truncated=true")
	}
	if result.CorrelationID != 99 {
		t.Fatalf("correlation ID = %d, want 99", result.CorrelationID)
	}
	if len(result.Nodes) != 1 || result.Nodes[0].Type != entityTypeAsset || result.Nodes[0].ID != 555 || result.Nodes[0].Depth != 2 {
		t.Fatalf("unexpected nodes: %+v", result.Nodes)
	}
	if len(result.Edges) != 1 {
		t.Fatalf("unexpected edge count: %d", len(result.Edges))
	}
	if result.Edges[0].EdgeID != 777 || result.Edges[0].SourceID != 1234 || result.Edges[0].TargetID != 555 {
		t.Fatalf("unexpected edge: %+v", result.Edges[0])
	}
}

func TestDecodeGraphQueryResultPayloadShort(t *testing.T) {
	_, _, err := decodeGraphQueryResultPayload([]byte{1, 2, 3})
	if err == nil {
		t.Fatal("expected error for short payload")
	}
}

func TestDecodeGraphQueryResultPayloadTruncatedNode(t *testing.T) {
	p := makeGraphQueryPayload(0, 555)
	// Keep header, node_count=1, but cut node body short.
	p = p[:21+5]
	_, _, err := decodeGraphQueryResultPayload(p)
	if err == nil {
		t.Fatal("expected error for truncated node payload")
	}
}

func TestHandleGraphQueryResultRoutesSameAnchorByCorrelation(t *testing.T) {
	client := NewNRCClient(Config{}, "workspace1")
	first := make(chan graphQueryResult, 1)
	second := make(chan graphQueryResult, 1)
	client.pendingGraphQueries[11] = []chan graphQueryResult{first}
	client.pendingGraphQueries[22] = []chan graphQueryResult{second}

	client.handleGraphQueryResult(makeGraphQueryPayload(22, 222))
	client.handleGraphQueryResult(makeGraphQueryPayload(11, 111))

	if result := <-first; result.CorrelationID != 11 || result.Nodes[0].ID != 111 {
		t.Fatalf("first request received wrong result: %+v", result)
	}
	if result := <-second; result.CorrelationID != 22 || result.Nodes[0].ID != 222 {
		t.Fatalf("second request received wrong result: %+v", result)
	}
}

func TestGetGraphRankRejectsUnsupportedServerImmediately(t *testing.T) {
	client := NewNRCClient(Config{}, "workspace1")
	client.protocolVersion.Store(graphRankProtocolVersion - 1)

	_, err := client.GetGraphRank(t.Context(), protocol.WorkspaceDataConvID, []protocol.GraphRankEntity{{Type: protocol.TargetTypeTask, ID: 1}}, nil, 1, 0, 0, 50)
	if err == nil {
		t.Fatal("expected old server protocol to reject graph ranking")
	}
}

func TestHandleErrorResponseSettlesGraphRank(t *testing.T) {
	client := NewNRCClient(Config{}, "workspace1")
	ch := make(chan graphRankResult, 1)
	client.pendingGraphRanks[22] = []chan graphRankResult{ch}
	payload := make([]byte, 2+2+4+4)
	binary.BigEndian.PutUint16(payload, protocol.C_GraphRank)
	binary.BigEndian.PutUint16(payload[2:], 4)
	copy(payload[4:], "nope")
	binary.BigEndian.PutUint32(payload[8:], 22)

	client.handleErrorResponse(payload)

	result := <-ch
	if result.Err == nil {
		t.Fatal("expected graph rank error response to settle waiter with error")
	}
}

func TestWaitForTasksReturnsForExistingSnapshot(t *testing.T) {
	client := NewNRCClient(Config{}, "workspace1")
	client.taskSnapshots[protocol.WorkspaceDataConvID] = true
	if err := client.WaitForTasks(t.Context(), protocol.WorkspaceDataConvID); err != nil {
		t.Fatalf("WaitForTasks returned error for ready snapshot: %v", err)
	}
}

func TestHandleAssetDeletedSettlesWaiters(t *testing.T) {
	client := NewNRCClient(Config{}, "workspace1")
	ch := make(chan assetDeleteResult, 1)

	client.pendingAssetDeletesMu.Lock()
	client.pendingAssetDeletes[0x11223344] = []chan assetDeleteResult{ch}
	client.pendingAssetDeletesMu.Unlock()

	client.handleAssetDeleted(makeDeletedPayload(10, 20, 0x11223344))

	select {
	case result := <-ch:
		if result.Err != nil || result.ConvID != 10 || result.AssetID != 20 {
			t.Fatalf("unexpected asset delete result: %+v", result)
		}
	default:
		t.Fatal("expected asset delete waiter to be settled")
	}
	if _, ok := client.pendingAssetDeletes[0x11223344]; ok {
		t.Fatal("expected asset delete waiter map entry to be cleared")
	}
}

func TestHandleEdgeDeletedSettlesWaiters(t *testing.T) {
	client := NewNRCClient(Config{}, "workspace1")
	ch := make(chan edgeDeleteResult, 1)

	client.pendingEdgeDeletesMu.Lock()
	client.pendingEdgeDeletes[0xAABBCCDD] = []chan edgeDeleteResult{ch}
	client.pendingEdgeDeletesMu.Unlock()

	client.handleEdgeDeleted(makeDeletedPayload(10, 99, 0xAABBCCDD))

	select {
	case result := <-ch:
		if result.Err != nil || result.ConvID != 10 || result.EdgeID != 99 {
			t.Fatalf("unexpected edge delete result: %+v", result)
		}
	default:
		t.Fatal("expected edge delete waiter to be settled")
	}
	if _, ok := client.pendingEdgeDeletes[0xAABBCCDD]; ok {
		t.Fatal("expected edge delete waiter map entry to be cleared")
	}
}

func makeGraphQueryPayload(correlationID uint32, nodeID uint64) []byte {
	var b bytes.Buffer

	_ = binary.Write(&b, binary.BigEndian, uint64(99))   // conv_id
	_ = binary.Write(&b, binary.BigEndian, uint16(2))    // start_type task
	_ = binary.Write(&b, binary.BigEndian, uint64(1234)) // start_id
	b.WriteByte(1)                                       // truncated
	_ = binary.Write(&b, binary.BigEndian, uint16(1))    // node_count
	_ = binary.Write(&b, binary.BigEndian, uint16(1))    // node type asset
	_ = binary.Write(&b, binary.BigEndian, nodeID)       // node id
	b.WriteByte(2)                                       // node depth
	_ = binary.Write(&b, binary.BigEndian, uint16(1))    // edge_count

	// Edge encoding expected by protocol.ParseEdge
	_ = binary.Write(&b, binary.BigEndian, uint64(777))    // edge_id
	_ = binary.Write(&b, binary.BigEndian, uint64(99))     // conv_id
	_ = binary.Write(&b, binary.BigEndian, uint16(2))      // source_type task
	_ = binary.Write(&b, binary.BigEndian, uint64(1234))   // source_id
	_ = binary.Write(&b, binary.BigEndian, uint16(1))      // target_type asset
	_ = binary.Write(&b, binary.BigEndian, nodeID)         // target_id
	_ = binary.Write(&b, binary.BigEndian, uint16(3))      // relation depends-on
	_ = binary.Write(&b, binary.BigEndian, uint64(170000)) // created_at
	_ = binary.Write(&b, binary.BigEndian, uint16(2))      // created_by_len
	b.WriteString("ai")
	_ = binary.Write(&b, binary.BigEndian, correlationID) // correlation_id

	return b.Bytes()
}

func makeDeletedPayload(convID, entityID uint64, correlationID uint32) []byte {
	var b bytes.Buffer
	_ = binary.Write(&b, binary.BigEndian, convID)
	_ = binary.Write(&b, binary.BigEndian, entityID)
	_ = binary.Write(&b, binary.BigEndian, correlationID)
	return b.Bytes()
}
