package e2e

import (
	"context"
	"encoding/binary"
	"fmt"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/cespare/xxhash/v2"
	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestChronicleOverlappingSetsAndWorkspaceIsolation(t *testing.T) {
	const a, b = "chronicle-sets-a", "chronicle-sets-b"
	server := startServerInWorkDirWithEnv(t, t.TempDir(), map[string]string{
		"NRC_THREAD_COUNT": "2", "NRC_CHRONICLE_WORKSPACES": a + "," + b,
		"NRC_CHRONICLE_SERVICE_SUBJECTS": `{"chronicle-sets-a":["worker"],"chronicle-sets-b":["worker"]}`,
	})
	defer server.stop(t)
	connect := func(workspace, kind, cap string) *websocket.Conn {
		t.Helper()
		c, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), chronicleJWTHeader(t, "worker", workspace, kind, cap))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		mustSetReadDeadline(t, c, 10*time.Second)
		mustExpectServerReady(t, c)
		return c
	}
	human, worker, competitor := connect(a, "user", ""), connect(a, "bot", "chronicle"), connect(a, "bot", "chronicle")
	otherHuman, otherWorker := connect(b, "user", ""), connect(b, "bot", "chronicle")
	note := createNoteAssetAndRead(t, human, 0, mustNotePreviewJSON(t, "A", ""))
	for _, title := range []string{"B", "C"} {
		if err := sendProtocolMessage(human, protocol.C_UpdateAsset, protocol.EncodeUpdateAsset(0, note.AssetID, mustNotePreviewJSON(t, title, ""), title)); err != nil {
			t.Fatal(err)
		}
		mustReadUntilOpcode(t, human, protocol.S_AssetUpdated, 16)
	}
	createNoteAssetAndRead(t, otherHuman, 0, mustNotePreviewJSON(t, "other workspace", ""))
	claim := protocol.ChronicleRequest{Op: "claim", Consumer: protocol.ChronicleConsumerVersion, Limit: 2}
	first := mustChronicle(t, worker, claim, "claimed")
	if len(first.Sources) != 2 || first.Sources[0] != "1" || first.Sources[1] != "2" {
		t.Fatalf("expected A/B: %+v", first)
	}
	other := mustChronicle(t, otherWorker, claim, "claimed")
	if len(other.Sources) != 1 || other.Sources[0] != "1" {
		t.Fatalf("workspace-local source order: %+v", other)
	}
	job := protocol.ChronicleRequest{Op: "commit", Consumer: claim.Consumer, Epoch: first.Epoch, Generation: first.Generation,
		Sources: []string{"2", "3"}, Outcome: "ack", Model: "fake", PromptVersion: "test", SchemaVersion: "s1"}
	// A/B is immutable. B/C cannot be smuggled through either service socket.
	mustChronicle(t, competitor, job, "invalid")
	mustChronicle(t, otherWorker, job, "invalid")
	job.Sources = first.Sources
	reservation := job
	reservation.Op = "reserve"
	reservation.InputTokens = 100
	reservation.OutputTokens = 1000
	mustChronicle(t, worker, reservation, "reserved")
	for _, c := range []*websocket.Conn{worker, competitor} {
		wire, err := protocol.EncodeChronicleRequest(job, 817)
		if err != nil {
			t.Fatal(err)
		}
		if err := c.WriteMessage(websocket.BinaryMessage, wire); err != nil {
			t.Fatal(err)
		}
	}
	for _, c := range []*websocket.Conn{worker, competitor} {
		r, err := protocol.DecodeChronicleResponse(mustReadUntilOpcode(t, c, protocol.S_Chronicle, 16))
		if err != nil || r.Status != "acknowledged" {
			t.Fatalf("concurrent exact replay: %+v %v", r, err)
		}
	}
	status := mustChronicle(t, worker, protocol.ChronicleRequest{Op: "status"}, "ok")
	otherStatus := mustChronicle(t, otherWorker, protocol.ChronicleRequest{Op: "status"}, "ok")
	if status.Acknowledged != 2 || status.Pending != 1 || status.Calls != 1 || otherStatus.Acknowledged != 0 || otherStatus.Calls != 0 || otherStatus.Pending != 1 {
		t.Fatalf("cross-workspace or double terminal effect: %+v %+v", status, otherStatus)
	}
	next := mustChronicle(t, worker, claim, "claimed")
	if len(next.Sources) != 1 || next.Sources[0] != "3" {
		t.Fatalf("C skipped/reprocessed: %+v", next)
	}
}

