package protocol

import (
	"bytes"
	"encoding/binary"
	"fmt"
)

// GraphNode represents a node in graph query results
type GraphNode struct {
	Type  uint16
	ID    uint64
	Depth uint8
}

// GraphDegreeEntry represents a degree result entry
type GraphDegreeEntry struct {
	Type   uint16
	ID     uint64
	Degree uint16
}

// GraphQueryResult represents a decoded S_GraphQueryResult payload.
type GraphQueryResult struct {
	ConvID        uint64
	StartType     uint16
	StartID       uint64
	Truncated     bool
	Nodes         []GraphNode
	Edges         []Edge
	CorrelationID uint32
}

// GraphShortestPathNode represents a node in shortest-path/common-neighbor payloads.
type GraphShortestPathNode struct {
	Type uint16
	ID   uint64
}

// GraphShortestPathResult represents a decoded S_GraphShortestPathResult payload.
type GraphShortestPathResult struct {
	ConvID        uint64
	FromType      uint16
	FromID        uint64
	ToType        uint16
	ToID          uint64
	Found         bool
	PathLength    uint8
	Nodes         []GraphShortestPathNode
	Edges         []Edge
	CorrelationID uint32
}

// GraphDegreeResult represents a decoded S_GraphDegreeResult payload.
type GraphDegreeResult struct {
	ConvID        uint64
	Entries       []GraphDegreeEntry
	CorrelationID uint32
}

// GraphCommonNeighborsResult represents a decoded S_GraphCommonNeighborsResult payload.
type GraphCommonNeighborsResult struct {
	ConvID        uint64
	AType         uint16
	AID           uint64
	BType         uint16
	BID           uint64
	Nodes         []GraphShortestPathNode
	Edges         []Edge
	CorrelationID uint32
}

// EncodeGraphQuery encodes C_GraphQuery request.
// Wire format: conv_id(8) + start_type(2) + start_id(8) + max_depth(1) + relation_mask(2) + direction(1) + flags(1)
func EncodeGraphQuery(convID int64, startType uint16, startID uint64, maxDepth uint8, relationMask uint16, direction uint8, flags uint8) []byte {
	return EncodeGraphQueryWithCorrelation(convID, startType, startID, maxDepth, relationMask, direction, flags, 0)
}

// EncodeGraphQueryWithCorrelation encodes C_GraphQuery request with a trailing correlation_id.
func EncodeGraphQueryWithCorrelation(convID int64, startType uint16, startID uint64, maxDepth uint8, relationMask uint16, direction uint8, flags uint8, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, startType)
	binary.Write(buf, binary.BigEndian, startID)
	buf.WriteByte(maxDepth)
	binary.Write(buf, binary.BigEndian, relationMask)
	buf.WriteByte(direction)
	buf.WriteByte(flags)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// EncodeGraphShortestPath encodes C_GraphShortestPath request.
// Wire format: conv_id(8) + from_type(2) + from_id(8) + to_type(2) + to_id(8) + relation_mask(2) + direction(1) + max_depth(1) + flags(1)
func EncodeGraphShortestPath(convID int64, fromType uint16, fromID uint64, toType uint16, toID uint64, relationMask uint16, direction uint8, maxDepth uint8, flags uint8) []byte {
	return EncodeGraphShortestPathWithCorrelation(convID, fromType, fromID, toType, toID, relationMask, direction, maxDepth, flags, 0)
}

// EncodeGraphShortestPathWithCorrelation encodes C_GraphShortestPath request with a trailing correlation_id.
func EncodeGraphShortestPathWithCorrelation(convID int64, fromType uint16, fromID uint64, toType uint16, toID uint64, relationMask uint16, direction uint8, maxDepth uint8, flags uint8, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, fromType)
	binary.Write(buf, binary.BigEndian, fromID)
	binary.Write(buf, binary.BigEndian, toType)
	binary.Write(buf, binary.BigEndian, toID)
	binary.Write(buf, binary.BigEndian, relationMask)
	buf.WriteByte(direction)
	buf.WriteByte(maxDepth)
	buf.WriteByte(flags)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// EncodeGraphDegree encodes C_GraphDegree request.
// Wire format: conv_id(8) + top_n(2) + type_filter(2) + relation_mask(2)
func EncodeGraphDegree(convID int64, topN uint16, typeFilter uint16, relationMask uint16) []byte {
	return EncodeGraphDegreeWithCorrelation(convID, topN, typeFilter, relationMask, 0)
}

