package protocol

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestMetadataListCodecs(t *testing.T) {
	for _, encode := range []func(uint64, uint32) []byte{EncodeListSliceOwners, EncodeListTicketAssignees, EncodeListCalendarPeople} {
		if got := encode(12, 34); !bytes.Equal(got, EncodeListTaskProjects(12, 34)) {
			t.Fatalf("request: %x", got)
		}
	}
	wire := func(values []string) []byte {
		b := new(bytes.Buffer)
		binary.Write(b, binary.BigEndian, uint64(12))
		binary.Write(b, binary.BigEndian, uint16(len(values)))
		for _, v := range values {
			writeString(b, v)
		}
		b.WriteByte(1)
		binary.Write(b, binary.BigEndian, uint32(34))
		return b.Bytes()
	}
	for _, decode := range []func([]byte) (*StringList, error){DecodeSliceOwners, DecodeTicketAssignees, DecodeCalendarPeople} {
		good := wire([]string{"alice", "é"})
		r, err := decode(good)
		if err != nil || r.ConvID != 12 || r.CorrelationID != 34 || !r.HasMore || len(r.Values) != 2 {
			t.Fatalf("decoded %#v: %v", r, err)
		}
		for i := 0; i < len(good); i++ {
			if _, err := decode(good[:i]); err == nil {
				t.Fatalf("accepted truncation %d", i)
			}
		}
		badFlag := append([]byte(nil), good...)
		badFlag[len(badFlag)-5] = 2
		for _, bad := range [][]byte{wire([]string{""}), wire([]string{"a", "a"}), wire([]string{"z", "a"}), wire([]string{"\xff"}), append(good, 0), badFlag} {
			if _, err := decode(bad); err == nil {
				t.Fatalf("accepted %x", bad)
			}
		}
		if r, err := decode(wire(nil)); err != nil || r.Values == nil || len(r.Values) != 0 {
			t.Fatalf("empty: %#v %v", r, err)
		}
	}
}
