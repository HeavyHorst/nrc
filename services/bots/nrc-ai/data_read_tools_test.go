package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"charm.land/fantasy"
	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func dataTaskPayload(id uint32, taskID uint64) []byte {
	var b bytes.Buffer
	write := func(v any) { _ = binary.Write(&b, binary.BigEndian, v) }
	text := func(s string) { write(uint16(len(s))); b.WriteString(s) }
	write(uint64(0))
	write(uint8(1))
	write(uint8(1))
	write(taskID)
	write(uint64(0))
	text("server task")
	text("fresh description")
	write(uint8(1))
	write(uint16(2))
	text("operator")
	write(uint8(1))
	write(uint8(0))
	text("creator")
	write(int64(123))
	write(int64(456))
	text("")
	write(int64(789))
	write(uint64(0))
	write(int64(0))
	text("")
	text("project")
	b.Write(protocol.EncodeAttachments(nil))
	text("")
	write(id)
	return b.Bytes()
}

func TestDataReadOutOfOrderAndOpcodeIsolation(t *testing.T) {
	c := NewNRCClient(Config{}, "ws")
	a, b := make(chan dataReadResult, 1), make(chan dataReadResult, 1)
	c.dataReads = map[uint32]pendingDataRead{11: {protocol.C_GetTask, a}, 22: {protocol.C_GetTask, b}}
	c.taskCache[0] = map[uint64]*protocol.Task{7: {ID: 7, Title: "stale"}}
	c.handleDataRead(protocol.S_TaskFull, []byte{1})
	c.handleDataRead(protocol.S_TaskFull, dataTaskPayload(0, 7))
	c.handleDataRead(protocol.S_TaskFull, dataTaskPayload(99, 7))
	c.settleDataRead(11, protocol.C_QueryCalendar, nil, errors.New("wrong opcode"))
	if len(c.dataReads) != 2 {
		t.Fatal("unrelated response settled read")
	}
	c.handleDataRead(protocol.S_TaskFull, dataTaskPayload(22, 8))
	c.handleDataRead(protocol.S_TaskFull, dataTaskPayload(11, 7))
	for ch, want := range map[chan dataReadResult]uint64{a: 7, b: 8} {
		select {
		case r := <-ch:
			if r.err != nil || r.value.(*protocol.TaskFull).Task.ID != want {
				t.Fatalf("bad response: %+v", r)
			}
		default:
			t.Fatal("missing response")
		}
	}
	if len(c.dataReads) != 0 || c.taskCache[0][7].Title != "stale" {
		t.Fatal("cache mutated or pending leaked")
	}
}

