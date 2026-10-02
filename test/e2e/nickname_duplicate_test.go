package e2e

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestDuplicateAuthenticatedIdentityConnections(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-dup-nick-%d", time.Now().UnixNano())

	clientA, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-duplicate-user"))
	if err != nil {
		t.Fatalf("failed to connect client A: %v", err)
	}
	defer clientA.Close()

	clientB, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-duplicate-user"))
	if err != nil {
		t.Fatalf("failed to connect client B: %v", err)
	}
	defer clientB.Close()

	mustSetReadDeadline(t, clientA, 5*time.Second)
	mustSetReadDeadline(t, clientB, 5*time.Second)

	mustExpectServerReady(t, clientA)
	mustExpectServerReady(t, clientB)

	pingTS := time.Now().UnixNano()
	if err := sendProtocolMessage(clientA, protocol.C_Ping, protocol.EncodePing(pingTS)); err != nil {
		t.Fatalf("failed to send ping after duplicate identity test: %v", err)
	}
	pongPayload := mustReadUntilOpcode(t, clientA, protocol.S_Pong, 8)
	pong, err := protocol.DecodePongResponse(pongPayload)
	if err != nil {
		t.Fatalf("failed to decode pong after duplicate identity test: %v payload=%x", err, pongPayload)
	}
	if pong.Timestamp != pingTS {
		t.Fatalf("pong timestamp mismatch after duplicate identity test: got %d want %d", pong.Timestamp, pingTS)
	}
}
