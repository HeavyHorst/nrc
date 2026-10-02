package protocol

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestEncodeStartDMWithCorrelation(t *testing.T) {
	data := EncodeStartDMWithCorrelation("alice", 0x01020304)
	if len(data) < 4 {
		t.Fatalf("encoded payload too short: %d", len(data))
	}
	if got := binary.BigEndian.Uint32(data[len(data)-4:]); got != 0x01020304 {
		t.Fatalf("correlation_id = 0x%08X, want 0x01020304", got)
	}
}

func TestEncodeListDMsWithCorrelation(t *testing.T) {
	data := EncodeListDMsWithCorrelation(0xAABBCCDD)
	if len(data) != 4 {
		t.Fatalf("expected 4 bytes, got %d", len(data))
	}
}

func TestEncodeLeaveDMWithCorrelation(t *testing.T) {
	data := EncodeLeaveDMWithCorrelation(42, 0x11223344)
	if len(data) != 12 {
		t.Fatalf("expected 12 bytes, got %d", len(data))
	}
	if got := binary.BigEndian.Uint32(data[8:12]); got != 0x11223344 {
		t.Fatalf("correlation_id = 0x%08X, want 0x11223344", got)
	}
}

func TestDecodeDMStartedCorrelation(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint64(9))
	writeString(buf, "bob")
	buf.WriteByte(1)
	buf.WriteByte(0)
	buf.WriteByte(1)
	binary.Write(buf, binary.BigEndian, uint32(55))

	decoded, err := DecodeDMStarted(buf.Bytes())
	if err != nil {
		t.Fatalf("DecodeDMStarted error: %v", err)
	}
	if decoded.CorrelationID != 55 {
		t.Fatalf("CorrelationID = %d, want 55", decoded.CorrelationID)
	}
}

func TestDecodeDMListCorrelation(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint16(1))
	binary.Write(buf, binary.BigEndian, uint32(77))
	binary.Write(buf, binary.BigEndian, uint64(10))
	writeString(buf, "alice")
	buf.WriteByte(1)
	buf.WriteByte(1)
	binary.Write(buf, binary.BigEndian, uint64(999))

	decoded, err := DecodeDMList(buf.Bytes())
	if err != nil {
		t.Fatalf("DecodeDMList error: %v", err)
	}
	if decoded.CorrelationID != 77 {
		t.Fatalf("CorrelationID = %d, want 77", decoded.CorrelationID)
	}
}

func TestDecodeDMLeft(t *testing.T) {
	payload := make([]byte, 12)
	binary.BigEndian.PutUint64(payload[0:8], 11)
	binary.BigEndian.PutUint32(payload[8:12], 22)

	decoded, err := DecodeDMLeft(payload)
	if err != nil {
		t.Fatalf("DecodeDMLeft error: %v", err)
	}
	if decoded.ConvID != 11 || decoded.CorrelationID != 22 {
		t.Fatalf("unexpected decoded dm left payload: %+v", decoded)
	}
}

func TestDecodeDMError(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	buf.WriteByte(1)
	writeString(buf, "target")
	writeString(buf, "message")
	binary.Write(buf, binary.BigEndian, uint32(44))

	decoded, err := DecodeDMError(buf.Bytes())
	if err != nil {
		t.Fatalf("DecodeDMError error: %v", err)
	}
	if decoded.CorrelationID != 44 {
		t.Fatalf("CorrelationID = %d, want 44", decoded.CorrelationID)
	}
}
