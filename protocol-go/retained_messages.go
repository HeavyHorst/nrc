package protocol

import (
	"bytes"
	"encoding/binary"
	"fmt"
)

const MaxMessagePageCount = 100

type ClientMessageID [16]byte

type SubscriptionReadyEntry struct{ ConvID, HighWaterSeq, RetentionCutoffSeq uint64 }
type SubscriptionReady struct {
	CorrelationID uint32
	Entries       []SubscriptionReadyEntry
}

type RetainedMessage struct {
	ConvID          uint64
	Sequence        uint64
	ClientMessageID ClientMessageID
	Username        string
	Timestamp       int64
	ContentType     uint8
	Content         string
}

type MessagePage struct {
	ConvID                                               uint64
	Ascending, HasMore, Truncated                        bool
	HighWaterSeq, RetentionCutoffSeq, ContinuationCursor uint64
	CorrelationID                                        uint32
	Messages                                             []RetainedMessage
}

// EncodeSendMessageV2 encodes client_message_id(16) and correlation_id(4) in addition to message data.
func EncodeSendMessageV2(convID uint64, id ClientMessageID, correlationID uint32, contentType uint8, content string) ([]byte, error) {
	if len(content) > MaxAllowedContentLength || contentType > ContentTypeMarkdown {
		return nil, fmt.Errorf("invalid message content")
	}
	b := bytes.NewBuffer(make([]byte, 0, 31+len(content)))
	binary.Write(b, binary.BigEndian, convID)
	b.Write(id[:])
	binary.Write(b, binary.BigEndian, correlationID)
	b.WriteByte(contentType)
	binary.Write(b, binary.BigEndian, uint16(len(content)))
	b.WriteString(content)
	return b.Bytes(), nil
}

func EncodeSubscribeConvsV2(correlationID uint32, convIDs ...uint64) ([]byte, error) {
	if len(convIDs) > MaxSubscribeConvs {
		return nil, fmt.Errorf("too many conversations: %d", len(convIDs))
	}
	b := bytes.NewBuffer(nil)
	binary.Write(b, binary.BigEndian, uint16(len(convIDs)))
	for _, id := range convIDs {
		binary.Write(b, binary.BigEndian, id)
	}
	binary.Write(b, binary.BigEndian, correlationID)
	return b.Bytes(), nil
}

func encodeMessageRange(convID, cursor uint64, limit uint16, correlationID uint32) ([]byte, error) {
	if limit == 0 || limit > MaxMessagePageCount {
		return nil, fmt.Errorf("limit must be 1..%d", MaxMessagePageCount)
	}
	b := bytes.NewBuffer(nil)
	binary.Write(b, binary.BigEndian, convID)
	binary.Write(b, binary.BigEndian, cursor)
	binary.Write(b, binary.BigEndian, limit)
	binary.Write(b, binary.BigEndian, correlationID)
	return b.Bytes(), nil
}

// EncodeListMessagesBefore requests newest-first records with sequence < beforeSeq.
func EncodeListMessagesBefore(convID, beforeSeq uint64, limit uint16, correlationID uint32) ([]byte, error) {
	return encodeMessageRange(convID, beforeSeq, limit, correlationID)
}

// EncodeReplayMessagesAfter requests ascending records with sequence > afterSeq.
func EncodeReplayMessagesAfter(convID, afterSeq uint64, limit uint16, correlationID uint32) ([]byte, error) {
	return encodeMessageRange(convID, afterSeq, limit, correlationID)
}

func DecodeSubscriptionReady(data []byte) (*SubscriptionReady, error) {
	if len(data) < 6 {
		return nil, fmt.Errorf("subscription ready too short")
	}
	count := int(binary.BigEndian.Uint16(data[4:6]))
	if count > MaxSubscribeConvs || len(data) != 6+count*24 {
		return nil, fmt.Errorf("malformed subscription ready")
	}
	r := &SubscriptionReady{CorrelationID: binary.BigEndian.Uint32(data[:4]), Entries: make([]SubscriptionReadyEntry, count)}
	for i := range r.Entries {
		p := 6 + i*24
		r.Entries[i] = SubscriptionReadyEntry{binary.BigEndian.Uint64(data[p:]), binary.BigEndian.Uint64(data[p+8:]), binary.BigEndian.Uint64(data[p+16:])}
	}
	return r, nil
}

func DecodeMessagePage(data []byte) (*MessagePage, error) {
	if len(data) < 41 {
		return nil, fmt.Errorf("message page too short")
	}
	if data[8] > 1 || data[9] > 1 || data[10] > 1 {
		return nil, fmt.Errorf("invalid boolean")
	}
	count := int(binary.BigEndian.Uint16(data[39:41]))
	if count > MaxMessagePageCount {
		return nil, fmt.Errorf("message count exceeds %d", MaxMessagePageCount)
	}
	p := &MessagePage{ConvID: binary.BigEndian.Uint64(data), Ascending: data[8] == 1, HasMore: data[9] == 1, Truncated: data[10] == 1,
		HighWaterSeq: binary.BigEndian.Uint64(data[11:]), RetentionCutoffSeq: binary.BigEndian.Uint64(data[19:]), ContinuationCursor: binary.BigEndian.Uint64(data[27:]), CorrelationID: binary.BigEndian.Uint32(data[35:]), Messages: make([]RetainedMessage, 0, count)}
	off := 41
	for i := 0; i < count; i++ {
		if len(data) < off+34 {
			return nil, fmt.Errorf("message %d truncated", i)
		}
		m := RetainedMessage{ConvID: binary.BigEndian.Uint64(data[off:]), Sequence: binary.BigEndian.Uint64(data[off+8:])}
		copy(m.ClientMessageID[:], data[off+16:off+32])
		off += 32
		nameLen := int(binary.BigEndian.Uint16(data[off:]))
		off += 2
		if nameLen > MaxUsernameLength || len(data) < off+nameLen+11 {
			return nil, fmt.Errorf("message %d malformed username", i)
		}
		m.Username = string(data[off : off+nameLen])
		off += nameLen
		m.Timestamp = int64(binary.BigEndian.Uint64(data[off:]))
		off += 8
		m.ContentType = data[off]
		off++
		if m.ContentType > ContentTypeMarkdown {
			return nil, fmt.Errorf("message %d invalid content type", i)
		}
		contentLen := int(binary.BigEndian.Uint16(data[off:]))
		off += 2
		if contentLen > MaxAllowedContentLength || len(data) < off+contentLen {
			return nil, fmt.Errorf("message %d malformed content", i)
		}
		m.Content = string(data[off : off+contentLen])
		off += contentLen
		p.Messages = append(p.Messages, m)
	}
	if off != len(data) {
		return nil, fmt.Errorf("unexpected trailing bytes: %d", len(data)-off)
	}
	return p, nil
}
