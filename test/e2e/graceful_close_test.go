package e2e

import (
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func buildServerBinaryWithDefines(t *testing.T, defines map[string]int64) string {
	t.Helper()

	repoRoot := repoRootFromThisFile(t)
	odinBin := discoverOdinBinary()

	buildDir := t.TempDir()
	binPath := filepath.Join(buildDir, "nrc-server-e2e-graceful")

	args := []string{"build", ".", "-o:speed", "-out:" + binPath}
	for key, value := range defines {
		args = append(args, fmt.Sprintf("-define:%s=%d", key, value))
	}

	buildCmd := exec.Command(odinBin, args...)
	buildCmd.Dir = repoRoot
	buildOutput, err := buildCmd.CombinedOutput()
	if err != nil {
		t.Fatalf("failed to build configured server binary with %q: %v\n%s", odinBin, err, string(buildOutput))
	}

	return binPath
}

func startServerWithDefines(t *testing.T, defines map[string]int64) *serverProcess {
	t.Helper()

	stopSharedServerIfRunning()

	workDir, err := os.MkdirTemp("", "nrc-e2e-graceful-")
	if err != nil {
		t.Fatalf("failed to create graceful-close server work dir: %v", err)
	}

	proc, err := startServerProcess(buildServerBinaryWithDefines(t, defines), workDir)
	if err != nil {
		_ = os.RemoveAll(workDir)
		t.Fatalf("failed to start configured server process: %v", err)
	}

	t.Cleanup(func() {
		stopServerProcess(proc)
		_ = os.RemoveAll(workDir)
	})

	return proc
}

func mustReadWebSocketClose(t *testing.T, conn *websocket.Conn, timeout time.Duration) *websocket.CloseError {
	t.Helper()

	if err := conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		t.Fatalf("failed to set close wait read deadline: %v", err)
	}

	for {
		_, _, err := conn.ReadMessage()
		if err == nil {
			continue
		}

		var closeErr *websocket.CloseError
		if errors.As(err, &closeErr) {
			return closeErr
		}

		var netErr net.Error
		if errors.As(err, &netErr) && netErr.Timeout() {
			t.Fatalf("timeout waiting for websocket close frame")
		}

		t.Fatalf("unexpected read error while waiting for websocket close: %v", err)
	}
}

func slowReaderDialer(t *testing.T) *websocket.Dialer {
	t.Helper()

	dialer := *websocket.DefaultDialer
	netDialer := &net.Dialer{
		Control: func(network, address string, c syscall.RawConn) error {
			var controlErr error
			err := c.Control(func(fd uintptr) {
				controlErr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_RCVBUF, 4096)
			})
			if err != nil {
				return err
			}
			return controlErr
		},
	}
	dialer.NetDialContext = netDialer.DialContext
	return &dialer
}

func TestQueueOverflowSendsWebSocketCloseFrame(t *testing.T) {
	_ = startServerWithDefines(t, map[string]int64{
		"NRC_MAX_QUEUE_SIZE": 0,
	})

	workspace := fmt.Sprintf("e2e-graceful-queue-%d", time.Now().UnixNano())
	sender, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-graceful-sender"))
	if err != nil {
		t.Fatalf("failed to connect sender websocket client: %v", err)
	}
	defer sender.Close()

	receiver, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-graceful-receiver"))
	if err != nil {
		t.Fatalf("failed to connect receiver websocket client: %v", err)
	}
	defer receiver.Close()

	mustSetReadDeadline(t, sender, 5*time.Second)
	mustSetReadDeadline(t, receiver, 5*time.Second)
	mustExpectServerReady(t, sender)
	mustExpectServerReady(t, receiver)

	const roomID int64 = 1
	if err := sendProtocolMessage(sender, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(roomID)); err != nil {
		t.Fatalf("failed to subscribe sender: %v", err)
	}
	mustWaitForPresenceUpdate(t, sender, 12)

	if err := sendProtocolMessage(receiver, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(roomID)); err != nil {
		t.Fatalf("failed to subscribe receiver: %v", err)
	}
	mustWaitForPresenceUpdate(t, receiver, 12)

	// Flood sender->receiver while receiver is not actively draining frames.
	messagePayload := strings.Repeat("q", 64*1024)
	for i := 0; i < 64; i++ {
		reqID := uint32(10_000 + i)
		_ = sendProtocolMessage(sender, protocol.C_SendMessage, protocol.EncodeSendMessage(roomID, reqID, messagePayload, protocol.ContentTypePlainText))
	}

	closeErr := mustReadWebSocketClose(t, receiver, 10*time.Second)
	if closeErr.Code != websocket.CloseTryAgainLater {
		t.Fatalf("expected close code %d, got %d text=%q", websocket.CloseTryAgainLater, closeErr.Code, closeErr.Text)
	}
	if closeErr.Text != "Server too busy" {
		t.Fatalf("expected close reason %q, got %q", "Server too busy", closeErr.Text)
	}
}