// EncodeGraphDegreeWithCorrelation encodes C_GraphDegree request with a trailing correlation_id.
func EncodeGraphDegreeWithCorrelation(convID int64, topN uint16, typeFilter uint16, relationMask uint16, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, topN)
	binary.Write(buf, binary.BigEndian, typeFilter)
	binary.Write(buf, binary.BigEndian, relationMask)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// EncodeGraphCommonNeighbors encodes C_GraphCommonNeighbors request.
// Wire format: conv_id(8) + a_type(2) + a_id(8) + b_type(2) + b_id(8) + relation_mask(2) + direction(1)
func EncodeGraphCommonNeighbors(convID int64, aType uint16, aID uint64, bType uint16, bID uint64, relationMask uint16, direction uint8) []byte {
	return EncodeGraphCommonNeighborsWithCorrelation(convID, aType, aID, bType, bID, relationMask, direction, 0)
}

// EncodeGraphCommonNeighborsWithCorrelation encodes C_GraphCommonNeighbors request with a trailing correlation_id.
func EncodeGraphCommonNeighborsWithCorrelation(convID int64, aType uint16, aID uint64, bType uint16, bID uint64, relationMask uint16, direction uint8, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, aType)
	binary.Write(buf, binary.BigEndian, aID)
	binary.Write(buf, binary.BigEndian, bType)
	binary.Write(buf, binary.BigEndian, bID)
	binary.Write(buf, binary.BigEndian, relationMask)
	buf.WriteByte(direction)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// DecodeGraphQueryResult decodes an S_GraphQueryResult payload.
func DecodeGraphQueryResult(data []byte) (*GraphQueryResult, error) {
	if len(data) < 23 {
		return nil, fmt.Errorf("graph query result payload too short")
	}

	resp := &GraphQueryResult{}
	offset := 0

	resp.ConvID = binary.BigEndian.Uint64(data[offset:])
	offset += 8
	resp.StartType = binary.BigEndian.Uint16(data[offset:])
	offset += 2
	resp.StartID = binary.BigEndian.Uint64(data[offset:])
	offset += 8
	resp.Truncated = data[offset] == 1
	offset += 1

	nodeCount := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2
	resp.Nodes = make([]GraphNode, 0, nodeCount)
	for i := 0; i < nodeCount; i++ {
		if len(data) < offset+11 {
			return nil, fmt.Errorf("graph query node %d truncated", i)
		}
		node := GraphNode{
			Type:  binary.BigEndian.Uint16(data[offset:]),
			ID:    binary.BigEndian.Uint64(data[offset+2:]),
			Depth: data[offset+10],
		}
		offset += 11
		resp.Nodes = append(resp.Nodes, node)
	}

	edgeCount := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2
	resp.Edges = make([]Edge, 0, edgeCount)
	for i := 0; i < edgeCount; i++ {
		edge, newOffset := ParseEdge(data, offset)
		if newOffset == offset {
			return nil, fmt.Errorf("graph query edge %d truncated", i)
		}
		offset = newOffset
		resp.Edges = append(resp.Edges, edge)
	}

	if len(data) < offset+4 {
		return nil, fmt.Errorf("graph query result missing correlation_id")
	}
	resp.CorrelationID = binary.BigEndian.Uint32(data[offset : offset+4])
	offset += 4

	if offset != len(data) {
		return nil, fmt.Errorf("unexpected trailing bytes in graph query result payload: %d", len(data)-offset)
	}

	return resp, nil
}

// DecodeGraphShortestPathResult decodes an S_GraphShortestPathResult payload.
func DecodeGraphShortestPathResult(data []byte) (*GraphShortestPathResult, error) {
	if len(data) < 34 {
		return nil, fmt.Errorf("graph shortest path result payload too short")
	}

	resp := &GraphShortestPathResult{}
	offset := 0

	resp.ConvID = binary.BigEndian.Uint64(data[offset:])
	offset += 8
	resp.FromType = binary.BigEndian.Uint16(data[offset:])
	offset += 2
	resp.FromID = binary.BigEndian.Uint64(data[offset:])
	offset += 8
	resp.ToType = binary.BigEndian.Uint16(data[offset:])
	offset += 2
	resp.ToID = binary.BigEndian.Uint64(data[offset:])
	offset += 8
	resp.Found = data[offset] == 1
	offset += 1
	resp.PathLength = data[offset]
	offset += 1

	nodeCount := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2
	resp.Nodes = make([]GraphShortestPathNode, 0, nodeCount)
	for i := 0; i < nodeCount; i++ {
		if len(data) < offset+10 {
			return nil, fmt.Errorf("graph shortest path node %d truncated", i)
		}
		node := GraphShortestPathNode{
			Type: binary.BigEndian.Uint16(data[offset:]),
			ID:   binary.BigEndian.Uint64(data[offset+2:]),
		}
		offset += 10
		resp.Nodes = append(resp.Nodes, node)
	}

	edgeCount := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2
	resp.Edges = make([]Edge, 0, edgeCount)
	for i := 0; i < edgeCount; i++ {
		edge, newOffset := ParseEdge(data, offset)
		if newOffset == offset {
			return nil, fmt.Errorf("graph shortest path edge %d truncated", i)
		}
		offset = newOffset
		resp.Edges = append(resp.Edges, edge)
	}

	if len(data) < offset+4 {
		return nil, fmt.Errorf("graph shortest path result missing correlation_id")
	}
	resp.CorrelationID = binary.BigEndian.Uint32(data[offset : offset+4])
	offset += 4

	if offset != len(data) {
		return nil, fmt.Errorf("unexpected trailing bytes in graph shortest path result payload: %d", len(data)-offset)
	}

	return resp, nil
}

