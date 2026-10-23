package protocol

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"unicode/utf8"
)

// StringList is one chunk of a sorted, unique, nonempty-string metadata list.
// HasMore indicates another response chunk, not another client request.
type StringList struct {
	ConvID        uint64
	Values        []string
	HasMore       bool
	CorrelationID uint32
}

func EncodeListSliceOwners(convID uint64, correlationID uint32) []byte {
	return EncodeListTaskProjects(convID, correlationID)
}

func EncodeListTicketAssignees(convID uint64, correlationID uint32) []byte {
	return EncodeListTaskProjects(convID, correlationID)
}

func EncodeListCalendarPeople(convID uint64, correlationID uint32) []byte {
	return EncodeListTaskProjects(convID, correlationID)
}

func DecodeSliceOwners(payload []byte) (*StringList, error)     { return decodeStringList(payload) }
func DecodeTicketAssignees(payload []byte) (*StringList, error) { return decodeStringList(payload) }
func DecodeCalendarPeople(payload []byte) (*StringList, error)  { return decodeStringList(payload) }

func decodeStringList(payload []byte) (*StringList, error) {
	b := bytes.NewReader(payload)
	r := &StringList{}
	var count uint16
	if binary.Read(b, binary.BigEndian, &r.ConvID) != nil || binary.Read(b, binary.BigEndian, &count) != nil {
		return nil, fmt.Errorf("invalid metadata list header")
	}
	r.Values = make([]string, 0, recordCapacity(int(count)))
	for i := 0; i < int(count); i++ {
		v, err := readString(b)
		if err != nil || v == "" || !utf8.ValidString(v) || i > 0 && v <= r.Values[i-1] {
			return nil, fmt.Errorf("invalid metadata list value")
		}
		r.Values = append(r.Values, v)
	}
	more, err := b.ReadByte()
	if err != nil || more > 1 || binary.Read(b, binary.BigEndian, &r.CorrelationID) != nil || b.Len() != 0 {
		return nil, fmt.Errorf("invalid metadata list tail")
	}
	r.HasMore = more == 1
	return r, nil
}
