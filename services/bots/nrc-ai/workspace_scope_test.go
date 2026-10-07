package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/heavyhorst/nrc/protocol-go"
)

func TestWorkspaceDataDoesNotSubscribeToChat(t *testing.T) {
	frames := make(chan *protocol.Message, 4)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.Close()
		for range 4 {
			_, data, err := conn.ReadMessage()
			if err != nil {
				t.Error(err)
				return
			}
			message, err := protocol.ReadMessage(data)
			if err != nil {
				t.Error(err)
				return
			}
			frames <- message
		}
	}))
	defer server.Close()
	conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	client := NewNRCClient(Config{}, "ws")
	client.conn = conn
	client.connected.Store(true)
	if err := client.SubscribeRoom(protocol.WorkspaceDataConvID); err != nil {
		t.Fatal(err)
	}
	select {
	case frame := <-frames:
		if frame.Opcode != protocol.C_SubscribeConvs || !bytes.Equal(frame.Data, protocol.EncodeSubscribeConvs(0)) {
			t.Fatalf("expected workspace-only delivery subscription: %+v", frame)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("missing workspace delivery subscription")
	}
	// Room and DM chat retain their original destination, unlike durable data.
	for _, chatID := range []uint64{73, 1<<63 | 91} {
		if err := client.SendChatMessage(chatID, "progress"); err != nil {
			t.Fatal(err)
		}
	}
	for i, scope := range []uint64{0, 73, 1<<63 | 91} {
		select {
		case frame := <-frames:
			wantOpcode := uint16(protocol.C_SendMessage)
			if i == 0 {
				wantOpcode = protocol.C_GetTasks
			}
			if frame.Opcode != wantOpcode || len(frame.Data) < 8 || binary.BigEndian.Uint64(frame.Data[:8]) != scope {
				t.Fatalf("frame %d: opcode=%d payload=%x, want opcode=%d scope=%d", i, frame.Opcode, frame.Data, wantOpcode, scope)
			}
		case <-time.After(3 * time.Second):
			t.Fatal("missing outbound frame")
		}
	}
}

func TestDurableClientRejectsRoomsAndDMsBeforeSending(t *testing.T) {
	client := NewNRCClient(Config{}, "ws")
	client.protocolVersion.Store(graphRankProtocolVersion)
	for _, scope := range []uint64{1, 1<<63 | 91} {
		t.Run(fmt.Sprint(scope), func(t *testing.T) {
			checks := []func() error{
				func() error { return client.SubscribeRoom(scope) },
				func() error { return client.WaitForTasks(t.Context(), scope) },
				func() error { _, err := client.CreateTask(t.Context(), scope, "task", "", 0); return err },
				func() error {
					_, err := client.UpdateTask(t.Context(), scope, protocol.Task{ID: 1}, "task", "", 0, 0, 0)
					return err
				},
				func() error { _, err := client.CreateAsset(t.Context(), scope, 5, 0, 0, "", "note"); return err },
				func() error { _, err := client.UpdateAsset(t.Context(), scope, 1, "", "note"); return err },
				func() error { return client.DeleteAsset(t.Context(), scope, 1) },
				func() error { _, err := client.CreateEdge(t.Context(), scope, 1, 1, 2, 2, 1); return err },
				func() error { return client.DeleteEdge(t.Context(), scope, 1) },
				func() error { _, err := client.GetEdges(t.Context(), scope); return err },
				func() error { _, err := client.GetAsset(t.Context(), scope, 1); return err },
				func() error {
					_, err := client.ListAssetsPage(t.Context(), scope, protocol.AssetTypeNote, noteListFilter{}, 10, true, nil)
					return err
				},
				func() error { _, err := client.ListTasksPage(t.Context(), scope, 0x1f, 10, nil); return err },
				func() error { _, err := client.ListNoteProjects(t.Context(), scope); return err },
				func() error { _, err := client.ListNoteTags(t.Context(), scope); return err },
				func() error { _, err := client.GetGraphNeighborhood(t.Context(), scope, 1, 1, 1, 0, 0, 0); return err },
				func() error { _, err := client.GetGraphRank(t.Context(), scope, nil, nil, 1, 0, 0, 10); return err },
			}
			for i, check := range checks {
				if err := check(); !errors.Is(err, errWorkspaceDataScope) {
					t.Fatalf("check %d returned %v, want workspace scope error", i, err)
				}
			}
		})
	}
	// Zero gets past scope and encoder validation, reaching the disconnected transport.
	_, err := client.GetGraphRank(t.Context(), protocol.WorkspaceDataConvID, []protocol.GraphRankEntity{{Type: 1, ID: 1}}, nil, 1, 0, 0, 10)
	if !errors.Is(err, errNotConnected) {
		t.Fatalf("zero-scope graph rank: %v", err)
	}
}

