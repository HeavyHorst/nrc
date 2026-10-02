package protocol

import (
	"bytes"
	"encoding/binary"
	"fmt"
)

// AuthResponse represents S_AuthResponse data
type AuthResponse struct {
	Success  bool
	UserID   string
	Nickname string
	ErrorMsg string
}

// EncodeAuthenticate encodes C_Authenticate request.
// Wire format: token_len(2) + token
func EncodeAuthenticate(token string) []byte {
	buf := bytes.NewBuffer(nil)
	writeString(buf, token)
	return buf.Bytes()
}

// DecodeAuthResponse decodes S_AuthResponse.
// Wire format: success(1) + user_id_len(2) + user_id + nickname_len(2) + nickname + error_msg_len(2) + error_msg
func DecodeAuthResponse(data []byte) (*AuthResponse, error) {
	buf := bytes.NewReader(data)
	resp := &AuthResponse{}

	var success uint8
	if err := binary.Read(buf, binary.BigEndian, &success); err != nil {
		return nil, fmt.Errorf("failed to read success: %w", err)
	}
	resp.Success = success == 1

	userID, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read user_id: %w", err)
	}
	resp.UserID = userID

	nickname, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read nickname: %w", err)
	}
	resp.Nickname = nickname

	errorMsg, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read error_msg: %w", err)
	}
	resp.ErrorMsg = errorMsg

	return resp, nil
}
