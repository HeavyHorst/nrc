package e2e

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestServerReadyOnAuthenticatedConnection(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-smoke-%d", time.Now().UnixNano())
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, "e2e-smoke-user"))
	if err != nil {
		t.Fatalf("failed to connect websocket client: %v", err)
	}
	defer conn.Close()

	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)
}

func TestServerReadyPayloadParsesAgainstBackend(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	expectedUsername := "e2e-ready-auth-user"
	workspace := fmt.Sprintf("e2e-ready-auth-%d", time.Now().UnixNano())
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, expectedUsername))
	if err != nil {
		t.Fatalf("failed to connect websocket client: %v", err)
	}
	defer conn.Close()

	mustSetReadDeadline(t, conn, 5*time.Second)
	msg := mustReadProtocolMessage(t, conn)
	if msg.Opcode != protocol.S_ServerReady {
		t.Fatalf("expected opcode %d, got %d", protocol.S_ServerReady, msg.Opcode)
	}

	wire, err := msg.Write()
	if err != nil {
		t.Fatalf("failed to re-encode protocol message: %v", err)
	}
	ready, err := protocol.ParseServerReady(wire)
	if err != nil {
		t.Fatalf("failed to parse server ready payload: %v", err)
	}

	if ready.BuildVersion == "" {
		t.Fatal("BuildVersion must be non-empty")
	}
	if ready.ProtocolVersion == 0 {
		t.Fatal("ProtocolVersion must be non-zero")
	}
	if ready.CPUModel == "" {
		t.Fatal("CPUModel must be non-empty")
	}
	if ready.Username != expectedUsername {
		t.Fatalf("Username = %q, want %q", ready.Username, expectedUsername)
	}
	if !ready.IsAuthenticated {
		t.Fatal("IsAuthenticated should be true for authenticated connection")
	}
}