func TestDomainToolsWirePaginationAndMetadata(t *testing.T) {
	const largeID uint64 = 9007199254740993
	const at int64 = 1790812800000000001
	for index, name := range []string{"calendar", "slices", "links"} {
		t.Run(name, func(t *testing.T) {
			c, requests := connectedListingTestClient(t)
			c.taskSnapshots[0] = true
			ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
			defer cancel()
			cache := newADKAssetSourceCache(time.Minute, 10)
			tools, err := newADKDataReadTools(&WorkspaceManager{ctx: ctx, clients: map[string]*NRCClient{"ws": c}}, cache)
			if err != nil {
				t.Fatal(err)
			}
			wrapped, err := wrapADKToolsForFantasy(tools...)
			if err != nil {
				t.Fatal(err)
			}
			ctx = context.WithValue(context.WithValue(ctx, workspaceContextKey{}, "ws"), convIDContextKey{}, uint64(0))
			in := map[string]any{"limit": 3}
			if index == 0 {
				in["start"], in["end"] = "2026-10-01T00:00:00Z", "2026-10-02T00:00:00Z"
			}
			if index == 1 {
				in["owner"] = ""
				in["include_closed"] = true
			}
			if index == 2 {
				in["entity_type"], in["id"] = "asset", "9007199254740993"
			}
			for page := 0; page < 2; page++ {
				b, _ := json.Marshal(in)
				done := make(chan fantasy.ToolResponse, 1)
				go func() {
					resp, e := wrapped[index].Run(ctx, fantasy.ToolCall{Input: string(b)})
					if e != nil {
						t.Error(e)
					}
					done <- resp
				}()
				var msg *protocol.Message
				select {
				case msg = <-requests:
				case <-ctx.Done():
					t.Fatal("missing domain request")
				}
				id := binary.BigEndian.Uint32(msg.Data[len(msg.Data)-4:])
				more := page == 0
				switch index {
				case 0:
					q := protocol.CalendarQuery{Start: 1790812800000000000, End: 1790899200000000000, Limit: 3, CorrelationID: id}
					if page == 1 {
						q.Cursor = &protocol.CalendarCursor{At: at, Kind: 2, ID: largeID}
					}
					want, _ := protocol.EncodeCalendarQuery(q)
					if msg.Opcode != protocol.C_QueryCalendar || !bytes.Equal(want, msg.Data) {
						t.Fatalf("bad calendar query %x", msg.Data)
					}
					c.settleDataRead(id, msg.Opcode, &protocol.CalendarPage{HasMore: more, Cursor: protocol.CalendarCursor{At: at, Kind: 2, ID: largeID}, Rows: []protocol.CalendarRow{{Kind: 2, ID: largeID, At: at, ActualStartAt: at - 123, EndAt: at + 987, Title: "appointment"}}}, nil)
				case 1:
					q := protocol.SliceQuery{Limit: 3, HasOwner: true, Owner: "", IncludeClosed: true}
					if page == 1 {
						q.Cursor = &protocol.SliceCursor{Closed: true, SortAt: at, SliceID: largeID}
					}
					if msg.Opcode != protocol.C_ListTaskSlices || !bytes.Equal(msg.Data, protocol.EncodeListTaskSlices(0, q, id)) {
						t.Fatalf("bad slice query %x", msg.Data)
					}
					c.settleDataRead(id, msg.Opcode, &protocol.TaskSliceList{Success: true, HasMore: more, NextCursor: protocol.SliceCursor{Closed: true, SortAt: at, SliceID: largeID}, TotalCount: 7, Slices: []protocol.TaskSlice{{SliceID: largeID, Name: "slice", Flags: 1, Backlog: 2, Todo: 3, InProgress: 5, Done: 7, Blocked: 11, Notes: 13, Files: 17, LastMovedAt: at}}}, nil)
				case 2:
					after := uint64(0)
					if page == 1 {
						after = largeID + 1
					}
					if msg.Opcode != protocol.C_ListEdgesPaged || !bytes.Equal(msg.Data, protocol.EncodeListEdgesPaged(0, protocol.TargetTypeAsset, largeID, 3, after, id)) {
						t.Fatalf("bad edge query %x", msg.Data)
					}
					c.settleDataRead(id, msg.Opcode, &protocol.EdgeListPageResponse{TargetType: protocol.TargetTypeAsset, TargetID: largeID, HasMore: more, NextEdgeID: largeID + 1, TotalCount: 4, Edges: []protocol.Edge{{EdgeID: largeID + 1, SourceType: protocol.TargetTypeAsset, SourceID: 8, TargetType: protocol.TargetTypeAsset, TargetID: largeID, Relation: protocol.RelationMemberOf, CreatedAt: at}}}, nil)
				}
				resp := <-done
				if resp.IsError || !strings.Contains(resp.Content, "9007199254740993") {
					t.Fatal(resp.Content)
				}
				var out map[string]any
				if err := json.Unmarshal([]byte(resp.Content), &out); err != nil {
					t.Fatal(err)
				}
				if out["has_more"] != more || out["count"] != float64(1) {
					t.Fatal(out)
				}
				if index < 2 {
					if more {
						in["cursor"] = out["cursor"]
					} else if out["cursor"] != nil {
						t.Fatal("last page has cursor")
					}
				}
				if index == 0 && !strings.Contains(resp.Content, `"actual_start_at":"1790812799999999878"`) {
					t.Fatal(resp.Content)
				}
				if index == 1 && (!strings.Contains(resp.Content, `"files":17`) || !strings.Contains(resp.Content, `"blocked":11`)) {
					t.Fatal(resp.Content)
				}
				if index == 2 {
					in["after_edge_id"] = out["next_edge_id"]
					if !strings.Contains(resp.Content, `"direction":"incoming"`) || !strings.Contains(resp.Content, `"relation":7`) {
						t.Fatal(resp.Content)
					}
				}
			}
		})
	}
}

