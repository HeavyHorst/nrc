package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type transactionBenchPacket struct {
	wire []byte
	ids  []uint64
	corr uint32
	txn  bool
}

func TestWorkerConvIDUsesWorkspaceDataScope(t *testing.T) {
	for _, conversations := range []int{1, 7, 64} {
		for _, worker := range []int{0, 3, 19} {
			for _, asset := range []int{0, 13, 127} {
				if got := workerConvID(config{Conversations: conversations}, worker, asset); got != 0 {
					t.Fatalf("conversations=%d worker=%d asset=%d: scope=%d, want 0", conversations, worker, asset, got)
				}
			}
		}
	}
}

// Drain a complete pipeline wave, checking every correlated ACK and result ID.
func transactionBenchWave(w *nrcWorker, packets []transactionBenchPacket) error {
	_ = w.conn.SetWriteDeadline(time.Now().Add(30 * time.Second))
	_ = w.conn.SetReadDeadline(time.Now().Add(30 * time.Second))
	for _, packet := range packets {
		if err := w.conn.WriteMessage(websocket.BinaryMessage, packet.wire); err != nil {
			return err
		}
	}
	seen := make([]bool, len(packets))
	for range packets {
		_, data, err := w.conn.ReadMessage()
		if err != nil {
			return err
		}
		msg, err := protocol.ReadMessage(data)
		if err != nil {
			return err
		}
		var corr uint32
		var ids []uint64
		if packets[0].txn {
			if msg.Opcode != protocol.S_TransactionResult {
				return fmt.Errorf("unexpected transaction response %d", msg.Opcode)
			}
			result, err := protocol.DecodeTransactionResult(msg.Data)
			if err != nil || result.Status != protocol.TransactionStatusCommitted {
				return fmt.Errorf("transaction did not commit: %+v %v", result, err)
			}
			corr = result.CorrelationID
			for _, item := range result.Results {
				if item.Type != protocol.TransactionOpAssetPatch {
					return fmt.Errorf("unexpected result type %d", item.Type)
				}
				ids = append(ids, item.EntityID)
			}
		} else {
			if msg.Opcode != protocol.S_AssetUpdated {
				return fmt.Errorf("unexpected update response %d", msg.Opcode)
			}
			result, err := protocol.DecodeAssetUpdated(msg.Data)
			if err != nil {
				return err
			}
			corr, ids = result.CorrelationID, []uint64{result.Asset.AssetID}
		}
		if corr == 0 || int(corr) > len(packets) || seen[corr-1] {
			return fmt.Errorf("unexpected/duplicate correlation %d", corr)
		}
		seen[corr-1] = true
		want := packets[corr-1].ids
		if len(want) != len(ids) {
			return fmt.Errorf("result count %d != %d", len(ids), len(want))
		}
		for i := range want {
			if ids[i] != want[i] {
				return fmt.Errorf("result ID %d != %d", ids[i], want[i])
			}
		}
	}
	return nil
}

