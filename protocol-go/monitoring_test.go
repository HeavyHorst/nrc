package protocol

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"math"
	"strings"
	"testing"
)

func TestMonitorDeliveryWireContract(t *testing.T) {
	want, _ := hex.DecodeString("004712345678000000000000000701020000000000000009000000000000000b066f70732d7631")
	r := MonitorDelivery{0x12345678, 7, 1, 2, 9, 11, "ops-v1"}
	got, err := EncodeMonitorDelivery(r)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("wire mismatch: %x %v", got, err)
	}
	r.Stream = 0
	if _, err = EncodeMonitorDelivery(r); err == nil {
		t.Fatal("export accepted route")
	}
	r.Route = ""
	r.Action = 4
	if _, err = EncodeMonitorDelivery(r); err == nil {
		t.Fatal("export can fail permanently")
	}
	r.Action = 1
	if _, err = EncodeMonitorDelivery(r); err == nil {
		t.Fatal("claim accepted settlement ID")
	}
	r.ID = 0
	r.Generation = 0
	if _, err := EncodeMonitorDelivery(r); err == nil {
		t.Fatal("removed export stream accepted")
	}
	body := append([]byte{0x12, 0x34, 0x56, 0x78}, []byte(`{"version":1,"state":2,"id":"18446744073709551615","generation":"11","created_at":"100","available_at":"100","lease_until":"60000000100","attempts":2,"payload":"{}"}`)...)
	result, err := DecodeMonitorDeliveryResult(body)
	if err != nil || result.CorrelationID != 0x12345678 || result.ID != "18446744073709551615" || result.Payload != "{}" {
		t.Fatalf("bad result: %+v %v", result, err)
	}
	for cut := 0; cut < len(body); cut++ {
		if _, err := DecodeMonitorDeliveryResult(body[:cut]); err == nil {
			t.Fatalf("accepted truncation at %d", cut)
		}
	}
	r.Action = 6
	if _, err := EncodeMonitorDelivery(r); err == nil {
		t.Fatal("discovery accepted export stream")
	}
	r.Stream = 1
	if b, err := EncodeMonitorDelivery(r); err != nil || len(b) != 33 {
		t.Fatal("discovery first page", err)
	}
	r.Route = "ops-v1"
	if b, err := EncodeMonitorDelivery(r); err != nil || len(b) != 39 {
		t.Fatal("discovery cursor", err)
	}
	r.ID = 1
	if _, err := EncodeMonitorDelivery(r); err == nil {
		t.Fatal("discovery accepted ID")
	}
	r.ID = 0
	r.Generation = 1
	if _, err := EncodeMonitorDelivery(r); err == nil {
		t.Fatal("discovery accepted generation")
	}
	r.Generation = 0
	r.Route = "bad/route"
	if _, err := EncodeMonitorDelivery(r); err == nil {
		t.Fatal("discovery accepted malformed cursor")
	}
	page := append([]byte{0, 0, 0, 9}, []byte(`{"version":1,"state":5,"id":"0","generation":"0","created_at":"0","available_at":"0","lease_until":"0","attempts":0,"payload":"","routes":["old-v1","ops-v1"],"next_route":"ops-v1"}`)...)
	gotPage, pageErr := DecodeMonitorDeliveryResult(page)
	if pageErr != nil || gotPage.State != 5 || gotPage.CorrelationID != 9 || len(gotPage.Routes) != 2 || gotPage.Routes[0] != "old-v1" || gotPage.NextRoute != "ops-v1" {
		t.Fatalf("bad discovery page: %+v %v", gotPage, pageErr)
	}
}

func TestMonitorStateWireContract(t *testing.T) {
	want, _ := hex.DecodeString("0048123456780000000000000007")
	got, err := EncodeGetMonitorState(7, 0x12345678)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("request: %x %v", got, err)
	}
	if _, err := EncodeGetMonitorState(0, 1); err == nil {
		t.Fatal("zero monitor")
	}
	body, _ := hex.DecodeString("1234567800000000000000070000000000000009ffffffffffffffff")
	state, err := DecodeMonitorState(body)
	if err != nil || state != (MonitorState{0x12345678, 7, 9, math.MaxUint64}) {
		t.Fatalf("state: %+v %v", state, err)
	}
	for cut := 0; cut < len(body); cut++ {
		if _, err := DecodeMonitorState(body[:cut]); err == nil {
			t.Fatal("accepted truncated state")
		}
	}
	if _, err := DecodeMonitorState(append(body, 0)); err == nil {
		t.Fatal("accepted trailing byte")
	}
}

