package protocol

import (
	"encoding/binary"
	"fmt"
	"unicode/utf8"
)

const (
	CalendarKindTask        uint8 = 0
	CalendarKindReminder    uint8 = 1
	CalendarKindAppointment uint8 = 2
	CalendarKindOccurrence  uint8 = 3
	CalendarMaxRange              = int64(62 * 24 * 60 * 60 * 1_000_000_000)
)

type CalendarCursor struct {
	At   int64
	Kind uint8
	ID   uint64
}

type CalendarQuery struct {
	Start, End        int64
	Limit             uint16
	Cursor            *CalendarCursor
	Assignee, Project string
	CorrelationID     uint32
}

type CalendarRow struct {
	Kind                 uint8  `json:"kind"`
	ID                   uint64 `json:"id"`
	At                   int64  `json:"at"`
	Blocked              bool   `json:"blocked"`
	Title                string `json:"title"`
	Assignee             string `json:"assignee"`
	Project              string `json:"project"`
	ActualStartAt, EndAt int64  `json:"-"`
	OccurrenceAt         int64  `json:"occurrence_at,omitempty"`
}

type CalendarPage struct {
	ConvID        uint64
	Rows          []CalendarRow
	HasMore       bool
	Cursor        CalendarCursor
	CorrelationID uint32
}

// IsAppointment includes both standalone appointments and recurring occurrences.
func (r CalendarRow) IsAppointment() bool {
	return r.Kind == CalendarKindAppointment || r.Kind == CalendarKindOccurrence
}

// MatchesAppointmentOccurrence matches the stable conference identity. For a
// recurring row use the ORIGINAL occurrence start, not At (the clamped paging
// key) or ActualStartAt (which changes on reschedule). A matching row alone is
// not authorization: callers must also check the authoritative asset metadata.
func (r CalendarRow) MatchesAppointmentOccurrence(assetID uint64, occurrenceAt int64) bool {
	if r.ID != assetID || occurrenceAt <= 0 {
		return false
	}
	if r.Kind == CalendarKindOccurrence {
		return r.OccurrenceAt == occurrenceAt
	}
	return r.Kind == CalendarKindAppointment && r.ActualStartAt == occurrenceAt
}

func EncodeCalendarQuery(q CalendarQuery) ([]byte, error) {
	if q.Start < 0 || q.End <= q.Start || q.End-q.Start > CalendarMaxRange {
		return nil, fmt.Errorf("calendar range must be positive, increasing, and at most 62 days")
	}
	if q.Limit < 1 || q.Limit > 100 {
		return nil, fmt.Errorf("calendar limit must be 1-100")
	}
	if len(q.Assignee) > MaxUsernameLength || len(q.Project) > MaxProjectLength || !utf8.ValidString(q.Assignee) || !utf8.ValidString(q.Project) {
		return nil, fmt.Errorf("invalid calendar filter")
	}
	buf := make([]byte, 52+len(q.Assignee)+len(q.Project))
	binary.BigEndian.PutUint64(buf, WorkspaceDataConvID)
	binary.BigEndian.PutUint64(buf[8:], uint64(q.Start))
	binary.BigEndian.PutUint64(buf[16:], uint64(q.End))
	binary.BigEndian.PutUint16(buf[24:], q.Limit)
	if q.Cursor != nil {
		if q.Cursor.At < q.Start || q.Cursor.At >= q.End || q.Cursor.Kind > CalendarKindOccurrence || q.Cursor.ID == 0 {
			return nil, fmt.Errorf("invalid calendar cursor")
		}
		buf[26] = 1
		binary.BigEndian.PutUint64(buf[27:], uint64(q.Cursor.At))
		buf[35] = q.Cursor.Kind
		binary.BigEndian.PutUint64(buf[36:], q.Cursor.ID)
	}
	o := 44
	for _, s := range []string{q.Assignee, q.Project} {
		binary.BigEndian.PutUint16(buf[o:], uint16(len(s)))
		o += 2
		copy(buf[o:], s)
		o += len(s)
	}
	binary.BigEndian.PutUint32(buf[o:], q.CorrelationID)
	return buf, nil
}

func DecodeCalendarPage(data []byte) (*CalendarPage, error) {
	if len(data) < 32 || data[10] > 1 {
		return nil, fmt.Errorf("invalid calendar page header")
	}
	p := &CalendarPage{ConvID: binary.BigEndian.Uint64(data), HasMore: data[10] == 1}
	count := int(binary.BigEndian.Uint16(data[8:]))
	p.Cursor = CalendarCursor{At: int64(binary.BigEndian.Uint64(data[11:])), Kind: data[19], ID: binary.BigEndian.Uint64(data[20:])}
	o := 28
	p.Rows = make([]CalendarRow, 0, count)
	readText := func() (string, error) {
		if o+2 > len(data) {
			return "", fmt.Errorf("truncated calendar string length")
		}
		n := int(binary.BigEndian.Uint16(data[o:]))
		o += 2
		if o+n > len(data) || !utf8.Valid(data[o:o+n]) {
			return "", fmt.Errorf("invalid calendar string")
		}
		s := string(data[o : o+n])
		o += n
		return s, nil
	}
	for i := 0; i < count; i++ {
		if o+18 > len(data) {
			return nil, fmt.Errorf("truncated calendar row")
		}
		r := CalendarRow{Kind: data[o], ID: binary.BigEndian.Uint64(data[o+1:]), At: int64(binary.BigEndian.Uint64(data[o+9:])), Blocked: data[o+17] == 1}
		o += 18
		if r.Kind > CalendarKindOccurrence || data[o-1] > 1 {
			return nil, fmt.Errorf("invalid calendar row")
		}
		var err error
		if r.Title, err = readText(); err != nil {
			return nil, err
		}
		if r.Assignee, err = readText(); err != nil {
			return nil, err
		}
		if r.Project, err = readText(); err != nil {
			return nil, err
		}
		if r.Kind == CalendarKindAppointment || r.Kind == CalendarKindOccurrence {
			if o+16 > len(data) {
				return nil, fmt.Errorf("truncated appointment interval")
			}
			r.ActualStartAt = int64(binary.BigEndian.Uint64(data[o:]))
			r.EndAt = int64(binary.BigEndian.Uint64(data[o+8:]))
			o += 16
		}
		if r.Kind == CalendarKindOccurrence {
			if o+8 > len(data) {
				return nil, fmt.Errorf("truncated occurrence identity")
			}
			r.OccurrenceAt = int64(binary.BigEndian.Uint64(data[o:]))
			o += 8
		}
		p.Rows = append(p.Rows, r)
	}
	if o+4 != len(data) {
		return nil, fmt.Errorf("calendar page length mismatch")
	}
	p.CorrelationID = binary.BigEndian.Uint32(data[o:])
	return p, nil
}
