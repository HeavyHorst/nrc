package e2e

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"testing"
	"time"

	"github.com/cespare/xxhash/v2"
	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

// SQLite owns WAL recovery now. Exercise the public durability contract rather
// than the removed workspace writer's record lengths or rotation diagnostics.
func TestOutsideInSQLiteWriteErrorRecoversAcknowledgedPrefixAndContinues(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("requires Linux RLIMIT_FSIZE")
	}
	if _, err := exec.LookPath("prlimit"); err != nil {
		t.Skip("prlimit is required")
	}
	dir := t.TempDir()
	workspace := "sqlite-write-fault"
	env := map[string]string{"NRC_THREAD_COUNT": "1"}
	server := startServerIgnoringFileSizeSignal(t, dir, env)
	servers := []*serverProcess{server}
	t.Cleanup(func() { cleanupFaultTestServers(t, servers) })
	connect := func() *websocket.Conn {
		conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "fault-writer"))
		if err != nil {
			t.Fatal(err)
		}
		mustSetReadDeadline(t, conn, 10*time.Second)
		mustExpectServerReady(t, conn)
		return conn
	}
	conn := connect()
	defer conn.Close()
	expected := make(map[uint64]protocol.Task)
	create := func(conn *websocket.Conn, title string, correlation uint32) {
		if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreateWithCorrelation(protocol.WorkspaceDataConvID, title, "durable fixture", 1, correlation)); err != nil {
			t.Fatal(err)
		}
		payload := mustReadUntilOpcode(t, conn, protocol.S_TaskCreated, 12)
		created, err := protocol.DecodeTaskCreated(payload)
		if err != nil || created.CorrelationID != correlation || created.Task.Title != title {
			t.Fatalf("create mismatch: %+v %v", created, err)
		}
		expected[created.Task.ID] = *created.Task
	}
	create(conn, "before fault", 1)
	wal := filepath.Join(dir, "data", "sharded-00000000000000000001", fmt.Sprintf("shard_%03d", xxhash.Sum64String(workspace)%256), "workspace.sqlite3-wal")
	info, err := os.Stat(wal)
	if err != nil {
		t.Fatal(err)
	}
	limit := strconv.FormatInt(info.Size(), 10)
	if output, err := exec.Command("prlimit", "--pid", strconv.Itoa(server.cmd.Process.Pid), "--fsize="+limit+":"+limit).CombinedOutput(); err != nil {
		t.Fatalf("set file-size limit: %v %s", err, output)
	}
	if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreateWithCorrelation(protocol.WorkspaceDataConvID, "must roll back", "rejected append", 1, 2)); err != nil {
		t.Fatal(err)
	}
	payload := mustReadUntilOpcode(t, conn, protocol.S_TaskListResponse, 12)
	response, err := protocol.DecodeTaskListResponse(payload)
	if response == nil || response.Success || response.CorrelationID != 2 || response.ErrorMessage != "Failed to create task" || err == nil {
		t.Fatalf("expected correlated storage failure: %+v %v", response, err)
	}
	_ = conn.Close()
	server.killAndWait(t)
	server = startServerInWorkDirWithEnv(t, dir, env)
	servers = append(servers, server)
	conn = connect()
	defer conn.Close()
	mustRequireExactTaskState(t, conn, protocol.WorkspaceDataConvID, expected)
	create(conn, "after fault", 3)
	_ = conn.Close()
	server.killAndWait(t)
	server = startServerInWorkDirWithEnv(t, dir, env)
	servers = append(servers, server)
	conn = connect()
	defer conn.Close()
	mustRequireExactTaskState(t, conn, protocol.WorkspaceDataConvID, expected)
}

func startServerIgnoringFileSizeSignal(t *testing.T, workDir string, extraEnv map[string]string) *serverProcess {
	t.Helper()
	stopSharedServerIfRunning()
	if err := os.MkdirAll(filepath.Join(workDir, "data"), 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("sh", "-c", `trap '' XFSZ; exec "$1"`, "sh", buildServerBinaryOnce(t))
	cmd.Dir = workDir
	cmd.Env = append(os.Environ(), "NRC_JWT_SECRET="+e2eJWTSecret, "NRC_BOT_SECRET="+metricsBotSecret, "NRC_PORT="+strconv.Itoa(serverPort))
	for key, value := range extraEnv {
		cmd.Env = append(cmd.Env, key+"="+value)
	}
	proc := &serverProcess{cmd: cmd}
	cmd.Stdout = &proc.logs
	cmd.Stderr = &proc.logs
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	if err := waitForServerReady(proc.cmd, 10*time.Second); err != nil {
		stopServerProcess(proc)
		t.Fatalf("fault-test server did not become ready: %v\n%s", err, proc.logs.String())
	}
	return proc
}