func TestMonitorRunWireContract(t *testing.T) {
	want, err := hex.DecodeString("00441234567800000000000000070000000000000009000000000000000b00000100046469736b01401d000000000000")
	if err != nil {
		t.Fatal(err)
	}
	r := ApplyMonitorRun{CorrelationID: 0x12345678, MonitorID: 7, Revision: 9, Sequence: 11, Observations: []MonitorObservation{{"disk", 1, 7.25}}}
	got, err := EncodeApplyMonitorRun(r)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("wire mismatch: %x, %v", got, err)
	}
	r.Failed = true
	if _, err := EncodeApplyMonitorRun(r); err == nil {
		t.Fatal("partial failed run accepted")
	}
	r.Failed = false
	r.Observations = append(r.Observations, r.Observations[0])
	if _, err := EncodeApplyMonitorRun(r); err == nil {
		t.Fatal("duplicate identity accepted")
	}
	r.Observations = r.Observations[:1]
	r.Observations[0].Value = math.NaN()
	if _, err := EncodeApplyMonitorRun(r); err == nil {
		t.Fatal("NaN accepted")
	}
	ack, _ := hex.DecodeString("123456780000000000000007000000000000000b01")
	a, err := DecodeMonitorRunApplied(ack)
	if err != nil || a.CorrelationID != 0x12345678 || a.MonitorID != 7 || a.Sequence != 11 || !a.Replayed {
		t.Fatalf("ack: %+v %v", a, err)
	}
}

func TestMonitorControlWireContract(t *testing.T) {
	want, _ := hex.DecodeString("00451234567800000000000000070000000000000009000000000000000b02")
	r := ControlMonitorInstance{0x12345678, 7, 9, 11, RetireMonitorInstance}
	got, err := EncodeControlMonitorInstance(r)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("wire mismatch: %x %v", got, err)
	}
	for _, bad := range []ControlMonitorInstance{
		{1, 0, 9, 11, RetireMonitorInstance}, {1, 7, 0, 11, RetireMonitorInstance},
		{1, 7, 9, 0, RetireMonitorInstance}, {1, 7, 9, 11, 3},
	} {
		if _, err := EncodeControlMonitorInstance(bad); err == nil {
			t.Fatal("invalid action accepted")
		}
	}
	ack, _ := hex.DecodeString("123456780000000000000007000000000000000b000000000000000a01")
	a, err := DecodeMonitorInstanceControlled(ack)
	if err != nil || a != (MonitorInstanceControlled{0x12345678, 7, 11, 10, true}) {
		t.Fatalf("ack: %+v %v", a, err)
	}
	for cut := 0; cut < len(ack); cut++ {
		if _, err := DecodeMonitorInstanceControlled(ack[:cut]); err == nil {
			t.Fatal("short receipt accepted")
		}
	}
	bad := append(append([]byte{}, ack...), 0)
	if _, err := DecodeMonitorInstanceControlled(bad); err == nil {
		t.Fatal("trailing byte accepted")
	}
	ack[28] = 2
	if _, err := DecodeMonitorInstanceControlled(ack); err == nil {
		t.Fatal("invalid replay bit accepted")
	}
	ack[28] = 0
	binary.BigEndian.PutUint64(ack[20:], 1<<63)
	if _, err := DecodeMonitorInstanceControlled(ack); err == nil {
		t.Fatal("negative revision accepted")
	}
}

