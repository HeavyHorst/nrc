package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/gorilla/websocket"
	p "github.com/heavyhorst/nrc/protocol-go"
)

// Exercise real WebSocket framing and protocol decode, including negative ACKs.
func TestProtocolCreateAcknowledgement(t *testing.T) {
	for _, correlation := range []uint32{1, 0, 9} {
		t.Run(string(rune('0'+correlation)), func(t *testing.T) {
			var calls atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/tickets" || r.Header.Get("X-NRC-Bot-Nickname") != "nrc-tickets" || r.Header.Get("X-NRC-Bot-Secret") != "test-secret" {
					t.Error("missing bot auth/scope")
				}
				c, e := (&websocket.Upgrader{}).Upgrade(w, r, nil)
				if e != nil {
					return
				}
				defer c.Close()
				send := func(op uint16, data []byte) {
					b, e := (&p.Message{Opcode: op, Data: data}).Write()
					if e != nil {
						t.Error(e)
						return
					}
					c.WriteMessage(websocket.BinaryMessage, b)
				}
				send(p.S_ServerReady, nil)
				_, wire, e := c.ReadMessage()
				if e != nil {
					return
				}
				m, e := p.ReadMessage(wire)
				if e != nil || m.Opcode != p.C_CreateAsset {
					t.Error("wrong mutation")
					return
				}
				calls.Add(1)
				want := p.EncodeCreateAssetWithCorrelation(0, ticketType, 0, 0, "{}", "body", 1)
				if string(m.Data) != string(want) {
					t.Error("wrong request payload")
				}
				// Full asset wire: type,id,parent type/id,owner,created,updated,conv,
				// encoding,raw length,preview,payload,attachment count,correlation.
				b := []byte{}
				u16 := func(v uint16) { b = binary.BigEndian.AppendUint16(b, v) }
				u64 := func(v uint64) { b = binary.BigEndian.AppendUint64(b, v) }
				str := func(v string) { u16(uint16(len(v))); b = append(b, v...) }
				u16(ticketType)
				u64(42)
				u16(0)
				u64(0)
				str("bot")
				u64(1)
				u64(1)
				u64(0)
				b = append(b, 0)
				b = binary.BigEndian.AppendUint32(b, 4)
				str("{}")
				str("body")
				u16(0)
				b = binary.BigEndian.AppendUint32(b, correlation)
				send(p.S_AssetCreated, b)
			}))
			defer server.Close()
			s := nrcSource{strings.Replace(server.URL, "http:", "ws:", 1), "tickets", "test-secret"}
			a, e := s.create(t.Context(), p.Asset{AssetType: ticketType, Preview: "{}", Payload: "body"})
			if correlation == 1 {
				if e != nil || a.AssetID != 42 {
					t.Fatal(a, e)
				}
			} else if e == nil {
				t.Fatal("accepted wrong correlation")
			}
			if calls.Load() != 1 {
				t.Fatal("mutation was retried")
			}
		})
	}
}

// Opt-in against an isolated real NRC workspace with a current ticket-capable
// server. Creates persistent test records; never run against customer production.
func TestNRCIntegration(t *testing.T) {
	server := os.Getenv("TICKETS_INTEGRATION_SERVER")
	if server == "" {
		t.Skip("isolated NRC server not configured")
	}
	workspace, secret := os.Getenv("TICKETS_INTEGRATION_WORKSPACE"), os.Getenv("NRC_BOT_SECRET")
	if workspace == "" || secret == "" {
		t.Fatal("workspace and bot secret required")
	}
	s := nrcSource{server, workspace, secret}
	ctx := context.Background()
	b, _ := json.Marshal(ticketPreview{Version: 1, Title: "Portal integration test", Requester: "integration@example.test", RequesterName: "Integration", Status: "open"})
	attachment := p.Attachment{FileId: "att_0123456789abcdef0123456789abcdef", Filename: "Protocol attachment.txt", Size: 17, MimeType: "text/plain", UploadedAt: 12345}
	ticket, e := s.create(ctx, p.Asset{AssetType: ticketType, Preview: string(b), Payload: "Persisted original request", Attachments: []p.Attachment{attachment}})
	if e != nil {
		t.Fatal(e)
	}
	b, _ = json.Marshal(entryPreview{1, "customer_reply", "Integration"})
	entry, e := s.create(ctx, p.Asset{AssetType: entryType, ParentType: 2, ParentID: ticket.AssetID, Preview: string(b), Payload: "Persisted reply", Attachments: []p.Attachment{attachment}})
	if e != nil {
		t.Fatal(e)
	}
	for _, want := range []p.Asset{ticket, entry} {
		got, e := s.get(ctx, want.AssetID)
		if e != nil || got.Payload != want.Payload || got.Preview != want.Preview || got.ParentID != want.ParentID || !slices.Equal(got.Attachments, want.Attachments) {
			t.Fatalf("readback failed: %v", e)
		}
		assets, e := s.list(ctx, want.AssetType)
		if e != nil {
			t.Fatal(e)
		}
		found := false
		for _, a := range assets {
			found = found || a.AssetID == want.AssetID
		}
		if !found {
			t.Fatal("not in list")
		}
	}
}
