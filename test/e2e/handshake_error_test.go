package e2e

import (
	"fmt"
	"io"
	"net"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func runInvalidHandshakeAndExpectClose(t *testing.T, path string) {
	t.Helper()

	rawConn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", serverHost, serverPort), 2*time.Second)
	if err != nil {
		t.Fatalf("failed to open raw TCP connection: %v", err)
	}

	invalidHandshake := fmt.Sprintf("GET %s HTTP/1.1\r\n", path) +
		fmt.Sprintf("Host: %s:%d\r\n", serverHost, serverPort) +
		"Connection: keep-alive\r\n" +
		"\r\n"

	if _, err := rawConn.Write([]byte(invalidHandshake)); err != nil {
		_ = rawConn.Close()
		t.Fatalf("failed writing invalid handshake: %v", err)
	}

	if err := rawConn.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		_ = rawConn.Close()
		t.Fatalf("failed setting raw read deadline: %v", err)
	}

	buf := make([]byte, 256)
	readN, readErr := rawConn.Read(buf)
	if readErr != nil {
		_ = rawConn.Close()
		t.Fatalf("expected HTTP error response for invalid handshake, got read error: %v", readErr)
	}
	if readN == 0 {
		_ = rawConn.Close()
		t.Fatalf("expected non-empty HTTP error response for invalid handshake")
	}

	if err := rawConn.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		_ = rawConn.Close()
		t.Fatalf("failed setting close-detection read deadline: %v", err)
	}

	_, closeErr := rawConn.Read(buf)
	if closeErr == nil {
		_ = rawConn.Close()
		t.Fatalf("expected invalid-handshake connection to be closed by server")
	}
	if closeErr != io.EOF {
		netErr, isNetErr := closeErr.(net.Error)
		if !isNetErr || !netErr.Timeout() {
			_ = rawConn.Close()
			t.Fatalf("expected EOF/timeout while waiting for close, got: %v", closeErr)
		}
	}

	_ = rawConn.Close()
}

func TestInvalidHandshakeClosesConnectionAndServerStaysHealthy(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)
	runInvalidHandshakeAndExpectClose(t, "/e2e-invalid-handshake")

	workspace := fmt.Sprintf("e2e-handshake-health-%d", time.Now().UnixNano())
	wsConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("server unhealthy after invalid handshake; websocket dial failed: %v", err)
	}
	defer wsConn.Close()

	mustSetReadDeadline(t, wsConn, 5*time.Second)
	mustExpectServerReady(t, wsConn)
}

func TestBurstInvalidHandshakesThenHealthyWebsocket(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	for i := 0; i < 25; i++ {
		runInvalidHandshakeAndExpectClose(t, fmt.Sprintf("/e2e-invalid-burst-%d", i))
	}

	workspace := fmt.Sprintf("e2e-handshake-burst-health-%d", time.Now().UnixNano())
	wsConn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("server unhealthy after burst invalid handshakes; websocket dial failed: %v", err)
	}
	defer wsConn.Close()

	mustSetReadDeadline(t, wsConn, 5*time.Second)
	mustExpectServerReady(t, wsConn)
}
