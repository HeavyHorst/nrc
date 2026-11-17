package protocol

import (
	"encoding/binary"
	"fmt"
	"strings"
	"testing"
)

func TestChronicleRequestInterop(t *testing.T) {
	r := ChronicleRequest{Op: "claim", Consumer: ChronicleConsumerVersion, NoteID: "18446744073709551615", Sources: []string{"1", "9007199254740993"}}
	frame, err := EncodeChronicleRequest(r, 0x01020304)
	if err != nil {
		t.Fatal(err)
	}
	// Shared verbatim with protocol/chronicle_test.odin.
	want := `{"op":"claim","consumer":"chronicle-v1","note_id":"18446744073709551615","sources":["1","9007199254740993"]}`
	if binary.BigEndian.Uint16(frame) != 74 || string(frame[2:len(frame)-4]) != want || binary.BigEndian.Uint32(frame[len(frame)-4:]) != 0x01020304 {
		t.Fatalf("wrong wire: %x", frame)
	}
	for _, op := range []string{"list", "claim", "chunk", "reserve", "commit", "retry", "status", "history", "gaps", "delete"} {
		if _, err := EncodeChronicleRequest(ChronicleRequest{Op: op}, 0); err != nil {
			t.Fatal(err)
		}
	}
}

func TestChronicleRequestBounds(t *testing.T) {
	valid := ChronicleRequest{Op: "commit", NoteID: "0", Cursor: "18446744073709551615", Summary: strings.Repeat("é", 2048), Model: strings.Repeat("x", 128), Limit: 65535, Field: 255, Offset: 4294967295, Length: 65535, InputTokens: 4294967295, OutputTokens: 4294967295}
	for i := 1; i <= 32; i++ {
		valid.Sources = append(valid.Sources, fmt.Sprint(i))
	}
	if _, err := EncodeChronicleRequest(valid, ^uint32(0)); err != nil {
		t.Fatal(err)
	}
	bad := []ChronicleRequest{
		{Op: "unknown"}, {Op: "list", Summary: strings.Repeat("x", 4097)},
		{Op: "list", Model: strings.Repeat("é", 65)}, {Op: "list", Summary: "\xff"},
		{Op: "list", Consumer: "\xff"}, {Op: "list", Reason: strings.Repeat("x", 129)},
		{Op: "list", Sources: []string{"0"}}, {Op: "list", Sources: []string{"2", "1"}},
		{Op: "list", Sources: []string{"1", "1"}}, {Op: "list", Sources: append(valid.Sources, "33")},
	}
	for _, id := range []string{"01", "-1", "+1", " 1", "1.0", "18446744073709551616", "١"} {
		bad = append(bad, ChronicleRequest{Op: "list", NoteID: id})
	}
	for _, r := range bad {
		if _, err := EncodeChronicleRequest(r, 0); err == nil {
			t.Fatalf("accepted %#v", r)
		}
	}
}

func chronicleResponseFixture(data string) []byte {
	return append([]byte{1, 2, 3, 4}, []byte(data)...)
}

func TestChronicleResponsePrecision(t *testing.T) {
	r, err := DecodeChronicleResponse(chronicleResponseFixture(`{"status":"claimed","epoch":"18446744073709551615","generation":"9007199254740993","raw_bytes":18446744073709551615,"sources":["9007199254740993"],"inputs":[{"source_id":"9007199254740993","note_id":"18446744073709551615","lengths":[0,1,2,3,4,5],"before_present":true,"before_hash":"abcdef"}],"entries":[{"generation":"9007199254740993","source_available":true}],"chunk":"YQ==","more":true}`))
	if err != nil {
		t.Fatal(err)
	}
	if r.CorrelationID != 0x01020304 || r.Epoch != "18446744073709551615" || r.RawBytes != ^uint64(0) || r.Inputs[0].SourceID != "9007199254740993" || len(r.Inputs[0].Lengths) != 6 || r.Entries[0].Generation != r.Generation || r.Chunk != "YQ==" || !r.More {
		t.Fatalf("wrong decode: %#v", r)
	}
	for _, status := range []string{"claimed", "empty", "busy", "committed", "acknowledged", "gap", "deleted", "forbidden", "expired", "budget", "backoff"} {
		if _, err := DecodeChronicleResponse(chronicleResponseFixture(fmt.Sprintf(`{"status":%q}`, status))); err != nil {
			t.Fatal(err)
		}
	}
}

func TestChronicleResponseInvalidAndFrameBounds(t *testing.T) {
	for _, data := range []string{`null`, `[]`, `1`, `{"note_id":9007199254740993}`, `{"raw_bytes":-1}`, `{} {}`, `{`, "{\"status\":\"\xff\"}"} {
		if _, err := DecodeChronicleResponse(chronicleResponseFixture(data)); err == nil {
			t.Fatalf("accepted %q", data)
		}
	}
	for n := 0; n < 6; n++ {
		if _, err := DecodeChronicleResponse(make([]byte, n)); err == nil {
			t.Fatalf("accepted length %d", n)
		}
	}
	// Whitespace counts toward the full frame cap, including opcode and correlation.
	exact := chronicleResponseFixture("{}" + strings.Repeat(" ", MaxProtocolPayloadSize-8))
	if _, err := DecodeChronicleResponse(exact); err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeChronicleResponse(append(exact, ' ')); err == nil {
		t.Fatal("accepted oversized frame")
	}
}

func TestChronicleHumanReadContract(t *testing.T) {
	frame, err := EncodeChronicleRequest(ChronicleRequest{Op: "gaps", NoteID: "18446744073709551615", Cursor: "9007199254740993", Limit: 16}, 73)
	if err != nil || string(frame[2:len(frame)-4]) != `{"op":"gaps","note_id":"18446744073709551615","cursor":"9007199254740993","limit":16}` {
		t.Fatalf("gaps request: %s, %v", frame, err)
	}
	r, err := DecodeChronicleResponse(chronicleResponseFixture(`{"status":"ok","can_delete":true,"processing":1,"failed":2,"acknowledged":3,"gap_count":4,"expired":5,"cursor":"9007199254740993","more":true,"gaps":[{"first_source":"9007199254740993","last_source":"18446744073709551615","note_id":"18446744073709551615","first_at":"9007199254740993","last_at":"18446744073709551615","reason":"expired","input_count":18446744073709551615,"source_available":false}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if !r.CanDelete || r.Processing != 1 || r.Failed != 2 || r.Acknowledged != 3 || r.GapCount != 4 || r.Expired != 5 || len(r.Gaps) != 1 || r.Gaps[0].InputCount != ^uint64(0) || r.Gaps[0].LastSource != "18446744073709551615" || r.Gaps[0].FirstAt != "9007199254740993" || r.Gaps[0].SourceAvailable {
		t.Fatalf("lost gap/status values: %+v", r)
	}
	for _, data := range []string{`{"gaps":[{"first_source":9007199254740993}]}`, `{"gaps":[{"last_at":9007199254740993}]}`, `{"gaps":[{"input_count":-1}]}`, `{"processing":18446744073709551616}`, `{"can_delete":"true"}`} {
		if _, err := DecodeChronicleResponse(chronicleResponseFixture(data)); err == nil {
			t.Fatalf("accepted %s", data)
		}
	}
	legacy, err := DecodeChronicleResponse(chronicleResponseFixture(`{"status":"ok"}`))
	if err != nil || legacy.CanDelete {
		t.Fatal("missing permission must fail closed")
	}
}
