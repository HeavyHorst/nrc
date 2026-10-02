package protocol

import (
	"bytes"
	"encoding/binary"
	"fmt"
)

// Edge represents a knowledge graph edge matching server wire format
type Edge struct {
	EdgeID     uint64
	ConvID     uint64
	SourceType uint16
	SourceID   uint64
	TargetType uint16
	TargetID   uint64
	Relation   uint16
	CreatedAt  int64
	CreatedBy  string
}

// EdgeCreatedResponse represents a decoded S_EdgeCreated payload.
// Wire format: edge(...) + correlation_id(4)
type EdgeCreatedResponse struct {
	Edge          Edge
	CorrelationID uint32
}

// EdgeDeletedResponse represents a decoded S_EdgeDeleted payload.
// Wire format: conv_id(8) + edge_id(8) + correlation_id(4)
type EdgeDeletedResponse struct {
	ConvID        uint64
	EdgeID        uint64
	CorrelationID uint32
}

// EdgeListResponse represents a decoded S_EdgeList payload.
// Wire format: conv_id(8) + target_type(2) + target_id(8) + count(2) + edges... + correlation_id(4)
type EdgeListResponse struct {
	ConvID        uint64
	TargetType    uint16
	TargetID      uint64
	Edges         []Edge
	CorrelationID uint32
}

// AllEdgeListResponse represents a decoded S_AllEdgeList payload.
// Wire format: conv_id(8) + count(4) + edges... + correlation_id(4)
type AllEdgeListResponse struct {
	ConvID        uint64
	Edges         []Edge
	CorrelationID uint32
}

// ParseEdge parses a single edge from binary data at offset.
func ParseEdge(data []byte, offset int) (Edge, int) {
	var e Edge

	if len(data) < offset+8 {
		return e, offset
	}
	e.EdgeID = binary.BigEndian.Uint64(data[offset:])
	offset += 8

	if len(data) < offset+8 {
		return e, offset
	}
	e.ConvID = binary.BigEndian.Uint64(data[offset:])
	offset += 8

	if len(data) < offset+2 {
		return e, offset
	}
	e.SourceType = binary.BigEndian.Uint16(data[offset:])
	offset += 2

	if len(data) < offset+8 {
		return e, offset
	}
	e.SourceID = binary.BigEndian.Uint64(data[offset:])
	offset += 8

	if len(data) < offset+2 {
		return e, offset
	}
	e.TargetType = binary.BigEndian.Uint16(data[offset:])
	offset += 2

	if len(data) < offset+8 {
		return e, offset
	}
	e.TargetID = binary.BigEndian.Uint64(data[offset:])
	offset += 8

	if len(data) < offset+2 {
		return e, offset
	}
	e.Relation = binary.BigEndian.Uint16(data[offset:])
	offset += 2

	if len(data) < offset+8 {
		return e, offset
	}
	e.CreatedAt = int64(binary.BigEndian.Uint64(data[offset:]))
	offset += 8

	if len(data) < offset+2 {
		return e, offset
	}
	createdByLen := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2
	if len(data) < offset+createdByLen {
		return e, offset
	}
	e.CreatedBy = string(data[offset : offset+createdByLen])
	offset += createdByLen

	return e, offset
}

// DecodeEdgeList decodes an S_EdgeList response.
// Format: conv_id(8) + target_type(2) + target_id(8) + count(2) + edges...
func DecodeEdgeList(data []byte) ([]Edge, error) {
	resp, err := DecodeEdgeListResponse(data)
	if err != nil {
		return nil, err
	}
	return resp.Edges, nil
}

// DecodeEdgeListResponse decodes an S_EdgeList response.
// Format: conv_id(8) + target_type(2) + target_id(8) + count(2) + edges... + correlation_id(4)
func DecodeEdgeListResponse(data []byte) (*EdgeListResponse, error) {
	if len(data) < 24 {
		return nil, fmt.Errorf("response too short")
	}

	resp := &EdgeListResponse{
		ConvID:     binary.BigEndian.Uint64(data[0:8]),
		TargetType: binary.BigEndian.Uint16(data[8:10]),
		TargetID:   binary.BigEndian.Uint64(data[10:18]),
	}

	count := int(binary.BigEndian.Uint16(data[18:20]))
	offset := 20

	resp.Edges = make([]Edge, 0, count)
	for i := 0; i < count; i++ {
		var e Edge
		e, offset = ParseEdge(data, offset)
		resp.Edges = append(resp.Edges, e)
	}

	if len(data) < offset+4 {
		return nil, fmt.Errorf("edge list payload missing correlation_id")
	}
	resp.CorrelationID = binary.BigEndian.Uint32(data[offset : offset+4])
	offset += 4

	if offset != len(data) {
		return nil, fmt.Errorf("unexpected trailing bytes in edge list payload: %d", len(data)-offset)
	}

	return resp, nil
}

