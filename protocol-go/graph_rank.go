package protocol

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"math"
)

const (
	MaxGraphRankAnchors    = 5
	MaxGraphRankCandidates = 50
	MaxGraphRankEntries    = MaxGraphRankCandidates * 2
	MaxGraphRankPaths      = MaxGraphRankAnchors
	MaxGraphRankDepth      = 4
	MaxGraphRankEdges      = MaxGraphRankEntries * MaxGraphRankPaths * MaxGraphRankDepth
)

func validGraphRankEntity(entity GraphRankEntity) bool {
	return (entity.Type == TargetTypeAsset || entity.Type == TargetTypeTask) && entity.ID != 0
}

type GraphRankEntity struct {
	Type uint16
	ID   uint64
}

type GraphRankPath struct {
	AnchorIndex uint8
	Depth       uint8
	EdgeIDs     []uint64
}

type GraphRankEntry struct {
	Entity GraphRankEntity
	Score  float64
	Paths  []GraphRankPath
}

type GraphRankResult struct {
	ConvID        uint64
	Truncated     bool
	Entries       []GraphRankEntry
	Edges         []Edge
	CorrelationID uint32
}

// EncodeGraphRankWithCorrelation asks the server to rank a bounded multi-anchor
// neighborhood. Candidates are search hits whose graph scores must be returned
// even when they do not rank among the strongest graph-only entities.
func EncodeGraphRankWithCorrelation(convID uint64, anchors, candidates []GraphRankEntity, maxDepth uint8, relationMask uint16, direction uint8, topN uint8, correlationID uint32) ([]byte, error) {
	if len(anchors) == 0 || len(anchors) > MaxGraphRankAnchors {
		return nil, fmt.Errorf("graph rank anchor count must be between 1 and %d", MaxGraphRankAnchors)
	}
	if len(candidates) > MaxGraphRankCandidates {
		return nil, fmt.Errorf("graph rank candidate count must not exceed %d", MaxGraphRankCandidates)
	}
	if convID != WorkspaceDataConvID || maxDepth == 0 || maxDepth > MaxGraphRankDepth || direction > 2 || topN == 0 || topN > MaxGraphRankCandidates {
		return nil, fmt.Errorf("graph rank request options are invalid")
	}
	for _, entity := range anchors {
		if !validGraphRankEntity(entity) {
			return nil, fmt.Errorf("graph rank anchor is invalid")
		}
	}
	for _, entity := range candidates {
		if !validGraphRankEntity(entity) {
			return nil, fmt.Errorf("graph rank candidate is invalid")
		}
	}
	buf := bytes.NewBuffer(make([]byte, 0, 19+(len(anchors)+len(candidates))*10))
	_ = binary.Write(buf, binary.BigEndian, convID)
	buf.WriteByte(uint8(len(anchors)))
	for _, entity := range anchors {
		_ = binary.Write(buf, binary.BigEndian, entity.Type)
		_ = binary.Write(buf, binary.BigEndian, entity.ID)
	}
	buf.WriteByte(uint8(len(candidates)))
	for _, entity := range candidates {
		_ = binary.Write(buf, binary.BigEndian, entity.Type)
		_ = binary.Write(buf, binary.BigEndian, entity.ID)
	}
	buf.WriteByte(maxDepth)
	_ = binary.Write(buf, binary.BigEndian, relationMask)
	buf.WriteByte(direction)
	buf.WriteByte(topN)
	_ = binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes(), nil
}

