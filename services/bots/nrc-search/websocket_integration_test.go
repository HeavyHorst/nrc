package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func protocolWireMessage(opcode uint16, payload []byte) ([]byte, error) {
	wire, err := (&protocol.Message{Opcode: opcode, Data: payload}).Write()
	if err != nil {
		return nil, err
	}
	return wire, nil
}

func waitForIndexedTask(t *testing.T, index *Index, identity EntityIdentity) *IndexEntry {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		if entry, ok := index.GetEntity(identity); ok {
			return entry
		}
		if time.Now().After(deadline) {
			t.Fatalf("task was not indexed through websocket read loop: %+v", identity)
		}
		time.Sleep(time.Millisecond)
	}
}

func TestNRCClientRunWebSocketTaskEventsAndReconciliation(t *testing.T) {
	created := &protocol.Task{ID: 41, ConvID: 0, Title: "Live WebSocket Task", Description: "from task event", Status: protocol.TaskStatusTodo}
	done := &protocol.Task{ID: 42, ConvID: 0, Title: "Unloaded Done over WebSocket", Description: "from reconciliation", Status: protocol.TaskStatusDone, CompletedAt: 100}
	connected := make(chan *websocket.Conn, 1)
	serverErrors := make(chan error, 1)
	var serverWriteMu sync.Mutex
	writeServerMessage := func(conn *websocket.Conn, opcode uint16, payload []byte) error {
		wire, err := protocolWireMessage(opcode, payload)
		if err != nil {
			return err
		}
		serverWriteMu.Lock()
		defer serverWriteMu.Unlock()
		return conn.WriteMessage(websocket.BinaryMessage, wire)
	}
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			serverErrors <- err
			return
		}
		connected <- conn

		ready := bytes.NewBuffer(nil)
		writeTestString(ready, "test-build")
		_ = binary.Write(ready, binary.BigEndian, uint32(1))
		if err := writeServerMessage(conn, protocol.S_ServerReady, ready.Bytes()); err != nil {
			serverErrors <- err
			return
		}
		for {
			_, data, err := conn.ReadMessage()
			if err != nil {
				return
			}
			message, err := protocol.ReadMessage(data)
			if err != nil {
				serverErrors <- err
				return
			}
			switch message.Opcode {
			case protocol.C_SubscribeConvs:
				if len(message.Data) != 10 || binary.BigEndian.Uint16(message.Data) != 1 || binary.BigEndian.Uint64(message.Data[2:]) != 0 {
					t.Errorf("durable subscription must contain only scope 0: %v", message.Data)
				}
			case protocol.C_ListTasksPaged:
				if binary.BigEndian.Uint64(message.Data) != 0 {
					t.Errorf("task reconciliation used chat scope: %v", message.Data)
				}
				correlationID := binary.BigEndian.Uint32(message.Data[len(message.Data)-4:])
				if err := writeServerMessage(conn, protocol.S_TaskListPage, encodeTaskPage(0, []*protocol.Task{created, done}, false, protocol.TaskPageCursor{}, correlationID)); err != nil {
					serverErrors <- err
					return
				}
			}
		}
	}))
	defer server.Close()

	storage := newTestStorage(t)
	embedder := &recordingEmbedder{}
	index := NewIndex()
	cfg := Config{
		NRCServer:   strings.Replace(server.URL, "http://", "ws://", 1),
		NRCNickname: "search-integration", EmbedTasks: true, ReconcileInterval: time.Hour,
	}
	client, err := NewNRCClient(cfg, "ws-integration", storage, embedder, index)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go client.Run(ctx)
	go client.DrainEmbedQueue(ctx)
	if err := waitForClientReady(ctx, client, 2*time.Second, "ws-integration"); err != nil {
		t.Fatal(err)
	}

	var serverConn *websocket.Conn
	select {
	case serverConn = <-connected:
	case err := <-serverErrors:
		t.Fatal(err)
	case <-time.After(2 * time.Second):
		t.Fatal("fake NRC websocket did not accept the client")
	}
	defer serverConn.Close()
	if err := writeServerMessage(serverConn, protocol.S_TaskCreated, encodeTaskEvent(created)); err != nil {
		t.Fatal(err)
	}
	if entry := waitForIndexedTask(t, index, taskIdentity("ws-integration", 41, 0)); entry.Preview != created.Title {
		t.Fatalf("live event entry = %+v", entry)
	}

	wm := NewWorkspaceManager(ctx, cfg, storage, embedder, index)
	wm.clients["ws-integration"] = client
	handler := newHTTPHandler(cfg, time.Now(), wm, index, embedder)
	response, _ := postTaskSearch(t, handler, `{"workspace":"ws-integration","query":"unloaded done websocket","conv_id":"0","filters":{"entity_types":["task"],"task":{"task_ids":["42"]}}}`)
	if response.Stale || len(response.Results) != 1 || response.Results[0].Entity.EntityID != 42 || response.Results[0].Metadata.Task.Status != protocol.TaskStatusDone {
		t.Fatalf("websocket reconciliation search = %#v", response)
	}

	select {
	case err := <-serverErrors:
		t.Fatal(err)
	default:
	}
}
