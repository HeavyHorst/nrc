package protocol

import (
	"encoding/binary"
	"math"
	"testing"
)

func TestEncodeGraphRankWithCorrelation(t *testing.T) {
	payload, err := EncodeGraphRankWithCorrelation(WorkspaceDataConvID, []GraphRankEntity{{Type: TargetTypeTask, ID: 11}}, []GraphRankEntity{{Type: TargetTypeAsset, ID: 22}}, 2, 3, 1, 50, 99)
	if err != nil {
		t.Fatal(err)
	}
	if len(payload) != 39 || binary.BigEndian.Uint64(payload) != 0 || payload[8] != 1 || payload[19] != 1 || binary.BigEndian.Uint32(payload[len(payload)-4:]) != 99 {
		t.Fatalf("unexpected graph rank payload: %v", payload)
	}
}

func TestEncodeGraphRankRejectsInvalidEntity(t *testing.T) {
	_, err := EncodeGraphRankWithCorrelation(WorkspaceDataConvID, []GraphRankEntity{{Type: 99, ID: 11}}, nil, 2, 3, 1, 50, 99)
	if err == nil {
		t.Fatal("expected invalid graph rank anchor to fail")
	}
}

func TestDecodeGraphRankResult(t *testing.T) {
	payload := make([]byte, 0, 80)
	put16 := func(v uint16) { var b [2]byte; binary.BigEndian.PutUint16(b[:], v); payload = append(payload, b[:]...) }
	put32 := func(v uint32) { var b [4]byte; binary.BigEndian.PutUint32(b[:], v); payload = append(payload, b[:]...) }
	put64 := func(v uint64) { var b [8]byte; binary.BigEndian.PutUint64(b[:], v); payload = append(payload, b[:]...) }
	put64(7)
	payload = append(payload, 1)
	put16(1)
	put16(TargetTypeTask)
	put64(11)
	put64(math.Float64bits(2.5))
	payload = append(payload, 1, 0, 1, 1)
	put64(42)
	put16(1)
	put64(42)
	put16(TargetTypeTask)
	put64(11)
	put16(TargetTypeAsset)
	put64(22)
	put16(RelationReferences)
	put32(99)

	result, err := DecodeGraphRankResult(payload)
	if err != nil {
		t.Fatal(err)
	}
	if result.ConvID != 7 || !result.Truncated || result.CorrelationID != 99 || len(result.Entries) != 1 || result.Entries[0].Score != 2.5 || result.Entries[0].Paths[0].EdgeIDs[0] != 42 || len(result.Edges) != 1 || result.Edges[0].TargetID != 22 {
		t.Fatalf("unexpected graph rank result: %#v", result)
	}

	for _, test := range []struct {
		name   string
		mutate func([]byte)
	}{
		{name: "too many entries", mutate: func(data []byte) { binary.BigEndian.PutUint16(data[9:11], MaxGraphRankEntries+1) }},
		{name: "invalid entry type", mutate: func(data []byte) { binary.BigEndian.PutUint16(data[11:13], 99) }},
		{name: "non-finite score", mutate: func(data []byte) { binary.BigEndian.PutUint64(data[21:29], math.Float64bits(math.Inf(1))) }},
		{name: "too many paths", mutate: func(data []byte) { data[29] = MaxGraphRankPaths + 1 }},
		{name: "path depth mismatch", mutate: func(data []byte) { data[31] = 2 }},
		{name: "too many edges", mutate: func(data []byte) { binary.BigEndian.PutUint16(data[41:43], MaxGraphRankEdges+1) }},
		{name: "invalid edge type", mutate: func(data []byte) { binary.BigEndian.PutUint16(data[51:53], 99) }},
	} {
		t.Run(test.name, func(t *testing.T) {
			malformed := append([]byte(nil), payload...)
			test.mutate(malformed)
			if _, err := DecodeGraphRankResult(malformed); err == nil {
				t.Fatal("expected malformed graph rank result to fail")
			}
		})
	}
}