func DecodeGraphRankResult(data []byte) (*GraphRankResult, error) {
	if len(data) < 15 {
		return nil, fmt.Errorf("graph rank result payload too short")
	}
	result := &GraphRankResult{ConvID: binary.BigEndian.Uint64(data)}
	offset := 8
	result.Truncated = data[offset] != 0
	offset++
	entryCount := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2
	if entryCount > MaxGraphRankEntries {
		return nil, fmt.Errorf("graph rank entry count %d exceeds maximum %d", entryCount, MaxGraphRankEntries)
	}
	result.Entries = make([]GraphRankEntry, 0, entryCount)
	for i := 0; i < entryCount; i++ {
		if len(data) < offset+19 {
			return nil, fmt.Errorf("graph rank entry %d truncated", i)
		}
		entry := GraphRankEntry{
			Entity: GraphRankEntity{Type: binary.BigEndian.Uint16(data[offset:]), ID: binary.BigEndian.Uint64(data[offset+2:])},
			Score:  math.Float64frombits(binary.BigEndian.Uint64(data[offset+10:])),
		}
		if !validGraphRankEntity(entry.Entity) || math.IsNaN(entry.Score) || math.IsInf(entry.Score, 0) {
			return nil, fmt.Errorf("graph rank entry %d is invalid", i)
		}
		offset += 18
		pathCount := int(data[offset])
		offset++
		if pathCount > MaxGraphRankPaths {
			return nil, fmt.Errorf("graph rank entry %d path count exceeds maximum %d", i, MaxGraphRankPaths)
		}
		entry.Paths = make([]GraphRankPath, 0, pathCount)
		for j := 0; j < pathCount; j++ {
			if len(data) < offset+3 {
				return nil, fmt.Errorf("graph rank entry %d path %d truncated", i, j)
			}
			path := GraphRankPath{AnchorIndex: data[offset], Depth: data[offset+1]}
			edgeCount := int(data[offset+2])
			offset += 3
			if path.AnchorIndex >= MaxGraphRankAnchors || path.Depth == 0 || int(path.Depth) != edgeCount || edgeCount > MaxGraphRankDepth || len(data) < offset+edgeCount*8 {
				return nil, fmt.Errorf("graph rank entry %d path %d has invalid edges", i, j)
			}
			path.EdgeIDs = make([]uint64, edgeCount)
			for k := range path.EdgeIDs {
				path.EdgeIDs[k] = binary.BigEndian.Uint64(data[offset:])
				offset += 8
			}
			entry.Paths = append(entry.Paths, path)
		}
		result.Entries = append(result.Entries, entry)
	}
	if len(data) < offset+2 {
		return nil, fmt.Errorf("graph rank result missing edge count")
	}
	edgeCount := int(binary.BigEndian.Uint16(data[offset:]))
	offset += 2
	if edgeCount > MaxGraphRankEdges {
		return nil, fmt.Errorf("graph rank edge count %d exceeds maximum %d", edgeCount, MaxGraphRankEdges)
	}
	result.Edges = make([]Edge, 0, edgeCount)
	for i := 0; i < edgeCount; i++ {
		if len(data) < offset+30 {
			return nil, fmt.Errorf("graph rank edge %d truncated", i)
		}
		edge := Edge{
			EdgeID:     binary.BigEndian.Uint64(data[offset:]),
			ConvID:     result.ConvID,
			SourceType: binary.BigEndian.Uint16(data[offset+8:]),
			SourceID:   binary.BigEndian.Uint64(data[offset+10:]),
			TargetType: binary.BigEndian.Uint16(data[offset+18:]),
			TargetID:   binary.BigEndian.Uint64(data[offset+20:]),
			Relation:   binary.BigEndian.Uint16(data[offset+28:]),
		}
		if edge.EdgeID == 0 || edge.SourceID == 0 || edge.TargetID == 0 ||
			(edge.SourceType != TargetTypeAsset && edge.SourceType != TargetTypeTask) ||
			(edge.TargetType != TargetTypeAsset && edge.TargetType != TargetTypeTask) ||
			edge.Relation < RelationReferences || edge.Relation > RelationMemberOf {
			return nil, fmt.Errorf("graph rank edge %d is invalid", i)
		}
		result.Edges = append(result.Edges, edge)
		offset += 30
	}
	if len(data) != offset+4 {
		return nil, fmt.Errorf("graph rank result has invalid trailing length")
	}
	result.CorrelationID = binary.BigEndian.Uint32(data[offset:])
	return result, nil
}
