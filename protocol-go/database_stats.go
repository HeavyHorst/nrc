package protocol

// DatabaseStats is the opt-in worker-port telemetry extension. Buckets are
// disjoint and sums are nanoseconds; exporters must form cumulative buckets.
type DatabaseStats struct {
	Generation [2]uint64 // v2 process incarnation; zero for legacy v1.
	Sequence   uint64    // v2 worker-owned sample order across connections.
	Counters   [22]uint64
	Histograms [8]DatabaseHistogram
}

type DatabaseHistogram struct {
	Buckets [14]uint64
	SumNS   uint64
}

const databaseStatsV1Size = 1 + 8*(22+8*15)
const databaseStatsSize = databaseStatsV1Size + 24

var DatabaseBoundsNS = [...]uint64{50000, 100000, 250000, 500000, 1000000, 2500000, 5000000, 10000000, 25000000, 50000000, 100000000, 250000000, 1000000000}

// EncodeDatabaseStats opts into telemetry. EncodeStats remains byte-compatible
// with old servers and clients. This request requires a telemetry-aware server.
func EncodeDatabaseStats(timestamp int64) []byte {
	return append(EncodeStats(timestamp), 2)
}
