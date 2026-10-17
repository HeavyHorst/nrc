package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	p "github.com/heavyhorst/nrc/protocol-go"
)

type serviceWireStep struct {
	opcode, response uint16
	request, data    []byte
}

// Every exchange uses a fresh connection, just as the real source does. Compare
// the entire request, including scope, limits, cursors and correlation IDs.
func serviceWireSource(t *testing.T, steps []serviceWireStep) nrcSource {
	t.Helper()
	var calls atomic.Int32
	up := websocket.Upgrader{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/fixed" || r.Header.Get("X-NRC-User-Type") != "bot" || r.Header.Get("X-NRC-Bot-Secret") != "fixture-secret" || r.Header.Get("X-NRC-Bot-Nickname") != "nrc-newsletter" {
			t.Error("incorrect source scope or bot authentication")
		}
		c, err := up.Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer c.Close()
		c.SetReadDeadline(time.Now().Add(3 * time.Second))
		c.SetWriteDeadline(time.Now().Add(3 * time.Second))
		send := func(op uint16, data []byte) bool {
			wire, err := (&p.Message{Opcode: op, Data: data}).Write()
			if err == nil {
				err = c.WriteMessage(websocket.BinaryMessage, wire)
			}
			if err != nil {
				t.Error(err)
			}
			return err == nil
		}
		if !send(p.S_ServerReady, nil) {
			return
		}
		kind, wire, err := c.ReadMessage()
		if err != nil {
			t.Error(err)
			return
		}
		index := int(calls.Add(1)) - 1
		if index >= len(steps) {
			t.Error("unexpected extra source request")
			return
		}
		step := steps[index]
		m, err := p.ReadMessage(wire)
		if err != nil {
			t.Error(err)
			return
		}
		if kind != websocket.BinaryMessage || m.Opcode != step.opcode || !bytes.Equal(m.Data, step.request) {
			t.Errorf("request %d: opcode=%d data=%x; want opcode=%d data=%x", index, m.Opcode, m.Data, step.opcode, step.request)
		}
		send(step.response, step.data)
	}))
	t.Cleanup(func() {
		srv.Close()
		if n := int(calls.Load()); n != len(steps) {
			t.Errorf("received %d requests, want %d", n, len(steps))
		}
	})
	return nrcSource{strings.Replace(srv.URL, "http", "ws", 1), "fixed", "fixture-secret"}
}

func serviceAsset(kind uint16, id uint64, title string, archived bool, companies ...string) []byte {
	preview, _ := json.Marshal(map[string]any{"version": 1, "title": title, "email": " CONTACT@Example.com ", "archived": archived, "service_for": companies})
	b := make([]byte, 51) // Full asset header, empty owner and content.
	binary.BigEndian.PutUint16(b, kind)
	binary.BigEndian.PutUint64(b[2:], id)
	b = binary.BigEndian.AppendUint16(b, uint16(len(preview)))
	b = append(b, preview...)
	b = binary.BigEndian.AppendUint16(b, 0)
	return append(b, p.EncodeAttachments(nil)...)
}

func serviceAssetPage(more bool, updated int64, id uint64, assets ...[]byte) []byte {
	b := make([]byte, 36)
	b[8] = 1 // Full content.
	if more {
		b[9] = 1
	}
	binary.BigEndian.PutUint64(b[10:], uint64(updated))
	binary.BigEndian.PutUint64(b[18:], id)
	binary.BigEndian.PutUint32(b[26:], uint32(len(assets)))
	binary.BigEndian.PutUint16(b[30:], uint16(len(assets)))
	binary.BigEndian.PutUint32(b[32:], 1)
	for _, a := range assets {
		b = append(b, a...)
	}
	return b
}

func serviceEdge(id, source, target uint64, relation uint16) p.Edge {
	return p.Edge{EdgeID: id, SourceType: p.TargetTypeAsset, SourceID: source, TargetType: p.TargetTypeAsset, TargetID: target, Relation: relation}
}

func serviceEdgePage(company uint64, more bool, next uint64, edges ...p.Edge) []byte {
	b := make([]byte, 37)
	binary.BigEndian.PutUint16(b[8:], p.TargetTypeAsset)
	binary.BigEndian.PutUint64(b[10:], company)
	if more {
		b[18] = 1
	}
	binary.BigEndian.PutUint64(b[19:], next)
	binary.BigEndian.PutUint32(b[27:], uint32(len(edges)))
	binary.BigEndian.PutUint16(b[31:], uint16(len(edges)))
	binary.BigEndian.PutUint32(b[33:], 1)
	for _, e := range edges {
		b = binary.BigEndian.AppendUint64(b, e.EdgeID)
		b = binary.BigEndian.AppendUint64(b, e.ConvID)
		b = binary.BigEndian.AppendUint16(b, e.SourceType)
		b = binary.BigEndian.AppendUint64(b, e.SourceID)
		b = binary.BigEndian.AppendUint16(b, e.TargetType)
		b = binary.BigEndian.AppendUint64(b, e.TargetID)
		b = binary.BigEndian.AppendUint16(b, e.Relation)
		b = binary.BigEndian.AppendUint64(b, uint64(e.CreatedAt))
		b = binary.BigEndian.AppendUint16(b, uint16(len(e.CreatedBy)))
		b = append(b, e.CreatedBy...)
	}
	return b
}

func serviceAssetsStep(kind uint16, cursor bool, updated int64, id uint64, data []byte) serviceWireStep {
	return serviceWireStep{p.C_ListAssetsPaged, p.S_AssetListPage, p.EncodeListAssetsPagedWithCorrelation(0, kind, true, 50, cursor, updated, id, 1), data}
}

