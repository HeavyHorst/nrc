package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"charm.land/fantasy"
	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestHistoryToolsWireReads(t *testing.T) {
	for _, tc := range []struct {
		name, input, reply, want string
		tool                     int
		bad                      bool
	}{
		{"history", `{"entity_type":"asset","entity_id":"9007199254740993","before":"93","limit":2}`, `{"events":[{"id":"91","entityType":"asset","entityId":"9007199254740993","actorName":"Ada","timestamp":"1790812800000000001","fields":["title"]},{"id":"87","action":"update"}],"nextBefore":"87"}`, `"timestamp":"1790812800000000001"`, 0, false},
		{"history_end", `{"before":"87"}`, `{"events":[],"nextBefore":"0"}`, `"nextBefore":"0"`, 0, false},
		{"history_error", `{}`, `{"events":[],"nextBefore":"0","error":"denied"}`, "denied", 0, true},
		{"history_bad_cursor", `{"before":"87"}`, `{"events":[{"id":"87"}],"nextBefore":"87"}`, "", 0, true},
		{"history_bad_order", `{}`, `{"events":[{"id":"87"},{"id":"91"}],"nextBefore":"91"}`, "", 0, true},
		{"summaries", `{"note_id":"9007199254740993","cursor":"7","limit":2}`, `{"status":"ok","entries":[{"generation":"9","note_id":"9007199254740993","summary":"Frist zurückgenommen","sources":["91"],"model":"fixture","source_available":false}],"cursor":"9","more":true}`, `"summary":"Frist zurückgenommen"`, 1, false},
		{"summaries_end", `{"cursor":"9"}`, `{"status":"ok","entries":[],"cursor":"","more":false}`, `"cursor":"9"`, 1, false},
		{"gaps", `{"operation":"gaps","cursor":"9"}`, `{"status":"ok","gaps":[{"first_source":"11","last_source":"17","note_id":"29","reason":"input_size","input_count":9007199254740993}],"cursor":"11","more":false}`, `"input_count":"9007199254740993"`, 1, false},
		{"status", `{"operation":"status"}`, `{"status":"ok","enabled":false,"pending":3,"failed":2,"gap_count":4,"can_delete":true}`, `"enabled":false`, 1, false},
		{"chronicle_error", `{}`, `{"status":"forbidden","error":"denied"}`, "denied", 1, true},
		{"chronicle_wrong_note", `{"note_id":"29"}`, `{"status":"ok","entries":[{"generation":"9","note_id":"30"}],"cursor":"9"}`, "", 1, true},
		{"chronicle_bad_order", `{"cursor":"9"}`, `{"status":"ok","entries":[{"generation":"7","note_id":"29"}],"cursor":"7"}`, "", 1, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			requests := make(chan *protocol.Message, 1)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
				if err != nil {
					return
				}
				defer conn.Close()
				_, raw, err := conn.ReadMessage()
				if err != nil {
					return
				}
				msg, err := protocol.ReadMessage(raw)
				if err != nil {
					t.Error(err)
					return
				}
				requests <- msg
				id := binary.BigEndian.Uint32(msg.Data[len(msg.Data)-4:])
				payload := make([]byte, 4)
				binary.BigEndian.PutUint32(payload, id)
				payload = append(payload, tc.reply...)
				opcode := uint16(168)
				if tc.tool == 1 {
					opcode = protocol.S_Chronicle
				}
				frame, _ := (&protocol.Message{Opcode: opcode, Data: payload}).Write()
				_ = conn.WriteMessage(websocket.BinaryMessage, frame)
				_, _, _ = conn.ReadMessage()
			}))
			defer server.Close()
			conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
			if err != nil {
				t.Fatal(err)
			}
			c := NewNRCClient(Config{}, "ws")
			c.conn = conn
			c.connected.Store(true)
			c.closeReady()
			c.taskSnapshots[0] = true
			ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
			defer cancel()
			done := make(chan struct{})
			go func(readCtx context.Context) { defer close(done); c.readPump(readCtx) }(ctx)
			defer func() { cancel(); conn.Close(); <-done }()
			tools := newHistoryTools(&WorkspaceManager{ctx: ctx, clients: map[string]*NRCClient{"ws": c}})
			ctx = context.WithValue(context.WithValue(ctx, workspaceContextKey{}, "ws"), convIDContextKey{}, uint64(0))
			result, err := tools[tc.tool].Run(ctx, fantasy.ToolCall{Input: tc.input})
			if tc.bad {
				if err == nil && !result.IsError {
					t.Fatalf("accepted invalid result: %s", result.Content)
				}
				if tc.want != "" && !strings.Contains(result.Content, tc.want) && (err == nil || !strings.Contains(err.Error(), tc.want)) {
					t.Fatalf("lost server error: %s %v", result.Content, err)
				}
			} else if err != nil || result.IsError || !strings.Contains(result.Content, tc.want) {
				t.Fatalf("result: %s, error: %v", result.Content, err)
			}
			if strings.Contains(result.Content, "can_delete") || strings.Contains(result.Content, "chunk") {
				t.Fatalf("exposed service fields: %s", result.Content)
			}
			select {
			case msg := <-requests:
				if tc.tool == 0 {
					if msg.Opcode != 62 || len(msg.Data) != 31 || binary.BigEndian.Uint64(msg.Data) != 0 {
						t.Fatalf("invalid history wire: %+v", msg)
					}
					if tc.name == "history" && (msg.Data[8] != 2 || binary.BigEndian.Uint64(msg.Data[9:]) != 9007199254740993 || binary.BigEndian.Uint64(msg.Data[17:]) != 93 || binary.BigEndian.Uint16(msg.Data[25:]) != 2) {
						t.Fatalf("lost history filters: %x", msg.Data)
					}
				} else {
					if msg.Opcode != protocol.C_Chronicle {
						t.Fatalf("invalid Chronicle opcode: %d", msg.Opcode)
					}
					var q protocol.ChronicleRequest
					if err := json.Unmarshal(msg.Data[:len(msg.Data)-4], &q); err != nil {
						t.Fatal(err)
					}
					if q.Op != "history" && q.Op != "status" && q.Op != "gaps" {
						t.Fatalf("non-read operation: %+v", q)
					}
					if tc.name == "summaries" && (q.NoteID != "9007199254740993" || q.Cursor != "7" || q.Limit != 2) {
						t.Fatalf("lost Chronicle filters: %+v", q)
					}
				}
			case <-ctx.Done():
				t.Fatal("missing wire request")
			}
		})
	}
}

