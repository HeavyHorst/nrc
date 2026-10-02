package conn

import (
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
}

func TestClassifyPreservesServerAndConnectionErrors(t *testing.T) {
	if got := Classify(&ServerError{Message: "no"}); got.Code != "server_error" || got.Retryable {
		t.Fatalf("server classification: %#v", got)
	}
	if got := Classify(&ConnectionError{Err: errors.New("closed")}); got.Code != "connection_failed" || !got.Retryable {
		t.Fatalf("connection classification: %#v", got)
	}
}

func TestDecodeServerErrorRejectsMalformedPayload(t *testing.T) {
	err := DecodeServerError([]byte{0, 1, 0})
	if !strings.Contains(err.Error(), "decoding server error response: error response too short") {
		t.Fatalf("DecodeServerError() = %q, want decoding error", err)
	}
}
