package e2e

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cespare/xxhash/v2"
	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func buildCommitFault(t *testing.T) string {
	t.Helper()
	lib := filepath.Join(t.TempDir(), "commit-fault.so")
	build := exec.Command("cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror", "-o", lib,
		filepath.Join(repoRootFromThisFile(t), "test/e2e/fixtures/chronicle_commit_fault.c"), "-ldl", "-lsqlite3")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build test-only COMMIT interposer: %v\n%s", err, out)
	}
	return lib
}

func waitForCommitBoundary(t *testing.T, reached, phase string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		b, err := os.ReadFile(reached)
		if err == nil && string(b) == phase+":0" {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("COMMIT boundary not reached: %q %v", b, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// Kill at an observed real SQLite boundary, not at an estimated delay. The
// interposer pauses before COMMIT or after it returns but before network reply.
// These are process-crash tests, not power-loss or physical-erasure tests.
func TestChronicleCrashAtCommitBoundary(t *testing.T) {
	lib := buildCommitFault(t)
	for _, operation := range []string{"capture", "result"} {
		for _, phase := range []string{"before", "after"} {
			t.Run(operation+"/"+phase, func(t *testing.T) {
				const workspace = "chronicle-crash"
				dir := t.TempDir()
				path := filepath.Join(dir, "data", "sharded-00000000000000000001",
					fmt.Sprintf("shard_%03d", xxhash.Sum64String(workspace)%256), "workspace.sqlite3")
				arm, reached := filepath.Join(dir, "arm"), filepath.Join(dir, "reached")
				env := map[string]string{
					"NRC_THREAD_COUNT": "2", "NRC_CHRONICLE_WORKSPACES": workspace,
					"NRC_CHRONICLE_SERVICE_SUBJECTS": `{"chronicle-crash":["worker"]}`,
					"NRC_CHRONICLE_DELETE_SUBJECTS":  `{"chronicle-crash":["human"]}`,
					"LD_PRELOAD":                     lib, "NRC_TEST_COMMIT_DB": path,
					"NRC_TEST_COMMIT_ARM": arm, "NRC_TEST_COMMIT_REACHED": reached,
					"NRC_TEST_COMMIT_KIND": operation,
				}
				server := startServerInWorkDirWithEnv(t, dir, env)
				t.Cleanup(func() { server.stop(t) })
				connect := func(subject, kind, capability string) *websocket.Conn {
					t.Helper()
					c, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), chronicleJWTHeader(t, subject, workspace, kind, capability))
					if err != nil {
						t.Fatal(err)
					}
					t.Cleanup(func() { c.Close() })
					mustSetReadDeadline(t, c, 20*time.Second)
					mustExpectServerReady(t, c)
					return c
				}
				human, worker := connect("human", "user", ""), connect("worker", "bot", "chronicle")
				createNoteAssetAndRead(t, human, 0, mustNotePreviewJSON(t, "durable control", ""))
				var job protocol.ChronicleRequest
				if operation == "result" {
					claimed := mustChronicle(t, worker, protocol.ChronicleRequest{Op: "claim", Consumer: protocol.ChronicleConsumerVersion, Limit: 32}, "claimed")
					job = protocol.ChronicleRequest{Op: "reserve", Consumer: protocol.ChronicleConsumerVersion,
						Epoch: claimed.Epoch, Generation: claimed.Generation, Sources: claimed.Sources,
						InputTokens: 123, OutputTokens: 1000}
					mustChronicle(t, worker, job, "reserved")
					job.Op, job.Outcome = "commit", "result"
					job.Summary, job.Model, job.PromptVersion, job.SchemaVersion = "Nur die Historie wird umgesetzt.", "fake", "test", "s1"
					job.InputTokens, job.OutputTokens = 53, 17
				}
				if err := os.WriteFile(arm, []byte(phase), 0600); err != nil {
					t.Fatal(err)
				}
				if operation == "capture" {
					if err := sendProtocolMessage(human, protocol.C_CreateAsset, protocol.EncodeCreateAsset(0, protocol.AssetTypeNote, protocol.ParentTypeNone, 0, mustNotePreviewJSON(t, "crash candidate", ""), "not a provider input")); err != nil {
						t.Fatal(err)
					}
				} else {
					wire, err := protocol.EncodeChronicleRequest(job, 820)
					if err != nil {
						t.Fatal(err)
					}
					if err := worker.WriteMessage(websocket.BinaryMessage, wire); err != nil {
						t.Fatal(err)
					}
				}
				waitForCommitBoundary(t, reached, phase)
				server.killAndWait(t)
				// Observe recovered SQLite state before startup epoch changes.
				check := exec.Command("python3", "-c", `
import sqlite3,sys
path,op,phase=sys.argv[1:]
with sqlite3.connect(path) as db:
    assert db.execute("PRAGMA integrity_check").fetchone()==("ok",)
    assert db.execute("PRAGMA foreign_key_check").fetchall()==[]
    n=2 if op=="capture" and phase=="after" else 1
    for table in ("assets","history","chronicle_inputs"):
        assert db.execute("SELECT count(*) FROM "+table).fetchone()==(n,),table
    published=op=="result" and phase=="after"
    assert db.execute("SELECT count(*) FROM chronicle_jobs WHERE state=1").fetchone()==(int(published),)
    assert db.execute("SELECT count(*) FROM chronicle_raw").fetchone()==(0 if published else n,)
    assert db.execute("SELECT raw_bytes FROM chronicle_workspaces").fetchone()==db.execute("SELECT coalesce(sum(byte_count),0) FROM chronicle_raw").fetchone()
    assert db.execute("SELECT pending_inputs FROM chronicle_workspaces").fetchone()==(0 if published else n,)
    if op=="result":
        expected=(1,53,17) if published else (1,123,1000)
        assert db.execute("SELECT calls,input_tokens,output_tokens FROM chronicle_budgets").fetchone()==expected
        assert db.execute("SELECT attempts FROM chronicle_inputs").fetchone()==(1,)
    print(op,phase,"recovered:",n,"canonical/history/inputs; published",int(published))
`, path, operation, phase)
				if out, err := check.CombinedOutput(); err != nil {
					t.Fatalf("recovery: %v\n%s", err, out)
				} else {
					t.Log(strings.TrimSpace(string(out)))
				}
				if operation == "result" && phase == "before" {
					// Disable while an unexpired reserved claim is durable, then
					// re-enable. Neither its raw input nor old epoch may revive.
					env["NRC_CHRONICLE_WORKSPACES"] = ""
					server = startServerInWorkDirWithEnv(t, dir, env)
					server.killAndWait(t)
					env["NRC_CHRONICLE_WORKSPACES"] = workspace
				}
				server = startServerInWorkDirWithEnv(t, dir, env)
				worker, human = connect("worker", "bot", "chronicle"), connect("human", "user", "")
				if operation == "result" {
					want := "expired"
					if phase == "after" {
						want = "committed"
					}
					replay := mustChronicle(t, worker, job, want)
					if phase == "after" && replay.Summary != job.Summary {
						t.Fatalf("lost response not replayable: %+v", replay)
					}
					status := mustChronicle(t, worker, protocol.ChronicleRequest{Op: "status"}, "ok")
					input, output := uint64(123), uint64(1000)
					if phase == "after" {
						input, output = 53, 17
					}
					if status.Calls != 1 || status.InputTokens != input || status.OutputTokens != output {
						t.Fatalf("restart/replay changed reservation or settled usage: %+v", status)
					}
					if phase == "before" && (status.Pending != 0 || status.RawBytes != 0 || status.GapCount != 1) {
						t.Fatalf("disable/re-enable revived an old capture: %+v", status)
					}
					if phase == "after" {
						mustChronicle(t, human, protocol.ChronicleRequest{Op: "delete", NoteID: "1"}, "deleted")
						replay = mustChronicle(t, worker, job, "deleted")
						if replay.Summary != "" {
							t.Fatal("deleted prose replayed")
						}
						server.killAndWait(t)
						server = startServerInWorkDirWithEnv(t, dir, env)
						worker = connect("worker", "bot", "chronicle")
						replay = mustChronicle(t, worker, job, "deleted")
						if replay.Summary != "" {
							t.Fatal("restart resurrected deleted prose")
						}
					}
				}
			})
		}
	}
}
