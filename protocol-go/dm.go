package protocol

import (
	"bytes"
	"encoding/binary"
	"fmt"
)

const DMConvFlag uint64 = 0x8000000000000000

// DMStarted represents S_DMStarted data
type DMStarted struct {
	ConvID        uint64
	Username      string
	Authenticated bool
	Online        bool
	IsInitiator   bool
	CorrelationID uint32
}

// DMEntry represents one entry in S_DMList
type DMEntry struct {
	ConvID        uint64
	Username      string
	Authenticated bool
	Online        bool
	LastSeen      uint64
}

// DMList represents S_DMList data
type DMList struct {
	Entries       []DMEntry
	CorrelationID uint32
}

// DMLeft represents S_DMLeft data
type DMLeft struct {
	ConvID        uint64
	CorrelationID uint32
}

// DMError represents S_DMError data
type DMError struct {
	Code           uint8
	TargetUsername string
	Message        string
	CorrelationID  uint32
}

// DMPartnerStatus represents S_DMPartnerStatus data.
type DMPartnerStatus struct {
	ConvID   uint64
	Username string
	Online   bool
	LastSeen uint64
}

// EncodeStartDM encodes C_StartDM request.
// Wire format: username_len(2) + username
func EncodeStartDM(username string) []byte {
	return EncodeStartDMWithCorrelation(username, 0)
}

