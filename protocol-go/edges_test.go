package protocol

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func buildEdgeBinary(e Edge) []byte {
	size := 8 + 8 + 2 + 8 + 2 + 8 + 2 + 8 + 2 + len(e.CreatedBy)
	buf := make([]byte, size)
	off := 0
	binary.BigEndian.PutUint64(buf[off:], e.EdgeID)
	off += 8
	binary.BigEndian.PutUint64(buf[off:], e.ConvID)
	off += 8
	binary.BigEndian.PutUint16(buf[off:], e.SourceType)
	off += 2
	binary.BigEndian.PutUint64(buf[off:], e.SourceID)
	off += 8
	binary.BigEndian.PutUint16(buf[off:], e.TargetType)
	off += 2
	binary.BigEndian.PutUint64(buf[off:], e.TargetID)
	off += 8
	binary.BigEndian.PutUint16(buf[off:], e.Relation)
	off += 2
	binary.BigEndian.PutUint64(buf[off:], uint64(e.CreatedAt))
	off += 8
	binary.BigEndian.PutUint16(buf[off:], uint16(len(e.CreatedBy)))
	off += 2
	copy(buf[off:], e.CreatedBy)
	return buf
}

func TestParseEdge(t *testing.T) {
	want := Edge{
		EdgeID: 42, ConvID: 10,
		SourceType: TargetTypeAsset, SourceID: 100,
		TargetType: TargetTypeTask, TargetID: 200,
		Relation: RelationDependsOn, CreatedAt: 1700000000, CreatedBy: "alice",
	}

	data := buildEdgeBinary(want)
	got, endOff := ParseEdge(data, 0)

	if endOff != len(data) {
		t.Errorf("offset = %d, want %d", endOff, len(data))
	}
	if got.EdgeID != want.EdgeID {
		t.Errorf("EdgeID = %d, want %d", got.EdgeID, want.EdgeID)
	}
	if got.ConvID != want.ConvID {
		t.Errorf("ConvID = %d, want %d", got.ConvID, want.ConvID)
	}
	if got.SourceType != want.SourceType {
		t.Errorf("SourceType = %d, want %d", got.SourceType, want.SourceType)
	}
	if got.SourceID != want.SourceID {
		t.Errorf("SourceID = %d, want %d", got.SourceID, want.SourceID)
	}
	if got.TargetType != want.TargetType {
		t.Errorf("TargetType = %d, want %d", got.TargetType, want.TargetType)
	}
	if got.TargetID != want.TargetID {
		t.Errorf("TargetID = %d, want %d", got.TargetID, want.TargetID)
	}
	if got.Relation != want.Relation {
		t.Errorf("Relation = %d, want %d", got.Relation, want.Relation)
	}
	if got.CreatedAt != want.CreatedAt {
		t.Errorf("CreatedAt = %d, want %d", got.CreatedAt, want.CreatedAt)
	}
	if got.CreatedBy != want.CreatedBy {
		t.Errorf("CreatedBy = %q, want %q", got.CreatedBy, want.CreatedBy)
	}
}

func TestParseEdgeMultiple(t *testing.T) {
	e1 := Edge{EdgeID: 1, ConvID: 10, SourceType: 1, SourceID: 100, TargetType: 2, TargetID: 200, Relation: 1, CreatedAt: 100, CreatedBy: "a"}
	e2 := Edge{EdgeID: 2, ConvID: 10, SourceType: 2, SourceID: 300, TargetType: 1, TargetID: 400, Relation: 3, CreatedAt: 200, CreatedBy: "b"}
	data := append(buildEdgeBinary(e1), buildEdgeBinary(e2)...)

	got1, off := ParseEdge(data, 0)
	if got1.EdgeID != 1 {
		t.Errorf("first EdgeID = %d, want 1", got1.EdgeID)
	}
	got2, off2 := ParseEdge(data, off)
	if got2.EdgeID != 2 {
		t.Errorf("second EdgeID = %d, want 2", got2.EdgeID)
	}
	if off2 != len(data) {
		t.Errorf("final offset = %d, want %d", off2, len(data))
	}
}

