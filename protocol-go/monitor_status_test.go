package protocol

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"testing"
)

func TestMonitorStatusWireContract(t *testing.T) {
	want, _ := hex.DecodeString("0049123456780000000000000007000000000000000b0200000000000000091001")
	got, err := EncodeQueryMonitorStatus(MonitorStatusQuery{CorrelationID: 0x12345678, MonitorID: 7, CursorID: 11, CursorRank: 2, At: 9, Limit: 16, IncludeRetired: true})
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("%x %v", got, err)
	}
	filtered, err := EncodeQueryMonitorStatus(MonitorStatusQuery{Limit: 16, StateFilter: 2, Search: "#12"})
	if err != nil || len(filtered) != 37 || !bytes.Equal(filtered[31:], []byte{16, 0, 2, '#', '1', '2'}) {
		t.Fatalf("filtered: %x %v", filtered, err)
	}
	for _, q := range []MonitorStatusQuery{{Limit: 1, StateFilter: 4}, {Limit: 1, Search: "\xff"}, {Limit: 1, MonitorID: 7, Search: "a"}} {
		if _, err := EncodeQueryMonitorStatus(q); err == nil {
			t.Fatal("accepted invalid filter", q)
		}
	}
	for _, q := range []MonitorStatusQuery{{Limit: 0}, {Limit: 17}, {Limit: 1, CursorRank: 9}, {Limit: 1, CursorID: 1}, {Limit: 1, CursorRank: 1}, {Limit: 1, IncludeRetired: true}, {Limit: 1, At: -1}} {
		if _, err := EncodeQueryMonitorStatus(q); err == nil {
			t.Fatal("accepted invalid query", q)
		}
	}
	body := append([]byte{0x12, 0x34, 0x56, 0x78}, []byte(`{"version":1,"monitor_id":"7","at":"1790000000000000001","cursor_id":"18446744073709551615","cursor_rank":0,"has_more":false,"rows":[{"id":"18446744073709551615","status":"firing","value":null,"incident_id":"9007199254740993"}]}`)...)
	page, err := DecodeMonitorStatusPage(body)
	if err != nil || page.CorrelationID != 0x12345678 || len(page.Rows) != 1 || page.Rows[0].ID != "18446744073709551615" || page.Rows[0].IncidentID != "9007199254740993" || page.Rows[0].Value != nil {
		t.Fatalf("%+v %v", page, err)
	}
	for cut := 0; cut < len(body); cut++ {
		if _, err := DecodeMonitorStatusPage(body[:cut]); err == nil {
			t.Fatal("accepted truncated page", cut)
		}
	}
	page.Rows = make([]MonitorStatusRow, 17)
	data, _ := json.Marshal(page)
	if _, err := DecodeMonitorStatusPage(append([]byte{0, 0, 0, 1}, data...)); err == nil {
		t.Fatal("accepted oversized row count")
	}
}
