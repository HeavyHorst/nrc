package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	p "github.com/heavyhorst/nrc/protocol-go"
)

// This test never builds Odin. Supply an absolute path to a server built from
// the same revision; all server state and DuckDB files belong to this test.
func TestHistorySnapshotOutboxIntegration(t *testing.T) {
	binary := os.Getenv("NRC_HISTORY_TEST_SERVER")
	if binary == "" {
		t.Skip("set NRC_HISTORY_TEST_SERVER to an absolute local NRC server binary")
	}
	if !filepath.IsAbs(binary) {
		t.Fatal("NRC_HISTORY_TEST_SERVER must be absolute")
	}
	create := func(t *testing.T, user *websocket.Conn) p.Asset {
		t.Helper()
		asset := monitorAsset("http://127.0.0.1:1/unused")
		asset.Preview = strings.ReplaceAll(strings.ReplaceAll(asset.Preview, `"interval_ns":1000000000`, `"interval_ns":60000000000`), `"timeout_ns":1000000000`, `"timeout_ns":10000000000`)
		wire, err := (&p.Message{Opcode: p.C_CreateAsset, Data: p.EncodeCreateAsset(0, p.AssetTypeMonitor, p.ParentTypeNone, 0, asset.Preview, asset.Payload)}).Write()
		if err != nil {
			t.Fatal(err)
		}
		user.SetWriteDeadline(time.Now().Add(15 * time.Second))
		if err := user.WriteMessage(websocket.BinaryMessage, wire); err != nil {
			t.Fatal(err)
		}
		for {
			user.SetReadDeadline(time.Now().Add(15 * time.Second))
			_, body, err := user.ReadMessage()
			if err != nil {
				t.Fatal(err)
			}
			msg, err := p.ReadMessage(body)
			if err != nil {
				t.Fatal(err)
			}
			if msg.Opcode == p.S_ErrorResponse {
				t.Fatalf("create monitor rejected: %x", msg.Data)
			}
			if msg.Opcode == p.S_AssetCreated {
				created, err := p.DecodeAssetCreated(msg.Data)
				if err != nil {
					t.Fatal(err)
				}
				return created.Asset
			}
		}
	}
	for _, tc := range []struct {
		name                 string
		monitors, runs, rows int
		load, concurrent     bool
	}{
		{"two_waves_paginated", 93, 186, 17, false, false},
		{"beyond_old_256_queue", 1, 493, 1, false, false},
		{"sustained_25_per_second_90_seconds", 93, 2250, 1, true, false},
		{"concurrent_hot_monitor_25_per_second_90_seconds", 1, 2250, 17, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if tc.load && os.Getenv("NRC_HISTORY_LOAD_TEST") != "1" {
				t.Skip("set NRC_HISTORY_LOAD_TEST=1 for the sustained load case")
			}
			source, user := startOutboxServer(t, binary)
			ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
			defer cancel()
			assets := make([]p.Asset, tc.monitors)
			ids := make([]uint64, tc.monitors)
			for i := range assets {
				assets[i] = create(t, user)
				ids[i] = assets[i].AssetID
			}
			type key struct{ id, sequence uint64 }
			type accepted struct {
				run           p.ApplyMonitorRun
				before, after int64
			}
			want := make(map[key]accepted)
			h := newHistoryWriter()
			path := filepath.Join(t.TempDir(), "history.duckdb")
			var wg sync.WaitGroup
			defer func() { cancel(); wg.Wait() }()
			if tc.concurrent {
				// Run both real consumers before admission, unlike the retained
				// backlog cases. All sequences contend on one paginated monitor.
				wg.Add(2)
				go func() { defer wg.Done(); h.serve(ctx, path) }()
				go func() { defer wg.Done(); collectStoredAvailability(ctx, h, newMonitorSet(ids), source, "proof", 8) }()
				outboxEventually(t, ctx, func() bool { return h.db.Load() != nil }, "concurrent writer startup")
			}
			start := time.Now()
			admissionCtx := ctx
			if tc.load {
				var stopAdmission context.CancelFunc
				admissionCtx, stopAdmission = context.WithDeadline(ctx, start.Add(91*time.Second))
				defer stopAdmission()
			}
			committedDuringAdmission := 0
			for i := 0; i < tc.runs; i++ {
				if tc.load {
					timer := time.NewTimer(time.Until(start.Add(time.Duration(i+1) * 40 * time.Millisecond)))
					select {
					case <-admissionCtx.Done():
						timer.Stop()
						t.Fatal(admissionCtx.Err())
					case <-timer.C:
					}
				}
				a := assets[i%len(assets)]
				run := p.ApplyMonitorRun{CorrelationID: 1, MonitorID: a.AssetID, Revision: a.UpdatedAt, Sequence: uint64(i/len(assets) + 1)}
				for j := 0; j < tc.rows; j++ {
					run.Observations = append(run.Observations, p.MonitorObservation{Identity: fmt.Sprintf("instance-%02d", j), Condition: uint8((int(run.Sequence) + j) % 2), Value: float64(i + j)})
				}
				before := time.Now().UnixNano()
				status, err := source.apply(admissionCtx, run)
				if err != nil || status != "confirmed" {
					t.Fatalf("apply %d/%d: acceptance=%s err=%v", i+1, tc.runs, status, err)
				}
				want[key{run.MonitorID, run.Sequence}] = accepted{run, before, time.Now().UnixNano()}
				// Deliberately exercise disposable raw-history overflow as well. It
				// must never suppress the independently durable snapshot outbox.
				h.offer(historyRun{ID: fmt.Sprintf("proof-%d", i), Workspace: "proof", Acceptance: status, Run: run, ObservedAt: before})
				if tc.concurrent && (i == tc.runs/2-1 || i == tc.runs-1) {
					db := h.db.Load()
					if db == nil {
						t.Fatal("concurrent writer lost its database during admission")
					}
					var committed int
					if err := db.QueryRowContext(admissionCtx, "SELECT count(*) FROM uptime_snapshots").Scan(&committed); err != nil {
						t.Fatal(err)
					}
					if committed <= committedDuringAdmission {
						t.Fatalf("collector/writer made no concurrent progress: accepted=%d committed=%d previous=%d", i+1, committed, committedDuringAdmission)
					}
					// At 25/sec, allow two seconds of delivery lag, not a
					// steadily growing backlog that only drains after admission stops.
					if i+1-committed > 50 {
						t.Fatalf("concurrent delivery fell behind by over two seconds: accepted=%d committed=%d", i+1, committed)
					}
					committedDuringAdmission = committed
					t.Logf("concurrent progress: accepted=%d committed_snapshots=%d elapsed=%s", i+1, committed, time.Since(start))
				}
			}
			if tc.load {
				elapsed := time.Since(start)
				if elapsed > 91*time.Second {
					t.Fatalf("could not sustain 25 confirmed runs/sec: %d accepted in %s", len(want), elapsed)
				}
				t.Logf("sustained admission: %d confirmed runs in %s (target 25/sec for 90sec)", len(want), elapsed)
			}
			if !tc.concurrent && tc.runs > 256 && h.dropped.Load() != uint64(tc.runs-256) {
				t.Fatalf("fixture did not overflow raw queue: dropped=%d", h.dropped.Load())
			}
			if !tc.concurrent {
				// Simulate sink commit followed by a lost outbox ACK. Reading twice
				// must return the original immutable evidence, not the newest run.
				page, found, err := source.pendingSnapshot(ctx, ids[0])
				if err != nil || !found || page.Sequence != 1 || len(page.Instances) != tc.rows {
					t.Fatalf("oldest pending page: %+v found=%v err=%v", page, found, err)
				}
				db, err := openHistory(ctx, path)
				if err != nil {
					t.Fatal(err)
				}
				if err := writeAvailability(ctx, db, historySnapshot{Workspace: "proof", MonitorSnapshotPage: page}); err != nil {
					db.Close()
					t.Fatal(err)
				}
				db.Close()
				again, found, err := source.pendingSnapshot(ctx, ids[0])
				if err != nil || !found || !reflect.DeepEqual(page, again) {
					t.Fatalf("unacknowledged evidence changed: found=%v err=%v", found, err)
				}
				gate := &outboxAckGate{nrcSource: source, page: page, entered: make(chan struct{}), release: make(chan struct{})}
				wg.Add(1)
				go func() { defer wg.Done(); collectStoredAvailability(ctx, h, newMonitorSet(ids), gate, "proof", 8) }()
				outboxEventually(t, ctx, func() bool { return len(h.snapshots) > 0 }, "collector handoff without writer")
				again, found, err = source.pendingSnapshot(ctx, ids[0])
				if err != nil || !found || !reflect.DeepEqual(page, again) {
					t.Fatalf("collector acknowledged before writer commit: found=%v err=%v", found, err)
				}
				wg.Add(1)
				go func() { defer wg.Done(); h.serve(ctx, path) }()
				select {
				case <-gate.entered:
				case <-ctx.Done():
					t.Fatal("replayed snapshot never reached post-commit acknowledgment")
				}
				var replaySnapshots, replayStates int
				if err := h.db.Load().QueryRowContext(ctx, `SELECT
 (SELECT count(*) FROM uptime_snapshots WHERE monitor_id=? AND observed_at=?),
 (SELECT count(*) FROM uptime_states WHERE monitor_id=? AND observed_at=?)`, page.MonitorID, page.At, page.MonitorID, page.At).Scan(&replaySnapshots, &replayStates); err != nil {
					t.Fatal(err)
				}
				if replaySnapshots != 1 || replayStates != tc.rows {
					t.Fatalf("lost-ACK replay duplicated sink rows before ACK: snapshots=%d states=%d", replaySnapshots, replayStates)
				}
				again, found, err = source.pendingSnapshot(ctx, ids[0])
				if err != nil || !found || !reflect.DeepEqual(page, again) {
					t.Fatalf("replayed snapshot disappeared before ACK: found=%v err=%v", found, err)
				}
				close(gate.release)
			}
			outboxEventually(t, ctx, func() bool {
				db := h.db.Load()
				if db == nil {
					return false
				}
				var snapshots, states int
				err := db.QueryRowContext(ctx, "SELECT (SELECT count(*) FROM uptime_snapshots),(SELECT count(*) FROM uptime_states)").Scan(&snapshots, &states)
				return err == nil && snapshots >= tc.runs && states >= tc.runs*tc.rows
			}, "complete sink rows")
			for _, id := range ids {
				outboxEventually(t, ctx, func() bool {
					_, found, err := source.pendingSnapshot(ctx, id)
					if err != nil {
						t.Fatalf("read pending %d: %v", id, err)
					}
					return !found
				}, fmt.Sprintf("outbox ACK for %d", id))
			}
			// Join every persisted state to its original accepted sequence. Exact
			// set equality also detects duplicate replay rows and extra snapshots.
			db := h.db.Load()
			rows, err := db.QueryContext(ctx, `SELECT s.monitor_id,s.sequence,s.revision,s.observed_at,u.identity,u.state,u.valid_until
 FROM uptime_snapshots s JOIN uptime_states u USING(workspace,monitor_id,observed_at,snapshot_id) WHERE s.workspace='proof'`)
			if err != nil {
				t.Fatal(err)
			}
			defer rows.Close()
			seen := make(map[key]map[string]bool)
			count := 0
			for rows.Next() {
				var k key
				var revision, at, until int64
				var identity string
				var state uint8
				if err := rows.Scan(&k.id, &k.sequence, &revision, &at, &identity, &state, &until); err != nil {
					t.Fatal(err)
				}
				a, ok := want[k]
				if !ok || revision != a.run.Revision || at < a.before || at > a.after || until != at+int64(190*time.Second) {
					t.Fatalf("unexpected snapshot key=%+v revision=%d at=%d until=%d accepted=%+v", k, revision, at, until, a)
				}
				if seen[k] == nil {
					seen[k] = make(map[string]bool)
				}
				matches := false
				for _, observation := range a.run.Observations {
					matches = matches || observation.Identity == identity && observation.Condition == state
				}
				if !matches || seen[k][identity] {
					t.Fatalf("wrong or duplicate original state: key=%+v identity=%s state=%d", k, identity, state)
				}
				seen[k][identity] = true
				count++
			}
			if err := rows.Err(); err != nil {
				t.Fatal(err)
			}
			var snapshotCount, stateCount int
			if err := db.QueryRowContext(ctx, "SELECT (SELECT count(*) FROM uptime_snapshots),(SELECT count(*) FROM uptime_states)").Scan(&snapshotCount, &stateCount); err != nil {
				t.Fatal(err)
			}
			if snapshotCount != tc.runs || len(seen) != len(want) || count != tc.runs*tc.rows || stateCount != count {
				t.Fatalf("reconciliation: snapshots=%d pairs=%d joined_states=%d stored_states=%d; want %d/%d/%d/%d", snapshotCount, len(seen), count, stateCount, tc.runs, len(want), tc.runs*tc.rows, tc.runs*tc.rows)
			}
			t.Logf("confirmed=%d reconciled_snapshots=%d reconciled_states=%d raw_drops=%d concurrent=%v elapsed=%s; all outboxes acknowledged, no duplicate sink rows", len(want), snapshotCount, count, h.dropped.Load(), tc.concurrent, time.Since(start))
		})
	}
	t.Run("paused_instance_beyond_active_limit", func(t *testing.T) {
		source, user := startOutboxServer(t, binary)
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		asset := create(t, user)
		type accepted struct {
			revision, before, after int64
		}
		want := make(map[uint64]accepted)
		apply := func(sequence uint64, start, end int) {
			t.Helper()
			run := p.ApplyMonitorRun{CorrelationID: 1, MonitorID: asset.AssetID, Revision: asset.UpdatedAt, Sequence: sequence}
			for i := start; i < end; i++ {
				run.Observations = append(run.Observations, p.MonitorObservation{Identity: fmt.Sprintf("i%04d", i), Condition: uint8((i + int(sequence)) % 2)})
			}
			before := time.Now().UnixNano()
			status, err := source.apply(ctx, run)
			after := time.Now().UnixNano()
			if err != nil || status != "confirmed" {
				t.Fatalf("apply sequence %d: status=%s err=%v", sequence, status, err)
			}
			want[sequence] = accepted{asset.UpdatedAt, before, after}
		}
		apply(1, 0, 1024)
		first, found, err := source.pendingSnapshot(ctx, asset.AssetID)
		if err != nil || !found || first.Sequence != 1 || len(first.Instances) != 1024 {
			t.Fatalf("initial full snapshot: rows=%d found=%v err=%v", len(first.Instances), found, err)
		}
		paused := first.Instances[0]
		if paused.Identity != "i0000" {
			t.Fatalf("unexpected first instance: %+v", paused)
		}
		wire, err := p.EncodeControlMonitorInstance(p.ControlMonitorInstance{CorrelationID: 1, MonitorID: asset.AssetID, Revision: asset.UpdatedAt, InstanceID: paused.ID, Action: p.PauseMonitorInstance})
		if err != nil {
			t.Fatal(err)
		}
		body, err := source.request(ctx, wire, p.S_MonitorInstanceControlled, 1)
		if err != nil {
			t.Fatal(err)
		}
		receipt, err := p.DecodeMonitorInstanceControlled(body)
		if err != nil || receipt.CorrelationID != 1 || receipt.MonitorID != asset.AssetID || receipt.InstanceID != paused.ID || receipt.Replayed || receipt.Revision <= asset.UpdatedAt {
			t.Fatalf("pause did not advance revision: receipt=%+v err=%v", receipt, err)
		}
		asset, err = source.asset(ctx, asset.AssetID)
		if err != nil || asset.UpdatedAt != receipt.Revision {
			t.Fatalf("read updated monitor: revision=%d want=%d err=%v", asset.UpdatedAt, receipt.Revision, err)
		}
		// Paused non-retired rows remain in every snapshot, but do not count
		// toward admission's 1024 active-instance limit.
		apply(2, 1, 1025)
		apply(3, 1, 1025)
		if again, found, err := source.pendingSnapshot(ctx, asset.AssetID); err != nil || !found || !reflect.DeepEqual(first, again) {
			t.Fatalf("successors changed original snapshot/deadlines: found=%v err=%v", found, err)
		}
		h := newHistoryWriter()
		path := filepath.Join(t.TempDir(), "history.duckdb")
		var wg sync.WaitGroup
		defer func() { cancel(); wg.Wait() }()
		wg.Add(2)
		go func() { defer wg.Done(); h.serve(ctx, path) }()
		go func() {
			defer wg.Done()
			collectStoredAvailability(ctx, h, newMonitorSet([]uint64{asset.AssetID}), source, "proof", 8)
		}()
		outboxEventually(t, ctx, func() bool {
			db := h.db.Load()
			if db == nil {
				return false
			}
			var snapshots, states int
			err := db.QueryRowContext(ctx, "SELECT (SELECT count(*) FROM uptime_snapshots),(SELECT count(*) FROM uptime_states)").Scan(&snapshots, &states)
			return err == nil && snapshots >= 3 && states >= 3074
		}, "all three snapshots including 1025-row successors")
		outboxEventually(t, ctx, func() bool {
			_, found, err := source.pendingSnapshot(ctx, asset.AssetID)
			if err != nil {
				t.Fatal(err)
			}
			return !found
		}, "oversized snapshot and successor ACKs")
		db := h.db.Load()
		rows, err := db.QueryContext(ctx, `SELECT s.sequence,s.revision,s.observed_at,u.identity,u.state,u.valid_until
 FROM uptime_snapshots s JOIN uptime_states u USING(workspace,monitor_id,observed_at,snapshot_id)
 WHERE s.workspace='proof' AND s.monitor_id=?`, asset.AssetID)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		seen := make(map[uint64]map[string]bool)
		for rows.Next() {
			var sequence uint64
			var revision, at, until int64
			var identity string
			var state uint8
			if err := rows.Scan(&sequence, &revision, &at, &identity, &state, &until); err != nil {
				t.Fatal(err)
			}
			a, ok := want[sequence]
			if !ok || revision != a.revision || at < a.before || at > a.after || until != at+int64(190*time.Second) || sequence == 1 && at != first.At {
				t.Fatalf("wrong original snapshot/deadline: sequence=%d revision=%d at=%d until=%d want=%+v", sequence, revision, at, until, a)
			}
			if seen[sequence] == nil {
				seen[sequence] = make(map[string]bool)
			}
			var index int
			if _, err := fmt.Sscanf(identity, "i%04d", &index); err != nil || identity != fmt.Sprintf("i%04d", index) || index < 0 || index > 1024 || sequence == 1 && index == 1024 || seen[sequence][identity] {
				t.Fatalf("unexpected or duplicate identity: sequence=%d identity=%q", sequence, identity)
			}
			wantState := uint8((index + int(sequence)) % 2)
			if sequence > 1 && identity == paused.Identity {
				wantState = 3
			}
			if state != wantState {
				t.Fatalf("wrong state: sequence=%d identity=%s got=%d want=%d", sequence, identity, state, wantState)
			}
			seen[sequence][identity] = true
		}
		if err := rows.Err(); err != nil {
			t.Fatal(err)
		}
		var snapshots, states int
		if err := db.QueryRowContext(ctx, "SELECT (SELECT count(*) FROM uptime_snapshots),(SELECT count(*) FROM uptime_states)").Scan(&snapshots, &states); err != nil {
			t.Fatal(err)
		}
		if snapshots != 3 || states != 3074 || len(seen) != 3 || len(seen[1]) != 1024 || len(seen[2]) != 1025 || len(seen[3]) != 1025 {
			t.Fatalf("reconciliation: snapshots=%d states=%d sequence rows=%d/%d/%d", snapshots, states, len(seen[1]), len(seen[2]), len(seen[3]))
		}
	})
	t.Run("disabled_monitor_controls", func(t *testing.T) {
		source, user := startOutboxServer(t, binary)
		update := func(t *testing.T, asset p.Asset, enabled bool) p.Asset {
			t.Helper()
			var preview map[string]any
			if err := json.Unmarshal([]byte(asset.Preview), &preview); err != nil {
				t.Fatal(err)
			}
			preview["enabled"] = enabled
			body, err := json.Marshal(preview)
			if err != nil {
				t.Fatal(err)
			}
			wire, err := (&p.Message{Opcode: p.C_UpdateAsset, Data: p.EncodeUpdateAsset(0, asset.AssetID, string(body), asset.Payload)}).Write()
			if err != nil {
				t.Fatal(err)
			}
			user.SetWriteDeadline(time.Now().Add(15 * time.Second))
			if err := user.WriteMessage(websocket.BinaryMessage, wire); err != nil {
				t.Fatal(err)
			}
			for {
				user.SetReadDeadline(time.Now().Add(15 * time.Second))
				_, body, err := user.ReadMessage()
				if err != nil {
					t.Fatal(err)
				}
				msg, err := p.ReadMessage(body)
				if err != nil {
					t.Fatal(err)
				}
				if msg.Opcode == p.S_ErrorResponse {
					t.Fatalf("update monitor rejected: %x", msg.Data)
				}
				if msg.Opcode == p.S_AssetUpdated {
					updated, err := p.DecodeAssetUpdated(msg.Data)
					if err != nil {
						t.Fatal(err)
					}
					if updated.Asset.AssetID == asset.AssetID {
						return updated.Asset
					}
				}
			}
		}
		for _, count := range []int{0, 17} {
			t.Run(fmt.Sprintf("instances_%d", count), func(t *testing.T) {
				ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
				defer cancel()
				asset := create(t, user)
				originalRevision := asset.UpdatedAt
				sequence := uint64(0)
				var before, after int64
				if count > 0 {
					sequence = 1
					run := p.ApplyMonitorRun{CorrelationID: 1, MonitorID: asset.AssetID, Revision: asset.UpdatedAt, Sequence: sequence}
					for i := 0; i < count; i++ {
						run.Observations = append(run.Observations, p.MonitorObservation{Identity: fmt.Sprintf("instance-%02d", i), Condition: uint8(i % 2), Value: float64(i)})
					}
					before = time.Now().UnixNano()
					status, err := source.apply(ctx, run)
					after = time.Now().UnixNano()
					if err != nil || status != "confirmed" {
						t.Fatalf("seed run: status=%s err=%v", status, err)
					}
				}
				asset = update(t, asset, false)
				read := func() p.MonitorSnapshotPage {
					t.Helper()
					page, found, err := source.pendingSnapshot(ctx, asset.AssetID)
					if err != nil || !found {
						t.Fatalf("disabled pending snapshot: found=%v err=%v", found, err)
					}
					return page
				}
				ack := func(page p.MonitorSnapshotPage) {
					t.Helper()
					if err := source.acknowledgeSnapshot(ctx, page); err != nil {
						t.Fatalf("ACK sequence=%d at=%d: %v", page.Sequence, page.At, err)
					}
				}
				if count > 0 {
					accepted := read()
					if accepted.PauseObservation || accepted.Sequence != sequence || accepted.Revision != originalRevision || len(accepted.Instances) != count || accepted.At < before || accepted.At > after {
						t.Fatalf("disabling replaced accepted-run evidence: %+v", accepted)
					}
					for i, row := range accepted.Instances {
						if row.Identity != fmt.Sprintf("instance-%02d", i) || row.State != uint8(i%2) || row.ValidUntil != accepted.At+int64(190*time.Second) {
							t.Fatalf("accepted-run evidence changed after disable: %+v", row)
						}
					}
					ack(accepted)
				}
				first := read()
				checkPause := func(page p.MonitorSnapshotPage) {
					t.Helper()
					if !page.PauseObservation || page.Sequence != sequence || page.Revision != asset.UpdatedAt || page.At <= 0 || page.Horizon != int64(190*time.Second) || len(page.Instances) != count {
						t.Fatalf("invalid bounded pause observation: %+v", page)
					}
					for i, row := range page.Instances {
						if row.Identity != fmt.Sprintf("instance-%02d", i) || row.State != 3 || row.ValidUntil != page.At+page.Horizon {
							t.Fatalf("invalid original pause expiry/state: %+v", row)
						}
					}
				}
				checkPause(first)
				if again := read(); !reflect.DeepEqual(first, again) {
					t.Fatalf("unacknowledged pause changed: first=%+v replay=%+v", first, again)
				}
				if count > 16 {
					// Check the actual continuation twice, not just the assembled
					// result: page two must keep page one's capture and expiry.
					pageAtCursor := func(cursor uint64) p.MonitorSnapshotPage {
						t.Helper()
						snapshotID, at := first.SnapshotID, first.At
						if cursor == 0 {
							snapshotID, at = 0, 0
						}
						wire, err := p.EncodeMonitorHistory(asset.AssetID, snapshotID, cursor, at, false)
						if err != nil {
							t.Fatal(err)
						}
						body, err := source.request(ctx, wire, p.S_MonitorState, 1)
						if err != nil {
							t.Fatal(err)
						}
						page, err := p.DecodeMonitorHistoryPage(body)
						if err != nil {
							t.Fatal(err)
						}
						return page
					}
					one := pageAtCursor(0)
					if one.Next == 0 || len(one.Instances) != 16 || !one.PauseObservation || one.SnapshotID != first.SnapshotID || one.At != first.At {
						t.Fatalf("pause did not paginate: %+v", one)
					}
					two := pageAtCursor(one.Next)
					if two.Next != 0 || len(two.Instances) != 1 || !two.PauseObservation || two.MonitorState != first.MonitorState || two.SnapshotID != first.SnapshotID || two.At != first.At || two.Horizon != first.Horizon || !reflect.DeepEqual(two.Instances, first.Instances[16:]) || !reflect.DeepEqual(two, pageAtCursor(one.Next)) {
						t.Fatalf("pause continuation was not immutable: %+v", two)
					}
				}
				db, err := openHistory(ctx, filepath.Join(t.TempDir(), "pause.duckdb"))
				if err != nil {
					t.Fatal(err)
				}
				defer db.Close()
				persist := func(page p.MonitorSnapshotPage) {
					t.Helper()
					if err := writeAvailability(ctx, db, historySnapshot{Workspace: "proof", MonitorSnapshotPage: page}); err != nil {
						t.Fatalf("persist pause (including sequence zero): %v", err)
					}
				}
				persist(first)
				persist(read()) // Lost-ACK replay must also deduplicate an empty snapshot.
				ack(first)
				next := read()
				checkPause(next)
				if first.SnapshotID == 0 || next.SnapshotID == 0 || next.SnapshotID == first.SnapshotID {
					t.Fatalf("pause captures need distinct nonzero identities: first=%d next=%d", first.SnapshotID, next.SnapshotID)
				}
				// A delayed ACK targets its durable capture ID, even if timestamps
				// happen to coincide or the wall clock moves backwards.
				ack(first)
				if replay := read(); !reflect.DeepEqual(next, replay) {
					t.Fatalf("delayed old pause ACK removed/replaced same-sequence capture: next=%+v replay=%+v", next, replay)
				}
				persist(next)
				var snapshots, states int
				if err := db.QueryRowContext(ctx, "SELECT (SELECT count(*) FROM uptime_snapshots),(SELECT count(*) FROM uptime_states)").Scan(&snapshots, &states); err != nil {
					t.Fatal(err)
				}
				if snapshots != 2 || states != 2*count {
					t.Fatalf("pause replay reconciliation: snapshots=%d states=%d want 2/%d", snapshots, states, 2*count)
				}
				ack(next)
				asset = update(t, asset, true)
				if _, found, err := source.pendingSnapshot(ctx, asset.AssetID); err != nil || found {
					t.Fatalf("pause ACK did not empty outbox: found=%v err=%v", found, err)
				}
			})
		}
	})
}