func TestChronicleAttemptsSurviveRebatchAndRestart(t *testing.T) {
	const workspace = "chronicle-attempts"
	dir := t.TempDir()
	path := filepath.Join(dir, "data", "sharded-00000000000000000001", fmt.Sprintf("shard_%03d", xxhash.Sum64String(workspace)%256), "workspace.sqlite3")
	env := map[string]string{"NRC_THREAD_COUNT": "2", "NRC_CHRONICLE_WORKSPACES": workspace, "NRC_CHRONICLE_SERVICE_SUBJECTS": `{"chronicle-attempts":["worker"]}`}
	server := startServerInWorkDirWithEnv(t, dir, env)
	t.Cleanup(func() { server.stop(t) })
	connect := func(kind, cap string) *websocket.Conn {
		t.Helper()
		c, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), chronicleJWTHeader(t, "worker", workspace, kind, cap))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		mustSetReadDeadline(t, c, 10*time.Second)
		mustExpectServerReady(t, c)
		return c
	}
	human, worker := connect("user", ""), connect("bot", "chronicle")
	createNoteAssetAndRead(t, human, 0, mustNotePreviewJSON(t, "retry control", ""))
	claim := protocol.ChronicleRequest{Op: "claim", Consumer: protocol.ChronicleConsumerVersion, Limit: 32}
	for attempt := 1; attempt <= 6; attempt++ {
		first := mustChronicle(t, worker, claim, "claimed")
		rebatch := protocol.ChronicleRequest{Op: "retry", Consumer: claim.Consumer, Epoch: first.Epoch, Generation: first.Generation, Sources: first.Sources, Reason: "rebatch"}
		mustChronicle(t, worker, rebatch, "released")
		inputs := mustChronicle(t, worker, protocol.ChronicleRequest{Op: "list", Consumer: claim.Consumer, Limit: 32}, "ok")
		if len(inputs.Inputs) != 1 || inputs.Inputs[0].Attempts != uint32(min(attempt-1, 5)) {
			t.Fatalf("rebatch reset attempts: %+v", inputs)
		}
		current := mustChronicle(t, worker, claim, "claimed")
		job := protocol.ChronicleRequest{Op: "reserve", Consumer: claim.Consumer, Epoch: current.Epoch, Generation: current.Generation, Sources: current.Sources, InputTokens: 100, OutputTokens: 1000}
		reservedAt := time.Now().UnixNano()
		mustChronicle(t, worker, job, "reserved")
		// Exact reservation replay is free, even beyond the fifth live attempt.
		mustChronicle(t, worker, job, "reserved")
		if attempt < 6 {
			job.Op = "retry"
			job.Reason = "timeout"
			mustChronicle(t, worker, job, "released")
		}
		// The sixth provider call is abandoned, without a retry release.
		server.killAndWait(t)
		// Advance only retry eligibility in a stopped disposable fixture. Do
		// not reset attempts, budgets, capture TTL, source IDs or terminal state.
		check := exec.Command("python3", "-c", `
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    n=int(sys.argv[2])
    assert db.execute("SELECT attempts,state FROM chronicle_inputs").fetchone()==(min(n,5),0)
    assert db.execute("SELECT calls,input_tokens,output_tokens FROM chronicle_budgets").fetchone()==(n,100*n,1000*n)
    if n>=5:
        retry_at,expires_at=db.execute("SELECT retry_at,expires_at FROM chronicle_inputs").fetchone()
        assert retry_at>=int(sys.argv[3])+900_000_000_000
        assert retry_at<expires_at
    else:
        db.execute("UPDATE chronicle_inputs SET retry_at=0")
    if n==6:
        assert db.execute("SELECT reserved FROM chronicle_jobs WHERE state=0").fetchone()==(1,)
        db.execute("UPDATE chronicle_jobs SET lease_until=0 WHERE state=0")
`, path, fmt.Sprint(attempt), fmt.Sprint(reservedAt))
		if out, err := check.CombinedOutput(); err != nil {
			t.Fatalf("durable attempt %d: %v\n%s", attempt, err, out)
		}
		server = startServerInWorkDirWithEnv(t, dir, env)
		worker = connect("bot", "chronicle")
		if attempt >= 5 {
			// Neither a released failure nor an abandoned reservation loses its
			// long backoff on restart; polling spends no extra call or raw input.
			mustChronicle(t, worker, claim, "backoff")
			status := mustChronicle(t, worker, protocol.ChronicleRequest{Op: "status"}, "ok")
			if status.Calls != uint64(attempt) || status.Pending != 1 || status.Failed != 1 || status.GapCount != 0 || status.RawBytes == 0 {
				t.Fatalf("retry pause lost work or charged another call: %+v", status)
			}
			server.killAndWait(t)
			advance := exec.Command("python3", "-c", `
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("UPDATE chronicle_inputs SET retry_at=0")
`, path)
			if out, err := advance.CombinedOutput(); err != nil {
				t.Fatalf("advance retry eligibility: %v\n%s", err, out)
			}
			server = startServerInWorkDirWithEnv(t, dir, env)
			worker = connect("bot", "chronicle")
		}
	}
	// A later note cannot replace the repeatedly failing head. Once the
	// provider recovers, finish the original input and then advance normally.
	human = connect("user", "")
	createNoteAssetAndRead(t, human, 0, mustNotePreviewJSON(t, "later note", ""))
	current := mustChronicle(t, worker, claim, "claimed")
	if len(current.Sources) != 1 || current.Sources[0] != "1" {
		t.Fatalf("retried source skipped or replaced: %+v", current)
	}
	chunk := protocol.ChronicleRequest{Op: "chunk", Consumer: claim.Consumer, Epoch: current.Epoch, Generation: current.Generation, Cursor: "1", Field: 3, Length: 128}
	if got := mustChronicle(t, worker, chunk, "ok"); got.Chunk != "cmV0cnkgY29udHJvbA==" {
		t.Fatalf("retry input title changed: %+v", got)
	}
	job := protocol.ChronicleRequest{Op: "reserve", Consumer: claim.Consumer, Epoch: current.Epoch, Generation: current.Generation, Sources: current.Sources, InputTokens: 100, OutputTokens: 1000}
	mustChronicle(t, worker, job, "reserved")
	mustChronicle(t, worker, job, "reserved")
	job.Op, job.Outcome = "commit", "ack"
	job.Model, job.PromptVersion, job.SchemaVersion = "fake", "test", "s1"
	mustChronicle(t, worker, job, "acknowledged")
	mustChronicle(t, worker, job, "acknowledged")
	status := mustChronicle(t, worker, protocol.ChronicleRequest{Op: "status"}, "ok")
	if status.Calls != 7 || status.InputTokens != 700 || status.OutputTokens != 7000 || status.Acknowledged != 1 || status.Failed != 0 || status.Pending != 1 || status.GapCount != 0 {
		t.Fatalf("recovery lost an input or replay spent extra budget: %+v", status)
	}
	next := mustChronicle(t, worker, claim, "claimed")
	if len(next.Sources) != 1 || next.Sources[0] != "2" {
		t.Fatalf("later input lost or reordered: %+v", next)
	}
}

