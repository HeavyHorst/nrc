package protocol

import (
	"encoding/binary"
	"strings"
	"testing"
)

func TestCalendarCodecPreservesAppointmentInterval(t *testing.T) {
	q, err := EncodeCalendarQuery(CalendarQuery{Start: 10, End: 20, Limit: 2, Assignee: "a", Project: "p"})
	if err != nil || len(q) != 54 || binary.BigEndian.Uint64(q) != 0 {
		t.Fatalf("query=%x err=%v", q, err)
	}
	b := make([]byte, 32+18+2+1+2+1+2+1+16)
	binary.BigEndian.PutUint16(b[8:], 1)
	b[10] = 1
	binary.BigEndian.PutUint64(b[11:], 12)
	b[19] = CalendarKindAppointment
	binary.BigEndian.PutUint64(b[20:], 7)
	b[28] = CalendarKindAppointment
	binary.BigEndian.PutUint64(b[29:], 7)
	binary.BigEndian.PutUint64(b[37:], 12)
	o := 46
	for _, s := range []string{"T", "a", "p"} {
		binary.BigEndian.PutUint16(b[o:], uint16(len(s)))
		o += 2
		copy(b[o:], s)
		o += len(s)
	}
	binary.BigEndian.PutUint64(b[o:], 10)
	binary.BigEndian.PutUint64(b[o+8:], 18)
	p, err := DecodeCalendarPage(b)
	if err != nil || !p.HasMore || p.Cursor.ID != 7 || len(p.Rows) != 1 || p.Rows[0].ActualStartAt != 10 || p.Rows[0].EndAt != 18 {
		t.Fatalf("page=%+v err=%v", p, err)
	}
	next, err := EncodeCalendarQuery(CalendarQuery{Start: 10, End: 20, Limit: 2, Cursor: &p.Cursor})
	if err != nil || next[26] != 1 || binary.BigEndian.Uint64(next[36:]) != 7 {
		t.Fatalf("next query=%x err=%v", next, err)
	}
}

func TestCalendarCodecValidation(t *testing.T) {
	for _, length := range []int{33, 255, 256} {
		_, err := EncodeCalendarQuery(CalendarQuery{Start: 1, End: 2, Limit: 1, Assignee: strings.Repeat("x", length)})
		if (err == nil) != (length <= 255) {
			t.Fatalf("participant filter length %d: %v", length, err)
		}
	}
	for _, q := range []CalendarQuery{{Start: 2, End: 1, Limit: 1}, {Start: 1, End: 2, Limit: 0}, {Start: 1, End: 2, Limit: 1, Cursor: &CalendarCursor{At: 1, Kind: 4, ID: 1}}} {
		if _, err := EncodeCalendarQuery(q); err == nil {
			t.Fatalf("accepted %+v", q)
		}
	}
	if _, err := DecodeCalendarPage(make([]byte, 31)); err == nil {
		t.Fatal("accepted short page")
	}
}

func TestCalendarOccurrenceIdentity(t *testing.T) {
	b := make([]byte, 32+24+24)
	binary.BigEndian.PutUint16(b[8:], 1)
	b[19], b[28] = CalendarKindOccurrence, CalendarKindOccurrence
	binary.BigEndian.PutUint64(b[11:], 12)
	binary.BigEndian.PutUint64(b[20:], 7)
	binary.BigEndian.PutUint64(b[29:], 7)
	binary.BigEndian.PutUint64(b[37:], 12)
	binary.BigEndian.PutUint64(b[52:], 12)
	binary.BigEndian.PutUint64(b[60:], 18)
	binary.BigEndian.PutUint64(b[68:], 9)
	p, err := DecodeCalendarPage(b)
	if err != nil {
		t.Fatal(err)
	}
	r := p.Rows[0]
	if r.Kind != CalendarKindOccurrence || r.OccurrenceAt != 9 || r.ActualStartAt != 12 || r.EndAt != 18 {
		t.Fatalf("row=%+v", r)
	}
	if !r.IsAppointment() || !r.MatchesAppointmentOccurrence(7, 9) || r.MatchesAppointmentOccurrence(7, 12) || r.MatchesAppointmentOccurrence(8, 9) {
		t.Fatal("occurrence matching used displayed start instead of stable identity")
	}
	standalone := CalendarRow{Kind: CalendarKindAppointment, ID: 7, ActualStartAt: 12}
	if !standalone.MatchesAppointmentOccurrence(7, 12) || standalone.MatchesAppointmentOccurrence(7, 9) {
		t.Fatal("standalone identity mismatch")
	}
	if _, err := EncodeCalendarQuery(CalendarQuery{Start: 10, End: 20, Limit: 1, Cursor: &p.Cursor}); err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeCalendarPage(b[:len(b)-1]); err == nil {
		t.Fatal("accepted truncated occurrence")
	}
}
