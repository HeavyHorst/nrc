package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"github.com/gorilla/websocket"
	p "github.com/heavyhorst/nrc/protocol-go"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestContactListingCursorAndBatchedCompanies(t *testing.T) {
	f := setup(t)
	const first uint64 = 9007199254740993
	var connections atomic.Int32
	var malformedBatch atomic.Int32
	up := websocket.Upgrader{}
	// Reuse wire fixtures, omitting the empty full-content payload length.
	header := func(kind uint16, id uint64, title string, archived bool, updated uint64) []byte {
		b := serviceAsset(kind, id, title, archived)
		b = b[:len(b)-2]
		preview := ""
		if archived {
			preview = `{"archived":true,"version":"legacy","title":42}`
		} else if kind == p.AssetTypeCustomerContact {
			preview = fmt.Sprintf(`{"version":1,"title":%q,"TITLE":42,"email":" CONTACT@Example.com "}`, title)
		}
		if preview != "" {
			b = binary.BigEndian.AppendUint16(b[:51], uint16(len(preview)))
			b = append(b, preview...)
			b = append(b, p.EncodeAttachments(nil)...)
		}
		binary.BigEndian.PutUint64(b[30:], updated)
		return b
	}
	page := func(more bool, updated int64, id uint64, total uint32, assets ...[]byte) []byte {
		b := serviceAssetPage(more, updated, id, assets...)
		b[8] = 0
		binary.BigEndian.PutUint32(b[26:], total)
		return b
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := up.Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer c.Close()
		connections.Add(1)
		c.SetReadDeadline(time.Now().Add(5 * time.Second))
		send := func(op uint16, data []byte) {
			b, _ := (&p.Message{Opcode: op, Data: data}).Write()
			if err := c.WriteMessage(websocket.BinaryMessage, b); err != nil {
				t.Error(err)
			}
		}
		send(p.S_ServerReady, nil)
		for {
			_, wire, err := c.ReadMessage()
			if err != nil {
				return
			}
			m, err := p.ReadMessage(wire)
			if err != nil {
				t.Error(err)
				return
			}
			switch m.Opcode {
			case p.C_ListAssetsPaged:
				if m.Data[len(m.Data)-1] != 1 || m.Data[10] != 0 {
					t.Error("active headers required")
				}
				if m.Data[13] == 0 {
					send(p.S_AssetListPage, page(true, 100, first-1, 3, header(9, first, "First", false, 100), header(9, first-1, "Second", false, 100)))
				} else {
					if binary.BigEndian.Uint64(m.Data[14:]) != 100 || binary.BigEndian.Uint64(m.Data[22:]) != first-1 {
						t.Error("cursor lost precision")
					}
					send(p.S_AssetListPage, page(false, 99, first-2, 3, header(9, first-2, "Last", false, 99)))
				}
			case p.C_ListEdgesPaged:
				id := binary.BigEndian.Uint64(m.Data[10:])
				edges := []p.Edge{}
				if id == first {
					for company := uint64(1); company <= 66; company++ {
						edges = append(edges, serviceEdge(company, id, company, p.RelationMemberOf))
					}
				} else if id == first-1 {
					edges = append(edges, serviceEdge(67, 2, id, p.RelationMemberOf))
				}
				send(p.S_EdgeListPage, serviceEdgePage(id, false, 0, edges...))
			case p.C_GetAssetsByIDs:
				count := int(binary.BigEndian.Uint16(m.Data[13:]))
				if count > 64 || m.Data[12] != 0 {
					t.Error("unbounded/full-content company batch")
				}
				assets := [][]byte{}
				for i := 0; i < count; i++ {
					id := binary.BigEndian.Uint64(m.Data[15+8*i:])
					if id == 4 {
						continue
					} // Deleted between membership and asset reads.
					kind := uint16(p.AssetTypeCustomerCompany)
					if id == 66 {
						kind = p.AssetTypeSlice
					}
					assets = append(assets, header(kind, id, fmt.Sprintf("Company %02d", id), id == 3, 0))
				}
				// A single batch can arrive in multiple response chunks.
				total := uint32(len(assets))
				mode := malformedBatch.Load()
				if mode == 3 {
					total = uint32(count + 1)
				}
				if len(assets) > 1 {
					if mode == 1 {
						send(p.S_AssetListPage, page(false, 0, 0, total, assets[:1]...))
						continue
					}
					send(p.S_AssetListPage, page(true, 0, 0, total, assets[:1]...))
					if mode == 3 {
						continue
					}
					assets = assets[1:]
				}
				if mode == 2 {
					total--
				}
				send(p.S_AssetListPage, page(false, 0, 0, total, assets...))
			default:
				t.Errorf("unexpected source opcode %d", m.Opcode)
				return
			}
		}
	}))
	defer srv.Close()
	f.a.source = nrcSource{strings.Replace(srv.URL, "http", "ws", 1), "w", "fixture-secret"}
	f.a.cfg.SearchURL = ":invalid" // Listing must work without a search service.
	f.a.s.Consent["contact@example.com"] = &consent{Status: "subscribed", Source: "DOI"}
	var result struct {
		Subscribers []struct {
			ID        string            `json:"contact_id"`
			Status    string            `json:"status"`
			Companies []p.SearchCompany `json:"companies"`
		} `json:"subscribers"`
		Total  int            `json:"total_count"`
		More   bool           `json:"has_more"`
		Cursor *contactCursor `json:"next_cursor"`
	}
	w := f.req("POST", "/api/subscribers/search", `{"query":"  ","limit":2}`)
	expect(t, w, 200)
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Subscribers) != 2 || result.Total != 3 || !result.More || result.Cursor == nil || result.Cursor.AssetID != first-1 {
		t.Fatalf("page: %s", w.Body.String())
	}
	if result.Subscribers[0].ID != "9007199254740993" || result.Subscribers[0].Status != "subscribed" || len(result.Subscribers[0].Companies) != 63 || result.Subscribers[0].Companies[62].Name != "Company 65" || len(result.Subscribers[1].Companies) != 1 || result.Subscribers[1].Companies[0].CustomerID != "2" {
		t.Fatalf("joined contacts: %s", w.Body.String())
	}
	body, _ := json.Marshal(map[string]any{"query": "", "limit": 2, "cursor": result.Cursor})
	w = f.req("POST", "/api/subscribers/search", string(body))
	expect(t, w, 200)
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Subscribers) != 1 || result.Subscribers[0].ID != "9007199254740991" || result.More || result.Cursor != nil || result.Total != 3 {
		t.Fatalf("last page: %s", w.Body.String())
	}
	if connections.Load() != 2 {
		t.Fatalf("expected one connection per page, got %d", connections.Load())
	}
	for mode, name := range []string{"premature final chunk", "changing total", "total exceeds requested IDs"} {
		t.Run(name, func(t *testing.T) {
			malformedBatch.Store(int32(mode + 1))
			expect(t, f.req("POST", "/api/subscribers/search", `{"query":"","limit":2}`), 503)
		})
	}
	expect(t, f.req("POST", "/api/subscribers/search", `{"query":"Company","cursor":{"updated_at":"100","asset_id":"1"}}`), 400)
}

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
