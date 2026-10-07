package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/heavyhorst/nrc/protocol-go"
)

func taskPagePayload(correlationID uint32, success bool) []byte {
	var b bytes.Buffer
	_ = binary.Write(&b, binary.BigEndian, uint64(0))
	if success {
		b.WriteByte(1)
	} else {
		b.WriteByte(0)
	}
	_ = binary.Write(&b, binary.BigEndian, uint16(0))
	b.WriteByte(0)
	_ = binary.Write(&b, binary.BigEndian, int64(-987))
	_ = binary.Write(&b, binary.BigEndian, uint64(123456))
	_ = binary.Write(&b, binary.BigEndian, uint32(42))
	_ = binary.Write(&b, binary.BigEndian, uint16(4))
	b.WriteString("nope")
	_ = binary.Write(&b, binary.BigEndian, correlationID)
	return b.Bytes()
}

func TestTaskPageCorrelationAndCacheIsolation(t *testing.T) {
	c := NewNRCClient(Config{}, "workspace1")
	c.taskCache[0] = map[uint64]*protocol.Task{9: {ID: 9, Title: "cached"}}
	first, second := make(chan taskPageResult, 1), make(chan taskPageResult, 1)
	c.pendingTaskPages[11] = []chan taskPageResult{first}
	c.pendingTaskPages[22] = []chan taskPageResult{second}
	c.handleTaskListPage(taskPagePayload(0, true))
	c.handleTaskListPage(taskPagePayload(99, true))
	c.handleTaskListPage([]byte{1})
	if len(c.pendingTaskPages) != 2 {
		t.Fatal("unrelated or malformed response settled a waiter")
	}
	c.handleTaskListPage(taskPagePayload(22, true))
	c.handleTaskListPage(taskPagePayload(11, false))
	select {
	case result := <-second:
		if result.Err != nil || result.Page.CorrelationID != 22 || result.Page.NextCursor.SortAt != -987 || result.Page.NextCursor.TaskID != 123456 || result.Page.TotalCount != 42 {
			t.Fatalf("unexpected page: %+v", result)
		}
	default:
		t.Fatal("success not delivered")
	}
	select {
	case result := <-first:
		if result.Err == nil || result.Page != nil {
			t.Fatalf("expected failed-page error: %+v", result)
		}
	default:
		t.Fatal("error not delivered")
	}
	if len(c.pendingTaskPages) != 0 || len(c.taskCache[0]) != 1 || c.taskCache[0][9].Title != "cached" || c.taskSnapshots[0] {
		t.Fatal("page changed snapshot or left pending requests")
	}
}

func TestListTasksPageWebSocketLifecycle(t *testing.T) {
	for _, mode := range []string{"success", "error", "cancel"} {
		t.Run(mode, func(t *testing.T) {
			requests := make(chan []byte, 1)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
				if err != nil {
					return
				}
				defer conn.Close()
				_, data, err := conn.ReadMessage()
				if err != nil {
					return
				}
				requests <- data
				msg, err := protocol.ReadMessage(data)
				if err != nil {
					return
				}
				id := binary.BigEndian.Uint32(msg.Data[len(msg.Data)-4:])
				if mode != "cancel" {
					opcode, payload := uint16(protocol.S_TaskListPage), taskPagePayload(id, true)
					if mode == "error" {
						opcode = protocol.S_ErrorResponse
						payload = make([]byte, 12)
						binary.BigEndian.PutUint16(payload, protocol.C_ListTasksPaged)
						binary.BigEndian.PutUint16(payload[2:], 4)
						copy(payload[4:], "nope")
						binary.BigEndian.PutUint32(payload[8:], id)
					}
					frame, _ := (&protocol.Message{Opcode: opcode, Data: payload}).Write()
					_ = conn.WriteMessage(websocket.BinaryMessage, frame)
				}
				_, _, _ = conn.ReadMessage()
			}))
			defer server.Close()
			conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			c := NewNRCClient(Config{}, "workspace1")
			c.conn = conn
			c.connected.Store(true)
			ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
			defer cancel()
			pumpDone := make(chan struct{})
			go func() { defer close(pumpDone); c.readPump(ctx) }()
			defer func() { conn.Close(); <-pumpDone }()
			result := make(chan taskPageResult, 1)
			cursor := &protocol.TaskPageCursor{SortAt: -123, TaskID: 987654}
			go func() {
				page, err := c.ListTasksPage(ctx, 0, 5, 37, cursor)
				result <- taskPageResult{Page: page, Err: err}
			}()
			select {
			case data := <-requests:
				msg, err := protocol.ReadMessage(data)
				if err != nil {
					t.Fatal(err)
				}
				if msg.Opcode != protocol.C_ListTasksPaged {
					t.Fatalf("opcode %d", msg.Opcode)
				}
				id := binary.BigEndian.Uint32(msg.Data[len(msg.Data)-4:])
				want, _ := protocol.EncodeListTasksPaged(0, 5, 37, cursor, id)
				if id == 0 || !bytes.Equal(msg.Data, want) {
					t.Fatalf("wrong request: %x", msg.Data)
				}
			case <-ctx.Done():
				t.Fatal("request not received")
			}
			if mode == "cancel" {
				cancel()
			}
			select {
			case got := <-result:
				if mode == "success" && (got.Err != nil || got.Page == nil) {
					t.Fatalf("success: %+v", got)
				}
				if mode == "error" && (got.Err == nil || got.Err.Error() != "nope") {
					t.Fatalf("error: %+v", got)
				}
				if mode == "cancel" && !errors.Is(got.Err, context.Canceled) {
					t.Fatalf("cancel: %+v", got)
				}
			case <-time.After(4 * time.Second):
				t.Fatal("request did not settle")
			}
			c.pendingTaskPagesMu.Lock()
			remaining := len(c.pendingTaskPages)
			c.pendingTaskPagesMu.Unlock()
			if remaining != 0 {
				t.Fatal("pending waiter leaked")
			}
		})
	}
}

