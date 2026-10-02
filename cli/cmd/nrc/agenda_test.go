package main

import (
	"bytes"
	"encoding/binary"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
	"github.com/heavyhorst/nrc/cli/pkg/config"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

func TestAgendaCommandsRejectAmbiguityWithoutMutation(t *testing.T) {
	// Two distinct legacy agendas after replay into workspace scope zero.
	var list bytes.Buffer
	for _, field := range []any{uint64(0), uint8(1), uint16(2), uint32(0)} {
		if err := binary.Write(&list, binary.BigEndian, field); err != nil {
			t.Fatal(err)
		}
	}
	for _, id := range []uint64{91, 37} {
		// Full asset with empty owner, preview, payload and attachments.
		for _, field := range []any{
			uint16(protocol.AssetTypeAgenda), id, uint16(0), uint64(0), uint16(0),
			int64(1), int64(2), uint64(0), uint8(0), uint32(0), uint16(0), uint16(0), uint16(0),
		} {
			if err := binary.Write(&list, binary.BigEndian, field); err != nil {
				t.Fatal(err)
			}
		}
	}
	response, err := (&protocol.Message{Opcode: protocol.S_AssetList, Data: list.Bytes()}).Write()
	if err != nil {
		t.Fatal(err)
	}
	for _, cmd := range []*cobra.Command{agendaShowCmd, agendaSetCmd} {
		t.Run(cmd.Name(), func(t *testing.T) {
			done := make(chan struct{})
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				defer close(done)
				upgrader := websocket.Upgrader{}
				ws, err := upgrader.Upgrade(w, r, nil)
				if err != nil {
					t.Error(err)
					return
				}
				defer ws.Close()
				_, request, err := ws.ReadMessage()
				if err != nil {
					t.Error(err)
					return
				}
				if len(request) < 10 || binary.BigEndian.Uint16(request) != protocol.C_ListAssets || binary.BigEndian.Uint64(request[2:]) != 0 {
					t.Errorf("expected workspace agenda list, got %x", request)
					return
				}
				if err := ws.WriteMessage(websocket.BinaryMessage, response); err != nil {
					t.Error(err)
					return
				}
				if _, request, err := ws.ReadMessage(); err == nil {
					t.Errorf("ambiguous agenda command sent a mutation: %x", request)
				}
			}))
			defer server.Close()
			t.Setenv("HOME", t.TempDir())
			if err := (&config.Config{Server: "ws" + strings.TrimPrefix(server.URL, "http") + "/", WorkspaceID: "agenda-test", RoomID: 73}).Save(); err != nil {
				t.Fatal(err)
			}
			err := cmd.RunE(cmd, []string{"must not replace either agenda"})
			if err == nil || !strings.Contains(err.Error(), "91 37") || !strings.Contains(err.Error(), "explicit ID") {
				t.Fatalf("expected actionable ambiguity error, got %v", err)
			}
			<-done
		})
	}
}

func TestAgendaSelectionAllowsEmptyAndSingle(t *testing.T) {
	for _, assets := range [][]protocol.Asset{nil, {{AssetID: 91}}} {
		if err := checkAgendaSelection(assets); err != nil {
			t.Fatal(err)
		}
	}
}