func TestIncidentActionWireContract(t *testing.T) {
	want, _ := hex.DecodeString("00461234567800000000000000070000000000000009010003626f62")
	r := ActOnIncident{0x12345678, 7, 9, AssignIncident, "bob"}
	got, err := EncodeActOnIncident(r)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("wire: %x %v", got, err)
	}
	for _, name := range []string{"", strings.Repeat("é", 16)} {
		r.Assignee = name
		b, err := EncodeActOnIncident(r)
		if err != nil || len(b) != 25+len(name) {
			t.Fatalf("valid assignment: %v", err)
		}
	}
	for _, bad := range []ActOnIncident{
		{1, 0, 9, AssignIncident, "bob"}, {1, 7, 0, AssignIncident, "bob"},
		{1, 7, 9, 2, ""}, {1, 7, 9, AcknowledgeIncident, "bob"},
		{1, 7, 9, AssignIncident, "\xff"}, {1, 7, 9, AssignIncident, strings.Repeat("é", 16) + "x"},
	} {
		if _, err := EncodeActOnIncident(bad); err == nil {
			t.Fatal("invalid action accepted")
		}
	}
	r.Action = AcknowledgeIncident
	r.Assignee = ""
	if b, err := EncodeActOnIncident(r); err != nil || len(b) != 25 {
		t.Fatalf("ack request: %v", err)
	}
	ack, _ := hex.DecodeString("123456780000000000000007000000000000000a01")
	a, err := DecodeIncidentActionApplied(ack)
	if err != nil || a != (IncidentActionApplied{0x12345678, 7, 10, true}) {
		t.Fatalf("receipt: %+v %v", a, err)
	}
	for cut := 0; cut < len(ack); cut++ {
		if _, err := DecodeIncidentActionApplied(ack[:cut]); err == nil {
			t.Fatal("short receipt accepted")
		}
	}
	if _, err := DecodeIncidentActionApplied(append(ack, 0)); err == nil {
		t.Fatal("trailing receipt byte accepted")
	}
	ack[20] = 2
	if _, err := DecodeIncidentActionApplied(ack); err == nil {
		t.Fatal("invalid replay flag")
	}
	ack[20] = 0
	binary.BigEndian.PutUint64(ack[12:], 1<<63)
	if _, err := DecodeIncidentActionApplied(ack); err == nil {
		t.Fatal("negative revision")
	}
}

func TestMonitorSnapshotWireContract(t *testing.T) {
	want, _ := hex.DecodeString("004812345678000000000000000700000000000000000000000000000009000000000000000b0000000000000000")
	got, err := EncodeGetMonitorSnapshot(MonitorState{0x12345678, 7, 9, 11}, 0, 0)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("request %x: %v", got, err)
	}
	if _, err = EncodeGetMonitorSnapshot(MonitorState{1, 7, 9, 11}, 1, 0); err == nil {
		t.Fatal("continuation without snapshot time")
	}
	b := make([]byte, 54)
	binary.BigEndian.PutUint32(b, 0x12345678)
	for offset, value := range map[int]uint64{4: 7, 12: 9, 20: 11, 28: 100, 36: 190} {
		binary.BigEndian.PutUint64(b[offset:], value)
	}
	binary.BigEndian.PutUint16(b[52:], 1)
	b = append(b, 0, 0, 0, 0, 0, 0, 0, 3, 0, 4, 'd', 'i', 's', 'k', 1, 0, 0, 0, 0, 0, 0, 0, 200)
	r, err := DecodeMonitorSnapshotPage(b)
	if err != nil || r.MonitorID != 7 || r.Revision != 9 || r.Sequence != 11 || r.At != 100 || r.Horizon != 190 || len(r.Instances) != 1 || r.Instances[0] != (MonitorAvailability{3, "disk", 1, 200}) {
		t.Fatalf("snapshot %+v: %v", r, err)
	}
	for cut := range len(b) {
		if _, err := DecodeMonitorSnapshotPage(b[:cut]); err == nil {
			t.Fatalf("accepted cut %d", cut)
		}
	}
	for _, offset := range []int{35, 36, 53, 63, 68} {
		bad := bytes.Clone(b)
		bad[offset] = 255
		if _, err := DecodeMonitorSnapshotPage(bad); err == nil {
			t.Fatalf("accepted corrupt offset %d", offset)
		}
	}
	if _, err := DecodeMonitorSnapshotPage(append(b, 0)); err == nil {
		t.Fatal("accepted trailing byte")
	}
}
