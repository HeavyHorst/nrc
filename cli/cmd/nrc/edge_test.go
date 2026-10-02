package main

import (
	"context"
	"encoding/binary"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/heavyhorst/nrc/cli/pkg/client"
	"github.com/heavyhorst/nrc/cli/pkg/conn"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestEdgeListExposesAutomaticPagination(t *testing.T) {
	flag := edgeListCmd.Flags().Lookup("page-size")
	if flag == nil || flag.DefValue != "250" || !strings.Contains(edgeListCmd.Long, "All pages are followed") {
		t.Fatalf("edge list pagination is not visible in command help: flag=%v help=%q", flag, edgeListCmd.Long)
	}
}

func TestFetchAllEdgesPagedFollowsCursor(t *testing.T) {
	requests := make(chan *protocol.Message, 2)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		for i, edgeID := range []uint64{10, 20} {
			_, wire, err := ws.ReadMessage()
			if err != nil {
				return
			}
			request, err := protocol.ReadMessage(wire)
			if err != nil {
				return
			}
			requests <- request
			response := &protocol.Message{
				Opcode: protocol.S_AllEdgeListPage,
				Data:   testAllEdgePage(7, i == 0, edgeID, 2, edgeID),
			}
			wire, err = response.Write()
			if err != nil {
				return
			}
			if err := ws.WriteMessage(websocket.BinaryMessage, wire); err != nil {
				return
			}
		}
	}))
	defer server.Close()

	c := client.New("ws"+strings.TrimPrefix(server.URL, "http")+"/", "workspace")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.Connect(ctx); err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	edges, err := fetchAllEdgesPaged(&conn.Session{Client: c, RoomID: 7}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(edges) != 2 || edges[0].EdgeID != 10 || edges[1].EdgeID != 20 {
		t.Fatalf("edges = %#v", edges)
	}

	first, second := <-requests, <-requests
	if first.Opcode != protocol.C_ListAllEdgesPaged || binary.BigEndian.Uint16(first.Data[8:]) != 1 || binary.BigEndian.Uint64(first.Data[10:]) != 0 {
		t.Fatalf("first request = opcode %d data %x", first.Opcode, first.Data)
	}
	if second.Opcode != protocol.C_ListAllEdgesPaged || binary.BigEndian.Uint64(second.Data[10:]) != 10 {
		t.Fatalf("second request = opcode %d data %x", second.Opcode, second.Data)
	}
}

func testAllEdgePage(convID uint64, hasMore bool, nextEdgeID uint64, total uint32, edgeID uint64) []byte {
	data := make([]byte, 27+48)
	binary.BigEndian.PutUint64(data[0:], convID)
	if hasMore {
		data[8] = 1
	}
	binary.BigEndian.PutUint64(data[9:], nextEdgeID)
	binary.BigEndian.PutUint32(data[17:], total)
	binary.BigEndian.PutUint16(data[21:], 1)
	binary.BigEndian.PutUint64(data[27:], edgeID)
	binary.BigEndian.PutUint64(data[35:], convID)
	binary.BigEndian.PutUint16(data[43:], protocol.TargetTypeTask)
	binary.BigEndian.PutUint64(data[45:], edgeID)
	binary.BigEndian.PutUint16(data[53:], protocol.TargetTypeAsset)
	binary.BigEndian.PutUint64(data[55:], edgeID+1)
	binary.BigEndian.PutUint16(data[63:], 1)
	return data
}
