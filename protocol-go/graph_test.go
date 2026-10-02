package protocol

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestEncodeGraphQueryWithCorrelation(t *testing.T) {
	data := EncodeGraphQueryWithCorrelation(1, TargetTypeAsset, 2, 3, 4, 0, 0, 0x01020304)
	if len(data) != 27 {
		t.Fatalf("expected 27 bytes, got %d", len(data))
	}
	if got := binary.BigEndian.Uint32(data[23:27]); got != 0x01020304 {
		t.Fatalf("correlation_id = 0x%08X, want 0x01020304", got)
	}
}

func TestEncodeGraphShortestPathWithCorrelation(t *testing.T) {
	data := EncodeGraphShortestPathWithCorrelation(1, 1, 2, 2, 3, 4, 0, 2, 0, 0xAABBCCDD)
	if len(data) != 37 {
		t.Fatalf("expected 37 bytes, got %d", len(data))
	}
	if got := binary.BigEndian.Uint32(data[33:37]); got != 0xAABBCCDD {
		t.Fatalf("correlation_id = 0x%08X, want 0xAABBCCDD", got)
	}
}

func TestEncodeGraphDegreeWithCorrelation(t *testing.T) {
	data := EncodeGraphDegreeWithCorrelation(1, 10, 1, 3, 0xFEEDBEEF)
	if len(data) != 18 {
		t.Fatalf("expected 18 bytes, got %d", len(data))
	}
	if got := binary.BigEndian.Uint32(data[14:18]); got != 0xFEEDBEEF {
		t.Fatalf("correlation_id = 0x%08X, want 0xFEEDBEEF", got)
	}
}

func TestEncodeGraphCommonNeighborsWithCorrelation(t *testing.T) {
	data := EncodeGraphCommonNeighborsWithCorrelation(1, 1, 2, 2, 3, 4, 0, 0x11223344)
	if len(data) != 35 {
		t.Fatalf("expected 35 bytes, got %d", len(data))
	}
	if got := binary.BigEndian.Uint32(data[31:35]); got != 0x11223344 {
		t.Fatalf("correlation_id = 0x%08X, want 0x11223344", got)
	}
}

func TestDecodeGraphQueryResult(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint64(1))
	binary.Write(buf, binary.BigEndian, uint16(TargetTypeAsset))
	binary.Write(buf, binary.BigEndian, uint64(10))
	buf.WriteByte(0)
	binary.Write(buf, binary.BigEndian, uint16(1))
	binary.Write(buf, binary.BigEndian, uint16(TargetTypeTask))
	binary.Write(buf, binary.BigEndian, uint64(20))
	buf.WriteByte(1)
	binary.Write(buf, binary.BigEndian, uint16(1))
	buf.Write(buildEdgeBinary(Edge{EdgeID: 5, ConvID: 1, SourceType: 1, SourceID: 10, TargetType: 2, TargetID: 20, Relation: 1, CreatedBy: "u"}))
	binary.Write(buf, binary.BigEndian, uint32(99))

	decoded, err := DecodeGraphQueryResult(buf.Bytes())
	if err != nil {
		t.Fatalf("DecodeGraphQueryResult error: %v", err)
	}
	if decoded.CorrelationID != 99 {
		t.Fatalf("CorrelationID = %d, want 99", decoded.CorrelationID)
	}
}

func TestDecodeGraphDegreeResult(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint64(1))
	binary.Write(buf, binary.BigEndian, uint16(1))
	binary.Write(buf, binary.BigEndian, uint16(TargetTypeAsset))
	binary.Write(buf, binary.BigEndian, uint64(10))
	binary.Write(buf, binary.BigEndian, uint16(3))
	binary.Write(buf, binary.BigEndian, uint32(101))

	decoded, err := DecodeGraphDegreeResult(buf.Bytes())
	if err != nil {
		t.Fatalf("DecodeGraphDegreeResult error: %v", err)
	}
	if decoded.CorrelationID != 101 {
		t.Fatalf("CorrelationID = %d, want 101", decoded.CorrelationID)
	}
}

func TestDecodeEmptyGraphDegreeResult(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint64(1))
	binary.Write(buf, binary.BigEndian, uint16(0))
	binary.Write(buf, binary.BigEndian, uint32(101))

	decoded, err := DecodeGraphDegreeResult(buf.Bytes())
	if err != nil {
		t.Fatalf("DecodeGraphDegreeResult error: %v", err)
	}
	if len(decoded.Entries) != 0 || decoded.CorrelationID != 101 {
		t.Fatalf("decoded empty degree result = %#v", decoded)
	}
}