// DecodeAllEdgeList decodes an S_AllEdgeList response.
// Format: conv_id(8) + count(4) + edges...
func DecodeAllEdgeList(data []byte) (uint64, []Edge, error) {
	resp, err := DecodeAllEdgeListResponse(data)
	if err != nil {
		return 0, nil, err
	}
	return resp.ConvID, resp.Edges, nil
}

// DecodeAllEdgeListResponse decodes an S_AllEdgeList response.
// Format: conv_id(8) + count(4) + edges... + correlation_id(4)
func DecodeAllEdgeListResponse(data []byte) (*AllEdgeListResponse, error) {
	if len(data) < 16 {
		return nil, fmt.Errorf("response too short")
	}
	resp := &AllEdgeListResponse{ConvID: binary.BigEndian.Uint64(data[0:8])}
	count := int(binary.BigEndian.Uint32(data[8:12]))
	offset := 12

	resp.Edges = make([]Edge, 0, count)
	for i := 0; i < count; i++ {
		var e Edge
		e, offset = ParseEdge(data, offset)
		resp.Edges = append(resp.Edges, e)
	}

	if len(data) < offset+4 {
		return nil, fmt.Errorf("all edge list payload missing correlation_id")
	}
	resp.CorrelationID = binary.BigEndian.Uint32(data[offset : offset+4])
	offset += 4

	if offset != len(data) {
		return nil, fmt.Errorf("unexpected trailing bytes in all edge list payload: %d", len(data)-offset)
	}

	return resp, nil
}

// DecodeEdgeCreated decodes an S_EdgeCreated payload.
// Wire format: edge(...) + correlation_id(4)
func DecodeEdgeCreated(data []byte) (*EdgeCreatedResponse, error) {
	edge, offset := ParseEdge(data, 0)

	resp := &EdgeCreatedResponse{Edge: edge}
	if len(data) < offset+4 {
		return nil, fmt.Errorf("edge created payload missing correlation_id")
	}
	resp.CorrelationID = binary.BigEndian.Uint32(data[offset : offset+4])
	offset += 4

	if offset != len(data) {
		return nil, fmt.Errorf("unexpected trailing bytes in edge created payload: %d", len(data)-offset)
	}

	return resp, nil
}

// DecodeEdgeDeleted decodes an S_EdgeDeleted payload.
// Wire format: conv_id(8) + edge_id(8) + correlation_id(4)
func DecodeEdgeDeleted(data []byte) (*EdgeDeletedResponse, error) {
	if len(data) != 20 {
		return nil, fmt.Errorf("edge deleted payload size mismatch: got %d want 20", len(data))
	}

	return &EdgeDeletedResponse{
		ConvID:        binary.BigEndian.Uint64(data[0:8]),
		EdgeID:        binary.BigEndian.Uint64(data[8:16]),
		CorrelationID: binary.BigEndian.Uint32(data[16:20]),
	}, nil
}

// EncodeCreateEdge encodes C_CreateEdge request.
func EncodeCreateEdge(convID int64, sourceType uint16, sourceID uint64, targetType uint16, targetID uint64, relation uint16) []byte {
	return EncodeCreateEdgeWithCorrelation(convID, sourceType, sourceID, targetType, targetID, relation, 0)
}

// EncodeCreateEdgeWithCorrelation encodes C_CreateEdge request with a trailing correlation_id.
func EncodeCreateEdgeWithCorrelation(convID int64, sourceType uint16, sourceID uint64, targetType uint16, targetID uint64, relation uint16, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, sourceType)
	binary.Write(buf, binary.BigEndian, sourceID)
	binary.Write(buf, binary.BigEndian, targetType)
	binary.Write(buf, binary.BigEndian, targetID)
	binary.Write(buf, binary.BigEndian, relation)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// EncodeDeleteEdge encodes C_DeleteEdge request. Format: conv_id(8) + edge_id(8)
func EncodeDeleteEdge(convID int64, edgeID uint64) []byte {
	return EncodeDeleteEdgeWithCorrelation(convID, edgeID, 0)
}

// EncodeDeleteEdgeWithCorrelation encodes C_DeleteEdge request with a trailing correlation_id.
func EncodeDeleteEdgeWithCorrelation(convID int64, edgeID uint64, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, edgeID)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// EncodeListEdges encodes C_ListEdges request.
func EncodeListEdges(convID int64, targetType uint16, targetID uint64) []byte {
	return EncodeListEdgesWithCorrelation(convID, targetType, targetID, 0)
}

// EncodeListEdgesWithCorrelation encodes C_ListEdges request with a trailing correlation_id.
func EncodeListEdgesWithCorrelation(convID int64, targetType uint16, targetID uint64, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, targetType)
	binary.Write(buf, binary.BigEndian, targetID)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// EncodeListAllEdges encodes C_ListAllEdges request. Format: conv_id(8)
