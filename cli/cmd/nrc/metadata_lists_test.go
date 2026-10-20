package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/heavyhorst/nrc/cli/pkg/client"
	"github.com/heavyhorst/nrc/cli/pkg/conn"
	p "github.com/heavyhorst/nrc/protocol-go"
)

func TestMetadataLists(t *testing.T) {
	for _, tc := range []struct {
		path              []string
		request, response uint16
	}{
		{[]string{"slice", "owners"}, 65, 171}, {[]string{"ticket", "assignees"}, 66, 172}, {[]string{"calendar", "people"}, 67, 173},
	} {
		t.Run(strings.Join(tc.path, "_"), func(t *testing.T) {
			cmd, _, err := rootCmd.Find(tc.path)
			if err != nil || cmd.Name() != tc.path[1] || cmd.Annotations["mutation"] == "true" || !strings.Contains(cmd.Long, "independent of loaded records") {
				t.Fatalf("command: %v %v", cmd, err)
			}
			if err := cmd.Args(cmd, []string{"extra"}); err == nil {
				t.Fatal("accepted positional argument")
			}
			requests := make(chan *p.Message, 1)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				ws, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
				if err != nil {
					return
				}
				defer ws.Close()
				_, wire, err := ws.ReadMessage()
				if err != nil {
					return
				}
				req, err := p.ReadMessage(wire)
				if err != nil {
					t.Error(err)
					return
				}
				requests <- req
				for i, v := range []string{"alice", "é"} {
					b := new(bytes.Buffer)
					binary.Write(b, binary.BigEndian, uint64(0))
					binary.Write(b, binary.BigEndian, uint16(1))
					binary.Write(b, binary.BigEndian, uint16(len(v)))
					b.WriteString(v)
					b.WriteByte(byte(1 - i))
					binary.Write(b, binary.BigEndian, uint32(0))
					wire, _ := (&p.Message{Opcode: tc.response, Data: b.Bytes()}).Write()
					if err := ws.WriteMessage(websocket.BinaryMessage, wire); err != nil {
						t.Error(err)
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
			values, err := fetchMetadataList(&conn.Session{Client: c, RoomID: 7}, tc.request, tc.response)
			if err != nil || !reflect.DeepEqual(values, []string{"alice", "é"}) {
				t.Fatalf("values %v error %v", values, err)
			}
			req := <-requests
			if req.Opcode != tc.request || !bytes.Equal(req.Data, make([]byte, 12)) {
				t.Fatalf("request %#v", req)
			}
		})
	}
}