// TestSlowReaderBackpressureDoesNotStopHealthyPeer exercises the real process
// send path under non-zero queue pressure: one subscribed client stops reading,
// another subscribed client continues reading, and the sender keeps receiving
// acknowledgements. The slow reader must receive the terminal 1013 close frame
// without corrupting the in-flight WebSocket stream, while healthy peers remain
// usable after the slow connection is detached.
func TestSlowReaderBackpressureDoesNotStopHealthyPeer(t *testing.T) {
	server := startServerWithDefines(t, map[string]int64{
		"NRC_MAX_QUEUE_SIZE": 4,
	})
	t.Cleanup(func() {
		if t.Failed() {
			t.Logf("server logs:\n%s", server.logs.String())
		}
	})

	workspace := fmt.Sprintf("e2e-slow-reader-%d", time.Now().UnixNano())
	const roomID int64 = 1

	sender, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-slow-reader-sender"))
	if err != nil {
		t.Fatalf("failed to connect sender websocket client: %v", err)
	}
	defer sender.Close()

	slow, _, err := slowReaderDialer(t).Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-slow-reader-slow"))
	if err != nil {
		t.Fatalf("failed to connect slow websocket client: %v", err)
	}
	defer slow.Close()

	healthy, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-slow-reader-healthy"))
	if err != nil {
		t.Fatalf("failed to connect healthy websocket client: %v", err)
	}
	defer healthy.Close()

	mustSetReadDeadline(t, sender, 30*time.Second)
	mustSetReadDeadline(t, slow, 30*time.Second)
	mustSetReadDeadline(t, healthy, 30*time.Second)
	mustExpectServerReady(t, sender)
	mustExpectServerReady(t, slow)
	mustExpectServerReady(t, healthy)

	if err := sendProtocolMessage(sender, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(roomID)); err != nil {
		t.Fatalf("failed to subscribe sender: %v", err)
	}
	mustWaitForPresenceUpdate(t, sender, 12)

	if err := sendProtocolMessage(slow, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(roomID)); err != nil {
		t.Fatalf("failed to subscribe slow receiver: %v", err)
	}
	mustWaitForPresenceUpdate(t, slow, 12)
	mustWaitForPresenceUpdate(t, sender, 12)

	if err := sendProtocolMessage(healthy, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(roomID)); err != nil {
		t.Fatalf("failed to subscribe healthy receiver: %v", err)
	}
	mustWaitForPresenceUpdate(t, healthy, 12)
	mustWaitForPresenceUpdate(t, sender, 12)
	// Drain healthy's peer-join update before starting the measured reader.
	mustWaitForPresenceUpdate(t, slow, 12)

	var healthyMessages int64
	var senderAcks int64
	var postHealthySeen int64
	var postAckSeen int64
	healthyErr := make(chan error, 1)
	senderErr := make(chan error, 1)
	stopHealthy := make(chan struct{})
	stopSender := make(chan struct{})
	postReqID := uint32(30_000)
	postContent := "healthy peer receives after slow reader closes"

	go drainProtocolFramesUntilStopped(healthy, stopHealthy, healthyErr, func(msg *protocol.Message) {
		if msg.Opcode == protocol.S_NewMessage {
			atomic.AddInt64(&healthyMessages, 1)
			chatMessage, err := protocol.DecodeChatMessage(msg.Data)
			if err == nil && chatMessage.ConvID == roomID && chatMessage.Content == postContent {
				atomic.StoreInt64(&postHealthySeen, 1)
			}
		}
	})
	go drainProtocolFramesUntilStopped(sender, stopSender, senderErr, func(msg *protocol.Message) {
		if msg.Opcode == protocol.S_AckSendMessage {
			atomic.AddInt64(&senderAcks, 1)
			ack, err := protocol.DecodeAckSendMessage(msg.Data)
			if err == nil && ack.ClientReqID == postReqID {
				atomic.StoreInt64(&postAckSeen, 1)
			}
		}
	})

	// Send more than the kernel can buffer for the non-reading peer. The old
	// 3 MiB flood was smaller than some TCP send-buffer limits, so all sends
	// could complete without ever filling the configured send queue. Pace
	// each message against both active readers so the extra volume
	// creates backpressure only on the peer that deliberately stopped reading.
	messagePayload := strings.Repeat("s", 32*1024)
	for i := 0; i < 512; i++ {
		reqID := uint32(20_000 + i)
		if err := sender.SetWriteDeadline(time.Now().Add(5 * time.Second)); err != nil {
			t.Fatalf("failed to set sender write deadline: %v", err)
		}
		if err := sendProtocolMessage(sender, protocol.C_SendMessage, protocol.EncodeSendMessage(roomID, reqID, messagePayload, protocol.ContentTypePlainText)); err != nil {
			t.Fatalf("failed to send flood message %d: %v", i, err)
		}
		want := int64(i + 1)
		waitForAtomicAtLeast(t, &healthyMessages, want, 5*time.Second, "healthy receiver flood messages")
		waitForAtomicAtLeast(t, &senderAcks, want, 5*time.Second, "sender flood acknowledgements")
	}
	if err := sender.SetWriteDeadline(time.Time{}); err != nil {
		t.Fatalf("failed to clear sender write deadline: %v", err)
	}

	closeErr := mustReadWebSocketClose(t, slow, 10*time.Second)
	if closeErr.Code != websocket.CloseTryAgainLater {
		t.Fatalf("expected slow reader close code %d, got %d text=%q", websocket.CloseTryAgainLater, closeErr.Code, closeErr.Text)
	}
	if closeErr.Text != "Server too busy" {
		t.Fatalf("expected slow reader close reason %q, got %q", "Server too busy", closeErr.Text)
	}

	waitForAtomicAtLeast(t, &healthyMessages, 1, 5*time.Second, "healthy receiver messages")
	waitForAtomicAtLeast(t, &senderAcks, 1, 5*time.Second, "sender acknowledgements")

	if err := sender.SetWriteDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatalf("failed to set sender post-close write deadline: %v", err)
	}
	if err := sendProtocolMessage(sender, protocol.C_SendMessage, protocol.EncodeSendMessage(roomID, postReqID, postContent, protocol.ContentTypePlainText)); err != nil {
		t.Fatalf("failed to send post-slow-reader message: %v", err)
	}
	if err := sender.SetWriteDeadline(time.Time{}); err != nil {
		t.Fatalf("failed to clear sender post-close write deadline: %v", err)
	}
	waitForAtomicAtLeast(t, &postHealthySeen, 1, 5*time.Second, "specific post-close healthy message")
	waitForAtomicAtLeast(t, &postAckSeen, 1, 5*time.Second, "specific post-close sender acknowledgement")

	close(stopHealthy)
	close(stopSender)
	_ = healthy.Close()
	_ = sender.Close()
	select {
	case err := <-healthyErr:
		if err != nil {
			t.Fatalf("healthy reader failed: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatalf("healthy reader did not stop")
	}
	select {
	case err := <-senderErr:
		if err != nil {
			t.Fatalf("sender reader failed: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatalf("sender reader did not stop")
	}
}

func drainProtocolFramesUntilStopped(conn *websocket.Conn, stop <-chan struct{}, errCh chan<- error, onMessage func(*protocol.Message)) {
	for {
		select {
		case <-stop:
			errCh <- nil
			return
		default:
		}

		frameType, wireData, err := conn.ReadMessage()
		if err != nil {
			select {
			case <-stop:
				errCh <- nil
			default:
				errCh <- err
			}
			return
		}
		if frameType != websocket.BinaryMessage {
			continue
		}
		msg, err := protocol.ReadMessage(wireData)
		if err != nil {
			errCh <- err
			return
		}
		onMessage(msg)
	}
}

func waitForAtomicAtLeast(t *testing.T, value *int64, want int64, timeout time.Duration, label string) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if got := atomic.LoadInt64(value); got >= want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s: got %d want at least %d", label, atomic.LoadInt64(value), want)
}