func EncodeListAllEdges(convID int64) []byte {
	return EncodeListAllEdgesWithCorrelation(convID, 0)
}

// EncodeListAllEdgesWithCorrelation encodes C_ListAllEdges request with a trailing correlation_id.
func EncodeListAllEdgesWithCorrelation(convID int64, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// EncodeListAllEdgesPaged encodes the payload (without opcode) of request 53.
// Zero afterEdgeID starts a live-room scan; zero limit uses the server default.
func EncodeListAllEdgesPaged(convID int64, limit uint16, afterEdgeID uint64, correlationID uint32) []byte {
	buf := make([]byte, 22)
	binary.BigEndian.PutUint64(buf[0:], uint64(convID))
	binary.BigEndian.PutUint16(buf[8:], limit)
	binary.BigEndian.PutUint64(buf[10:], afterEdgeID)
	binary.BigEndian.PutUint32(buf[18:], correlationID)
	return buf
}

type AllEdgeListPageResponse struct {
	ConvID        uint64
	HasMore       bool
	NextEdgeID    uint64
	TotalCount    uint32
	CorrelationID uint32
	Edges         []Edge
}

// DecodeAllEdgeListPage decodes response 161 without its two-byte opcode.
func DecodeAllEdgeListPage(data []byte) (*AllEdgeListPageResponse, error) {
	if len(data) < 27 || data[8] > 1 {
		return nil, fmt.Errorf("invalid edge page header")
	}
	resp := &AllEdgeListPageResponse{
		ConvID:        binary.BigEndian.Uint64(data[0:]),
		HasMore:       data[8] == 1,
		NextEdgeID:    binary.BigEndian.Uint64(data[9:]),
		TotalCount:    binary.BigEndian.Uint32(data[17:]),
		CorrelationID: binary.BigEndian.Uint32(data[23:]),
	}
	count := int(binary.BigEndian.Uint16(data[21:]))
	if count > (len(data)-27)/48 {
		return nil, fmt.Errorf("truncated edge page")
	}
	resp.Edges = make([]Edge, 0, count)
	offset := 27
	for i := 0; i < count; i++ {
		if len(data)-offset < 48 {
			return nil, fmt.Errorf("truncated edge record")
		}
		size := 48 + int(binary.BigEndian.Uint16(data[offset+46:]))
		if size > len(data)-offset {
			return nil, fmt.Errorf("truncated edge creator")
		}
		edge, next := ParseEdge(data, offset)
		resp.Edges = append(resp.Edges, edge)
		offset = next
	}
	if offset != len(data) {
		return nil, fmt.Errorf("unexpected trailing bytes in edge page")
	}
	return resp, nil
}

func EncodeListEdgesPaged(convID int64, targetType uint16, targetID uint64, limit uint16, afterEdgeID uint64, correlationID uint32) []byte {
	buf := make([]byte, 32)
	binary.BigEndian.PutUint64(buf[0:], uint64(convID))
	binary.BigEndian.PutUint16(buf[8:], targetType)
	binary.BigEndian.PutUint64(buf[10:], targetID)
	binary.BigEndian.PutUint16(buf[18:], limit)
	binary.BigEndian.PutUint64(buf[20:], afterEdgeID)
	binary.BigEndian.PutUint32(buf[28:], correlationID)
	return buf
}

type EdgeListPageResponse struct {
	ConvID        uint64
	TargetType    uint16
	TargetID      uint64
	HasMore       bool
	NextEdgeID    uint64
	TotalCount    uint32
	Edges         []Edge
	CorrelationID uint32
}

func DecodeEdgeListPage(data []byte) (*EdgeListPageResponse, error) {
	if len(data) < 37 || data[18] > 1 {
		return nil, fmt.Errorf("invalid incident edge page header")
	}
	r := &EdgeListPageResponse{ConvID: binary.BigEndian.Uint64(data), TargetType: binary.BigEndian.Uint16(data[8:]), TargetID: binary.BigEndian.Uint64(data[10:]), HasMore: data[18] == 1, NextEdgeID: binary.BigEndian.Uint64(data[19:]), TotalCount: binary.BigEndian.Uint32(data[27:]), CorrelationID: binary.BigEndian.Uint32(data[33:])}
	count, offset := int(binary.BigEndian.Uint16(data[31:])), 37
	r.Edges = make([]Edge, 0, count)
	for i := 0; i < count; i++ {
		if len(data)-offset < 48 {
			return nil, fmt.Errorf("truncated edge record")
		}
		size := 48 + int(binary.BigEndian.Uint16(data[offset+46:]))
		if size > len(data)-offset {
			return nil, fmt.Errorf("truncated edge creator")
		}
		edge, next := ParseEdge(data, offset)
		r.Edges = append(r.Edges, edge)
		offset = next
	}
	if offset != len(data) {
		return nil, fmt.Errorf("unexpected trailing bytes in incident edge page")
	}
	return r, nil
}
