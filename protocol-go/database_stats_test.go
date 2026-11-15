package protocol

import (
	"encoding/binary"
	"testing"
)

func TestDatabaseStatsExtension(t *testing.T) {
	legacy := statsShardSweepFixture()
	for _, version := range []byte{1, 2} {
		size, header := databaseStatsV1Size, 1
		if version == 2 {
			size, header = databaseStatsSize, 25
		}
		payload := append(append([]byte{}, legacy...), make([]byte, size)...)
		payload[len(legacy)] = version
		if version == 2 {
			binary.BigEndian.PutUint64(payload[len(legacy)+1:], 0xfedcba9876543210)
			binary.BigEndian.PutUint64(payload[len(legacy)+9:], 37)
			binary.BigEndian.PutUint64(payload[len(legacy)+17:], 0x123456789abcdef0)
		}
		// Independent wire construction checks counter/histogram order and widths.
		for i := 0; i < 142; i++ {
			binary.BigEndian.PutUint64(payload[len(legacy)+header+i*8:], uint64(i+11))
		}
		stats, err := DecodeStatsResponse(payload)
		if err != nil {
			t.Fatal(err)
		}
		if stats.Database.Counters[21] != 32 || stats.Database.Histograms[0].Buckets[0] != 33 || stats.Database.Histograms[7].SumNS != 152 {
			t.Fatalf("incorrect extension layout: %+v", stats.Database)
		}
		if version == 2 && (stats.Database.Generation != [2]uint64{0xfedcba9876543210, 37} || stats.Database.Sequence != 0x123456789abcdef0) {
			t.Fatal("lost v2 identity/order")
		}
		if version == 1 && (stats.Database.Generation != [2]uint64{} || stats.Database.Sequence != 0) {
			t.Fatal("fabricated v1 identity")
		}
		old, err := DecodeStatsResponse(legacy)
		if err != nil || old.Database != nil {
			t.Fatalf("legacy: %+v, %v", old, err)
		}
		for _, malformed := range [][]byte{payload[:len(payload)-1], append(append([]byte{}, payload...), 0)} {
			if _, err := DecodeStatsResponse(malformed); err == nil {
				t.Fatal("accepted bad length")
			}
		}
		payload[len(legacy)] = 3
		if _, err := DecodeStatsResponse(payload); err == nil {
			t.Fatal("accepted unknown version")
		}
		// A supported version with the other version's length must also fail.
		payload[len(legacy)] = 3 - version
		if _, err := DecodeStatsResponse(payload); err == nil {
			t.Fatal("accepted mismatched version/length")
		}
	}
	if got := EncodeDatabaseStats(93); len(got) != 9 || got[8] != 2 || binary.BigEndian.Uint64(got) != 93 {
		t.Fatalf("request: %x", got)
	}
	if len(EncodeStats(93)) != 8 {
		t.Fatal("legacy request changed")
	}
}
