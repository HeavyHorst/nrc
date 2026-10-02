package protocol

import (
	"encoding/binary"
	"strings"
	"testing"
)

func TestCustomerSearchCodecsRoundTripAndMalformed(t *testing.T) {
	req, err := EncodeSearchCustomers(17, 23, 41, true, "München", 99)
	if err != nil {
		t.Fatal(err)
	}
	if binary.BigEndian.Uint64(req) != 17 || binary.BigEndian.Uint16(req[8:]) != 23 || binary.BigEndian.Uint64(req[10:]) != 41 || req[18] != 1 || string(req[21:len(req)-4]) != "München" || binary.BigEndian.Uint32(req[len(req)-4:]) != 99 {
		t.Fatalf("incorrect encoded customer request: %x", req)
	}
	asset := Asset{AssetType: AssetTypeCustomerCompany, AssetID: 57, Owner: "alice", CreatedAt: 3, UpdatedAt: 4, ConvID: 17, Preview: `{"version":1,"title":"A & B"}`}
	header := make([]byte, 27)
	binary.BigEndian.PutUint64(header, 17)
	header[8] = 1
	binary.BigEndian.PutUint64(header[9:], 57)
	binary.BigEndian.PutUint32(header[17:], 8)
	binary.BigEndian.PutUint16(header[21:], 1)
	binary.BigEndian.PutUint32(header[23:], 99)
	wire := append(header, buildAssetHeaderBinary(asset)...)
	got, err := DecodeCustomerSearchPage(wire)
	if err != nil {
		t.Fatal(err)
	}
	if got.ConvID != 17 || !got.HasMore || got.NextCompanyID != 57 || got.TotalCount != 8 || got.CorrelationID != 99 || len(got.Assets) != 1 || got.Assets[0].AssetID != 57 || got.Assets[0].Preview != asset.Preview {
		t.Fatalf("incorrect decoded customer page: %+v", got)
	}
	for n := 0; n < len(wire); n++ {
		if _, err := DecodeCustomerSearchPage(wire[:n]); err == nil {
			t.Fatalf("accepted customer-page truncation at %d", n)
		}
	}
	if _, err := DecodeCustomerSearchPage(append(wire, 0)); err == nil {
		t.Fatal("accepted customer-page trailing byte")
	}
	if _, err := EncodeSearchCustomers(1, 1, 0, false, strings.Repeat("x", 257), 0); err == nil {
		t.Fatal("accepted oversized customer query")
	}
}

func TestIncidentEdgePageCodecsRoundTripAndMalformed(t *testing.T) {
	req := EncodeListEdgesPaged(7, TargetTypeAsset, 13, 2, 19, 29)
	if len(req) != 32 || binary.BigEndian.Uint64(req) != 7 || binary.BigEndian.Uint16(req[8:]) != TargetTypeAsset || binary.BigEndian.Uint64(req[10:]) != 13 || binary.BigEndian.Uint16(req[18:]) != 2 || binary.BigEndian.Uint64(req[20:]) != 19 || binary.BigEndian.Uint32(req[28:]) != 29 {
		t.Fatalf("incorrect encoded incident-edge request: %x", req)
	}
	edge := Edge{EdgeID: 31, ConvID: 7, SourceType: TargetTypeAsset, SourceID: 13, TargetType: TargetTypeTask, TargetID: 17, Relation: RelationRelatedTo, CreatedAt: 23, CreatedBy: "bob"}
	header := make([]byte, 37)
	binary.BigEndian.PutUint64(header, 7)
	binary.BigEndian.PutUint16(header[8:], TargetTypeAsset)
	binary.BigEndian.PutUint64(header[10:], 13)
	header[18] = 1
	binary.BigEndian.PutUint64(header[19:], 31)
	binary.BigEndian.PutUint32(header[27:], 4)
	binary.BigEndian.PutUint16(header[31:], 1)
	binary.BigEndian.PutUint32(header[33:], 29)
	wire := append(header, buildEdgeBinary(edge)...)
	got, err := DecodeEdgeListPage(wire)
	if err != nil {
		t.Fatal(err)
	}
	if got.ConvID != 7 || got.TargetType != TargetTypeAsset || got.TargetID != 13 || !got.HasMore || got.NextEdgeID != 31 || got.TotalCount != 4 || got.CorrelationID != 29 || len(got.Edges) != 1 || got.Edges[0] != edge {
		t.Fatalf("incorrect decoded incident-edge page: %+v", got)
	}
	for n := 0; n < len(wire); n++ {
		if _, err := DecodeEdgeListPage(wire[:n]); err == nil {
			t.Fatalf("accepted incident-edge truncation at %d", n)
		}
	}
	if _, err := DecodeEdgeListPage(append(wire, 0)); err == nil {
		t.Fatal("accepted incident-edge trailing byte")
	}
}
