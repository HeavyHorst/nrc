package conn

import (
	"bytes"
	"encoding/binary"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
	"github.com/heavyhorst/nrc/cli/pkg/config"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestSessionRetriesOnlyExplicitDatabaseOverload(t *testing.T) {
	for _, code := range []string{protocol.DBConnectionOverloaded, protocol.DBWorkerOverloaded} {
		t.Run(code, func(t *testing.T) {
			correlation := uint32(73)
			request := &protocol.Message{Opcode: protocol.C_ListTaskSlices, Data: protocol.EncodeListTaskSlices(0, protocol.SliceQuery{Project: "project-after-correlation", Limit: 10}, correlation)}
			if code == protocol.DBConnectionOverloaded {
				request = &protocol.Message{Opcode: protocol.C_CreateTask, Data: protocol.EncodeTaskCreateFullWithCorrelation(0, "synthetic", "body", 1, "project-after-correlation", nil, correlation)}
			}
			upgrader := websocket.Upgrader{}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				c, err := upgrader.Upgrade(w, r, nil)
				if err != nil {
					t.Error(err)
					return
				}
				defer c.Close()
				var first []byte
				for i := 0; i < 4; i++ {
					_, data, err := c.ReadMessage()
					if err != nil {
						t.Error(err)
						return
					}
					if i == 0 {
						first = data
					} else if !bytes.Equal(first, data) {
						t.Error("retry changed request bytes")
					}
					payload := make([]byte, 10+len(code))
					binary.BigEndian.PutUint16(payload, protocol.S_ErrorResponse)
					binary.BigEndian.PutUint16(payload[2:], request.Opcode)
					binary.BigEndian.PutUint16(payload[4:], uint16(len(code)))
					copy(payload[6:], code)
					binary.BigEndian.PutUint32(payload[6+len(code):], correlation)
					if err := c.WriteMessage(websocket.BinaryMessage, payload); err != nil {
						t.Error(err)
						return
					}
				}
			}))
			defer server.Close()
			t.Setenv("HOME", t.TempDir())
			if err := (&config.Config{Server: "ws" + strings.TrimPrefix(server.URL, "http") + "/", WorkspaceID: "test"}).Save(); err != nil {
				t.Fatal(err)
			}
			s, err := Dial("")
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			_, err = s.SendAndRecv(request)
			if got := Classify(err); got.Code != code || !got.Retryable {
				t.Fatalf("%v: %+v", err, got)
			}
		})
	}
}

func TestSessionRetriesHistoryWithNonzeroCorrelation(t *testing.T) {
	const correlation = uint32(73)
	request := &protocol.Message{Opcode: 62, Data: make([]byte, 31)}
	binary.BigEndian.PutUint16(request.Data[25:], 10)
	binary.BigEndian.PutUint32(request.Data[27:], correlation)
	wire, _ := request.Write()
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer c.Close()
		for _, body := range []string{`{"error":"db_worker_overloaded"}`, `{"events":[],"nextBefore":"0"}`} {
			_, data, err := c.ReadMessage()
			if err != nil {
				return
			}
			if !bytes.Equal(data, wire) {
				t.Error("history retry changed request bytes")
			}
			response := make([]byte, 6+len(body))
			binary.BigEndian.PutUint16(response, 168)
			binary.BigEndian.PutUint32(response[2:], correlation)
			copy(response[6:], body)
			if err := c.WriteMessage(websocket.BinaryMessage, response); err != nil {
				t.Error(err)
				return
			}
		}
	}))
	defer server.Close()
	t.Setenv("HOME", t.TempDir())
	if err := (&config.Config{Server: "ws" + strings.TrimPrefix(server.URL, "http") + "/", WorkspaceID: "test"}).Save(); err != nil {
		t.Fatal(err)
	}
	s, err := Dial("")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	response, err := s.SendAndRecv(request)
	if err != nil {
		t.Fatal(err)
	}
	if response.Opcode != 168 || len(response.Data) < 4 || binary.BigEndian.Uint32(response.Data) != correlation || string(response.Data[4:]) != `{"events":[],"nextBefore":"0"}` {
		t.Fatalf("history did not recover from overload: %+v", response)
	}
}