func TestParseEdgeTruncated(t *testing.T) {
	e := Edge{EdgeID: 1, ConvID: 10, SourceType: 1, SourceID: 100, TargetType: 2, TargetID: 200, Relation: 1, CreatedAt: 100, CreatedBy: "a"}
	data := buildEdgeBinary(e)

	// Only 5 bytes - should not panic
	_, _ = ParseEdge(data[:5], 0)
}

func TestDecodeEdgeCreated(t *testing.T) {
	want := Edge{
		EdgeID:     999,
		ConvID:     42,
		SourceType: TargetTypeAsset,
		SourceID:   11,
		TargetType: TargetTypeAsset,
		TargetID:   22,
		Relation:   RelationRelatedTo,
		CreatedAt:  1700000001,
		CreatedBy:  "bob",
	}

	payload := append(buildEdgeBinary(want), []byte{0, 0, 0, 9}...)
	decoded, err := DecodeEdgeCreated(payload)
	if err != nil {
		t.Fatalf("DecodeEdgeCreated error: %v", err)
	}

	if decoded.Edge.EdgeID != want.EdgeID {
		t.Fatalf("EdgeID = %d, want %d", decoded.Edge.EdgeID, want.EdgeID)
	}
	if decoded.Edge.Relation != want.Relation {
		t.Fatalf("Relation = %d, want %d", decoded.Edge.Relation, want.Relation)
	}
	if decoded.CorrelationID != 9 {
		t.Fatalf("CorrelationID = %d, want 9", decoded.CorrelationID)
	}
}

func TestDecodeEdgeCreatedTrailingBytes(t *testing.T) {
	edge := Edge{EdgeID: 1, ConvID: 1, SourceType: 1, SourceID: 1, TargetType: 2, TargetID: 2, Relation: 1, CreatedBy: "x"}
	payload := append(buildEdgeBinary(edge), []byte{0, 0, 0, 1, 0xff}...)

	_, err := DecodeEdgeCreated(payload)
	if err == nil {
		t.Fatal("expected error for trailing bytes")
	}
}

func TestEncodeCreateEdgeWireFormat(t *testing.T) {
	data := EncodeCreateEdge(10, TargetTypeAsset, 100, TargetTypeTask, 200, RelationBlocks)
	if len(data) != 34 {
		t.Fatalf("expected 34 bytes, got %d", len(data))
	}
	off := 0
	convID := int64(binary.BigEndian.Uint64(data[off:]))
	off += 8
	if convID != 10 {
		t.Errorf("convID = %d, want 10", convID)
	}
	srcType := binary.BigEndian.Uint16(data[off:])
	off += 2
	if srcType != TargetTypeAsset {
		t.Errorf("sourceType = %d, want %d", srcType, TargetTypeAsset)
	}
	srcID := binary.BigEndian.Uint64(data[off:])
	off += 8
	if srcID != 100 {
		t.Errorf("sourceID = %d, want 100", srcID)
	}
	tgtType := binary.BigEndian.Uint16(data[off:])
	off += 2
	if tgtType != TargetTypeTask {
		t.Errorf("targetType = %d, want %d", tgtType, TargetTypeTask)
	}
	tgtID := binary.BigEndian.Uint64(data[off:])
	off += 8
	if tgtID != 200 {
		t.Errorf("targetID = %d, want 200", tgtID)
	}
	rel := binary.BigEndian.Uint16(data[off:])
	off += 2
	if rel != RelationBlocks {
		t.Errorf("relation = %d, want %d", rel, RelationBlocks)
	}
	if corr := binary.BigEndian.Uint32(data[off:]); corr != 0 {
		t.Errorf("correlation_id = %d, want 0", corr)
	}
}

