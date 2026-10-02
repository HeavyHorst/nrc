package protocol

import (
	"bytes"
	"encoding/binary"
	"fmt"
)

// NicknameResponse represents S_NicknameResponse data.
type NicknameResponse struct {
	Success         bool
	IsAuthenticated bool
	Nickname        string
	ErrorMsg        string
}

// EncodeSetNickname encodes C_SetNickname request.
// Wire format: nickname_len(2) + nickname
func EncodeSetNickname(nickname string) []byte {
	buf := bytes.NewBuffer(nil)
	writeString(buf, nickname)
	return buf.Bytes()
}

// DecodeNicknameResponse decodes S_NicknameResponse.
// Wire format: success(1) + is_authenticated(1) + nickname_len(2) + nickname + error_msg_len(2) + error_msg
func DecodeNicknameResponse(data []byte) (*NicknameResponse, error) {
	if len(data) < 6 {
		return nil, fmt.Errorf("nickname response too short: need at least 6 bytes, got %d", len(data))
	}

	resp := &NicknameResponse{}
	resp.Success = data[0] == 1
	resp.IsAuthenticated = data[1] == 1

	offset := 2
	nicknameLen := int(binary.BigEndian.Uint16(data[offset : offset+2]))
	offset += 2
	if len(data) < offset+nicknameLen+2 {
		return nil, fmt.Errorf("nickname response truncated before error length: payload=%d nickname_len=%d", len(data), nicknameLen)
	}

	resp.Nickname = string(data[offset : offset+nicknameLen])
	offset += nicknameLen

	errorLen := int(binary.BigEndian.Uint16(data[offset : offset+2]))
	offset += 2
	if len(data) < offset+errorLen {
		return nil, fmt.Errorf("nickname response truncated in error message: payload=%d error_len=%d", len(data), errorLen)
	}

	resp.ErrorMsg = string(data[offset : offset+errorLen])
	return resp, nil
}
