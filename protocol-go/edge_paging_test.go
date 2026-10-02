package protocol

import (
	"bytes"
	"testing"
)

func TestEdgePageWireContract(t *testing.T) {
	want := []byte{1, 2, 3, 4, 5, 6, 7, 8, 2, 1, 17, 18, 19, 20, 21, 22, 23, 24, 161, 162, 163, 164}
	got := EncodeListAllEdgesPaged(0x0102030405060708, 513, 0x1112131415161718, 0xa1a2a3a4)
	if !bytes.Equal(got, want) {
		t.Fatalf("request bytes: got %x want %x", got, want)
	}
	// Same independently specified header as the Odin wire-contract test,
	// without its opcode. The existing Edge codec owns the record layout.
	header := []byte{0, 0, 0, 0, 0, 0, 0, 23, 1, 0, 0, 0, 0, 0, 0, 0, 11, 0, 0, 1, 65, 0, 1, 161, 162, 163, 164}
	edge := Edge{EdgeID: 11, ConvID: 23, SourceType: 1, SourceID: 31, TargetType: 2, TargetID: 47, Relation: 1, CreatedAt: -17, CreatedBy: "xy"}
	wire := append(header, buildEdgeBinary(edge)...)
	resp, err := DecodeAllEdgeListPage(wire)
	if err != nil {
		t.Fatal(err)
	}
	if resp.ConvID != 23 || !resp.HasMore || resp.NextEdgeID != 11 || resp.TotalCount != 321 || resp.CorrelationID != 0xa1a2a3a4 || len(resp.Edges) != 1 || resp.Edges[0] != edge {
		t.Fatalf("incorrect decoded page: %+v", resp)
	}
	for n := 0; n < len(wire); n++ {
		if _, err := DecodeAllEdgeListPage(wire[:n]); err == nil {
			t.Fatalf("accepted truncation at %d", n)
		}
	}
	if _, err := DecodeAllEdgeListPage(append(wire, 0)); err == nil {
		t.Fatal("accepted trailing byte")
	}
	wire[8] = 2
	if _, err := DecodeAllEdgeListPage(wire); err == nil {
		t.Fatal("accepted invalid has_more")
	}
}
