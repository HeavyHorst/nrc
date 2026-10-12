package protocol

import (
	"encoding/binary"
	"testing"
)

func TestDecodeWorkspaceOverview(t *testing.T) {
	payload := make([]byte, 103)
	payload[8] = 1
	binary.BigEndian.PutUint64(payload[9:], 123456789)
	for i := 0; i < 20; i++ {
		binary.BigEndian.PutUint32(payload[17+i*4:], uint32(i+65536))
	}
	binary.BigEndian.PutUint32(payload[99:], 0x12345678)
	got, err := DecodeWorkspaceOverview(payload)
	if err != nil {
		t.Fatal(err)
	}
	if got.StatusCounts != [4]uint32{65536, 65537, 65538, 65539} || got.AssignedTasks != 65540 || got.UnassignedTasks != 65541 || got.OpenSlices != 65542 ||
		got.SizeBuckets != [5]uint32{65543, 65544, 65545, 65546, 65547} || got.BlockedBuckets != [3]uint32{65548, 65549, 65550} ||
		got.AgeBuckets != [5]uint32{65551, 65552, 65553, 65554, 65555} || got.SampledAt != 123456789 || got.CorrelationID != 0x12345678 || !got.Success {
		t.Fatalf("wire fields shifted or narrowed: %+v", got)
	}
	for _, invalid := range [][]byte{payload[:102], append(append([]byte{}, payload...), 0)} {
		if _, err := DecodeWorkspaceOverview(invalid); err == nil {
			t.Fatal("accepted malformed length")
		}
	}
	payload[8] = 2
	if _, err := DecodeWorkspaceOverview(payload); err == nil {
		t.Fatal("accepted invalid success flag")
	}
	payload[8] = 0
	binary.BigEndian.PutUint16(payload[97:], 1)
	if _, err := DecodeWorkspaceOverview(payload); err == nil {
		t.Fatal("accepted missing error bytes")
	}
	failure := append(append([]byte{}, payload[:99]...), 'x', 0, 0, 0, 7)
	got, err = DecodeWorkspaceOverview(failure)
	if err != nil || got.Success || got.Error != "x" || got.CorrelationID != 7 {
		t.Fatalf("failed response: %+v, %v", got, err)
	}
}