// DecodeGraphDegreeResult decodes an S_GraphDegreeResult payload.
func DecodeGraphDegreeResult(data []byte) (*GraphDegreeResult, error) {
	if len(data) < 14 {
		return nil, fmt.Errorf("graph degree result payload too short")
	}

	resp := &GraphDegreeResult{}
	offset := 0

	resp.ConvID = binary.BigEndian.Uint64(data[offset:])
	offset += 8

	count := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2

	resp.Entries = make([]GraphDegreeEntry, 0, count)
	for i := 0; i < count; i++ {
		if len(data) < offset+12 {
			return nil, fmt.Errorf("graph degree entry %d truncated", i)
		}
		entry := GraphDegreeEntry{
			Type:   binary.BigEndian.Uint16(data[offset:]),
			ID:     binary.BigEndian.Uint64(data[offset+2:]),
			Degree: binary.BigEndian.Uint16(data[offset+10:]),
		}
		offset += 12
		resp.Entries = append(resp.Entries, entry)
	}

	if len(data) < offset+4 {
		return nil, fmt.Errorf("graph degree result missing correlation_id")
	}
	resp.CorrelationID = binary.BigEndian.Uint32(data[offset : offset+4])
	offset += 4

	if offset != len(data) {
		return nil, fmt.Errorf("unexpected trailing bytes in graph degree result payload: %d", len(data)-offset)
	}

	return resp, nil
}

// DecodeGraphCommonNeighborsResult decodes an S_GraphCommonNeighborsResult payload.
func DecodeGraphCommonNeighborsResult(data []byte) (*GraphCommonNeighborsResult, error) {
	if len(data) < 32 {
		return nil, fmt.Errorf("graph common neighbors result payload too short")
	}

	resp := &GraphCommonNeighborsResult{}
	offset := 0

	resp.ConvID = binary.BigEndian.Uint64(data[offset:])
	offset += 8
	resp.AType = binary.BigEndian.Uint16(data[offset:])
	offset += 2
	resp.AID = binary.BigEndian.Uint64(data[offset:])
	offset += 8
	resp.BType = binary.BigEndian.Uint16(data[offset:])
	offset += 2
	resp.BID = binary.BigEndian.Uint64(data[offset:])
	offset += 8

	nodeCount := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2
	resp.Nodes = make([]GraphShortestPathNode, 0, nodeCount)
	for i := 0; i < nodeCount; i++ {
		if len(data) < offset+10 {
			return nil, fmt.Errorf("graph common neighbors node %d truncated", i)
		}
		node := GraphShortestPathNode{
			Type: binary.BigEndian.Uint16(data[offset:]),
			ID:   binary.BigEndian.Uint64(data[offset+2:]),
		}
		offset += 10
		resp.Nodes = append(resp.Nodes, node)
	}

	edgeCount := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2
	resp.Edges = make([]Edge, 0, edgeCount)
	for i := 0; i < edgeCount; i++ {
		edge, newOffset := ParseEdge(data, offset)
		if newOffset == offset {
			return nil, fmt.Errorf("graph common neighbors edge %d truncated", i)
		}
		offset = newOffset
		resp.Edges = append(resp.Edges, edge)
	}

	if len(data) < offset+4 {
		return nil, fmt.Errorf("graph common neighbors result missing correlation_id")
	}
	resp.CorrelationID = binary.BigEndian.Uint32(data[offset : offset+4])
	offset += 4

	if offset != len(data) {
		return nil, fmt.Errorf("unexpected trailing bytes in graph common neighbors result payload: %d", len(data)-offset)
	}

	return resp, nil
}