func TestChronicleParallelDurableOrderedPublication(t *testing.T) {
	const workspace = "chronicle-parallel"
	dir := t.TempDir()
	path := filepath.Join(dir, "data", "sharded-00000000000000000001", fmt.Sprintf("shard_%03d", xxhash.Sum64String(workspace)%256), "workspace.sqlite3")
	env := map[string]string{"NRC_THREAD_COUNT": "2", "NRC_CHRONICLE_WORKSPACES": workspace,
		"NRC_CHRONICLE_SERVICE_SUBJECTS": `{"chronicle-parallel":["worker"]}`,
		"NRC_CHRONICLE_DELETE_SUBJECTS":  `{"chronicle-parallel":["worker"]}`}
	server := startServerInWorkDirWithEnv(t, dir, env)
	t.Cleanup(func() { server.stop(t) })
	connect := func(kind, capability string) *websocket.Conn {
		t.Helper()
		c, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), chronicleJWTHeader(t, "worker", workspace, kind, capability))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		mustSetReadDeadline(t, c, 30*time.Second)
		mustExpectServerReady(t, c)
		return c
	}
	human := connect("user", "")
	for i := 1; i <= 11; i++ {
		createNoteAssetAndRead(t, human, 0, mustNotePreviewJSON(t, fmt.Sprintf("note %d", i), ""))
	}
	var sockets [10]*websocket.Conn
	var claims [10]*protocol.ChronicleResponse
	for i := range sockets {
		sockets[i] = connect("bot", "chronicle")
	}
	claim := protocol.ChronicleRequest{Op: "claim", Consumer: protocol.ChronicleConsumerVersion, Limit: 1}
	var wg sync.WaitGroup
	for i := range sockets {
		wg.Go(func() {
			// Exercise the same explicit-overload retry as the real sidecar;
			// concurrent writer admission may return S_Error rather than a claim.
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			wire, err := protocol.EncodeChronicleRequest(claim, 817)
			if err != nil {
				t.Error(err)
				return
			}
			r, err := protocol.RetryDatabaseRequest(ctx, protocol.C_Chronicle, 817, func(context.Context) (*protocol.Message, error) {
				if err := sockets[i].WriteMessage(websocket.BinaryMessage, wire); err != nil {
					return nil, err
				}
				_, data, err := sockets[i].ReadMessage()
				if err != nil {
					return nil, err
				}
				if len(data) < 2 {
					return nil, fmt.Errorf("short response")
				}
				return &protocol.Message{Opcode: binary.BigEndian.Uint16(data), Data: data[2:]}, nil
			})
			if err != nil {
				t.Error(err)
				return
			}
			claims[i], err = protocol.DecodeChronicleResponse(r.Data)
			if err != nil || r.Opcode != protocol.S_Chronicle || claims[i].Status != "claimed" {
				t.Errorf("concurrent claim: %+v %v", r, err)
			}
		})
	}
	wg.Wait()
	var jobs [10]protocol.ChronicleRequest
	for _, r := range claims {
		if r == nil || len(r.Sources) != 1 {
			t.Fatalf("missing concurrent claim: %+v", r)
		}
		n, err := strconv.Atoi(r.Sources[0])
		if err != nil || n < 1 || n > 10 || jobs[n-1].Generation != "" {
			t.Fatalf("overlapping or skipped concurrent claim: %+v", r)
		}
		jobs[n-1] = protocol.ChronicleRequest{Op: "reserve", Consumer: claim.Consumer, Epoch: r.Epoch, Generation: r.Generation,
			Sources: r.Sources, NoteID: r.NoteID, InputTokens: 1000, OutputTokens: 1000}
		mustChronicle(t, sockets[0], jobs[n-1], "reserved")
		jobs[n-1].Op, jobs[n-1].Outcome, jobs[n-1].Summary = "commit", "result", "summary "+r.Sources[0]
		jobs[n-1].Model, jobs[n-1].PromptVersion, jobs[n-1].SchemaVersion = "fake", "test", "s1"
		jobs[n-1].InputTokens, jobs[n-1].OutputTokens = 100, 10
	}
	worker := sockets[0]
	mustChronicle(t, worker, claim, "busy")
	for i := 9; i >= 1; i-- {
		mustChronicle(t, worker, jobs[i], "staged")
		mustChronicle(t, worker, jobs[i], "staged") // no second settlement or inference
	}
	mustChronicle(t, worker, claim, "busy") // completed results still occupy the window
	page := mustChronicle(t, worker, protocol.ChronicleRequest{Op: "history", Limit: 16}, "ok")
	if len(page.Entries) != 0 {
		t.Fatalf("published past unresolved head: %+v", page)
	}
	list := mustChronicle(t, worker, protocol.ChronicleRequest{Op: "list", Consumer: claim.Consumer, Limit: 32}, "ok")
	if len(list.Inputs) != 1 || list.Inputs[0].SourceID != "11" {
		t.Fatalf("claimed or completed sources offered again: %+v", list)
	}
	status := mustChronicle(t, worker, protocol.ChronicleRequest{Op: "status"}, "ok")
	if status.Calls != 10 || status.InputTokens != 1900 || status.OutputTokens != 1090 || status.Pending != 2 {
		t.Fatalf("staged budget settlement or pending count: %+v", status)
	}
	server.killAndWait(t)
	check := exec.Command("python3", "-c", `
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    assert db.execute("SELECT count(*) FROM chronicle_jobs WHERE state=1 AND publication_generation IS NULL").fetchone()==(9,)
    assert db.execute("SELECT count(*) FROM chronicle_raw").fetchone()==(2,)
    assert db.execute("PRAGMA integrity_check").fetchone()==('ok',)
    assert not db.execute("PRAGMA foreign_key_check").fetchall()
    # Advance only disposable timing fixtures: completed results outlive raw TTL;
    # abandoned head retains its reservation and attempts, but becomes retryable.
    db.execute("UPDATE chronicle_inputs SET captured_at=1,expires_at=2 WHERE state=1")
    db.execute("UPDATE chronicle_inputs SET retry_at=0 WHERE state=0")
`, path)
	if out, err := check.CombinedOutput(); err != nil {
		t.Fatalf("durable staged fixture: %v\n%s", err, out)
	}
	server = startServerInWorkDirWithEnv(t, dir, env)
	worker, human = connect("bot", "chronicle"), connect("user", "")
	mustChronicle(t, worker, jobs[0], "expired") // old epoch cannot write
	reclaimed := mustChronicle(t, worker, claim, "claimed")
	if len(reclaimed.Sources) != 1 || reclaimed.Sources[0] != "1" {
		t.Fatalf("abandoned head not reclaimed: %+v", reclaimed)
	}
	// The new claim ID is later than every staged claim. Public IDs must still
	// follow source order, not claim generation or provider completion order.
	job := jobs[0]
	job.Epoch, job.Generation = reclaimed.Epoch, reclaimed.Generation
	job.Op, job.InputTokens, job.OutputTokens = "reserve", 1000, 1000
	mustChronicle(t, worker, job, "reserved")
	job.Op, job.InputTokens, job.OutputTokens = "commit", 100, 10
	mustChronicle(t, worker, job, "committed")
	mustChronicle(t, worker, job, "committed")
	for _, newest := range []bool{false, true} {
		q := protocol.ChronicleRequest{Op: "history", Limit: 3, NewestFirst: newest}
		seen := 0
		for {
			page = mustChronicle(t, worker, q, "ok")
			for _, entry := range page.Entries {
				n := seen + 1
				if newest {
					n = 10 - seen
				}
				if len(entry.Sources) != 1 || entry.Sources[0] != strconv.Itoa(n) || entry.Summary != fmt.Sprintf("summary %d", n) || entry.Generation != strconv.Itoa(n) {
					t.Fatalf("publication lost/reordered result %d: %+v", n, entry)
				}
				seen++
			}
			q.Cursor = page.Cursor
			if !page.More {
				break
			}
		}
		if seen != 10 {
			t.Fatalf("lost finished results after restart: %d", seen)
		}
	}
	status = mustChronicle(t, worker, protocol.ChronicleRequest{Op: "status"}, "ok")
	if status.Calls != 11 || status.InputTokens != 2000 || status.OutputTokens != 1100 || status.Pending != 1 || status.GapCount != 0 {
		t.Fatalf("restart lost reservations, results or pending work: %+v", status)
	}
	// Deletion must also revoke a durably staged result before it is published.
	createNoteAssetAndRead(t, human, 0, mustNotePreviewJSON(t, "delete staged", ""))
	eleven := mustChronicle(t, worker, claim, "claimed")
	twelve := mustChronicle(t, worker, claim, "claimed")
	job = protocol.ChronicleRequest{Op: "reserve", Consumer: claim.Consumer, Epoch: twelve.Epoch, Generation: twelve.Generation,
		Sources: twelve.Sources, InputTokens: 1000, OutputTokens: 1000}
	mustChronicle(t, worker, job, "reserved")
	job.Op, job.Outcome, job.Summary = "commit", "result", "must disappear"
	job.Model, job.PromptVersion, job.SchemaVersion = "fake", "test", "s1"
	mustChronicle(t, worker, job, "staged")
	mustChronicle(t, human, protocol.ChronicleRequest{Op: "delete", NoteID: twelve.NoteID}, "deleted")
	if deleted := mustChronicle(t, worker, job, "deleted"); deleted.Summary != "" {
		t.Fatal("deleted staged prose replayed")
	}
	job = protocol.ChronicleRequest{Op: "commit", Consumer: claim.Consumer, Epoch: eleven.Epoch, Generation: eleven.Generation,
		Sources: eleven.Sources, Outcome: "gap", Reason: "token_limit"}
	mustChronicle(t, worker, job, "gap")
	page = mustChronicle(t, worker, protocol.ChronicleRequest{Op: "history", Limit: 16}, "ok")
	if len(page.Entries) != 10 {
		t.Fatalf("deleted staged result published: %+v", page)
	}
	// Capture disable terminalizes an unfinished head, but must not strand a
	// previously accepted later result. No sidecar or service RPC runs after restart.
	for _, title := range []string{"unfinished before disable", "accepted before disable"} {
		createNoteAssetAndRead(t, human, 0, mustNotePreviewJSON(t, title, ""))
	}
	mustChronicle(t, worker, claim, "claimed")
	later := mustChronicle(t, worker, claim, "claimed")
	job = protocol.ChronicleRequest{Op: "reserve", Consumer: claim.Consumer, Epoch: later.Epoch, Generation: later.Generation,
		Sources: later.Sources, InputTokens: 1000, OutputTokens: 1000}
	mustChronicle(t, worker, job, "reserved")
	job.Op, job.Outcome, job.Summary = "commit", "result", "survives disable"
	job.Model, job.PromptVersion, job.SchemaVersion = "fake", "test", "s1"
	mustChronicle(t, worker, job, "staged")
	server.killAndWait(t)
	env["NRC_CHRONICLE_WORKSPACES"] = ""
	server = startServerInWorkDirWithEnv(t, dir, env)
	human = connect("user", "")
	page = mustChronicle(t, human, protocol.ChronicleRequest{Op: "history", Limit: 16}, "ok")
	if len(page.Entries) != 11 || page.Entries[10].Summary != "survives disable" || page.Entries[10].Sources[0] != later.Sources[0] {
		t.Fatalf("capture disable stranded accepted result: %+v", page)
	}
	status = mustChronicle(t, human, protocol.ChronicleRequest{Op: "status"}, "ok")
	if status.Enabled || status.Pending != 0 || status.Calls != 13 || status.GapCount != 2 {
		t.Fatalf("disabled maintenance changed budget or lost receipts: %+v", status)
	}
}
