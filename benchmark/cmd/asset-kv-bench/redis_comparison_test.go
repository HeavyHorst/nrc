package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"sort"
	"strconv"
	"testing"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

const (
	comparisonPopulation = 4096
	comparisonHot        = 32
	comparisonWarmWaves  = 16
)

type comparisonShape struct {
	operationsPerRequest int
	requestsPerWave      int
}

type comparisonResult struct {
	Backend          string  `json:"backend"`
	Shape            string  `json:"shape"`
	PayloadBytes     int     `json:"payload_bytes"`
	Operations       int     `json:"operations_per_request"`
	Requests         int     `json:"requests_per_wave"`
	DurationMS       float64 `json:"duration_ms"`
	Updates          int     `json:"updates"`
	UpdatesPerSecond float64 `json:"updates_per_sec"`
	PayloadMBPerSec  float64 `json:"payload_MB_per_sec"`
	WaveP50MS        float64 `json:"wave_p50_ms"`
	WaveP99MS        float64 `json:"wave_p99_ms"`
	RequestBytes     uint64  `json:"serialized_request_bytes"`
}

func comparisonShapeFor(name string) (comparisonShape, bool) {
	switch name {
	case "single":
		return comparisonShape{1, 1}, true
	case "pipeline":
		return comparisonShape{1, 128}, true
	case "batch":
		return comparisonShape{32, 1}, true
	case "batch-pipeline":
		return comparisonShape{32, 4}, true
	default:
		return comparisonShape{}, false
	}
}

// comparisonAssignment gives every key alternating values on successive writes.
// Sixty-four waves are a complete period for every supported shape.
func comparisonAssignment(wave, position, width int) (key, variant int) {
	logical := wave*width + position
	return logical % comparisonHot, (logical / comparisonHot) % 2
}

func comparisonPayload(size, variant int) []byte {
	b := make([]byte, size)
	var x uint32 = uint32(0x9e3779b9 + variant*0x13579b)
	for i := range b {
		x = x*1664525 + 1013904223
		b[i] = byte(x >> 24)
	}
	return b
}

func readRedisOK(r *bufio.Reader) error {
	prefix, err := r.ReadByte()
	if err != nil {
		return err
	}
	line, _, err := readRESPLine(r)
	if err != nil {
		return err
	}
	if prefix != '+' || line != "OK" {
		return fmt.Errorf("expected Redis +OK, got %q%s", prefix, line)
	}
	return nil
}

func readRedisBulk(r *bufio.Reader) ([]byte, error) {
	prefix, err := r.ReadByte()
	if err != nil {
		return nil, err
	}
	line, _, err := readRESPLine(r)
	if err != nil {
		return nil, err
	}
	if prefix == '-' {
		return nil, fmt.Errorf("Redis error: %s", line)
	}
	if prefix != '$' {
		return nil, fmt.Errorf("expected Redis bulk reply, got %q%s", prefix, line)
	}
	n, err := strconv.Atoi(line)
	if err != nil || n < 0 {
		return nil, fmt.Errorf("invalid Redis bulk length %q", line)
	}
	b := make([]byte, n+2)
	if _, err := io.ReadFull(r, b); err != nil {
		return nil, err
	}
	if b[n] != '\r' || b[n+1] != '\n' {
		return nil, fmt.Errorf("malformed Redis bulk terminator")
	}
	return b[:n], nil
}

func writeComparisonAll(conn net.Conn, data []byte) error {
	for len(data) != 0 {
		n, err := conn.Write(data)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrUnexpectedEOF
		}
		data = data[n:]
	}
	return nil
}

