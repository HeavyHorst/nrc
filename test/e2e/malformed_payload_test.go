package e2e

import (
	"errors"
	"fmt"
	"net"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestMalformedPayloadRobustness(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-malformed-%d", time.Now().UnixNano())

	testCases := []struct {
		name       string
		opcode     uint16
		payload    []byte
		originCode uint16
	}{
		{
			name:   "send-message-content-length-mismatch",
			opcode: protocol.C_SendMessage,
			payload: []byte{
				0, 0, 0, 0, 0, 0, 0, 1, // conv_id = 1
				0, 0, 0, 1, // client_req_id = 1
				0,          // content_type = plain text
				0xff, 0xff, // content_len = 65535 (missing content bytes)
			},
			originCode: protocol.C_SendMessage,
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
			if err != nil {
				t.Fatalf("failed to connect malformed-case client: %v", err)
			}

			mustSetReadDeadline(t, conn, 5*time.Second)
			mustExpectServerReady(t, conn)

			if err := sendProtocolMessage(conn, tc.opcode, tc.payload); err != nil {
				_ = conn.Close()
				t.Fatalf("failed to send malformed payload (%s): %v", tc.name, err)
			}

			closed := expectErrorResponseOrCleanClose(t, conn, tc.originCode)
			if !closed {
				_ = conn.Close()
			}

			assertServerStillHealthy(t, workspace)
		})
	}
}

func expectErrorResponseOrCleanClose(t *testing.T, conn *websocket.Conn, originOpcode uint16) bool {
	t.Helper()

	if err := conn.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatalf("failed to set read deadline: %v", err)
	}

	frameType, wireData, err := conn.ReadMessage()
	if err != nil {
		if isCleanWebsocketClose(err) || isConnClosed(err) {
			return true
		}

		var netErr net.Error
		if errors.As(err, &netErr) && netErr.Timeout() {
			t.Fatalf("timeout waiting for error response or close")
		}

		t.Fatalf("unexpected read error after malformed payload: %v", err)
	}

	if frameType != websocket.BinaryMessage {
		t.Fatalf("expected binary frame after malformed payload, got frame type %d", frameType)
	}

	msg, err := protocol.ReadMessage(wireData)
	if err != nil {
		t.Fatalf("failed to parse protocol message after malformed payload: %v", err)
	}
	if msg.Opcode != protocol.S_ErrorResponse {
		t.Fatalf("expected S_ErrorResponse (%d), got opcode %d payload=%x", protocol.S_ErrorResponse, msg.Opcode, msg.Data)
	}

	errResp, err := protocol.DecodeErrorResponse(msg.Data)
	if err != nil {
		t.Fatalf("failed to decode S_ErrorResponse payload: %v payload=%x", err, msg.Data)
	}
	if errResp.OriginOpcode != originOpcode {
		t.Fatalf("error response origin opcode mismatch: got %d want %d", errResp.OriginOpcode, originOpcode)
	}

	return false
}

func isCleanWebsocketClose(err error) bool {
	return websocket.IsCloseError(
		err,
		websocket.CloseNormalClosure,
		websocket.CloseGoingAway,
		websocket.CloseNoStatusReceived,
		websocket.CloseProtocolError,
	)
}

func assertServerStillHealthy(t *testing.T, workspace string) {
	t.Helper()

	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("server health check failed: could not reconnect after malformed payload: %v", err)
	}
	defer conn.Close()

	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	pingTS := time.Now().UnixNano()
	if err := sendProtocolMessage(conn, protocol.C_Ping, protocol.EncodePing(pingTS)); err != nil {
		t.Fatalf("server health check ping send failed: %v", err)
	}
	pongPayload := mustReadUntilOpcode(t, conn, protocol.S_Pong, 8)
	pong, err := protocol.DecodePongResponse(pongPayload)
	if err != nil {
		t.Fatalf("server health check pong decode failed: %v payload=%x", err, pongPayload)
	}
	if pong.Timestamp != pingTS {
		t.Fatalf("server health check ping timestamp mismatch: got %d want %d", pong.Timestamp, pingTS)
	}
}
