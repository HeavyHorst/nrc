package e2e

import (
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestConcurrencySmokeManyClientsAckProgress(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-concurrency-%d", time.Now().UnixNano())
	const roomID int64 = 1
	const clientCount = 16

	type senderClient struct {
		conn  *websocket.Conn
		reqID uint32
	}
	clients := make([]senderClient, 0, clientCount)

	for i := 0; i < clientCount; i++ {
		conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
		if err != nil {
			t.Fatalf("failed to connect client %d: %v", i, err)
		}

		mustSetReadDeadline(t, conn, 10*time.Second)
		mustExpectServerReady(t, conn)

		if err := sendProtocolMessage(conn, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(roomID)); err != nil {
			conn.Close()
			t.Fatalf("failed to subscribe client %d: %v", i, err)
		}

		clients = append(clients, senderClient{conn: conn, reqID: uint32(10000 + i)})
	}
	defer func() {
		for _, c := range clients {
			_ = c.conn.Close()
		}
	}()

	errCh := make(chan error, clientCount)
	var wg sync.WaitGroup

	for i := range clients {
		wg.Add(1)
		idx := i
		go func() {
			defer wg.Done()

			msg := fmt.Sprintf("concurrency-smoke-message-%d", idx)
			if err := sendProtocolMessage(clients[idx].conn, protocol.C_SendMessage, protocol.EncodeSendMessage(roomID, clients[idx].reqID, msg, protocol.ContentTypePlainText)); err != nil {
				errCh <- fmt.Errorf("client %d failed to send message: %w", idx, err)
				return
			}

			if err := waitForAckForReqID(clients[idx].conn, clients[idx].reqID, 8*time.Second); err != nil {
				errCh <- fmt.Errorf("client %d ack wait failed: %w", idx, err)
				return
			}
		}()
	}

	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(20 * time.Second):
		t.Fatal("concurrency smoke test timed out waiting for send/ack completion")
	}

	close(errCh)
	for err := range errCh {
		if err != nil {
			t.Fatal(err)
		}
	}

	pingTS := time.Now().UnixNano()
	if err := sendProtocolMessage(clients[0].conn, protocol.C_Ping, protocol.EncodePing(pingTS)); err != nil {
		t.Fatalf("failed to send health-check ping after concurrency run: %v", err)
	}
	pongPayload := mustReadUntilOpcode(t, clients[0].conn, protocol.S_Pong, 32)
	pong, err := protocol.DecodePongResponse(pongPayload)
	if err != nil {
		t.Fatalf("failed to decode health-check S_Pong: %v payload=%x", err, pongPayload)
	}
	if pong.Timestamp != pingTS {
		t.Fatalf("health-check pong timestamp mismatch: got %d want %d", pong.Timestamp, pingTS)
	}
}

func waitForAckForReqID(conn *websocket.Conn, reqID uint32, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if err := conn.SetReadDeadline(deadline); err != nil {
			return fmt.Errorf("failed setting ack read deadline: %w", err)
		}

		frameType, wireData, err := conn.ReadMessage()
		if err != nil {
			return err
		}
		if frameType != websocket.BinaryMessage {
			continue
		}

		msg, err := protocol.ReadMessage(wireData)
		if err != nil {
			continue
		}
		if msg.Opcode != protocol.S_AckSendMessage {
			continue
		}

		ack, err := protocol.DecodeAckSendMessage(msg.Data)
		if err != nil {
			continue
		}
		if ack.ClientReqID == reqID {
			return nil
		}
	}

	return fmt.Errorf("timed out waiting for ack req_id=%d", reqID)
}