func buildNRCComparisonWaves(t *testing.T, refs []assetRef, convID uint64, shape comparisonShape, values [2][]byte) ([64][]transactionBenchPacket, uint64) {
	t.Helper()
	var waves [64][]transactionBenchPacket
	var total uint64
	width := shape.operationsPerRequest * shape.requestsPerWave
	for phase := range waves {
		if phase >= max(1, 64/width) {
			waves[phase] = waves[phase%max(1, 64/width)]
			for _, packet := range waves[phase] {
				total += uint64(len(packet.wire))
			}
			continue
		}
		for request := 0; request < shape.requestsPerWave; request++ {
			packet := transactionBenchPacket{corr: uint32(request + 1), txn: shape.operationsPerRequest > 1}
			var operations []protocol.TransactionOperation
			var body []byte
			for op := 0; op < shape.operationsPerRequest; op++ {
				position := request*shape.operationsPerRequest + op
				key, variant := comparisonAssignment(phase, position, width)
				packet.ids = append(packet.ids, refs[key].ID)
				if packet.txn {
					patch, err := protocol.EncodeTransactionAssetPatch(protocol.TransactionAssetPatch{
						ConvID: convID, Asset: protocol.Existing(protocol.TransactionEntityAsset, refs[key].ID),
						Present: protocol.TransactionAssetPatchPreview | protocol.TransactionAssetPatchPayload,
						Preview: []byte{}, Payload: values[variant], PayloadRawLen: uint32(len(values[variant])),
					})
					if err != nil {
						t.Fatal(err)
					}
					operations = append(operations, protocol.TransactionOperation{Type: protocol.TransactionOpAssetPatch, Body: patch})
				} else {
					body = protocol.EncodeUpdateAssetWithMetadataAndCorrelation(int64(convID), refs[key].ID,
						protocol.AssetPayloadEncodingPlain, uint32(len(values[variant])), "", string(values[variant]), packet.corr)
				}
			}
			opcode := uint16(protocol.C_UpdateAsset)
			if packet.txn {
				opcode = protocol.C_ApplyTransaction
				var err error
				body, err = protocol.EncodeApplyTransaction(packet.corr, operations)
				if err != nil {
					t.Fatal(err)
				}
			}
			var err error
			packet.wire, err = (&protocol.Message{Opcode: opcode, Data: body}).Write()
			if err != nil {
				t.Fatal(err)
			}
			total += uint64(len(packet.wire))
			waves[phase] = append(waves[phase], packet)
		}
	}
	return waves, total / 64
}

func buildRedisComparisonWaves(shape comparisonShape, keys []string, values [2][]byte) ([64][]byte, uint64) {
	var waves [64][]byte
	var total uint64
	width := shape.operationsPerRequest * shape.requestsPerWave
	for phase := range waves {
		if phase >= max(1, 64/width) {
			waves[phase] = waves[phase%max(1, 64/width)]
			total += uint64(len(waves[phase]))
			continue
		}
		var wave bytes.Buffer
		for request := 0; request < shape.requestsPerWave; request++ {
			if shape.operationsPerRequest == 1 {
				key, variant := comparisonAssignment(phase, request, width)
				writeRESPArray(&wave, "SET", []byte(keys[key]), values[variant])
			} else {
				args := make([][]byte, 0, shape.operationsPerRequest*2)
				for op := 0; op < shape.operationsPerRequest; op++ {
					key, variant := comparisonAssignment(phase, request*shape.operationsPerRequest+op, width)
					args = append(args, []byte(keys[key]), values[variant])
				}
				writeRESPArray(&wave, "MSET", args...)
			}
		}
		waves[phase] = append([]byte(nil), wave.Bytes()...)
		total += uint64(wave.Len())
	}
	return waves, total / 64
}