func TestHistoryToolsRejectWritesAndInvalidScope(t *testing.T) {
	c, requests := connectedListingTestClient(t)
	c.taskSnapshots[0] = true
	ctx := context.WithValue(context.WithValue(t.Context(), workspaceContextKey{}, "ws"), convIDContextKey{}, uint64(0))
	tools := newHistoryTools(&WorkspaceManager{ctx: ctx, clients: map[string]*NRCClient{"ws": c}})
	for _, input := range []string{`{"operation":"delete"}`, `{"operation":"claim"}`, `{"operation":"chunk"}`, `{"operation":"reserve"}`, `{"operation":"commit"}`, `{"operation":"retry"}`, `{"operation":"list"}`, `{"note_id":"0"}`, `{"cursor":"01"}`, `{"limit":17}`, `{"operation":"status","cursor":"9"}`} {
		result, err := tools[1].Run(ctx, fantasy.ToolCall{Input: input})
		if err == nil && !result.IsError {
			t.Fatal("accepted invalid Chronicle request", input)
		}
	}
	for _, input := range []string{`{"entity_type":"room"}`, `{"entity_type":"asset"}`, `{"entity_id":"1"}`, `{"before":"-1"}`, `{"limit":101}`} {
		result, err := tools[0].Run(ctx, fantasy.ToolCall{Input: input})
		if err == nil && !result.IsError {
			t.Fatal("accepted invalid history request", input)
		}
	}
	for _, tool := range tools {
		for _, denied := range []context.Context{context.WithValue(ctx, convIDContextKey{}, uint64(42)), context.WithValue(ctx, workspaceContextKey{}, "")} {
			result, err := tool.Run(denied, fantasy.ToolCall{Input: `{}`})
			if err == nil && !result.IsError {
				t.Fatal("accepted invalid scope", tool.Info().Name)
			}
		}
	}
	select {
	case msg := <-requests:
		t.Fatal("invalid request reached server", msg.Opcode)
	default:
	}
}