func TestEncodeCreateEdgeWithCorrelationWireFormat(t *testing.T) {
	data := EncodeCreateEdgeWithCorrelation(10, TargetTypeAsset, 100, TargetTypeTask, 200, RelationBlocks, 0xAABBCCDD)
	if len(data) != 34 {
		t.Fatalf("expected 34 bytes, got %d", len(data))
	}
	if got := binary.BigEndian.Uint32(data[30:34]); got != 0xAABBCCDD {
		t.Fatalf("correlation_id = 0x%08X, want 0xAABBCCDD", got)
	}
}

func TestEncodeDeleteEdgeWireFormat(t *testing.T) {
	data := EncodeDeleteEdge(10, 20)
	if len(data) != 20 {
		t.Fatalf("expected 20 bytes, got %d", len(data))
	}
}

func TestEncodeDeleteEdgeWithCorrelationWireFormat(t *testing.T) {
	data := EncodeDeleteEdgeWithCorrelation(10, 20, 0xABCD1234)
	if len(data) != 20 {
		t.Fatalf("expected 20 bytes, got %d", len(data))
	}
	if got := binary.BigEndian.Uint32(data[16:20]); got != 0xABCD1234 {
		t.Fatalf("correlation_id = 0x%08X, want 0xABCD1234", got)
	}
}

func TestEncodeListEdgesWireFormat(t *testing.T) {
	data := EncodeListEdges(10, TargetTypeTask, 100)
	if len(data) != 22 {
		t.Fatalf("expected 22 bytes, got %d", len(data))
	}
}

func TestDecodeEdgeListResponseCorrelation(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint64(1))
	binary.Write(buf, binary.BigEndian, uint16(TargetTypeAsset))
	binary.Write(buf, binary.BigEndian, uint64(9))
	binary.Write(buf, binary.BigEndian, uint16(1))
	buf.Write(buildEdgeBinary(Edge{EdgeID: 2, ConvID: 1, SourceType: 1, SourceID: 3, TargetType: 2, TargetID: 4, Relation: 1, CreatedBy: "u"}))
	binary.Write(buf, binary.BigEndian, uint32(77))

	resp, err := DecodeEdgeListResponse(buf.Bytes())
	if err != nil {
		t.Fatalf("DecodeEdgeListResponse error: %v", err)
	}
	if resp.CorrelationID != 77 {
		t.Fatalf("CorrelationID = %d, want 77", resp.CorrelationID)
	}
}

func TestEncodeListAllEdgesWireFormat(t *testing.T) {
	data := EncodeListAllEdges(10)
	if len(data) != 12 {
		t.Fatalf("expected 12 bytes, got %d", len(data))
	}
}

func TestDecodeAllEdgeListResponseCorrelation(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint64(1))
	binary.Write(buf, binary.BigEndian, uint32(1))
	buf.Write(buildEdgeBinary(Edge{EdgeID: 2, ConvID: 1, SourceType: 1, SourceID: 3, TargetType: 2, TargetID: 4, Relation: 1, CreatedBy: "u"}))
	binary.Write(buf, binary.BigEndian, uint32(88))

	resp, err := DecodeAllEdgeListResponse(buf.Bytes())
	if err != nil {
		t.Fatalf("DecodeAllEdgeListResponse error: %v", err)
	}
	if resp.CorrelationID != 88 {
		t.Fatalf("CorrelationID = %d, want 88", resp.CorrelationID)
	}
}

func TestDecodeEdgeDeleted(t *testing.T) {
	payload := make([]byte, 20)
	binary.BigEndian.PutUint64(payload[0:8], 1)
	binary.BigEndian.PutUint64(payload[8:16], 2)
	binary.BigEndian.PutUint32(payload[16:20], 3)

	decoded, err := DecodeEdgeDeleted(payload)
	if err != nil {
		t.Fatalf("DecodeEdgeDeleted error: %v", err)
	}
	if decoded.ConvID != 1 || decoded.EdgeID != 2 || decoded.CorrelationID != 3 {
		t.Fatalf("unexpected decoded edge deleted payload: %+v", decoded)
	}
}
