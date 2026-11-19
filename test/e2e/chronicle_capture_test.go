package e2e

import (
	"fmt"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/cespare/xxhash/v2"
	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestChronicleCaptureOptInAndRestart(t *testing.T) {
	workDir := t.TempDir()
	const workspace = "chronicle-capture"
	path := filepath.Join(workDir, "data", "sharded-00000000000000000001",
		fmt.Sprintf("shard_%03d", xxhash.Sum64String(workspace)%256), "workspace.sqlite3")
	stages := []struct {
		enabled        bool
		title          string
		notes, pending int
		gaps, raw      int
	}{
		{true, "first", 1, 1, 0, 1},
		{true, "", 1, 1, 0, 1},
		{false, "not captured", 2, 0, 1, 0},
		{true, "after re-enable", 3, 1, 1, 1},
	}
	for index, stage := range stages {
		func() {
			allowlist := ""
			enabled := 0
			if stage.enabled {
				// Duplicate names must not advance an epoch twice.
				allowlist = " " + workspace + ", " + workspace + " , "
				enabled = 1
			}
			server := startServerInWorkDirWithEnv(t, workDir, map[string]string{
				"NRC_CHRONICLE_WORKSPACES": allowlist,
				"NRC_THREAD_COUNT":         "1",
			})
			defer server.stop(t)
			if stage.title != "" {
				conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
				if err != nil {
					t.Fatal(err)
				}
				defer conn.Close()
				mustSetReadDeadline(t, conn, 5*time.Second)
				mustExpectServerReady(t, conn)
				createNoteAssetAndRead(t, conn, protocol.WorkspaceDataConvID, mustNotePreviewJSON(t, stage.title, ""))
			}
			// Inspect committed SQLite state while the real server is still open:
			// its WebSocket success must not precede committed capture visibility.
			check := exec.Command("python3", "-c", `
import sqlite3, sys
path, workspace = sys.argv[1:3]
epoch, enabled, notes, pending, gaps, raw = map(int, sys.argv[3:])
with sqlite3.connect("file:" + path + "?mode=ro", uri=True) as db:
    w = workspace.encode()
    assert db.execute("PRAGMA user_version").fetchone() == (9,)
    assert db.execute("SELECT epoch,enabled FROM chronicle_workspaces WHERE workspace=?", (w,)).fetchone() == (epoch,enabled)
    assert db.execute("SELECT count(*) FROM assets WHERE workspace=?", (w,)).fetchone() == (notes,)
    assert db.execute("SELECT count(*) FROM history WHERE workspace=?", (w,)).fetchone() == (notes,)
    assert db.execute("SELECT count(*) FROM chronicle_inputs WHERE workspace=? AND state=0", (w,)).fetchone() == (pending,)
    assert db.execute("SELECT coalesce(sum(input_count),0) FROM chronicle_gaps WHERE workspace=? AND reason=?", (w,b"disabled")).fetchone() == (gaps,)
    assert db.execute("SELECT count(*) FROM chronicle_raw WHERE workspace=?", (w,)).fetchone() == (raw,)
    assert db.execute("SELECT raw_bytes FROM chronicle_workspaces WHERE workspace=?", (w,)).fetchone()[0] == db.execute("SELECT coalesce(sum(byte_count),0) FROM chronicle_raw WHERE workspace=?", (w,)).fetchone()[0]
`, path, workspace, strconv.Itoa(index+1), strconv.Itoa(enabled),
				strconv.Itoa(stage.notes), strconv.Itoa(stage.pending), strconv.Itoa(stage.gaps), strconv.Itoa(stage.raw))
			if output, err := check.CombinedOutput(); err != nil {
				t.Fatalf("chronicle stage %d: %v\n%s", index, err, output)
			}
		}()
	}
}

func TestChronicleExpiryCleanupWhileIdleAfterRestart(t *testing.T) {
	workDir := t.TempDir()
	// Place the fixture on the first shard in the cleanup sweep so this tests
	// the real one-second idle wakeup without waiting for all 256 shards.
	workspace := ""
	for i := 0; i < 10000; i++ {
		candidate := fmt.Sprintf("chronicle-expiry-%d", i)
		if xxhash.Sum64String(candidate)%256 == 0 {
			workspace = candidate
			break
		}
	}
	if workspace == "" {
		t.Fatal("no fixture workspace on shard zero")
	}
	path := filepath.Join(workDir, "data", "sharded-00000000000000000001", "shard_000", "workspace.sqlite3")
	env := map[string]string{"NRC_CHRONICLE_WORKSPACES": workspace, "NRC_THREAD_COUNT": "1"}
	func() {
		server := startServerInWorkDirWithEnv(t, workDir, env)
		defer server.stop(t)
		conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		mustSetReadDeadline(t, conn, 5*time.Second)
		mustExpectServerReady(t, conn)
		createNoteAssetAndRead(t, conn, protocol.WorkspaceDataConvID, mustNotePreviewJSON(t, "expire", ""))
		createNoteAssetAndRead(t, conn, protocol.WorkspaceDataConvID, mustNotePreviewJSON(t, "keep", ""))
	}()
	// Age only one committed capture while stopped. Canonical notes/history
	// remain untouched. The other input must survive the same cleanup pass.
	age := exec.Command("python3", "-c", `
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("UPDATE chronicle_inputs SET captured_at=1,expires_at=2 WHERE source_id=(SELECT min(source_id) FROM chronicle_inputs)")
    assert db.execute("SELECT count(*) FROM chronicle_raw").fetchone() == (2,)
`, path)
	if output, err := age.CombinedOutput(); err != nil {
		t.Fatalf("age capture: %v\n%s", err, output)
	}
	server := startServerInWorkDirWithEnv(t, workDir, env)
	defer server.stop(t)
	// No WebSocket connection or mutation after restart: maintenance must wake
	// independently, commit the text-free gap and free exactly its raw quota.
	check := exec.Command("python3", "-c", `
import sqlite3, sys, time
with sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True) as db:
    deadline = time.monotonic() + 8
    while db.execute("SELECT coalesce(sum(input_count),0) FROM chronicle_gaps WHERE reason=?", (b"ttl",)).fetchone() != (1,):
        assert time.monotonic() < deadline, "idle cleanup did not commit"
        time.sleep(.02)
    assert db.execute("SELECT count(*) FROM chronicle_inputs").fetchone() == (1,)
    assert db.execute("SELECT count(*) FROM chronicle_inputs WHERE state=0").fetchone() == (1,)
    assert db.execute("SELECT count(*) FROM chronicle_raw").fetchone() == (1,)
    assert db.execute("SELECT pending_inputs FROM chronicle_workspaces").fetchone() == (1,)
    assert db.execute("SELECT raw_bytes FROM chronicle_workspaces").fetchone()[0] == db.execute("SELECT sum(byte_count) FROM chronicle_raw").fetchone()[0]
    assert db.execute("SELECT count(*) FROM assets").fetchone() == (2,)
    assert db.execute("SELECT count(*) FROM history").fetchone() == (2,)
    assert db.execute("SELECT epoch FROM chronicle_workspaces").fetchone() == (2,)
`, path)
	if output, err := check.CombinedOutput(); err != nil {
		t.Fatalf("idle expiry: %v\n%s", err, output)
	}
}