// TestRedisComparison is an opt-in, single-connection real-server comparison.
func TestRedisComparison(t *testing.T) {
	backend := os.Getenv("KV_COMPARE_BACKEND")
	if backend == "" {
		t.Skip("set KV_COMPARE_BACKEND=nrc or redis and start the corresponding isolated server")
	}
	if backend != "nrc" && backend != "redis" {
		t.Fatal("KV_COMPARE_BACKEND must be nrc or redis")
	}
	shapeName := os.Getenv("KV_COMPARE_SHAPE")
	shape, ok := comparisonShapeFor(shapeName)
	if !ok {
		t.Fatal("KV_COMPARE_SHAPE must be single, pipeline, batch, or batch-pipeline")
	}
	payloadBytes, err := strconv.Atoi(os.Getenv("KV_COMPARE_BYTES"))
	if err != nil || (payloadBytes != 64 && payloadBytes != 1024 && payloadBytes != 16384) {
		t.Fatal("KV_COMPARE_BYTES must be 64, 1024, or 16384")
	}
	// Keep large batches below the production 128 KiB WebSocket frame cap.
	if payloadBytes == 16384 && shape.operationsPerRequest > 1 {
		shape.operationsPerRequest = 4
		if shapeName == "batch-pipeline" {
			shape.requestsPerWave = 32
		}
	}
	rounds := 512
	if raw, present := os.LookupEnv("KV_COMPARE_ROUNDS"); present {
		rounds, err = strconv.Atoi(raw)
		if err != nil || rounds <= 0 {
			t.Fatal("KV_COMPARE_ROUNDS must be a positive integer")
		}
	}
	values := [2][]byte{comparisonPayload(payloadBytes, 0), comparisonPayload(payloadBytes, 1)}
	expected := make([]int, comparisonHot)
	for i := range expected {
		// Preload variant 1 so every key's first measured or warm write to
		// variant 0 is also a real value change.
		expected[i] = 1
	}
	width := shape.operationsPerRequest * shape.requestsPerWave
	totalWrites := (comparisonWarmWaves + rounds) * width
	for key := range expected {
		if key < totalWrites {
			lastWrite := key + ((totalWrites-1-key)/comparisonHot)*comparisonHot
			expected[key] = (lastWrite / comparisonHot) % 2
		}
	}
	latencies := make([]int64, rounds)
	var requestBytes uint64
	const convID = uint64(7719)

	if backend == "nrc" {
		cfg := config{ServerURL: "ws://127.0.0.1:18089", Workspaces: 1, Auth: true, JWTSecret: defaultJWTSecret,
			JWTIssuer: defaultJWTIssuer, JWTAudience: defaultJWTAudience, JWTTTL: time.Hour, Timeout: 30 * time.Second}
		w, err := openNRCWorker(context.Background(), cfg, 0)
		if err != nil {
			t.Fatal(err)
		}
		defer w.Close()
		refs := make([]assetRef, 0, comparisonPopulation)
		preload := assetPayload{AssetType: protocol.AssetTypeNote, ParentType: protocol.ParentTypeNone,
			PayloadEncoding: protocol.AssetPayloadEncodingPlain, PayloadRawLen: uint32(payloadBytes), Payload: string(values[1]), Preview: ""}
		for offset := 0; offset < comparisonPopulation; offset += 32 {
			ops := make([]benchOp, 32)
			for i := range ops {
				ops[i] = benchOp{Kind: "create", ConvID: convID, Asset: preload}
			}
			for _, result := range w.ExecuteBatch(context.Background(), ops) {
				if result.Err != nil || result.Ref.ID == 0 {
					t.Fatalf("NRC preload failed: %+v", result)
				}
				refs = append(refs, result.Ref)
			}
		}
		waves, _ := buildNRCComparisonWaves(t, refs, convID, shape, values)
		for round := 0; round < rounds; round++ {
			for _, packet := range waves[(comparisonWarmWaves+round)%64] {
				requestBytes += uint64(len(packet.wire))
			}
		}
		for wave := 0; wave < comparisonWarmWaves; wave++ {
			if err := transactionBenchWave(w, waves[wave%64]); err != nil {
				t.Fatal(err)
			}
		}
		started := time.Now()
		for round := 0; round < rounds; round++ {
			wave := comparisonWarmWaves + round
			waveStart := time.Now()
			if err := transactionBenchWave(w, waves[wave%64]); err != nil {
				t.Fatal(err)
			}
			latencies[round] = time.Since(waveStart).Nanoseconds()
		}
		elapsed := time.Since(started)
		for i := 0; i < comparisonHot; i++ {
			corr := w.nextCorrelationID()
			_, data, err := w.sendAndWait(protocol.C_GetAsset, protocol.EncodeGetAssetWithCorrelation(int64(convID), refs[i].ID, corr), protocol.S_AssetFull, corr)
			if err != nil {
				t.Fatal(err)
			}
			got, err := protocol.DecodeAssetFullResponse(data)
			if err != nil || got.Asset.AssetID != refs[i].ID || got.Asset.Payload != string(values[expected[i]]) || got.Asset.Preview != "" {
				t.Fatalf("NRC hot asset %d final state mismatch: %v", i, err)
			}
		}
		verifyNRCCold(t, w, convID, refs[len(refs)-1], values[1])
		writeComparisonResult(t, backend, shapeName, payloadBytes, rounds, shape, elapsed, latencies, requestBytes)
		return
	}

	conn, err := net.DialTimeout("tcp", "127.0.0.1:18090", 30*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	r := bufio.NewReader(conn)
	keys := make([]string, comparisonPopulation)
	for i := range keys {
		keys[i] = fmt.Sprintf("nrc-kv-comparison:%d:%d", os.Getpid(), i)
	}
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	for offset := 0; offset < comparisonPopulation; offset += 32 {
		var request bytes.Buffer
		args := make([][]byte, 0, 64)
		for i := 0; i < 32; i++ {
			args = append(args, []byte(keys[offset+i]), values[1])
		}
		writeRESPArray(&request, "MSET", args...)
		if err := writeComparisonAll(conn, request.Bytes()); err != nil {
			t.Fatal(err)
		}
		if err := readRedisOK(r); err != nil {
			t.Fatal(err)
		}
	}
	waves, _ := buildRedisComparisonWaves(shape, keys, values)
	for round := 0; round < rounds; round++ {
		requestBytes += uint64(len(waves[(comparisonWarmWaves+round)%64]))
	}
	runRedisWave := func(wave int) error {
		_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
		if err := writeComparisonAll(conn, waves[wave%64]); err != nil {
			return err
		}
		for request := 0; request < shape.requestsPerWave; request++ {
			if err := readRedisOK(r); err != nil {
				return fmt.Errorf("request %d: %w", request, err)
			}
		}
		return nil
	}
	for wave := 0; wave < comparisonWarmWaves; wave++ {
		if err := runRedisWave(wave); err != nil {
			t.Fatal(err)
		}
	}
	started := time.Now()
	for round := 0; round < rounds; round++ {
		wave := comparisonWarmWaves + round
		waveStart := time.Now()
		if err := runRedisWave(wave); err != nil {
			t.Fatal(err)
		}
		latencies[round] = time.Since(waveStart).Nanoseconds()
	}
	elapsed := time.Since(started)
	for i := 0; i < comparisonHot; i++ {
		verifyRedisValue(t, conn, r, keys[i], values[expected[i]])
	}
	verifyRedisValue(t, conn, r, keys[len(keys)-1], values[1])
	writeComparisonResult(t, backend, shapeName, payloadBytes, rounds, shape, elapsed, latencies, requestBytes)
}

func verifyNRCCold(t *testing.T, w *nrcWorker, convID uint64, ref assetRef, want []byte) {
	t.Helper()
	corr := w.nextCorrelationID()
	_, data, err := w.sendAndWait(protocol.C_GetAsset, protocol.EncodeGetAssetWithCorrelation(int64(convID), ref.ID, corr), protocol.S_AssetFull, corr)
	if err != nil {
		t.Fatal(err)
	}
	got, err := protocol.DecodeAssetFullResponse(data)
	if err != nil || got.Asset.AssetID != ref.ID || got.Asset.Payload != string(want) || got.Asset.Preview != "" {
		t.Fatalf("NRC cold asset final state mismatch: %v", err)
	}
}

func verifyRedisValue(t *testing.T, conn net.Conn, r *bufio.Reader, key string, want []byte) {
	t.Helper()
	var request bytes.Buffer
	writeRESPArray(&request, "GET", []byte(key))
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	if err := writeComparisonAll(conn, request.Bytes()); err != nil {
		t.Fatal(err)
	}
	got, err := readRedisBulk(r)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("Redis key %q final state mismatch: %v", key, err)
	}
}

