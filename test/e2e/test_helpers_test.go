package e2e

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

const (
	e2eJWTSecret   = "e2e-only-workspace-auth-secret"
	e2eJWTIssuer   = "nrc-tailscale-proxy"
	e2eJWTAudience = "nrc"
	e2eJWTTTL      = 5 * time.Minute
)

type e2eJWTHeader struct {
	Alg string `json:"alg"`
	Typ string `json:"typ"`
}

type e2eJWTClaims struct {
	Sub       string `json:"sub"`
	Username  string `json:"username"`
	Workspace string `json:"workspace,omitempty"`
	Iss       string `json:"iss"`
	Aud       string `json:"aud"`
	Exp       int64  `json:"exp"`
	Nbf       int64  `json:"nbf"`
}

var e2eAuthUserCounter uint64

func nextE2EAuthUsername() string {
	seq := atomic.AddUint64(&e2eAuthUserCounter, 1)
	return fmt.Sprintf("e2e-user-%d", seq)
}

func buildProxyStyleJWT(username string, now time.Time, workspace ...string) (string, error) {
	headerJSON, err := json.Marshal(e2eJWTHeader{Alg: "HS256", Typ: "JWT"})
	if err != nil {
		return "", fmt.Errorf("marshal jwt header: %w", err)
	}

	claims := e2eJWTClaims{
		Sub:      username,
		Username: username,
		Iss:      e2eJWTIssuer,
		Aud:      e2eJWTAudience,
		Nbf:      now.Unix() - 2,
		Exp:      now.Add(e2eJWTTTL).Unix(),
	}
	if len(workspace) > 0 {
		claims.Workspace = workspace[0]
	}

	claimsJSON, err := json.Marshal(claims)
	if err != nil {
		return "", fmt.Errorf("marshal jwt claims: %w", err)
	}

	headerSegment := base64.RawURLEncoding.EncodeToString(headerJSON)
	payloadSegment := base64.RawURLEncoding.EncodeToString(claimsJSON)
	signingInput := headerSegment + "." + payloadSegment

	mac := hmac.New(sha256.New, []byte(e2eJWTSecret))
	if _, err := mac.Write([]byte(signingInput)); err != nil {
		return "", fmt.Errorf("sign jwt: %w", err)
	}

	signatureSegment := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return signingInput + "." + signatureSegment, nil
}

func mustAuthHeader(t *testing.T, username string) http.Header {
	t.Helper()

	if username == "" {
		username = nextE2EAuthUsername()
	}

	token, err := buildProxyStyleJWT(username, time.Now())
	if err != nil {
		t.Fatalf("failed to build X-NRC-Auth token for %q: %v", username, err)
	}

	headers := make(http.Header)
	headers.Set("X-NRC-Auth", token)
	return headers
}

func mustSetReadDeadline(t *testing.T, conn *websocket.Conn, timeout time.Duration) {
	t.Helper()
	if err := conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		t.Fatalf("failed to set read deadline: %v", err)
	}
}

func mustExpectServerReady(t *testing.T, conn *websocket.Conn) {
	t.Helper()
	msg := mustReadProtocolMessage(t, conn)
	if msg.Opcode != protocol.S_ServerReady {
		t.Fatalf("expected first message opcode %d (ServerReady), got %d payload=%x", protocol.S_ServerReady, msg.Opcode, msg.Data)
	}
}

func mustSubscribeWorkspaceData(t *testing.T, conn *websocket.Conn) {
	t.Helper()
	if err := sendProtocolMessage(conn, protocol.C_SubscribeConvs, protocol.EncodeSubscribeConvs(protocol.WorkspaceDataConvID)); err != nil {
		t.Fatal(err)
	}
	// Workspace delivery subscriptions have no room-presence acknowledgment.
	if err := sendProtocolMessage(conn, protocol.C_Ping, protocol.EncodePing(1)); err != nil {
		t.Fatal(err)
	}
	mustReadUntilOpcode(t, conn, protocol.S_Pong, 16)
}

func mustReadProtocolMessage(t *testing.T, conn *websocket.Conn) *protocol.Message {
	t.Helper()

	frameType, wireData, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("failed to read websocket message: %v", err)
	}
	if frameType != websocket.BinaryMessage {
		t.Fatalf("expected binary frame, got frame type %d", frameType)
	}

	msg, err := protocol.ReadMessage(wireData)
	if err != nil {
		t.Fatalf("failed to parse protocol message: %v", err)
	}

	return msg
}