func TestResolveDMConversationIDs(t *testing.T) {
	resolvers := map[string]func(string) (int64, error){
		"direct":  ResolveRoom,
		"dynamic": func(value string) (int64, error) { return ResolveRoomDynamic("workspace", value) },
		"flag":    func(value string) (int64, error) { return ResolveRoomFlag("workspace", value) },
	}
	for name, resolve := range resolvers {
		t.Run(name, func(t *testing.T) {
			for _, tc := range []struct {
				value string
				bits  uint64
			}{
				{"9223372036854775808", 1 << 63},
				{" 18446744073709551615 ", ^uint64(0)},
				{"-1", ^uint64(0)},
				{"42", 42},
			} {
				id, err := resolve(tc.value)
				if err != nil || uint64(id) != tc.bits {
					t.Fatalf("%q = %d, %v", tc.value, id, err)
				}
			}
			for _, value := range []string{"18446744073709551616", "9999999999999999999999999999999999999999", "-9223372036854775809"} {
				if id, err := resolve(value); err == nil {
					t.Fatalf("overflow %q became room %d", value, id)
				}
			}
		})
	}
	if id, err := ResolveRoomFlag("workspace", "release-2026"); err != nil || id <= 0 {
		t.Fatalf("dynamic room regressed: %d, %v", id, err)
	}
}

func TestDurableSessionIgnoresConfiguredChatRoom(t *testing.T) {
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer c.Close()
		for {
			if _, _, err := c.ReadMessage(); err != nil {
				return
			}
		}
	}))
	defer server.Close()
	t.Setenv("HOME", t.TempDir())
	if err := (&config.Config{Server: "ws" + strings.TrimPrefix(server.URL, "http") + "/", WorkspaceID: "workspace", RoomID: 73}).Save(); err != nil {
		t.Fatal(err)
	}
	data, err := Dial("")
	if err != nil {
		t.Fatal(err)
	}
	defer data.Close()
	if data.RoomID != 0 {
		t.Fatalf("durable scope = %d, want 0", data.RoomID)
	}
	chat, err := DialChat("")
	if err != nil {
		t.Fatal(err)
	}
	defer chat.Close()
	if chat.RoomID != 73 {
		t.Fatalf("chat scope = %d, want configured 73", chat.RoomID)
	}
	if _, err := Dial("73"); err == nil {
		t.Fatal("legacy explicit data room was silently published as workspace data")
	}
}

func TestDecodeServerError(t *testing.T) {
	message := "Asset not found"
	payload := make([]byte, 2+2+len(message)+4)
	binary.BigEndian.PutUint16(payload[0:2], protocol.C_GetAsset)
	binary.BigEndian.PutUint16(payload[2:4], uint16(len(message)))
	copy(payload[4:], message)
	binary.BigEndian.PutUint32(payload[4+len(message):], 42)

	err := DecodeServerError(payload)
	if got, want := err.Error(), "server error: Asset not found"; got != want {
		t.Fatalf("DecodeServerError() = %q, want %q", got, want)
	}
	var serverErr *ServerError
	if !errors.As(err, &serverErr) || serverErr.OriginOpcode != protocol.C_GetAsset || serverErr.CorrelationID != 42 {
		t.Fatalf("lost server origin/correlation: %#v", err)
	}
}

func TestClassifyPreservesServerAndConnectionErrors(t *testing.T) {
	if got := Classify(&ServerError{Message: "no"}); got.Code != "server_error" || got.Retryable {
		t.Fatalf("server classification: %#v", got)
	}
	if got := Classify(&ConnectionError{Err: errors.New("closed")}); got.Code != "connection_failed" || !got.Retryable {
		t.Fatalf("connection classification: %#v", got)
	}
	for _, tc := range []struct {
		origin    uint16
		message   string
		retryable bool
	}{
		{protocol.C_SendMessageV2, "retained_send_overloaded", true},
		{protocol.C_GetAsset, "retained_send_overloaded", false},
		{protocol.C_SendMessageV2, "retained message storage failed", false},
		{protocol.C_SendMessageV2, "retained_send_overloaded extra", false},
	} {
		payload := make([]byte, len(tc.message)+8)
		binary.BigEndian.PutUint16(payload, tc.origin)
		binary.BigEndian.PutUint16(payload[2:], uint16(len(tc.message)))
		copy(payload[4:], tc.message)
		binary.BigEndian.PutUint32(payload[4+len(tc.message):], 9)
		got := Classify(DecodeServerError(payload))
		if got.Retryable != tc.retryable || (tc.retryable && got.Code != "retained_send_overloaded") {
			t.Fatalf("%d %q: %#v", tc.origin, tc.message, got)
		}
	}
}

func TestDecodeServerErrorRejectsMalformedPayload(t *testing.T) {
	err := DecodeServerError([]byte{0, 1, 0})
	if !strings.Contains(err.Error(), "decoding server error response: error response too short") {
		t.Fatalf("DecodeServerError() = %q, want decoding error", err)
	}
}
