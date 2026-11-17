package e2e

import (
	"fmt"
	"os/exec"
	"path/filepath"
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
	for attempt := 1; attempt <= 5; attempt++ {
		first := mustChronicle(t, worker, claim, "claimed")
		rebatch := protocol.ChronicleRequest{Op: "retry", Consumer: claim.Consumer, Epoch: first.Epoch, Generation: first.Generation, Sources: first.Sources, Reason: "rebatch"}
		mustChronicle(t, worker, rebatch, "released")
		current := mustChronicle(t, worker, claim, "claimed")
		inputs := mustChronicle(t, worker, protocol.ChronicleRequest{Op: "list", Consumer: claim.Consumer, Limit: 32}, "ok")
		if len(inputs.Inputs) != 1 || inputs.Inputs[0].Attempts != uint32(attempt-1) {
			t.Fatalf("rebatch reset attempts: %+v", inputs)
		}
		job := protocol.ChronicleRequest{Op: "reserve", Consumer: claim.Consumer, Epoch: current.Epoch, Generation: current.Generation, Sources: current.Sources, InputTokens: 100, OutputTokens: 1000}
		mustChronicle(t, worker, job, "reserved")
		// Exact reservation replay is free, even on the fifth live attempt.
		mustChronicle(t, worker, job, "reserved")
		job.Op = "retry"
		job.Reason = "timeout"
		mustChronicle(t, worker, job, "released")
		server.killAndWait(t)
		// Advance only retry eligibility in a stopped disposable fixture. Do
		// not reset attempts, budgets, capture TTL, source IDs or terminal state.
		check := exec.Command("python3", "-c", `
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    n=int(sys.argv[2])
    assert db.execute("SELECT attempts,state FROM chronicle_inputs").fetchone()==(n,0)
    assert db.execute("SELECT calls,input_tokens,output_tokens FROM chronicle_budgets").fetchone()==(n,100*n,1000*n)
    db.execute("UPDATE chronicle_inputs SET retry_at=0")
`, path, fmt.Sprint(attempt))
		if out, err := check.CombinedOutput(); err != nil {
			t.Fatalf("durable attempt %d: %v\n%s", attempt, err, out)
		}
		server = startServerInWorkDirWithEnv(t, dir, env)
		worker = connect("bot", "chronicle")
	}
	mustChronicle(t, worker, claim, "exhausted")
	mustChronicle(t, worker, claim, "exhausted")
	status := mustChronicle(t, worker, protocol.ChronicleRequest{Op: "status"}, "ok")
	if status.Calls != 5 || status.Failed != 1 || status.Pending != 1 || status.GapCount != 0 || status.RawBytes == 0 {
		t.Fatalf("exhausted input skipped or charged again: %+v", status)
	}
}