func TestGetTaskWireLifecycle(t *testing.T) {
	for _, mode := range []string{"success", "error", "not-found", "cancel", "disconnect"} {
		t.Run(mode, func(t *testing.T) {
			requests := make(chan []byte, 1)
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
				requests <- raw
				msg, err := protocol.ReadMessage(raw)
				if err != nil {
					return
				}
				id := binary.BigEndian.Uint32(msg.Data[16:])
				if mode == "success" || mode == "error" || mode == "not-found" {
					opcode, payload := uint16(protocol.S_TaskFull), dataTaskPayload(id, 7)
					if mode == "error" {
						opcode = protocol.S_ErrorResponse
						payload = make([]byte, 12)
						binary.BigEndian.PutUint16(payload, protocol.C_GetTask)
						binary.BigEndian.PutUint16(payload[2:], 4)
						copy(payload[4:], "nope")
						binary.BigEndian.PutUint32(payload[8:], id)
					}
					if mode == "not-found" {
						payload = make([]byte, 30)
						binary.BigEndian.PutUint16(payload[10:], 14)
						copy(payload[12:], "Task not found")
						binary.BigEndian.PutUint32(payload[26:], id)
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
			c := NewNRCClient(Config{}, "ws")
			c.conn = conn
			c.connected.Store(true)
			c.taskCache[0] = map[uint64]*protocol.Task{7: {ID: 7, Title: "stale"}}
			ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
			defer cancel()
			done := make(chan struct{})
			go func() { defer close(done); c.readPump(ctx) }()
			defer func() { conn.Close(); <-done }()
			result := make(chan dataReadResult, 1)
			go func() { task, e := c.GetTask(ctx, 0, 7); result <- dataReadResult{task, e} }()
			select {
			case raw := <-requests:
				msg, e := protocol.ReadMessage(raw)
				if e != nil || msg.Opcode != protocol.C_GetTask || !bytes.Equal(msg.Data, protocol.EncodeGetTask(0, 7, binary.BigEndian.Uint32(msg.Data[16:]))) {
					t.Fatal("incorrect request")
				}
			case <-ctx.Done():
				t.Fatal("no request")
			}
			if mode == "cancel" {
				cancel()
			}
			if mode == "disconnect" {
				c.Stop()
			}
			select {
			case r := <-result:
				switch mode {
				case "success":
					if r.err != nil || r.value.(protocol.Task).Title != "server task" {
						t.Fatalf("bad success %+v", r)
					}
				case "error":
					if r.err == nil || r.err.Error() != "nope" {
						t.Fatalf("bad error %+v", r)
					}
				case "not-found":
					if r.err == nil || !strings.Contains(r.err.Error(), "Task not found") {
						t.Fatalf("lost failed TaskFull: %+v", r)
					}
				case "cancel":
					if !errors.Is(r.err, context.Canceled) {
						t.Fatal(r.err)
					}
				case "disconnect":
					if !errors.Is(r.err, errNotConnected) {
						t.Fatal(r.err)
					}
				}
			case <-time.After(4 * time.Second):
				t.Fatal("read stuck")
			}
			c.dataReadsMu.Lock()
			remaining := len(c.dataReads)
			c.dataReadsMu.Unlock()
			if remaining != 0 || c.taskCache[0][7].Title != "stale" {
				t.Fatal("leak or cache update")
			}
		})
	}
}

func TestDataReadPageProtocolResponses(t *testing.T) {
	c := NewNRCClient(Config{}, "ws")
	for _, tc := range []struct {
		opcode, origin uint16
		payload        []byte
	}{
		{protocol.S_CalendarPage, protocol.C_QueryCalendar, make([]byte, 32)},
		{protocol.S_EdgeListPage, protocol.C_ListEdgesPaged, make([]byte, 37)},
		{protocol.S_TaskSliceList, protocol.C_ListTaskSlices, make([]byte, 47)},
	} {
		p := tc.payload
		switch tc.opcode {
		case protocol.S_CalendarPage:
			binary.BigEndian.PutUint32(p[28:], 13)
		case protocol.S_EdgeListPage:
			binary.BigEndian.PutUint32(p[33:], 13)
		case protocol.S_TaskSliceList:
			p[8] = 1
			binary.BigEndian.PutUint32(p[len(p)-4:], 13)
		}
		ch := make(chan dataReadResult, 1)
		c.dataReads = map[uint32]pendingDataRead{13: {tc.origin, ch}}
		c.handleDataRead(tc.opcode, p)
		select {
		case r := <-ch:
			if r.err != nil {
				t.Fatal(r.err)
			}
		default:
			t.Fatalf("opcode %d did not decode", tc.opcode)
		}
	}
}

func TestDataReadToolsConstructAndPrecision(t *testing.T) {
	tools, err := newADKDataReadTools(nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	for i, name := range []string{"query_calendar", "list_task_slices", "list_entity_links"} {
		if tools[i].Name() != name {
			t.Fatalf("wrong name %s", tools[i].Name())
		}
		info := fantasyToolInfo(tools[i].(adkRunnableTool))
		if len(info.Parameters) == 0 {
			t.Fatalf("empty schema for %s", name)
		}
		if i == 2 {
			idSchema := info.Parameters["id"].(map[string]any)
			if !strings.EqualFold(idSchema["type"].(string), "string") {
				t.Fatal("entity ID schema is not a string")
			}
		}
	}
	for _, s := range []string{"9007199254740993", "18446744073709551615"} {
		v, e := dataUint(s)
		if e != nil || dataString(v) != s {
			t.Fatalf("lost uint64 precision %s", s)
		}
	}
	var in dataCalendarInput
	if err = json.Unmarshal([]byte(`{"start":"2026-10-01T00:00:00Z","end":"2026-10-02T00:00:00Z","cursor":{"at":"1790812800000000001","kind":2,"id":"18446744073709551615"}}`), &in); err != nil {
		t.Fatal(err)
	}
	at, e := dataInt(in.Cursor.At)
	id, e2 := dataUint(in.Cursor.ID)
	if e != nil || e2 != nil || dataTime(at) != in.Cursor.At || dataString(id) != in.Cursor.ID {
		t.Fatal("cursor precision lost")
	}
	for _, s := range []string{"0", "-1", "1.2", "18446744073709551616"} {
		if _, e := dataUint(s); e == nil {
			t.Fatalf("accepted %s", s)
		}
	}
	c := NewNRCClient(Config{}, "ws")
	if _, e := c.GetTask(t.Context(), 1, 7); !errors.Is(e, errWorkspaceDataScope) {
		t.Fatal(e)
	}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, e := c.GetTask(ctx, 0, 7); !errors.Is(e, context.Canceled) {
		t.Fatal(e)
	}
	if len(c.dataReads) != 0 {
		t.Fatal("early error leaked waiter")
	}
}

func TestDataReadErrorOpcodeAndDisconnectCleanup(t *testing.T) {
	for _, origin := range []uint16{protocol.C_GetTask, protocol.C_QueryCalendar, protocol.C_ListTaskSlices, protocol.C_ListEdgesPaged} {
		c := NewNRCClient(Config{}, "ws")
		ch := make(chan dataReadResult, 1)
		c.dataReads = map[uint32]pendingDataRead{99: {origin, ch}}
		payload := make([]byte, 12)
		binary.BigEndian.PutUint16(payload, origin)
		binary.BigEndian.PutUint16(payload[2:], 4)
		copy(payload[4:], "nope")
		binary.BigEndian.PutUint32(payload[8:], 99)
		c.handleErrorResponse(payload)
		if r := <-ch; r.err == nil || r.err.Error() != "nope" {
			t.Fatalf("origin %d: %+v", origin, r)
		}
		c.dataReads = map[uint32]pendingDataRead{100: {origin, ch}}
		c.failDataReads(errNotConnected)
		if r := <-ch; !errors.Is(r.err, errNotConnected) {
			t.Fatal(r.err)
		}
		c.handleErrorResponse(payload)
		if len(c.dataReads) != 0 || len(ch) != 0 {
			t.Fatal("late response or disconnect leaked")
		}
	}
}
