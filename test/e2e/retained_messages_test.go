package e2e

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestRetainedImportActivationAndRestart(t *testing.T) {
	repo, root := repoRootFromThisFile(t), t.TempDir()
	sourceWork, targetWork := filepath.Join(root, "source"), filepath.Join(root, "activated")
	if err := initializeEmptyShardedLayout(sourceWork); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(sourceWork, "data")
	if err := os.WriteFile(filepath.Join(source, "storage-layout.lock"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(targetWork, 0o700); err != nil {
		t.Fatal(err)
	}
	run := func(cmd *exec.Cmd) {
		t.Helper()
		cmd.Env = append(cmd.Environ(), "PYTHONDONTWRITEBYTECODE=1")
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%v: %v\n%s", cmd.Args, err, output)
		}
	}
	// Generate all three storage states through the real Odin writer, without
	// timing a process kill against asynchronous seal completion.
	fixture := exec.Command(filepath.Join(repo, "test/run_odin_tests.sh"), repo,
		"-vet", "-define:ODIN_TEST_NAMES=main.test_retained_activation_fixture", "-define:ODIN_TEST_THREADS=1")
	fixture.Dir = root
	fixture.Env = append(os.Environ(), "ODIN_BIN="+discoverOdinBinary(),
		"NRC_TEST_RETAINED_FIXTURE_ROOT="+filepath.Join(source, "sharded-00000000000000000001"))
	run(fixture)
	// Compare every file, including retained WALs, indexes and manifests.
	inventory := func(dir string) map[string][32]byte {
		t.Helper()
		result := make(map[string][32]byte)
		err := filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
			if err != nil || entry.IsDir() {
				return err
			}
			body, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			rel, err := filepath.Rel(dir, path)
			result[rel] = sha256.Sum256(body)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	before := inventory(source)
	builder := filepath.Join(root, "projection-builder")
	build := exec.Command(discoverOdinBinary(), "build", repo, "-vet", "-define:NRC_SQLITE_PROJECTION_BUILDER=true", "-out:"+builder)
	build.Dir = root
	run(build)
	imported := filepath.Join(root, "imported")
	tools := filepath.Join(repo, "tools/wal-to-sqlite")
	run(exec.Command("python3", filepath.Join(tools, "import_wal.py"), "--source", source, "--target", imported, "--projection-builder", builder))
	importBefore := inventory(imported)
	target := filepath.Join(targetWork, "data")
	run(exec.Command("python3", filepath.Join(tools, "activate_import.py"), "--source", source, "--import-dir", imported, "--target", target))
	after := inventory(target)
	retainedFiles := 0
	for name, digest := range before {
		if strings.Contains(name, "/messages/") {
			retainedFiles++
			if after[name] != digest {
				t.Fatalf("retained file changed during activation: %s", name)
			}
		}
	}
	if retainedFiles == 0 {
		t.Fatal("empty retained fixture")
	}
	blobs := filepath.Join(root, "blobs")
	if err := os.Mkdir(blobs, 0o700); err != nil {
		t.Fatal(err)
	}
	for i := 1; i <= 4; i++ {
		if err := os.WriteFile(filepath.Join(blobs, fmt.Sprintf("att_%032d", i)), []byte{byte(i)}, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	gc := func() {
		t.Helper()
		cmd := exec.Command(buildServerBinaryOnce(t), "attachment-gc", "--apply", "--attachments-dir", blobs)
		cmd.Dir = targetWork
		run(cmd)
		for i := 1; i <= 3; i++ {
			body, err := os.ReadFile(filepath.Join(blobs, fmt.Sprintf("att_%032d", i)))
			if err != nil || string(body) != string([]byte{byte(i)}) {
				t.Fatalf("lost retained attachment %d: %v", i, err)
			}
		}
		if _, err := os.Stat(filepath.Join(blobs, "att_00000000000000000000000000000004")); !os.IsNotExist(err) {
			t.Fatalf("orphan was not quarantined: %v", err)
		}
	}
	gc() // Check frozen references before startup recovery can finish sealing.
	for restart := 0; restart < 2; restart++ {
		func() {
			server := startServerInWorkDirWithEnv(t, targetWork, map[string]string{"NRC_MESSAGE_RETENTION": "24h", "NRC_THREAD_COUNT": "2"})
			defer server.stop(t)
			conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace("activation-retained"), mustAuthHeader(t, "activation-reader"))
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			mustSetReadDeadline(t, conn, 20*time.Second)
			mustExpectServerReady(t, conn)
			subscribe, err := protocol.EncodeSubscribeConvsV2(100, 42)
			if err != nil {
				t.Fatal(err)
			}
			if err := sendProtocolMessage(conn, protocol.C_SubscribeConvsV2, subscribe); err != nil {
				t.Fatal(err)
			}
			mustReadUntilOpcode(t, conn, protocol.S_SubscriptionReady, 16)
			request, err := protocol.EncodeListMessagesBefore(42, 0, 10, 101)
			if err != nil {
				t.Fatal(err)
			}
			if err := sendProtocolMessage(conn, protocol.C_ListMessagesBefore, request); err != nil {
				t.Fatal(err)
			}
			page, err := protocol.DecodeMessagePage(mustReadUntilOpcode(t, conn, protocol.S_MessagePage, 16))
			if err != nil || len(page.Messages) != 3 {
				t.Fatalf("restart %d: retained page=%+v error=%v", restart, page, err)
			}
			for i, state := range []string{"active", "frozen", "sealed"} {
				seq := 3 - i
				message := page.Messages[i]
				want := fmt.Sprintf("%s /files/att_%032d?filename=%s.bin", state, seq, state)
				if message.Sequence != uint64(seq) || message.Content != want || message.Username != "alice" {
					t.Fatalf("restart %d: expected seq=%d body=%q, got %+v", restart, seq, want, message)
				}
			}
			_ = conn.Close()
			server.stopGracefully(t)
		}()
	}
	gc()
	if !reflect.DeepEqual(before, inventory(source)) || !reflect.DeepEqual(importBefore, inventory(imported)) {
		t.Fatal("activation or server modified offline inputs")
	}
}

func TestRetainedMessageSurvivesRestartAndDeduplicates(t *testing.T) {
	workDir := t.TempDir()
	retentionEnv := map[string]string{"NRC_MESSAGE_RETENTION": "24h", "NRC_MESSAGE_DEDUP_WINDOW": "5m"}
	server := startServerInWorkDirWithEnv(t, workDir, retentionEnv)

	const workspace = "e2e-retained-messages"
	const roomID uint64 = 2
	var clientID protocol.ClientMessageID
	copy(clientID[:], []byte("stable-message-1"))

	connect := func() *websocket.Conn {
		conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "retained-alice"))
		if err != nil {
			t.Fatalf("connect retained client: %v", err)
		}
		mustSetReadDeadline(t, conn, 20*time.Second)
		mustExpectServerReady(t, conn)
		subscribe, err := protocol.EncodeSubscribeConvsV2(0x1001, roomID)
		if err != nil {
			t.Fatalf("encode retained subscription: %v", err)
		}
		if err := sendProtocolMessage(conn, protocol.C_SubscribeConvsV2, subscribe); err != nil {
			t.Fatalf("send retained subscription: %v", err)
		}
		readyPayload := mustReadUntilOpcode(t, conn, protocol.S_SubscriptionReady, 16)
		ready, err := protocol.DecodeSubscriptionReady(readyPayload)
		if err != nil || len(ready.Entries) != 1 || ready.Entries[0].ConvID != roomID {
			t.Fatalf("invalid subscription-ready payload: ready=%+v err=%v", ready, err)
		}
		return conn
	}

	conn := connect()
	sendPayload, err := protocol.EncodeSendMessageV2(roomID, clientID, 0x2001, protocol.ContentTypePlainText, "retained hello")
	if err != nil {
		t.Fatalf("encode retained message: %v", err)
	}
	if err := sendProtocolMessage(conn, protocol.C_SendMessageV2, sendPayload); err != nil {
		t.Fatalf("send retained message: %v", err)
	}
	ackPayload := mustReadUntilOpcode(t, conn, protocol.S_AckSendMessage, 16)
	ack, err := protocol.DecodeAckSendMessage(ackPayload)
	if err != nil || ack.AssignedSeq == 0 {
		t.Fatalf("invalid retained message ack: ack=%+v err=%v", ack, err)
	}
	originalSeq := ack.AssignedSeq
	var secondID protocol.ClientMessageID
	copy(secondID[:], []byte("stable-message-2"))
	secondPayload, err := protocol.EncodeSendMessageV2(roomID, secondID, 0x2002, protocol.ContentTypePlainText, "retained second")
	if err != nil {
		t.Fatalf("encode second retained message: %v", err)
	}
	if err := sendProtocolMessage(conn, protocol.C_SendMessageV2, secondPayload); err != nil {
		t.Fatalf("send second retained message: %v", err)
	}
	secondAckPayload := mustReadUntilOpcode(t, conn, protocol.S_AckSendMessage, 16)
	secondAck, err := protocol.DecodeAckSendMessage(secondAckPayload)
	if err != nil || secondAck.AssignedSeq <= originalSeq {
		t.Fatalf("invalid second retained ack: ack=%+v err=%v", secondAck, err)
	}
	_ = conn.Close()
	server.stop(t)

	server = startServerInWorkDirWithEnv(t, workDir, retentionEnv)
	defer server.stop(t)
	conn = connect()
	defer conn.Close()

	historyPayload, err := protocol.EncodeListMessagesBefore(roomID, 0, 100, 0x3001)
	if err != nil {
		t.Fatalf("encode retained history request: %v", err)
	}
	if err := sendProtocolMessage(conn, protocol.C_ListMessagesBefore, historyPayload); err != nil {
		t.Fatalf("send retained history request: %v", err)
	}
	pagePayload := mustReadUntilOpcode(t, conn, protocol.S_MessagePage, 16)
	page, err := protocol.DecodeMessagePage(pagePayload)
	if err != nil || len(page.Messages) != 2 || page.Messages[0].Content != "retained second" || page.Messages[1].Sequence != uint64(originalSeq) || page.Messages[1].Content != "retained hello" || page.Messages[1].ClientMessageID != clientID {
		t.Fatalf("unexpected retained page: page=%+v err=%v logs=%s", page, err, server.logs.String())
	}

	// Retry after recovery: the original sequence is acknowledged and no second record is appended.
	if err := sendProtocolMessage(conn, protocol.C_SendMessageV2, sendPayload); err != nil {
		t.Fatalf("retry retained message: %v", err)
	}
	retryAckPayload := mustReadUntilOpcode(t, conn, protocol.S_AckSendMessage, 16)
	retryAck, err := protocol.DecodeAckSendMessage(retryAckPayload)
	if err != nil || retryAck.AssignedSeq != originalSeq || binary.BigEndian.Uint32(retryAckPayload[:4]) != 0x2001 {
		t.Fatalf("retry did not return original identity: ack=%+v err=%v", retryAck, err)
	}
}

func TestRetainedDMLifecycleAndAuthorization(t *testing.T) {
	workDir := t.TempDir()
	env := map[string]string{"NRC_MESSAGE_RETENTION": "24h", "NRC_MESSAGE_DEDUP_WINDOW": "5m", "NRC_THREAD_COUNT": "1"}
	server := startServerInWorkDirWithEnv(t, workDir, env)
	defer func() { server.stop(t) }()
	const workspace = "retained-dm-lifecycle"
	dial := func(ws, user string) *websocket.Conn {
		t.Helper()
		c, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(ws), mustAuthHeader(t, user))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		mustSetReadDeadline(t, c, 20*time.Second)
		mustExpectServerReady(t, c)
		return c
	}
	send := func(c *websocket.Conn, op uint16, payload []byte) {
		t.Helper()
		if err := sendProtocolMessage(c, op, payload); err != nil {
			t.Fatal(err)
		}
	}
	alice, bob := dial(workspace, "alice"), dial(workspace, "bob")
	send(alice, protocol.C_StartDM, protocol.EncodeStartDMWithCorrelation("bob", 1))
	started, err := protocol.DecodeDMStarted(mustReadUntilOpcode(t, alice, protocol.S_DMStarted, 32))
	if err != nil {
		t.Fatal(err)
	}
	id := started.ConvID
	mustReadUntilOpcode(t, bob, protocol.S_DMStarted, 32)
	subscribe := func(c *websocket.Conn, enabled bool) {
		t.Helper()
		payload, err := protocol.EncodeSubscribeConvsV2(2, id)
		if err != nil {
			t.Fatal(err)
		}
		send(c, protocol.C_SubscribeConvsV2, payload)
		ready, err := protocol.DecodeSubscriptionReady(mustReadUntilOpcode(t, c, protocol.S_SubscriptionReady, 32))
		if err != nil || (len(ready.Entries) == 1) != enabled {
			t.Fatalf("readiness: %+v %v", ready, err)
		}
	}
	subscribe(alice, true)
	var clientID protocol.ClientMessageID
	clientID[0] = 37
	message, err := protocol.EncodeSendMessageV2(id, clientID, 3, protocol.ContentTypePlainText, "private durable body")
	if err != nil {
		t.Fatal(err)
	}
	send(alice, protocol.C_SendMessageV2, message)
	ack, err := protocol.DecodeAckSendMessage(mustReadUntilOpcode(t, alice, protocol.S_AckSendMessage, 32))
	if err != nil {
		t.Fatal(err)
	}
	live, err := protocol.DecodeMessagePage(mustReadUntilOpcode(t, bob, protocol.S_MessagePage, 32))
	if err != nil || live.CorrelationID != 0 || len(live.Messages) != 1 || live.Messages[0].Content != "private durable body" {
		t.Fatalf("live DM: %+v %v", live, err)
	}
	history, err := protocol.EncodeListMessagesBefore(id, 0, 10, 4)
	if err != nil {
		t.Fatal(err)
	}
	readHistory := func(c *websocket.Conn) []byte {
		t.Helper()
		// Maintenance explicitly rejects this attempt; waiting for its page
		// would hide that error and eventually time out. Retry only that reply.
		deadline := time.Now().Add(2 * time.Second)
		mustSetReadDeadline(t, c, time.Until(deadline))
		defer mustSetReadDeadline(t, c, 20*time.Second)
		send(c, protocol.C_ListMessagesBefore, history)
		for i := 0; i < 128; i++ {
			msg := mustReadProtocolMessage(t, c)
			if msg.Opcode == protocol.S_MessagePage {
				page, err := protocol.DecodeMessagePage(msg.Data)
				if err != nil {
					t.Fatal(err)
				}
				if page.CorrelationID == 4 {
					return msg.Data
				}
			}
			if msg.Opcode != protocol.S_ErrorResponse {
				continue
			}
			response, err := protocol.DecodeErrorResponse(msg.Data)
			if err != nil || response.OriginOpcode != protocol.C_ListMessagesBefore || response.CorrelationID != 4 || response.ErrorMessage != "message storage maintenance; retry" {
				t.Fatalf("unexpected history error: %+v %v", response, err)
			}
			if time.Until(deadline) <= 10*time.Millisecond {
				t.Fatal("history maintenance exceeded retry deadline")
			}
			time.Sleep(10 * time.Millisecond)
			send(c, protocol.C_ListMessagesBefore, history)
		}
		t.Fatal("history response budget exhausted")
		return nil
	}
	checkHistory := func(c *websocket.Conn) {
		t.Helper()
		page, err := protocol.DecodeMessagePage(readHistory(c))
		if err != nil || len(page.Messages) != 1 || page.Messages[0].Sequence != uint64(ack.AssignedSeq) || page.Messages[0].Content != "private durable body" {
			t.Fatalf("history: %+v %v", page, err)
		}
	}
	expectDenied := func(c *websocket.Conn, op uint16, payload []byte) {
		t.Helper()
		send(c, op, payload)
		response := mustReadUntilOpcode(t, c, protocol.S_ErrorResponse, 32)
		if len(response) < 2 || binary.BigEndian.Uint16(response) != op {
			t.Fatalf("wrong error: %x", response)
		}
	}
	probe, _ := protocol.EncodeSubscribeConvsV2(9, id)
	for _, intruder := range []*websocket.Conn{dial(workspace, "mallory"), dial("another-workspace", "alice")} {
		expectDenied(intruder, protocol.C_SubscribeConvsV2, probe)
		expectDenied(intruder, protocol.C_ListMessagesBefore, history)
		expectDenied(intruder, protocol.C_SendMessageV2, message)
	}
	alice.Close()
	bob.Close()
	server.stop(t)
	env["NRC_THREAD_COUNT"] = "2"
	server = startServerInWorkDirWithEnv(t, workDir, env)
	alice = dial(workspace, "alice") // Bob stays offline throughout recovery.
	send(alice, protocol.C_ListDMs, protocol.EncodeListDMsWithCorrelation(5))
	list, err := protocol.DecodeDMList(mustReadUntilOpcode(t, alice, protocol.S_DMList, 32))
	if err != nil || len(list.Entries) != 1 || list.Entries[0].ConvID != id || list.Entries[0].Online {
		t.Fatalf("recovered DMs: %+v %v", list, err)
	}
	subscribe(alice, true)
	checkHistory(alice)
	send(alice, protocol.C_SendMessageV2, message)
	retry, err := protocol.DecodeAckSendMessage(mustReadUntilOpcode(t, alice, protocol.S_AckSendMessage, 32))
	if err != nil || retry.AssignedSeq != ack.AssignedSeq {
		t.Fatalf("DM retry: %+v %v", retry, err)
	}
	checkHistory(alice)
	alice.Close()
	server.stop(t)

	// Global retention disable purges history but must not stop durable revocations.
	env["NRC_MESSAGE_RETENTION"] = "0"
	server = startServerInWorkDirWithEnv(t, workDir, env)
	alice = dial(workspace, "alice")
	subscribe(alice, false)
	expectDenied(alice, protocol.C_ListMessagesBefore, history)
	expectDenied(alice, protocol.C_SendMessageV2, message)
	send(alice, protocol.C_LeaveDM, protocol.EncodeLeaveDMWithCorrelation(id, 6))
	mustReadUntilOpcode(t, alice, protocol.S_DMLeft, 32)
	alice.Close()
	server.stop(t)
	env["NRC_MESSAGE_RETENTION"] = "24h"
	server = startServerInWorkDirWithEnv(t, workDir, env)
	alice = dial(workspace, "alice")
	expectDenied(alice, protocol.C_SubscribeConvsV2, probe)
	expectDenied(alice, protocol.C_SendMessageV2, message)
	expectDenied(alice, protocol.C_ListMessagesBefore, history)
	// Reopening the stored pair works offline and intentionally restores access.
	send(alice, protocol.C_StartDM, protocol.EncodeStartDMWithCorrelation("bob", 7))
	reopened, err := protocol.DecodeDMStarted(mustReadUntilOpcode(t, alice, protocol.S_DMStarted, 32))
	if err != nil || reopened.ConvID != id || reopened.Online {
		t.Fatalf("reopened DM: %+v %v", reopened, err)
	}
	subscribe(alice, true)
	page, err := protocol.DecodeMessagePage(readHistory(alice))
	if err != nil || len(page.Messages) != 0 {
		t.Fatalf("disabled retention resurrected DM history: %+v %v", page, err)
	}
	clientID[0] = 38
	message, err = protocol.EncodeSendMessageV2(id, clientID, 8, protocol.ContentTypePlainText, "private durable body")
	if err != nil {
		t.Fatal(err)
	}
	send(alice, protocol.C_SendMessageV2, message)
	ack, err = protocol.DecodeAckSendMessage(mustReadUntilOpcode(t, alice, protocol.S_AckSendMessage, 32))
	if err != nil {
		t.Fatal(err)
	}
	checkHistory(alice)
}
