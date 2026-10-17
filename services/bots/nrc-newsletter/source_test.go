package main

import (
	"context"
	"encoding/binary"
	"github.com/gorilla/websocket"
	p "github.com/heavyhorst/nrc/protocol-go"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestLivePagedContactWire(t *testing.T) {
	for _, wrong := range []bool{false, true} {
		t.Run(map[bool]string{false: "all pages", true: "foreign scope refused"}[wrong], func(t *testing.T) {
			up := websocket.Upgrader{}
			page := 0
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/fixed" || r.Header.Get("X-NRC-User-Type") != "bot" || r.Header.Get("X-NRC-Bot-Secret") != "bot-secret" {
					t.Error("wrong bot source authentication")
				}
				c, e := up.Upgrade(w, r, nil)
				if e != nil {
					t.Error(e)
					return
				}
				defer c.Close()
				c.SetReadDeadline(time.Now().Add(time.Second * 2))
				ready, _ := (&p.Message{Opcode: p.S_ServerReady}).Write()
				c.WriteMessage(websocket.BinaryMessage, ready)
				_, wire, e := c.ReadMessage()
				if e != nil {
					t.Error(e)
					return
				}
				m, e := p.ReadMessage(wire)
				if e != nil {
					t.Error(e)
					return
				}
				if m.Opcode != p.C_ListAssetsPaged || binary.BigEndian.Uint64(m.Data) != 0 || binary.BigEndian.Uint16(m.Data[8:]) != p.AssetTypeCustomerContact || m.Data[10] != 1 || binary.BigEndian.Uint16(m.Data[11:]) != 50 {
					t.Errorf("wrong contact request: %x", m.Data)
				}
				if page == 1 && (m.Data[13] != 1 || binary.BigEndian.Uint64(m.Data[14:]) != 100 || binary.BigEndian.Uint64(m.Data[22:]) != 1) {
					t.Error("cursor not forwarded exactly")
				}
				page++
				data := make([]byte, 36)
				data[8] = 1
				if page == 1 {
					data[9] = 1
				}
				binary.BigEndian.PutUint64(data[10:], 100)
				binary.BigEndian.PutUint64(data[18:], uint64(page))
				binary.BigEndian.PutUint32(data[26:], 2)
				binary.BigEndian.PutUint16(data[30:], 1)
				binary.BigEndian.PutUint32(data[32:], 1)
				if wrong {
					binary.BigEndian.PutUint64(data, 9)
				}
				// Asset full header: empty owner/body, metadata in Preview, no attachments.
				asset := make([]byte, 51)
				binary.BigEndian.PutUint16(asset, p.AssetTypeCustomerContact)
				binary.BigEndian.PutUint64(asset[2:], uint64(page))
				preview := `{"version":1,"title":"Contact","email":"CONTACT@example.com"}`
				asset = binary.BigEndian.AppendUint16(asset, uint16(len(preview)))
				asset = append(asset, preview...)
				asset = binary.BigEndian.AppendUint16(asset, 0)
				asset = append(asset, p.EncodeAttachments(nil)...)
				data = append(data, asset...)
				response, _ := (&p.Message{Opcode: p.S_AssetListPage, Data: data}).Write()
				c.WriteMessage(websocket.BinaryMessage, response)
			}))
			defer srv.Close()
			src := nrcSource{strings.Replace(srv.URL, "http", "ws", 1), "fixed", "bot-secret"}
			rows, e := src.contacts(context.Background())
			if wrong {
				if e == nil {
					t.Fatal("foreign workspace accepted")
				}
				return
			}
			if e != nil || len(rows) != 2 || rows[0].Email != "contact@example.com" || rows[1].ID != "2" {
				t.Fatalf("paged register: %+v %v", rows, e)
			}
		})
	}
}
