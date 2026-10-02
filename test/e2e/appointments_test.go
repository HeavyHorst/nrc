package e2e

import (
	"encoding/binary"
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestAppointmentCalendarPersistence(t *testing.T) {
	dir := t.TempDir()
	workspace := fmt.Sprintf("e2e-appointment-%d", time.Now().UnixNano())
	server := startServerInWorkDir(t, dir)
	defer func() { server.stop(t) }()
	connect := func() *websocket.Conn {
		conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "appointment-owner"))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.Close() })
		mustSetReadDeadline(t, conn, 20*time.Second)
		mustExpectServerReady(t, conn)
		return conn
	}
	conn := connect()
	send := func(op uint16, body []byte) {
		t.Helper()
		if err := sendProtocolMessage(conn, op, body); err != nil {
			t.Fatal(err)
		}
	}
	preview := `{"version":1,"title":"Call \\ Alex","start_at":"100","end_at":"300","assignee":"alice","project":"NRC"}`
	send(protocol.C_CreateAsset, protocol.EncodeCreateAsset(0, protocol.AssetTypeAppointment, protocol.ParentTypeNone, 0, preview, ""))
	created, err := protocol.DecodeAssetCreated(mustReadUntilOpcode(t, conn, protocol.S_AssetCreated, 12))
	if err != nil {
		t.Fatal(err)
	}
	id := created.Asset.AssetID
	query := func(start, end uint64, want bool) {
		t.Helper()
		body := make([]byte, 52)
		binary.BigEndian.PutUint64(body[8:], start)
		binary.BigEndian.PutUint64(body[16:], end)
		binary.BigEndian.PutUint16(body[24:], 10)
		binary.BigEndian.PutUint32(body[48:], 91)
		send(protocol.C_QueryCalendar, body)
		page := mustReadUntilOpcode(t, conn, protocol.S_CalendarPage, 12)
		if len(page) < 32 {
			t.Fatalf("short page: %x", page)
		}
		count := binary.BigEndian.Uint16(page[8:])
		if !want {
			if count != 0 {
				t.Fatalf("unexpected appointments: %d", count)
			}
			return
		}
		if count != 1 || page[10] != 0 || page[28] != 2 || binary.BigEndian.Uint64(page[29:]) != id {
			t.Fatalf("wrong appointment page: %x", page)
		}
		if binary.BigEndian.Uint64(page[37:]) != start {
			t.Fatalf("overlap key not clamped: %x", page)
		}
		offset := 46
		for _, expected := range []string{`Call \ Alex`, "alice", "NRC"} {
			n := int(binary.BigEndian.Uint16(page[offset:]))
			offset += 2
			if string(page[offset:offset+n]) != expected {
				t.Fatalf("field got %q want %q", page[offset:offset+n], expected)
			}
			offset += n
		}
		if binary.BigEndian.Uint64(page[offset:]) != 100 || binary.BigEndian.Uint64(page[offset+8:]) != 300 {
			t.Fatalf("lost interval: %x", page)
		}
	}
	query(200, 250, true)
	query(300, 400, false)
	send(protocol.C_UpdateAsset, protocol.EncodeUpdateAsset(0, id, `{"version":1,"title":"bad","start_at":"100","end_at":"99"}`, ""))
	mustReadUntilOpcode(t, conn, protocol.S_ErrorResponse, 12)
	query(200, 250, true) // rejected writes cannot remove the old index entry
	conn.Close()
	server.stop(t)
	server = startServerInWorkDir(t, dir)
	conn = connect()
	query(200, 250, true) // actual WAL recovery, not just a client reload
	send(protocol.C_DeleteAsset, protocol.EncodeDeleteAsset(0, id))
	mustReadUntilOpcode(t, conn, protocol.S_AssetDeleted, 12)
	query(200, 250, false)
}
