package e2e

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/cespare/xxhash/v2"
	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestOutsideInWALWriteErrorRecoversAcknowledgedPrefixAndContinues(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("outside-in WAL rejection requires Linux RLIMIT_FSIZE semantics")
	}
	if _, err := exec.LookPath("prlimit"); err != nil {
		t.Skip("prlimit is required for outside-in WAL rejection")
	}

	serverWorkDir := t.TempDir()
	serverEnv := map[string]string{"NRC_THREAD_COUNT": "1"}
	workspace := fmt.Sprintf("e2e-wal-error-%d", time.Now().UnixNano())
	shard := xxhash.Sum64String(workspace) % 256
	walPath := filepath.Join(
		serverWorkDir,
		"data",
		"sharded-00000000000000000001",
		fmt.Sprintf("shard_%03d", shard),
		"active.wal",
	)

	// strace write(2) injection cannot reach writes performed by io_uring.
	// A kernel-enforced size limit rejects the next append with EFBIG instead.
	server := startServerIgnoringFileSizeSignal(t, serverWorkDir, serverEnv)
	servers := []*serverProcess{server}
	t.Cleanup(func() { cleanupFaultTestServers(t, servers) })

	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-wal-error-writer"))
	if err != nil {
		t.Fatalf("connect WAL-error writer: %v", err)
	}
	defer conn.Close()
	mustSetReadDeadline(t, conn, 10*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID
	expected := make(map[uint64]protocol.Task, 3)
	for index := 0; index < 3; index++ {
		correlationID := uint32(0xE0050000 + index)
		title := fmt.Sprintf("acknowledged before WAL error %d", index)
		if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreateWithCorrelation(roomID, title, "kernel-accepted prefix before write rejection", 1, correlationID)); err != nil {
			t.Fatalf("send acknowledged prefix create %d: %v", index, err)
		}
		payload := mustReadUntilOpcode(t, conn, protocol.S_TaskCreated, 12)
		created, err := protocol.DecodeTaskCreated(payload)
		if err != nil {
			t.Fatalf("decode acknowledged prefix create %d: %v", index, err)
		}
		if created.CorrelationID != correlationID || created.Task.Title != title {
			t.Fatalf("acknowledged prefix create %d mismatch: %+v", index, created)
		}
		expected[created.Task.ID] = *created.Task
	}

	prefixInfo, err := os.Stat(walPath)
	if err != nil {
		t.Fatalf("stat acknowledged WAL prefix: %v", err)
	}
	limit := strconv.FormatInt(prefixInfo.Size(), 10)
	if output, err := exec.Command("prlimit", "--pid", strconv.Itoa(server.cmd.Process.Pid), "--fsize="+limit+":"+limit).CombinedOutput(); err != nil {
		t.Fatalf("set server WAL file-size limit: %v: %s", err, strings.TrimSpace(string(output)))
	}
	const failedTitle = "must not survive WAL rejection"
	const failedCorrelationID = uint32(0xE00500FF)
	if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreateWithCorrelation(roomID, failedTitle, "kernel-rejected write", 1, failedCorrelationID)); err != nil {
		t.Fatalf("send rejected create: %v", err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	if payload, readErr := readUntilOpcode(conn, protocol.S_TaskCreated, 12); readErr == nil {
		created, decodeErr := protocol.DecodeTaskCreated(payload)
		t.Fatalf("rejected mutation was acknowledged: response=%+v decode_err=%v", created, decodeErr)
	}
	_ = conn.Close()
	waitForFatalStorageServerExit(t, server, workspace, "EFBIG", 10*time.Second)
	if logs := server.logs.String(); !strings.Contains(logs, "WAL poisoned after ambiguous append: wrote 0/") || !strings.Contains(logs, "err=EFBIG") {
		t.Fatalf("server did not observe the kernel's EFBIG rejection:\n%s", logs)
	}
	rejectedInfo, err := os.Stat(walPath)
	if err != nil || rejectedInfo.Size() != prefixInfo.Size() {
		t.Fatalf("rejected write changed the WAL prefix: info=%v err=%v", rejectedInfo, err)
	}

	server = startServerInWorkDirWithEnv(t, serverWorkDir, serverEnv)
	servers = append(servers, server)
	recovered, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-wal-error-recovered"))
	if err != nil {
		t.Fatalf("connect after WAL-error restart: %v", err)
	}
	defer recovered.Close()
	mustSetReadDeadline(t, recovered, 10*time.Second)
	mustExpectServerReady(t, recovered)
	mustRequireExactTaskState(t, recovered, roomID, expected)

	const continuedTitle = "write after WAL-error recovery"
	const continuedCorrelationID = uint32(0xE0050100)
	if err := sendProtocolMessage(recovered, protocol.C_CreateTask, protocol.EncodeTaskCreateWithCorrelation(roomID, continuedTitle, "storage capacity restored", 2, continuedCorrelationID)); err != nil {
		t.Fatalf("send continued write after WAL-error: %v", err)
	}
	continuedPayload := mustReadUntilOpcode(t, recovered, protocol.S_TaskCreated, 12)
	continued, err := protocol.DecodeTaskCreated(continuedPayload)
	if err != nil {
		t.Fatalf("decode continued write after WAL-error: %v", err)
	}
	if continued.CorrelationID != continuedCorrelationID || continued.Task.Title != continuedTitle {
		t.Fatalf("continued write after WAL-error mismatch: %+v", continued)
	}
	expected[continued.Task.ID] = *continued.Task
	_ = recovered.Close()

	server.killAndWait(t)
	server = startServerInWorkDirWithEnv(t, serverWorkDir, serverEnv)
	servers = append(servers, server)
	finalConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-wal-error-final"))
	if err != nil {
		t.Fatalf("connect after final WAL-error recovery restart: %v", err)
	}
	defer finalConn.Close()
	mustSetReadDeadline(t, finalConn, 10*time.Second)
	mustExpectServerReady(t, finalConn)
	mustRequireExactTaskState(t, finalConn, roomID, expected)
}

func TestOutsideInPartialWALWriteTruncatesTailAndContinues(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("outside-in partial WAL writes require Linux RLIMIT_FSIZE semantics")
	}
	if _, err := exec.LookPath("prlimit"); err != nil {
		t.Skip("prlimit is required for outside-in partial WAL writes")
	}

	serverWorkDir := t.TempDir()
	serverEnv := map[string]string{"NRC_THREAD_COUNT": "1"}
	workspace := fmt.Sprintf("e2e-partial-wal-%d", time.Now().UnixNano())
	shard := xxhash.Sum64String(workspace) % 256
	walPath := filepath.Join(
		serverWorkDir,
		"data",
		"sharded-00000000000000000001",
		fmt.Sprintf("shard_%03d", shard),
		"active.wal",
	)

	server := startServerIgnoringFileSizeSignal(t, serverWorkDir, serverEnv)
	servers := []*serverProcess{server}
	t.Cleanup(func() { cleanupFaultTestServers(t, servers) })
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-partial-wal-writer"))
	if err != nil {
		t.Fatalf("connect partial-WAL writer: %v", err)
	}
	defer conn.Close()
	mustSetReadDeadline(t, conn, 10*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID
	expected := make(map[uint64]protocol.Task, 2)
	for index := 0; index < 2; index++ {
		correlationID := uint32(0xE0060000 + index)
		title := fmt.Sprintf("acknowledged before partial WAL write %d", index)
		if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreateWithCorrelation(roomID, title, "kernel-accepted prefix before short write", 1, correlationID)); err != nil {
			t.Fatalf("send partial-WAL baseline %d: %v", index, err)
		}
		payload := mustReadUntilOpcode(t, conn, protocol.S_TaskCreated, 12)
		created, err := protocol.DecodeTaskCreated(payload)
		if err != nil || created.CorrelationID != correlationID || created.Task.Title != title {
			t.Fatalf("partial-WAL baseline %d mismatch: response=%+v err=%v", index, created, err)
		}
		expected[created.Task.ID] = *created.Task
	}
	prefixInfo, err := os.Stat(walPath)
	if err != nil {
		t.Fatalf("stat acknowledged WAL prefix: %v", err)
	}
	const partialBytes = int64(16)
	fileSizeLimit := prefixInfo.Size() + partialBytes
	limit := strconv.FormatInt(fileSizeLimit, 10)
	if output, err := exec.Command("prlimit", "--pid", strconv.Itoa(server.cmd.Process.Pid), "--fsize="+limit+":"+limit).CombinedOutput(); err != nil {
		t.Fatalf("set server WAL file-size limit: %v: %s", err, strings.TrimSpace(string(output)))
	}

	const failedTitle = "must not survive partial WAL write"
	if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreateWithCorrelation(roomID, failedTitle, strings.Repeat("partial-write-payload-", 32), 1, 0xE00600FF)); err != nil {
		t.Fatalf("send partial-WAL mutation: %v", err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	if payload, readErr := readUntilOpcode(conn, protocol.S_TaskCreated, 12); readErr == nil {
		created, decodeErr := protocol.DecodeTaskCreated(payload)
		t.Fatalf("partial-WAL mutation was acknowledged: response=%+v decode_err=%v", created, decodeErr)
	}
	_ = conn.Close()
	waitForFatalStorageServerExit(t, server, workspace, "partial WAL write", 10*time.Second)
	shortWriteMarker := fmt.Sprintf("WAL poisoned after ambiguous append: wrote %d/", partialBytes)
	if !strings.Contains(server.logs.String(), shortWriteMarker) {
		t.Fatalf("server did not observe the expected short WAL write %q:\n%s", shortWriteMarker, server.logs.String())
	}

	partialInfo, err := os.Stat(walPath)
	if err != nil {
		t.Fatalf("stat partial WAL tail: %v", err)
	}
	if partialInfo.Size() != fileSizeLimit {
		t.Fatalf("kernel did not leave the expected partial WAL tail: got=%d want=%d", partialInfo.Size(), fileSizeLimit)
	}

	server = startServerInWorkDirWithEnv(t, serverWorkDir, serverEnv)
	servers = append(servers, server)
	recoveredInfo, err := os.Stat(walPath)
	if err != nil {
		t.Fatalf("stat recovered WAL after partial write: %v", err)
	}
	if recoveredInfo.Size() != prefixInfo.Size() {
		t.Fatalf("recovery did not truncate partial WAL exactly: got=%d want=%d", recoveredInfo.Size(), prefixInfo.Size())
	}
	recovered, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-partial-wal-recovered"))
	if err != nil {
		t.Fatalf("connect after partial-WAL recovery: %v", err)
	}
	defer recovered.Close()
	mustSetReadDeadline(t, recovered, 10*time.Second)
	mustExpectServerReady(t, recovered)
	mustRequireExactTaskState(t, recovered, roomID, expected)

	const continuedTitle = "write after partial WAL recovery"
	if err := sendProtocolMessage(recovered, protocol.C_CreateTask, protocol.EncodeTaskCreateWithCorrelation(roomID, continuedTitle, "continued after tail truncation", 2, 0xE0060100)); err != nil {
		t.Fatalf("send write after partial-WAL recovery: %v", err)
	}
	continuedPayload := mustReadUntilOpcode(t, recovered, protocol.S_TaskCreated, 12)
	continued, err := protocol.DecodeTaskCreated(continuedPayload)
	if err != nil || continued.CorrelationID != 0xE0060100 || continued.Task.Title != continuedTitle {
		t.Fatalf("continued partial-WAL write mismatch: response=%+v err=%v", continued, err)
	}
	expected[continued.Task.ID] = *continued.Task
	_ = recovered.Close()

	server.killAndWait(t)
	server = startServerInWorkDirWithEnv(t, serverWorkDir, serverEnv)
	servers = append(servers, server)
	finalConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-partial-wal-final"))
	if err != nil {
		t.Fatalf("connect after final partial-WAL restart: %v", err)
	}
	defer finalConn.Close()
	mustSetReadDeadline(t, finalConn, 10*time.Second)
	mustExpectServerReady(t, finalConn)
	mustRequireExactTaskState(t, finalConn, roomID, expected)
}

func TestOutsideInNonWritableShardDirectoryDefersRotationAndRecovers(t *testing.T) {
	if runtime.GOOS != "linux" || os.Geteuid() == 0 {
		t.Skip("outside-in directory permission faults require non-root Linux permissions")
	}

	serverWorkDir := t.TempDir()
	serverEnv := map[string]string{"NRC_THREAD_COUNT": "1"}
	workspace := fmt.Sprintf("e2e-rotation-permission-%d", time.Now().UnixNano())
	shard := xxhash.Sum64String(workspace) % 256
	shardDir := filepath.Join(
		serverWorkDir,
		"data",
		"sharded-00000000000000000001",
		fmt.Sprintf("shard_%03d", shard),
	)
	walPath := filepath.Join(shardDir, "active.wal")

	server := startServerInWorkDirWithEnv(t, serverWorkDir, serverEnv)
	servers := []*serverProcess{server}
	t.Cleanup(func() { cleanupFaultTestServers(t, servers) })
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-rotation-permission-writer"))
	if err != nil {
		t.Fatalf("connect rotation-permission writer: %v", err)
	}
	defer conn.Close()
	mustSetReadDeadline(t, conn, 10*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID
	if err := sendProtocolMessage(conn, protocol.C_CreateTask, protocol.EncodeTaskCreateWithCorrelation(roomID, "rotation permission survivor", "initial", 1, 0xE0070001)); err != nil {
		t.Fatalf("create rotation-permission survivor: %v", err)
	}
	createdPayload := mustReadUntilOpcode(t, conn, protocol.S_TaskCreated, 12)
	created, err := protocol.DecodeTaskCreated(createdPayload)
	if err != nil {
		t.Fatalf("decode rotation-permission survivor: %v", err)
	}
	expected := *created.Task

	const compactionThreshold = int64(8192)
	const description = "rotation permission churn:" +
		"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
	longDescription := description + strings.Repeat("x", 1800)
	var recordBytes int64
	for update := 1; update <= 20; update++ {
		before, statErr := os.Stat(walPath)
		if statErr != nil {
			t.Fatalf("stat active WAL before churn %d: %v", update, statErr)
		}
		if recordBytes > 0 && before.Size()+recordBytes > compactionThreshold {
			break
		}
		title := fmt.Sprintf("rotation survivor %04d", update)
		if err := sendProtocolMessage(conn, protocol.C_UpdateTask, protocol.EncodeTaskUpdateWithCorrelation(roomID, int64(expected.ID), title, longDescription, int32(protocol.TaskStatusInProgress), 2, 0, uint32(0xE0070100+update))); err != nil {
			t.Fatalf("send rotation churn %d: %v", update, err)
		}
		updatedPayload := mustReadUntilOpcode(t, conn, protocol.S_TaskUpdated, 12)
		updated, decodeErr := protocol.DecodeTaskUpdated(updatedPayload)
		if decodeErr != nil {
			t.Fatalf("decode rotation churn %d: %v", update, decodeErr)
		}
		expected = *updated.Task
		after, statErr := os.Stat(walPath)
		if statErr != nil {
			t.Fatalf("stat active WAL after churn %d: %v", update, statErr)
		}
		observedRecordBytes := after.Size() - before.Size()
		if observedRecordBytes <= 0 {
			t.Fatalf("active WAL unexpectedly rotated before permission fault: before=%d after=%d", before.Size(), after.Size())
		}
		if recordBytes > 0 && observedRecordBytes != recordBytes {
			t.Fatalf("rotation churn record size changed: got=%d want=%d", observedRecordBytes, recordBytes)
		}
		recordBytes = observedRecordBytes
	}
	prefixInfo, err := os.Stat(walPath)
	if err != nil {
		t.Fatalf("stat WAL before rotation permission fault: %v", err)
	}
	if recordBytes == 0 || prefixInfo.Size()+recordBytes <= compactionThreshold {
		t.Fatalf("WAL is not poised to rotate: size=%d next_record=%d threshold=%d", prefixInfo.Size(), recordBytes, compactionThreshold)
	}

	if err := os.Chmod(shardDir, 0o555); err != nil {
		t.Fatalf("make shard directory non-writable: %v", err)
	}
	defer os.Chmod(shardDir, 0o755)
	probePath := filepath.Join(shardDir, "permission-probe")
	if err := os.WriteFile(probePath, nil, 0o644); err == nil {
		_ = os.Remove(probePath)
		t.Fatal("non-writable shard directory still allowed file creation")
	}

	failedTitle := "rotation blocked by directory permissions"
	failedCorrelationID := uint32(0xE00700FF)
	if err := sendProtocolMessage(conn, protocol.C_UpdateTask, protocol.EncodeTaskUpdateWithCorrelation(roomID, int64(expected.ID), failedTitle, longDescription, int32(protocol.TaskStatusDone), 3, 0, failedCorrelationID)); err != nil {
		t.Fatalf("send permission-blocked rotation update: %v", err)
	}
	_, busyErr := readUntilOpcode(conn, protocol.S_TaskUpdated, 12)
	var closeErr *websocket.CloseError
	if !errors.As(busyErr, &closeErr) || closeErr.Code != websocket.CloseTryAgainLater {
		t.Fatalf("permission-blocked mutation must receive an explicit busy close: %v", busyErr)
	}
	fenceConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-rotation-permission-fence"))
	if err != nil {
		t.Fatalf("connect read fence after busy close: %v", err)
	}
	mustSetReadDeadline(t, fenceConn, 10*time.Second)
	mustExpectServerReady(t, fenceConn)
	mustRequireExactTaskState(t, fenceConn, roomID, map[uint64]protocol.Task{expected.ID: expected})
	_ = fenceConn.Close()
	blockedInfo, err := os.Stat(walPath)
	if err != nil {
		t.Fatalf("stat WAL after permission-blocked rotation: %v", err)
	}
	if blockedInfo.Size() != prefixInfo.Size() {
		t.Fatalf("permission-blocked rotation changed active WAL: got=%d want=%d", blockedInfo.Size(), prefixInfo.Size())
	}

	if err := os.Chmod(shardDir, 0o755); err != nil {
		t.Fatalf("restore shard directory permissions: %v", err)
	}
	recoveredConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-rotation-permission-recovered"))
	if err != nil {
		t.Fatalf("connect after restoring rotation permissions: %v", err)
	}
	defer recoveredConn.Close()
	mustSetReadDeadline(t, recoveredConn, 10*time.Second)
	mustExpectServerReady(t, recoveredConn)
	if err := sendProtocolMessage(recoveredConn, protocol.C_UpdateTask, protocol.EncodeTaskUpdateWithCorrelation(roomID, int64(expected.ID), failedTitle, longDescription, int32(protocol.TaskStatusDone), 3, 0, 0xE0070200)); err != nil {
		t.Fatalf("retry update after restoring rotation permissions: %v", err)
	}
	retriedPayload := mustReadUntilOpcode(t, recoveredConn, protocol.S_TaskUpdated, 12)
	retried, err := protocol.DecodeTaskUpdated(retriedPayload)
	if err != nil || retried.Task.Title != failedTitle {
		t.Fatalf("retry after restoring rotation permissions failed: response=%+v err=%v", retried, err)
	}
	expected = *retried.Task
	_ = recoveredConn.Close()

	server.killAndWait(t)
	if !strings.Contains(server.logs.String(), "rejected by shard storage backpressure for workspace "+workspace) {
		t.Fatalf("server did not report rotation backpressure:\n%s", server.logs.String())
	}
	server = startServerInWorkDirWithEnv(t, serverWorkDir, serverEnv)
	servers = append(servers, server)
	finalConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-rotation-permission-final"))
	if err != nil {
		t.Fatalf("connect after rotation-permission restart: %v", err)
	}
	defer finalConn.Close()
	mustSetReadDeadline(t, finalConn, 10*time.Second)
	mustExpectServerReady(t, finalConn)
	mustRequireExactTaskState(t, finalConn, roomID, map[uint64]protocol.Task{expected.ID: expected})
}

func startServerIgnoringFileSizeSignal(t *testing.T, workDir string, extraEnv map[string]string) *serverProcess {
	t.Helper()
	stopSharedServerIfRunning()
	if err := initializeEmptyShardedLayout(workDir); err != nil {
		t.Fatalf("initialize partial-WAL test layout: %v", err)
	}

	cmd := exec.Command("sh", "-c", `trap '' XFSZ; exec "$1"`, "sh", buildServerBinaryOnce(t))
	cmd.Dir = workDir
	cmd.Env = append(
		os.Environ(),
		"NRC_JWT_SECRET="+e2eJWTSecret,
		"NRC_BOT_SECRET="+metricsBotSecret,
		"NRC_PORT="+strconv.Itoa(serverPort),
	)
	for key, value := range extraEnv {
		cmd.Env = append(cmd.Env, key+"="+value)
	}

	proc := &serverProcess{cmd: cmd}
	cmd.Stdout = &proc.logs
	cmd.Stderr = &proc.logs
	if err := cmd.Start(); err != nil {
		t.Fatalf("start server with ignored SIGXFSZ: %v", err)
	}
	if err := waitForServerReady(proc.cmd, 10*time.Second); err != nil {
		stopServerProcess(proc)
		t.Fatalf("partial-WAL server did not become ready: %v\nlogs:\n%s", err, proc.logs.String())
	}
	return proc
}

func waitForFatalStorageServerExit(t *testing.T, server *serverProcess, workspace, fault string, timeout time.Duration) {
	t.Helper()
	done := make(chan error, 1)
	go func() { done <- server.cmd.Wait() }()
	select {
	case err := <-done:
		server.exited = true
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) || exitErr.ExitCode() != 1 {
			t.Fatalf("server did not use fatal-storage exit status 1 after %s: err=%v\nlogs:\n%s", fault, err, server.logs.String())
		}
		expectedLog := "Persistent task create rejected by WAL for workspace " + workspace
		// Submission and completion failures have separate diagnostics.
		batchFailure := "Shard WAL durability sync failed; shutting down"
		writeFailure := "Shard WAL async write failed; shutting down"
		logs := server.logs.String()
		if !strings.Contains(logs, expectedLog) && !strings.Contains(logs, batchFailure) && !strings.Contains(logs, writeFailure) {
			t.Fatalf("server did not log a fatal WAL rejection or batch failure:\n%s", logs)
		}
	case <-time.After(timeout):
		_ = server.cmd.Process.Kill()
		<-done
		server.exited = true
		t.Fatalf("server did not shut down after %s within %s\nlogs:\n%s", fault, timeout, server.logs.String())
	}
}