func TestListTasksPageEarlyErrorsCleanUp(t *testing.T) {
	c := NewNRCClient(Config{}, "workspace1")
	if _, err := c.ListTasksPage(t.Context(), 1, 1, 1, nil); !errors.Is(err, errWorkspaceDataScope) {
		t.Fatal(err)
	}
	if _, err := c.ListTasksPage(t.Context(), 0, 1, 1, nil); !errors.Is(err, errNotConnected) {
		t.Fatal(err)
	}
	c.connected.Store(true)
	for _, args := range [][2]uint16{{0, 1}, {1, 0}, {1, 1}} {
		if _, err := c.ListTasksPage(t.Context(), 0, uint8(args[0]), args[1], nil); err == nil {
			t.Fatal("expected encoding/send error")
		}
		if len(c.pendingTaskPages) != 0 {
			t.Fatal("pending waiter leaked")
		}
	}
}

func connectedListingTestClient(t *testing.T) (*NRCClient, <-chan *protocol.Message) {
	t.Helper()
	requests := make(chan *protocol.Message, 4)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		for {
			_, data, err := conn.ReadMessage()
			if err != nil {
				return
			}
			msg, err := protocol.ReadMessage(data)
			if err != nil {
				t.Error(err)
				return
			}
			requests <- msg
		}
	}))
	conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		server.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close(); server.Close() })
	c := NewNRCClient(Config{}, "ws")
	c.conn = conn
	c.connected.Store(true)
	c.closeReady()
	return c, requests
}

func TestListAssetsPageSendsCursorAndType(t *testing.T) {
	for _, filter := range []noteListFilter{{}, {Project: "repo"}, {Tag: "incident"}} {
		t.Run(filter.Project+filter.Tag, func(t *testing.T) {
			c, requests := connectedListingTestClient(t)
			ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
			defer cancel()
			assetType := protocol.AssetTypeNote
			if filter == (noteListFilter{}) {
				assetType = protocol.AssetTypeFile
			}
			result := make(chan assetPageResult, 1)
			go func() {
				page, err := c.ListAssetsPage(ctx, 0, assetType, filter, 37, false, &assetPageCursor{UpdatedAt: 1791352800123456789, AssetID: 9007199254740993})
				result <- assetPageResult{Page: page, Err: err}
			}()
			var msg *protocol.Message
			select {
			case msg = <-requests:
			case <-ctx.Done():
				t.Fatal("missing request")
			}
			wantOpcode := uint16(protocol.C_ListAssetsPaged)
			if filter.Project != "" {
				wantOpcode = protocol.C_ListAssetsPagedByProject
			}
			if filter.Tag != "" {
				wantOpcode = protocol.C_ListAssetsPagedByTag
			}
			// Check raw wire fields independently of the request encoder.
			if msg.Opcode != wantOpcode || binary.BigEndian.Uint16(msg.Data[8:]) != assetType || binary.BigEndian.Uint16(msg.Data[11:]) != 37 || msg.Data[13] != 1 || binary.BigEndian.Uint64(msg.Data[14:]) != 1791352800123456789 || binary.BigEndian.Uint64(msg.Data[22:]) != 9007199254740993 {
				t.Fatalf("wrong cursor/type request: %x", msg.Data)
			}
			id := binary.BigEndian.Uint32(msg.Data[len(msg.Data)-4:])
			// Dispatch an actual S_AssetListPage payload through the decoder/router.
			payload := make([]byte, 36)
			binary.BigEndian.PutUint32(payload[26:], 73)
			binary.BigEndian.PutUint32(payload[32:], id)
			c.handleAssetListPage(payload)
			got := <-result
			if got.Err != nil || got.Page.TotalCount != 73 || len(c.pendingAssetPages) != 0 {
				t.Fatalf("page/cleanup: %+v", got)
			}
		})
	}
}

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
