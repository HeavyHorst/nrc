package main

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type readResult struct {
	messageType int
	data        []byte
	err         error
}

type fakeConnection struct {
	reads            []readResult
	writeControlErr  error
	readDeadlineErr  error
	writeDeadlineErr error
}

func (conn *fakeConnection) SetReadDeadline(time.Time) error  { return conn.readDeadlineErr }
func (conn *fakeConnection) SetWriteDeadline(time.Time) error { return conn.writeDeadlineErr }
func (conn *fakeConnection) Close() error                     { return nil }

func (conn *fakeConnection) ReadMessage() (int, []byte, error) {
	if len(conn.reads) == 0 {
		return 0, nil, errors.New("no queued read")
	}
	result := conn.reads[0]
	conn.reads = conn.reads[1:]
	return result.messageType, result.data, result.err
}

func (conn *fakeConnection) WriteControl(int, []byte, time.Time) error {
	return conn.writeControlErr
}

func TestPercentileMS(t *testing.T) {
	values := []int64{
		int64(time.Millisecond),
		2 * int64(time.Millisecond),
		3 * int64(time.Millisecond),
		4 * int64(time.Millisecond),
		5 * int64(time.Millisecond),
	}

	if got := percentileMS(values, 0.50); got != 3 {
		t.Fatalf("p50: got %v, want 3", got)
	}
	if got := percentileMS(values, 0.95); got != 4 {
		t.Fatalf("p95: got %v, want 4", got)
	}
	if got := percentileMS(values, 1); got != 5 {
		t.Fatalf("max: got %v, want 5", got)
	}
}

func TestBuildJWTClaims(t *testing.T) {
	token, err := buildJWT("connrate", "secret", "issuer", "audience", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("JWT parts: got %d, want 3", len(parts))
	}
	claimsJSON, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var claims map[string]any
	if err := json.Unmarshal(claimsJSON, &claims); err != nil {
		t.Fatal(err)
	}
	if claims["username"] != "connrate" || claims["iss"] != "issuer" || claims["aud"] != "audience" {
		t.Fatalf("unexpected claims: %#v", claims)
	}
}

func TestCompleteLifecycle(t *testing.T) {
	validReady := encodeServerReadyForTest(t, "connrate", true)
	closeResponse := readResult{err: &websocket.CloseError{Code: websocket.CloseNormalClosure}}
	opts := options{
		auth:           true,
		jwtUsername:    "connrate",
		webSocketClose: true,
		readTimeout:    time.Second,
		writeTimeout:   time.Second,
	}

	tests := []struct {
		name    string
		conn    *fakeConnection
		failure lifecycleFailure
	}{
		{
			name: "valid lifecycle",
			conn: &fakeConnection{reads: []readResult{
				{messageType: websocket.BinaryMessage, data: validReady},
				closeResponse,
			}},
			failure: lifecycleOK,
		},
		{
			name:    "wrong message type",
			conn:    &fakeConnection{reads: []readResult{{messageType: websocket.TextMessage, data: validReady}}},
			failure: lifecycleServerReadyFailure,
		},
		{
			name:    "wrong opcode",
			conn:    &fakeConnection{reads: []readResult{{messageType: websocket.BinaryMessage, data: []byte{0, 101}}}},
			failure: lifecycleServerReadyFailure,
		},
		{
			name:    "malformed ready",
			conn:    &fakeConnection{reads: []readResult{{messageType: websocket.BinaryMessage, data: []byte{0, byte(protocol.S_ServerReady)}}}},
			failure: lifecycleServerReadyFailure,
		},
		{
			name:    "unauthenticated ready",
			conn:    &fakeConnection{reads: []readResult{{messageType: websocket.BinaryMessage, data: encodeServerReadyForTest(t, "connrate", false)}}},
			failure: lifecycleServerReadyFailure,
		},
		{
			name:    "wrong username",
			conn:    &fakeConnection{reads: []readResult{{messageType: websocket.BinaryMessage, data: encodeServerReadyForTest(t, "other", true)}}},
			failure: lifecycleServerReadyFailure,
		},
		{
			name: "close write failure",
			conn: &fakeConnection{
				reads:           []readResult{{messageType: websocket.BinaryMessage, data: validReady}},
				writeControlErr: errors.New("write failed"),
			},
			failure: lifecycleCloseWriteFailure,
		},
		{
			name: "missing close response",
			conn: &fakeConnection{reads: []readResult{
				{messageType: websocket.BinaryMessage, data: validReady},
				{err: errors.New("read timeout")},
			}},
			failure: lifecycleCloseReadFailure,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			latency, failure := completeLifecycle(test.conn, opts, time.Now().Add(-time.Millisecond))
			if failure != test.failure {
				t.Fatalf("failure: got %v, want %v", failure, test.failure)
			}
			if failure == lifecycleOK && latency <= 0 {
				t.Fatalf("successful lifecycle latency must be positive, got %d", latency)
			}
		})
	}
}

func encodeServerReadyForTest(t *testing.T, username string, authenticated bool) []byte {
	t.Helper()
	buf := bytes.NewBuffer(nil)
	write := func(value any) {
		if err := binary.Write(buf, binary.BigEndian, value); err != nil {
			t.Fatal(err)
		}
	}
	write(protocol.S_ServerReady)
	write(uint16(len("test")))
	buf.WriteString("test")
	write(uint32(4))
	write(uint16(0))
	write(uint16(len(username)))
	buf.WriteString(username)
	if authenticated {
		buf.WriteByte(1)
	} else {
		buf.WriteByte(0)
	}
	return buf.Bytes()
}