// Opt-in real-server benchmark. Build once with go test -c; invoke independently
// against a fresh supervised server for each repetition. Normal Go tests skip it.
func TestTransactionThroughput(t *testing.T) {
	if os.Getenv("NRC_TRANSACTION_BENCH") != "1" {
		t.Skip("set NRC_TRANSACTION_BENCH=1 and start an isolated server")
	}
	cfg := config{ServerURL: "ws://127.0.0.1:18089", Workspaces: 1, Auth: true,
		JWTSecret: defaultJWTSecret, JWTIssuer: defaultJWTIssuer, JWTAudience: defaultJWTAudience,
		JWTTTL: time.Hour, Timeout: 30 * time.Second, PayloadSize: 1024, PreviewSize: 128}
	for name, destination := range map[string]*int{
		"NRC_TRANSACTION_BENCH_PAYLOAD_BYTES": &cfg.PayloadSize,
		"NRC_TRANSACTION_BENCH_PREVIEW_BYTES": &cfg.PreviewSize,
	} {
		if value, present := os.LookupEnv(name); present {
			n, err := strconv.Atoi(value)
			if err != nil || n < 0 {
				t.Fatalf("%s must be a nonnegative integer", name)
			}
			*destination = n
		}
	}
	var w *nrcWorker
	var err error
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		w, err = openNRCWorker(context.Background(), cfg, 0)
		if err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	type benchCase struct {
		population, operationsPerRequest, requestsPerWave int
	}
	cases := []benchCase{}
	for _, population := range []int{32, 4096} {
		for _, shape := range [][2]int{{1, 32}, {32, 1}, {1, 128}, {32, 4}} {
			cases = append(cases, benchCase{population, shape[0], shape[1]})
		}
	}
	caseID, err := strconv.Atoi(os.Getenv("NRC_TRANSACTION_BENCH_CASE"))
	if err != nil || caseID < 0 || caseID >= len(cases) {
		t.Fatal("NRC_TRANSACTION_BENCH_CASE must be 0 through 7")
	}
	cases = cases[caseID : caseID+1]
	mutations := 65536
	if value, present := os.LookupEnv("NRC_TRANSACTION_BENCH_INFLIGHT"); present {
		width, err := strconv.Atoi(value)
		if err != nil || (width != 128 && width != 256 && width != 512 && width != 1024) {
			t.Fatal("NRC_TRANSACTION_BENCH_INFLIGHT must be 128, 256, 512 or 1024")
		}
		cases[0].requestsPerWave = width / cases[0].operationsPerRequest
		// Keep 512 measured waves at every depth, rather than shortening deeper
		// pipeline samples and estimating p99 from fewer observations.
		mutations = width * 512
	}
	rows := []map[string]any{}
	for caseIndex, c := range cases {
		convID := uint64(1000 + caseIndex)
		refs := []assetRef{}
		for offset := 0; offset < c.population; offset += 32 {
			batch := make([]benchOp, 32)
			for i := range batch {
				batch[i] = benchOp{Kind: "create", ConvID: convID, Asset: makeAssetPayload(cfg, 0, offset+i, false)}
			}
			for _, r := range w.ExecuteBatch(context.Background(), batch) {
				if r.Err != nil || r.Ref.ID == 0 {
					t.Fatalf("preload: %+v", r)
				}
				refs = append(refs, r.Ref)
			}
		}
		// Pre-encode two alternating waves. All modes update the same 32 hot
		// assets; populated conversations add unchanged indexed Note assets.
		var waves [2][]transactionBenchPacket
		var values [2]assetPayload
		for parity := range waves {
			values[parity] = makeAssetPayload(cfg, 0, parity, true)
			for request := 0; request < c.requestsPerWave; request++ {
				packet := transactionBenchPacket{corr: uint32(request + 1), txn: c.operationsPerRequest > 1}
				operations := []protocol.TransactionOperation{}
				var payload []byte
				opcode := uint16(protocol.C_UpdateAsset)
				for op := 0; op < c.operationsPerRequest; op++ {
					index := request*c.operationsPerRequest + op
					ref := refs[index%32]
					value := makeAssetPayload(cfg, 0, (parity+index/32)%2, true)
					packet.ids = append(packet.ids, ref.ID)
					if packet.txn {
						body, e := protocol.EncodeTransactionAssetPatch(protocol.TransactionAssetPatch{
							ConvID: convID, Asset: protocol.Existing(protocol.TransactionEntityAsset, ref.ID),
							Present: protocol.TransactionAssetPatchPreview | protocol.TransactionAssetPatchPayload,
							Preview: []byte(value.Preview), Payload: []byte(value.Payload), PayloadRawLen: value.PayloadRawLen})
						if e != nil {
							t.Fatal(e)
						}
						operations = append(operations, protocol.TransactionOperation{Type: protocol.TransactionOpAssetPatch, Body: body})
					} else {
						payload = protocol.EncodeUpdateAssetWithMetadataAndCorrelation(int64(convID), ref.ID, value.PayloadEncoding, value.PayloadRawLen, value.Preview, value.Payload, packet.corr)
					}
				}
				if packet.txn {
					opcode = protocol.C_ApplyTransaction
					payload, err = protocol.EncodeApplyTransaction(packet.corr, operations)
					if err != nil {
						t.Fatal(err)
					}
				}
				packet.wire, err = (&protocol.Message{Opcode: opcode, Data: payload}).Write()
				if err != nil {
					t.Fatal(err)
				}
				waves[parity] = append(waves[parity], packet)
			}
		}
		for warm := 0; warm < 16; warm++ {
			if err := transactionBenchWave(w, waves[warm%2]); err != nil {
				t.Fatal(err)
			}
		}
		width := c.operationsPerRequest * c.requestsPerWave
		rounds := mutations / width
		latencies := make([]float64, rounds)
		started := time.Now()
		for round := 0; round < rounds; round++ {
			waveStart := time.Now()
			err = transactionBenchWave(w, waves[round%2])
			latencies[round] = float64(time.Since(waveStart).Nanoseconds()) / 1e6
			if err != nil {
				break
			}
		}
		elapsed := time.Since(started)
		if err != nil {
			t.Fatal(err)
		}
		// Verify final payloads and previews, including one untouched cold asset.
		for i, ref := range refs {
			if i >= 32 && i != len(refs)-1 {
				continue
			}
			want := ref.Asset
			if i < 32 {
				want = values[((rounds-1)%2+(width-1)/32)%2]
			}
			corr := w.nextCorrelationID()
			_, data, e := w.sendAndWait(protocol.C_GetAsset, protocol.EncodeGetAssetWithCorrelation(int64(convID), ref.ID, corr), protocol.S_AssetFull, corr)
			if e != nil {
				t.Fatal(e)
			}
			got, e := protocol.DecodeAssetFullResponse(data)
			if e != nil || got.Asset.AssetID != ref.ID || got.Asset.Payload != want.Payload || got.Asset.Preview != want.Preview {
				t.Fatalf("final state mismatch for asset %d: %v", ref.ID, e)
			}
		}
		sort.Float64s(latencies)
		row := map[string]any{"population": c.population, "operations_per_request": c.operationsPerRequest,
			"payload_bytes": cfg.PayloadSize, "preview_bytes": cfg.PreviewSize,
			"requests_per_wave": c.requestsPerWave, "mutations": mutations,
			"mutations_per_sec": float64(mutations) / elapsed.Seconds(), "duration_ms": float64(elapsed.Nanoseconds()) / 1e6,
			"wave_p50_ms": latencies[len(latencies)/2], "wave_p99_ms": latencies[len(latencies)*99/100]}
		rows = append(rows, row)
		t.Log(row)
	}
	data, err := json.MarshalIndent(rows, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(os.Getenv("NRC_TRANSACTION_BENCH_OUTPUT"), data, 0600); err != nil {
		t.Fatal(err)
	}
}
