package main

import (
	"context"
	"encoding/binary"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestSourceWireBoundary(t *testing.T) {
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/test-workspace" || r.Header.Get("X-NRC-User-Type") != "bot" || r.Header.Get("X-NRC-Bot-Secret") != "fixture-secret" {
			t.Error("wrong workspace or bot identity")
		}
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.Close()
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		ready, _ := (&protocol.Message{Opcode: protocol.S_ServerReady}).Write()
		conn.WriteMessage(websocket.BinaryMessage, ready)
		_, wire, err := conn.ReadMessage()
		if err != nil {
			t.Error(err)
			return
		}
		msg, err := protocol.ReadMessage(wire)
		if err != nil {
			t.Error(err)
			return
		}
		if msg.Opcode != protocol.C_GetAsset || len(msg.Data) != 20 || binary.BigEndian.Uint64(msg.Data[:8]) != 0 || binary.BigEndian.Uint64(msg.Data[8:16]) != 987 || binary.BigEndian.Uint32(msg.Data[16:]) != 1 {
			t.Errorf("incorrect note request: %x", wire)
		}
		// A full asset with an ID different from the request must be refused.
		data := make([]byte, 55)
		binary.BigEndian.PutUint16(data[0:2], 5)
		binary.BigEndian.PutUint64(data[2:10], 986)
		data = append(data, protocol.EncodeAttachments(nil)...)
		data = binary.BigEndian.AppendUint32(data, 1)
		response, _ := (&protocol.Message{Opcode: protocol.S_AssetFull, Data: data}).Write()
		conn.WriteMessage(websocket.BinaryMessage, response)
	}))
	defer server.Close()
	s := nrcSource{strings.Replace(server.URL, "http", "ws", 1), "test-workspace", "fixture-secret"}
	if _, err := s.get(context.Background(), 987); err == nil || !strings.Contains(err.Error(), "requested workspace note") {
		t.Fatalf("wrong asset response accepted / fixture invalid: %v", err)
	}
}

// Opt-in integration against a disposable local NRC server, never a production URL.
func TestLiveNRC(t *testing.T) {
	server := os.Getenv("PUBLISH_TEST_NRC_URL")
	if server == "" {
		t.Skip("set PUBLISH_TEST_NRC_URL to a disposable NRC instance")
	}
	s := nrcSource{server, "publish-e2e", os.Getenv("NRC_BOT_SECRET")}
	ctx := context.Background()
	preview := `{"title":"Integration fixture","format":"markdown"}`
	payload := "## Beispiel\n\nUrsprünglicher Stand."
	data, err := s.request(ctx, protocol.C_CreateAsset, protocol.EncodeCreateAssetWithCorrelation(0, 5, 0, 0, preview, payload, 1), protocol.S_AssetCreated)
	if err != nil {
		t.Fatal(err)
	}
	created, err := protocol.DecodeAssetCreated(data)
	if err != nil {
		t.Fatal(err)
	}
	id := created.Asset.AssetID
	t.Cleanup(func() {
		s.request(ctx, protocol.C_DeleteAsset, protocol.EncodeDeleteAssetWithCorrelation(0, id, 1), protocol.S_AssetDeleted)
	})
	got, err := s.get(ctx, id)
	if err != nil || got.Payload != payload {
		t.Fatalf("get: %+v %v", got, err)
	}
	page, err := s.list(ctx, 0, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, note := range page.Assets {
		if note.AssetID == id {
			found = true
		}
	}
	if !found {
		t.Fatal("created note absent from paged source picker")
	}
	a := testApp(t)
	a.source = s
	r := candidate()
	r.SourceID = id
	r.Markdown = got.Payload
	r.SourceUpdated = got.UpdatedAt
	draft, err := a.store.create(r, "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.request(ctx, protocol.C_UpdateAsset, protocol.EncodeUpdateAssetWithCorrelation(0, id, preview, "Agent changed live source", 1), protocol.S_AssetUpdated); err != nil {
		t.Fatal(err)
	}
	if err := a.store.approve(draft.ID, "reviewer"); err != nil {
		t.Fatal(err)
	}
	article := request(a.public(), "GET", "/articles/einrichtung", nil, false)
	if article.Code != 200 || !strings.Contains(article.Body.String(), "Ursprünglicher Stand.") || strings.Contains(article.Body.String(), "Agent changed") {
		t.Fatal("live NRC edit leaked into publication")
	}
}
