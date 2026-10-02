package protocol

import (
	"bytes"
	"encoding/binary"
	"fmt"
)

// Message represents a protocol message with a uint16 opcode.
type Message struct {
	Opcode uint16
	Data   []byte
}

// Write encodes a message to binary. Format: opcode(2) + data
func (m *Message) Write() ([]byte, error) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, m.Opcode)
	buf.Write(m.Data)
	return buf.Bytes(), nil
}

// ReadMessage decodes a message from binary. Format: opcode(2) + data
func ReadMessage(data []byte) (*Message, error) {
	if len(data) < 2 {
		return nil, fmt.Errorf("message too short (need 2 bytes for opcode, got %d)", len(data))
	}
	opcode := binary.BigEndian.Uint16(data[0:2])
	return &Message{
		Opcode: opcode,
		Data:   data[2:],
	}, nil
}

func writeString(buf *bytes.Buffer, s string) {
	binary.Write(buf, binary.BigEndian, uint16(len(s)))
	buf.WriteString(s)
}

func readString(buf *bytes.Reader) (string, error) {
	var length uint16
	if err := binary.Read(buf, binary.BigEndian, &length); err != nil {
		return "", err
	}
	data := make([]byte, length)
	if _, err := buf.Read(data); err != nil {
		return "", err
	}
	return string(data), nil
}
