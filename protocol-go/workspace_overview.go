package protocol

import (
	"encoding/binary"
	"fmt"
	"unicode/utf8"
)

// WorkspaceOverview is one unpaged snapshot. Buckets count open slices;
// coverage and status counts count unique tasks, excluding retired Notes.
type WorkspaceOverview struct {
	ConvID                                     uint64
	Success                                    bool
	SampledAt                                  int64
	StatusCounts                               [4]uint32
	AssignedTasks, UnassignedTasks, OpenSlices uint32
	SizeBuckets                                [5]uint32
	BlockedBuckets                             [3]uint32
	AgeBuckets                                 [5]uint32
	Error                                      string
	CorrelationID                              uint32
}

// DecodeWorkspaceOverview reads the response body, without its opcode.
func DecodeWorkspaceOverview(payload []byte) (*WorkspaceOverview, error) {
	if len(payload) < 103 || payload[8] > 1 {
		return nil, fmt.Errorf("invalid workspace overview header")
	}
	errorLen := int(binary.BigEndian.Uint16(payload[97:]))
	if len(payload) != 103+errorLen || !utf8.Valid(payload[99:99+errorLen]) {
		return nil, fmt.Errorf("invalid workspace overview length or error")
	}
	result := &WorkspaceOverview{ConvID: binary.BigEndian.Uint64(payload), Success: payload[8] == 1,
		SampledAt: int64(binary.BigEndian.Uint64(payload[9:])), Error: string(payload[99 : 99+errorLen]),
		CorrelationID: binary.BigEndian.Uint32(payload[99+errorLen:])}
	offset := 17
	read := func() uint32 { value := binary.BigEndian.Uint32(payload[offset:]); offset += 4; return value }
	for i := range result.StatusCounts {
		result.StatusCounts[i] = read()
	}
	result.AssignedTasks, result.UnassignedTasks, result.OpenSlices = read(), read(), read()
	for i := range result.SizeBuckets {
		result.SizeBuckets[i] = read()
	}
	for i := range result.BlockedBuckets {
		result.BlockedBuckets[i] = read()
	}
	for i := range result.AgeBuckets {
		result.AgeBuckets[i] = read()
	}
	return result, nil
}