func serviceEdgesStep(company, after uint64, data []byte) serviceWireStep {
	return serviceWireStep{p.C_ListEdgesPaged, p.S_EdgeListPage, p.EncodeListEdgesPaged(0, p.TargetTypeAsset, company, 250, after, 1), data}
}

func TestCustomerSourceServiceMembershipWire(t *testing.T) {
	for _, directory := range []bool{false, true} {
		t.Run(map[bool]string{false: "service roles", true: "subscriber directory"}[directory], func(t *testing.T) {
			ct, co := uint16(p.AssetTypeCustomerContact), uint16(p.AssetTypeCustomerCompany)
			steps := []serviceWireStep{
				serviceAssetsStep(ct, false, 0, 0, serviceAssetPage(true, 101, 1,
					serviceAsset(ct, 1, "Forward", false, "10", "20"))),
				serviceAssetsStep(ct, true, 101, 1, serviceAssetPage(false, 0, 0,
					serviceAsset(ct, 2, "Reverse", false, "10"),
					serviceAsset(ct, 3, "Stale nomination", false, "10"),
					serviceAsset(ct, 4, "Wrong relation", false, "10"),
					serviceAsset(ct, 5, "Archived", true, "10"),
					serviceAsset(ct, 6, "Not nominated", false),
					serviceAsset(ct, 7, "Archived company role", false, "30"))),
				serviceAssetsStep(co, false, 0, 0, serviceAssetPage(true, 202, 10,
					serviceAsset(co, 10, "Active", false))),
				serviceAssetsStep(co, true, 202, 10, serviceAssetPage(false, 0, 0,
					serviceAsset(co, 20, "Stale role only", false),
					serviceAsset(co, 30, "Archived company", true),
					serviceAsset(co, 40, "No roles", false))),
				serviceEdgesStep(10, 0, serviceEdgePage(10, true, 101,
					serviceEdge(101, 1, 10, p.RelationMemberOf))),
				serviceEdgesStep(10, 101, serviceEdgePage(10, false, 0,
					serviceEdge(102, 10, 2, p.RelationMemberOf),
					serviceEdge(103, 4, 10, p.RelationRelatedTo),
					serviceEdge(104, 5, 10, p.RelationMemberOf),
					serviceEdge(105, 6, 10, p.RelationMemberOf))),
				serviceEdgesStep(20, 0, serviceEdgePage(20, false, 0)),
			}
			if directory {
				steps = append(steps, serviceEdgesStep(40, 0, serviceEdgePage(40, false, 0, serviceEdge(106, 40, 6, p.RelationMemberOf))))
			}
			src := serviceWireSource(t, steps)
			var got []customer
			var err error
			if directory {
				got, err = src.directory(context.Background())
			} else {
				got, err = src.customers(context.Background())
			}
			want := []customer{
				{ID: "10", Name: "Active", Contacts: []contact{{"1", "Forward", "contact@example.com"}, {"2", "Reverse", "contact@example.com"}}},
				{ID: "20", Name: "Stale role only", Contacts: []contact{}},
				{ID: "40", Name: "No roles", Contacts: []contact{}},
			}
			if directory {
				want[0].Members = []contact{{"1", "Forward", "contact@example.com"}, {"2", "Reverse", "contact@example.com"}, {"6", "Not nominated", "contact@example.com"}}
				want[2].Members = []contact{{"6", "Not nominated", "contact@example.com"}}
			}
			if err != nil || !reflect.DeepEqual(got, want) {
				t.Fatalf("customers = %#v, %v; want %#v", got, err, want)
			}
		})
	}
}

func TestCustomerSourceRejectsForeignWirePages(t *testing.T) {
	for _, field := range []string{"asset scope", "asset correlation", "asset record scope", "company scope", "edge scope", "edge target type", "edge target ID", "edge correlation", "edge record scope"} {
		t.Run(field, func(t *testing.T) {
			ct, co := uint16(p.AssetTypeCustomerContact), uint16(p.AssetTypeCustomerCompany)
			a := serviceAsset(ct, 1, "Contact", false, "10")
			if field == "asset record scope" {
				binary.BigEndian.PutUint64(a[38:], 99)
			}
			contacts := serviceAssetPage(false, 0, 0, a)
			companies := serviceAssetPage(false, 0, 0, serviceAsset(co, 10, "Company", false))
			edge := serviceEdge(1, 1, 10, p.RelationMemberOf)
			if field == "edge record scope" {
				edge.ConvID = 99
			}
			edges := serviceEdgePage(10, false, 0, edge)
			switch field {
			case "asset scope":
				binary.BigEndian.PutUint64(contacts, 99)
			case "asset correlation":
				binary.BigEndian.PutUint32(contacts[32:], 99)
			case "company scope":
				binary.BigEndian.PutUint64(companies, 99)
			case "edge scope":
				binary.BigEndian.PutUint64(edges, 99)
			case "edge target type":
				binary.BigEndian.PutUint16(edges[8:], 0)
			case "edge target ID":
				binary.BigEndian.PutUint64(edges[10:], 99)
			case "edge correlation":
				binary.BigEndian.PutUint32(edges[33:], 99)
			}
			steps := []serviceWireStep{serviceAssetsStep(ct, false, 0, 0, contacts)}
			if !strings.HasPrefix(field, "asset") {
				steps = append(steps, serviceAssetsStep(co, false, 0, 0, companies))
				if field != "company scope" {
					steps = append(steps, serviceEdgesStep(10, 0, edges))
				}
			}
			src := serviceWireSource(t, steps)
			got, err := src.customers(context.Background())
			if err == nil || got != nil {
				t.Fatalf("foreign %s accepted: customers=%+v err=%v", field, got, err)
			}
		})
	}
}