// Delay only the replayed snapshot's real WebSocket ACK so the test can inspect
// committed sink rows while the original evidence is still in the real outbox.
type outboxAckGate struct {
	nrcSource
	page             p.MonitorSnapshotPage
	entered, release chan struct{}
	once             sync.Once
}

func (g *outboxAckGate) acknowledgeSnapshot(ctx context.Context, page p.MonitorSnapshotPage) error {
	if page.MonitorID == g.page.MonitorID && page.SnapshotID == g.page.SnapshotID {
		g.once.Do(func() { close(g.entered) })
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-g.release:
		}
	}
	return g.nrcSource.acknowledgeSnapshot(ctx, page)
}

func outboxEventually(t *testing.T, ctx context.Context, ready func() bool, description string) {
	t.Helper()
	timer := time.NewTimer(90 * time.Second)
	defer timer.Stop()
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for !ready() {
		select {
		case <-ctx.Done():
			t.Fatalf("waiting for %s: %v", description, ctx.Err())
		case <-timer.C:
			t.Fatalf("timed out waiting for %s", description)
		case <-ticker.C:
		}
	}
}

func startOutboxServer(t *testing.T, binary string) (nrcSource, *websocket.Conn) {
	t.Helper()
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "data"), 0o755); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	logs, err := os.Create(filepath.Join(dir, "server.log"))
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(binary)
	cmd.Dir = dir
	// Do not let developer configuration redirect this isolated fixture's data.
	for _, env := range os.Environ() {
		if !strings.HasPrefix(env, "NRC_") {
			cmd.Env = append(cmd.Env, env)
		}
	}
	cmd.Env = append(cmd.Env, fmt.Sprintf("NRC_PORT=%d", port), "NRC_THREAD_COUNT=2", "NRC_JWT_SECRET=test-only-secret", "NRC_BOT_SECRET=test-only-bot-secret")
	cmd.Stdout, cmd.Stderr = logs, logs
	if err := cmd.Start(); err != nil {
		logs.Close()
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	t.Cleanup(func() {
		cmd.Process.Signal(os.Interrupt)
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			cmd.Process.Kill()
			<-done
		}
		logs.Close()
		if t.Failed() {
			body, _ := os.ReadFile(filepath.Join(dir, "server.log"))
			t.Logf("isolated server log:\n%s", body)
		}
	})
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	outboxEventually(t, ctx, func() bool {
		c, err := net.DialTimeout("tcp", address, 100*time.Millisecond)
		if err == nil {
			c.Close()
		}
		return err == nil
	}, "isolated server startup")
	claims, err := json.Marshal(map[string]any{"iss": "nrc-tailscale-proxy", "aud": "nrc", "sub": "snapshot-fixture", "username": "snapshot-fixture", "workspace": "proof", "exp": time.Now().Add(time.Hour).Unix()})
	if err != nil {
		t.Fatal(err)
	}
	token := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`)) + "." + base64.RawURLEncoding.EncodeToString(claims)
	mac := hmac.New(sha256.New, []byte("test-only-secret"))
	mac.Write([]byte(token))
	token += "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	server := "ws://" + address
	user, response, err := websocket.DefaultDialer.DialContext(ctx, server+"/proof", http.Header{"X-NRC-Auth": {token}})
	if err != nil {
		if response != nil && response.Body != nil {
			response.Body.Close()
		}
		t.Fatal(err)
	}
	t.Cleanup(func() { user.Close() })
	// Consume ServerReady before sending the first create request.
	for {
		user.SetReadDeadline(time.Now().Add(15 * time.Second))
		_, body, err := user.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		msg, err := p.ReadMessage(body)
		if err != nil {
			t.Fatal(err)
		}
		if msg.Opcode == p.S_ServerReady {
			break
		}
	}
	return nrcSource{server, "proof", "checker", "test-only-bot-secret"}, user
}
