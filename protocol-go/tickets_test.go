package protocol

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"testing"
)

func TestTicketPageCodec(t *testing.T) {
	q, err := EncodeTicketQuery(42, json.RawMessage(`{"follow_up":"due"}`))
	if err != nil || binary.BigEndian.Uint32(q) != 42 || string(q[4:]) != `{"follow_up":"due"}` {
		t.Fatal(q, err)
	}
	if _, err := EncodeTicketQuery(1, json.RawMessage(`{`)); err == nil {
		t.Fatal("invalid JSON accepted")
	}
	for _, full := range []bool{false, true} {
		a := Asset{AssetType: AssetTypeTicket, AssetID: 7, Preview: `{}`, Payload: "body", PayloadRawLen: 4}
		wire := buildAssetHeaderBinary(a)
		if full {
			wire = buildFullAssetBinary(a)
		}
		b := make([]byte, 13)
		binary.BigEndian.PutUint32(b, 42)
		binary.BigEndian.PutUint32(b[4:], 2)
		copy(b[8:], `{}`)
		binary.BigEndian.PutUint16(b[10:], 1)
		if full {
			b[12] = 1
		}
		b = append(b, wire...)
		p, err := DecodeTicketPage(b)
		if err != nil || p.CorrelationID != 42 || p.FullContent != full || len(p.Assets) != 1 || p.Assets[0].AssetID != 7 {
			t.Fatal(p, err)
		}
		for n := 0; n < len(b); n++ {
			if _, err := DecodeTicketPage(b[:n]); err == nil {
				t.Fatalf("accepted truncation %d", n)
			}
		}
		for _, offset := range []int{4, 8, 12} {
			bad := append([]byte(nil), b...)
			bad[offset] = 255
			if _, err := DecodeTicketPage(bad); err == nil {
				t.Fatalf("accepted corruption at %d", offset)
			}
		}
		if _, err := DecodeTicketPage(append(b, 0)); err == nil {
			t.Fatal("accepted trailing byte")
		}
	}
}

func TestTicketDueMembershipUsesServerAndChunks(t *testing.T) {
	assets := make([]Asset, 101)
	for i := range assets {
		assets[i] = Asset{AssetID: uint64(i + 1), Preview: `{"follow_up_at":"1"}`}
	}
	// Server considers a locally future ticket due and a locally past ticket not due.
	assets[0].Preview = `{"follow_up_at":"9223372036854775807"}`
	calls := 0
	due, err := TicketDueMembership(assets, func(q json.RawMessage) (*TicketPage, error) {
		var v struct {
			FollowUp      string   `json:"follow_up"`
			SearchResults bool     `json:"search_results"`
			IDs           []string `json:"ids"`
			Limit         int      `json:"limit"`
		}
		if err := json.Unmarshal(q, &v); err != nil {
			t.Fatal(err)
		}
		want := 100
		if calls == 1 {
			want = 1
		}
		if v.FollowUp != "due" || !v.SearchResults || v.Limit != 100 || len(v.IDs) != want {
			t.Fatal(string(q))
		}
		calls++
		if calls == 1 {
			return &TicketPage{Metadata: json.RawMessage(`{}`), Assets: assets[:1]}, nil
		}
		return &TicketPage{Metadata: json.RawMessage(`{}`)}, nil
	})
	if err != nil || calls != 2 || !due[1] || due[2] || len(due) != 1 {
		t.Fatal(due, calls, err)
	}
	want := errors.New("server rejected query")
	if _, err := TicketDueMembership(assets, func(json.RawMessage) (*TicketPage, error) { return nil, want }); !errors.Is(err, want) {
		t.Fatal(err)
	}
}

func TestTicketDueMembershipFollowsByteBoundedPages(t *testing.T) {
	assets := []Asset{{AssetID: 11}, {AssetID: 22}}
	calls := 0
	due, err := TicketDueMembership(assets, func(q json.RawMessage) (*TicketPage, error) {
		calls++
		if calls == 1 {
			return &TicketPage{Metadata: json.RawMessage(`{"has_more":true,"cursor":{"id":"11","number":"42","text":""}}`), Assets: assets[:1]}, nil
		}
		var request struct {
			Cursor struct {
				ID string `json:"id"`
			} `json:"cursor"`
		}
		if err := json.Unmarshal(q, &request); err != nil || request.Cursor.ID != "11" {
			t.Fatal(string(q), err)
		}
		return &TicketPage{Metadata: json.RawMessage(`{"has_more":false}`), Assets: assets[1:]}, nil
	})
	if err != nil || calls != 2 || !due[11] || !due[22] {
		t.Fatal(due, calls, err)
	}
}