func TestWorkspaceCacheAndToolScopeIgnoreChatIdentity(t *testing.T) {
	client := NewNRCClient(Config{}, "ws")
	client.subscribedRooms[73] = true
	client.taskCache[0] = map[uint64]*protocol.Task{4: {ID: 4, Title: "shared"}}
	if client.IsSubscribed(0) {
		t.Fatal("chat subscription must not imply a workspace snapshot")
	}
	client.taskSnapshots[0] = true
	if !client.IsSubscribed(0) || len(client.GetTasks(0)) != 1 || len(client.GetTasks(73)) != 0 {
		t.Fatal("workspace cache mixed with chat scope")
	}
	for _, scope := range []uint64{0, 73, 1<<63 | 91} {
		ctx := context.WithValue(t.Context(), workspaceContextKey{}, "ws")
		ctx = context.WithValue(ctx, convIDContextKey{}, scope)
		_, got, err := adkSessionScope(newFantasyADKToolContext(ctx, "call"))
		if scope == 0 {
			if err != nil || got != 0 {
				t.Fatalf("workspace tool scope: %d, %v", got, err)
			}
		} else if !errors.Is(err, errWorkspaceDataScope) {
			t.Fatalf("nonzero tool scope accepted: %d, %v", got, err)
		}
	}
}

func TestWorkspaceHTTPScopesRejectLegacyRoomsAndDMs(t *testing.T) {
	for _, scope := range []uint64{73, 1<<63 | 91} {
		for name, handler := range map[string]http.HandlerFunc{
			"retrieve":   handleRetrieve(nil, nil),
			"paste-task": handlePasteToTask(nil),
			"paste-note": handlePasteToNote(nil, nil),
		} {
			t.Run(fmt.Sprintf("%s/%d", name, scope), func(t *testing.T) {
				body := fmt.Sprintf(`{"workspace":"ws","conv_id":"%d","query":"task","raw_text":"task"}`, scope)
				response := httptest.NewRecorder()
				handler(response, httptest.NewRequest(http.MethodPost, "/", strings.NewReader(body)))
				if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "scope") {
					t.Fatalf("nonzero HTTP scope: %d %s", response.Code, response.Body.String())
				}
			})
		}
		_, err := retrieveRoom(t.Context(), nil, nil, protocol.RetrieveRequest{Workspace: "ws", ConvID: scope, Query: "task"})
		if !errors.Is(err, errWorkspaceDataScope) {
			t.Fatalf("retrieve scope: %v", err)
		}
		_, err = NewSearchClient("").Search(t.Context(), "ws", "task", scope, 5, true)
		if !errors.Is(err, errWorkspaceDataScope) {
			t.Fatalf("search scope: %v", err)
		}
	}
	var request askRequest
	if err := json.Unmarshal([]byte(`{"workspace":"ws","context_conv_id":"0","display_conv_id":"9223372036854775899","question":"task"}`), &request); err != nil {
		t.Fatal(err)
	}
	if request.ConvID != 0 || request.DisplayConvID != 1<<63|91 {
		t.Fatalf("ask data/chat identity conflated: %+v", request)
	}
}