func writeComparisonResult(t *testing.T, backend, shapeName string, payloadBytes, rounds int, shape comparisonShape, elapsed time.Duration, latencies []int64, requestBytes uint64) {
	t.Helper()
	sorted := append([]int64(nil), latencies...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	updates := rounds * shape.operationsPerRequest * shape.requestsPerWave
	result := comparisonResult{
		Backend: backend, Shape: shapeName, PayloadBytes: payloadBytes,
		Operations: shape.operationsPerRequest, Requests: shape.requestsPerWave,
		DurationMS: float64(elapsed.Nanoseconds()) / 1e6, Updates: updates,
		UpdatesPerSecond: float64(updates) / elapsed.Seconds(),
		PayloadMBPerSec:  float64(updates*payloadBytes) / elapsed.Seconds() / 1e6,
		WaveP50MS:        float64(sorted[len(sorted)/2]) / 1e6,
		WaveP99MS:        float64(sorted[len(sorted)*99/100]) / 1e6,
		RequestBytes:     requestBytes,
	}
	data, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if output := os.Getenv("KV_COMPARE_OUTPUT"); output != "" {
		if err := os.WriteFile(output, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	t.Log(string(data))
}

func TestComparisonAssignmentAlternatesAndCycles(t *testing.T) {
	for _, width := range []int{1, 4, 32, 128} {
		last := make([]int, comparisonHot)
		seen := make([]bool, comparisonHot)
		for wave := 0; wave < 64; wave++ {
			for position := 0; position < width; position++ {
				key, variant := comparisonAssignment(wave, position, width)
				if seen[key] && last[key] == variant {
					t.Fatalf("width %d key %d did not alternate", width, key)
				}
				seen[key], last[key] = true, variant
			}
		}
		for key, ok := range seen {
			if !ok {
				t.Fatalf("width %d never touched key %d", width, key)
			}
		}
	}
}

func TestReadRedisOKStrict(t *testing.T) {
	if err := readRedisOK(bufio.NewReader(bytes.NewBufferString("+OK\r\n"))); err != nil {
		t.Fatal(err)
	}
	for _, reply := range []string{"+PONG\r\n", "-ERR no\r\n", ":1\r\n"} {
		if err := readRedisOK(bufio.NewReader(bytes.NewBufferString(reply))); err == nil {
			t.Fatalf("accepted %q", reply)
		}
	}
}