// EncodeStartDMWithCorrelation encodes C_StartDM request with trailing correlation_id.
func EncodeStartDMWithCorrelation(username string, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	writeString(buf, username)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// EncodeListDMs encodes C_ListDMs request.
// Wire format: correlation_id(4)
func EncodeListDMs() []byte {
	return EncodeListDMsWithCorrelation(0)
}

// EncodeListDMsWithCorrelation encodes C_ListDMs request with correlation_id.
func EncodeListDMsWithCorrelation(correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// EncodeLeaveDM encodes C_LeaveDM request.
// Wire format: conv_id(8)
func EncodeLeaveDM(convID uint64) []byte {
	return EncodeLeaveDMWithCorrelation(convID, 0)
}

// EncodeLeaveDMWithCorrelation encodes C_LeaveDM request with trailing correlation_id.
func EncodeLeaveDMWithCorrelation(convID uint64, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// DecodeDMStarted decodes S_DMStarted.
// Wire format: conv_id(8) + username_len(2) + username + authenticated(1) + online(1) + is_initiator(1) + correlation_id(4)
func DecodeDMStarted(data []byte) (*DMStarted, error) {
	buf := bytes.NewReader(data)
	dm := &DMStarted{}

	if err := binary.Read(buf, binary.BigEndian, &dm.ConvID); err != nil {
		return nil, fmt.Errorf("failed to read conv_id: %w", err)
	}

	username, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read username: %w", err)
	}
	dm.Username = username

	var authenticated uint8
	if err := binary.Read(buf, binary.BigEndian, &authenticated); err != nil {
		return nil, fmt.Errorf("failed to read authenticated: %w", err)
	}
	dm.Authenticated = authenticated == 1

	var online uint8
	if err := binary.Read(buf, binary.BigEndian, &online); err != nil {
		return nil, fmt.Errorf("failed to read online: %w", err)
	}
	dm.Online = online == 1

	var isInitiator uint8
	if err := binary.Read(buf, binary.BigEndian, &isInitiator); err != nil {
		return nil, fmt.Errorf("failed to read is_initiator: %w", err)
	}
	dm.IsInitiator = isInitiator == 1

	if buf.Len() < 4 {
		return nil, fmt.Errorf("dm started payload missing correlation_id")
	}
	if err := binary.Read(buf, binary.BigEndian, &dm.CorrelationID); err != nil {
		return nil, fmt.Errorf("failed to read correlation_id: %w", err)
	}

	if buf.Len() != 0 {
		return nil, fmt.Errorf("unexpected trailing bytes in dm started payload: %d", buf.Len())
	}

	return dm, nil
}

// DecodeDMList decodes S_DMList.
// Wire format: count(2) + correlation_id(4) + [conv_id(8) + username_len(2) + username + authenticated(1) + online(1) + last_seen(8)] * count
func DecodeDMList(data []byte) (*DMList, error) {
	buf := bytes.NewReader(data)
	list := &DMList{}

	var count uint16
	if err := binary.Read(buf, binary.BigEndian, &count); err != nil {
		return nil, fmt.Errorf("failed to read count: %w", err)
	}

	if buf.Len() < 4 {
		return nil, fmt.Errorf("dm list payload missing correlation_id")
	}
	if err := binary.Read(buf, binary.BigEndian, &list.CorrelationID); err != nil {
		return nil, fmt.Errorf("failed to read correlation_id: %w", err)
	}

	list.Entries = make([]DMEntry, 0, count)
	for i := 0; i < int(count); i++ {
		entry := DMEntry{}

		if err := binary.Read(buf, binary.BigEndian, &entry.ConvID); err != nil {
			return nil, fmt.Errorf("failed to read conv_id for entry %d: %w", i, err)
		}

		username, err := readString(buf)
		if err != nil {
			return nil, fmt.Errorf("failed to read username for entry %d: %w", i, err)
		}
		entry.Username = username

		var authenticated uint8
		if err := binary.Read(buf, binary.BigEndian, &authenticated); err != nil {
			return nil, fmt.Errorf("failed to read authenticated for entry %d: %w", i, err)
		}
		entry.Authenticated = authenticated == 1

		var online uint8
		if err := binary.Read(buf, binary.BigEndian, &online); err != nil {
			return nil, fmt.Errorf("failed to read online for entry %d: %w", i, err)
		}
		entry.Online = online == 1

		if err := binary.Read(buf, binary.BigEndian, &entry.LastSeen); err != nil {
			return nil, fmt.Errorf("failed to read last_seen for entry %d: %w", i, err)
		}

		list.Entries = append(list.Entries, entry)
	}

	if buf.Len() != 0 {
		return nil, fmt.Errorf("unexpected trailing bytes in dm list payload: %d", buf.Len())
	}

	return list, nil
}

// DecodeDMLeft decodes S_DMLeft payload.
// Wire format: conv_id(8) + correlation_id(4)
func DecodeDMLeft(data []byte) (*DMLeft, error) {
	if len(data) != 12 {
		return nil, fmt.Errorf("dm left payload size mismatch: got %d want 12", len(data))
	}

	return &DMLeft{
		ConvID:        binary.BigEndian.Uint64(data[0:8]),
		CorrelationID: binary.BigEndian.Uint32(data[8:12]),
	}, nil
}

// DecodeDMError decodes S_DMError payload.
// Wire format: code(1) + target_username_len(2) + target_username + message_len(2) + message + correlation_id(4)
func DecodeDMError(data []byte) (*DMError, error) {
	buf := bytes.NewReader(data)
	resp := &DMError{}

	if err := binary.Read(buf, binary.BigEndian, &resp.Code); err != nil {
		return nil, fmt.Errorf("failed to read dm error code: %w", err)
	}

	target, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read dm error target username: %w", err)
	}
	resp.TargetUsername = target

	msg, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read dm error message: %w", err)
	}
	resp.Message = msg

	if buf.Len() < 4 {
		return nil, fmt.Errorf("dm error missing correlation_id")
	}
	if err := binary.Read(buf, binary.BigEndian, &resp.CorrelationID); err != nil {
		return nil, fmt.Errorf("failed to read dm error correlation_id: %w", err)
	}

	if buf.Len() != 0 {
		return nil, fmt.Errorf("unexpected trailing bytes in dm error payload: %d", buf.Len())
	}

	return resp, nil
}

// DecodeDMPartnerStatus decodes S_DMPartnerStatus payload.
// Wire format: conv_id(8) + online(1) + username_len(2) + username + last_seen(8)
func DecodeDMPartnerStatus(data []byte) (*DMPartnerStatus, error) {
	buf := bytes.NewReader(data)
	status := &DMPartnerStatus{}

	if err := binary.Read(buf, binary.BigEndian, &status.ConvID); err != nil {
		return nil, fmt.Errorf("failed to read conv_id: %w", err)
	}

	var online uint8
	if err := binary.Read(buf, binary.BigEndian, &online); err != nil {
		return nil, fmt.Errorf("failed to read online: %w", err)
	}
	status.Online = online == 1

	username, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read username: %w", err)
	}
	status.Username = username

	if err := binary.Read(buf, binary.BigEndian, &status.LastSeen); err != nil {
		return nil, fmt.Errorf("failed to read last_seen: %w", err)
	}

	if buf.Len() != 0 {
		return nil, fmt.Errorf("unexpected trailing bytes in dm partner status payload: %d", buf.Len())
	}

	return status, nil
}