func mustReadUntilOpcode(t *testing.T, conn *websocket.Conn, wantOpcode uint16, maxReads int) []byte {
	t.Helper()

	for i := 0; i < maxReads; i++ {
		msg := mustReadProtocolMessage(t, conn)
		if msg.Opcode == wantOpcode {
			return msg.Data
		}
	}

	t.Fatalf("did not receive expected opcode %d within %d frames", wantOpcode, maxReads)
	return nil
}

func mustParseWireAssetWithCorrelation(t *testing.T, payload []byte) (protocol.Asset, uint32) {
	t.Helper()

	asset, offset := protocol.ParseAssetFull(payload, 0)
	if offset == 0 {
		t.Fatalf("failed to parse wire asset payload: %x", payload)
	}
	if len(payload) != offset+4 {
		t.Fatalf("wire asset payload size mismatch: asset_end=%d payload_len=%d", offset, len(payload))
	}

	return asset, binary.BigEndian.Uint32(payload[offset:])
}

func mustParseWireAssetListFull(t *testing.T, payload []byte) []protocol.Asset {
	t.Helper()

	if len(payload) < 17 {
		t.Fatalf("asset list payload too short: %d", len(payload))
	}

	offset := 8 // conv_id
	fullContent := payload[offset] == 1
	offset += 1
	if !fullContent {
		t.Fatalf("expected full-content asset list payload")
	}

	count := int(binary.BigEndian.Uint16(payload[offset:]))
	offset += 2
	offset += 4 // correlation_id

	assets := make([]protocol.Asset, 0, count)
	for i := 0; i < count; i++ {
		asset, nextOffset := protocol.ParseAssetFull(payload, offset)
		if nextOffset == offset {
			t.Fatalf("failed to parse asset list entry %d from payload: %x", i, payload[offset:])
		}
		assets = append(assets, asset)
		offset = nextOffset
	}

	if offset != len(payload) {
		t.Fatalf("unexpected trailing bytes in full asset list payload: %d", len(payload)-offset)
	}

	return assets
}

func mustWaitForPresenceUpdate(t *testing.T, conn *websocket.Conn, maxReads int) {
	t.Helper()

	_ = mustReadUntilOpcode(t, conn, protocol.S_RoomPresenceUpdate, maxReads)
}

func mustNotReceiveOpcodeWithin(t *testing.T, conn *websocket.Conn, blockedOpcode uint16, window time.Duration) {
	t.Helper()
	deadline := time.Now().Add(window)

	for {
		now := time.Now()
		if !now.Before(deadline) {
			return
		}

		if err := conn.SetReadDeadline(deadline); err != nil {
			t.Fatalf("failed to set read deadline for isolation check: %v", err)
		}

		frameType, wireData, err := conn.ReadMessage()
		if err != nil {
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() {
				return
			}
			t.Fatalf("unexpected read error during isolation check: %v", err)
		}

		if frameType != websocket.BinaryMessage {
			continue
		}

		msg, err := protocol.ReadMessage(wireData)
		if err != nil {
			continue
		}

		if msg.Opcode == blockedOpcode {
			t.Fatalf("received blocked opcode %d in isolated workspace: payload=%x", blockedOpcode, msg.Data)
		}
	}
}

func sendProtocolMessage(conn *websocket.Conn, opcode uint16, payload []byte) error {
	msg := &protocol.Message{Opcode: opcode, Data: payload}
	wireData, err := msg.Write()
	if err != nil {
		return err
	}

	return conn.WriteMessage(websocket.BinaryMessage, wireData)
}

func sendProtocolMessageChunked(conn *websocket.Conn, opcode uint16, payload []byte, chunkSize int) error {
	msg := &protocol.Message{Opcode: opcode, Data: payload}
	wireData, err := msg.Write()
	if err != nil {
		return err
	}
	if chunkSize <= 0 {
		chunkSize = len(wireData)
	}

	writer, err := conn.NextWriter(websocket.BinaryMessage)
	if err != nil {
		return err
	}

	for offset := 0; offset < len(wireData); offset += chunkSize {
		end := offset + chunkSize
		if end > len(wireData) {
			end = len(wireData)
		}
		if _, err := writer.Write(wireData[offset:end]); err != nil {
			_ = writer.Close()
			return err
		}
	}

	return writer.Close()
}
