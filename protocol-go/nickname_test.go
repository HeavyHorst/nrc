package protocol

import (
	"bytes"
	"testing"
)

func TestDecodeNicknameResponse(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	buf.WriteByte(1) // success
	buf.WriteByte(0) // is_authenticated
	writeString(buf, "alice")
	writeString(buf, "")

	resp, err := DecodeNicknameResponse(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if !resp.Success {
		t.Fatal("expected Success=true")
	}
	if resp.Nickname != "alice" {
		t.Fatalf("Nickname = %q, want %q", resp.Nickname, "alice")
	}
}

func TestDecodeNicknameResponseTooShort(t *testing.T) {
	_, err := DecodeNicknameResponse([]byte{1, 0, 0})
	if err == nil {
		t.Fatal("expected error for short nickname response")
	}
}
