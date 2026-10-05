package protocol

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestTaskSliceIndependentCounterSums(t *testing.T) {
	s := TaskSlice{Backlog: 40000, Todo: 30000, Done: 65535, Notes: 1, Files: 2}
	if s.OpenCount() != 70000 || s.TaskCount() != 135535 || s.MemberCount() != 135538 {
		t.Fatalf("wrapped independent counters: open=%d tasks=%d members=%d", s.OpenCount(), s.TaskCount(), s.MemberCount())
	}
	for _, s := range []TaskSlice{{Backlog: 65535}, {Backlog: 65535, Todo: 1}} {
		want := uint32(s.Backlog) + uint32(s.Todo)
		if s.OpenCount() != want || s.TaskCount() != want {
			t.Fatalf("boundary sum: got open=%d tasks=%d, want %d", s.OpenCount(), s.TaskCount(), want)
		}
	}
}

func TestEncodeListTaskSlices(t *testing.T) {
	// The first page of an unfiltered listing: conv_id, no flags, an empty owner,
	// an empty name, the page bound and the correlation id.
	payload := EncodeListTaskSlices(12, SliceQuery{Limit: 100}, 34)
	if len(payload) != 22 || binary.BigEndian.Uint64(payload) != 12 || payload[8] != 0 || payload[9] != 0 ||
		binary.BigEndian.Uint16(payload[10:]) != 0 || payload[12] != 0 ||
		binary.BigEndian.Uint16(payload[13:]) != 0 || binary.BigEndian.Uint16(payload[15:]) != 100 ||
		payload[17] != 0 || binary.BigEndian.Uint32(payload[18:]) != 34 {
		t.Fatalf("unexpected slice request: %x", payload)
	}

	// The filters, the page bound and the cursor all reach the wire.
	filtered := EncodeListTaskSlices(12, SliceQuery{
		IncludeClosed: true, HasOwner: true, Owner: "anke",
		HasName: true, Name: "shard", Limit: 50,
		Cursor: &SliceCursor{Closed: true, SortAt: 9000, SliceID: 77},
	}, 9)
	if filtered[8] != 1 || filtered[9] != 1 {
		t.Fatalf("flags not encoded: %x", filtered)
	}
	if binary.BigEndian.Uint16(filtered[10:]) != 4 || string(filtered[12:16]) != "anke" {
		t.Fatalf("owner not encoded: %x", filtered)
	}
	offset := 16
	if filtered[offset] != 1 {
		t.Fatalf("has_name not encoded: %x", filtered)
	}
	offset++
	if binary.BigEndian.Uint16(filtered[offset:]) != 5 || string(filtered[offset+2:offset+7]) != "shard" {
		t.Fatalf("name not encoded: %x", filtered)
	}
	offset += 7
	if binary.BigEndian.Uint16(filtered[offset:]) != 50 {
		t.Fatalf("limit not encoded: %x", filtered)
	}
	offset += 2
	if filtered[offset] != 1 || filtered[offset+1] != 1 {
		t.Fatalf("cursor flags not encoded: %x", filtered)
	}
	if int64(binary.BigEndian.Uint64(filtered[offset+2:])) != 9000 ||
		binary.BigEndian.Uint64(filtered[offset+10:]) != 77 {
		t.Fatalf("cursor key not encoded: %x", filtered)
	}
	if binary.BigEndian.Uint32(filtered[offset+18:]) != 9 {
		t.Fatalf("correlation id not encoded: %x", filtered)
	}
}

func writeSlice(buf *bytes.Buffer, slice TaskSlice) {
	writeString(buf, slice.Name)
	binary.Write(buf, binary.BigEndian, slice.SliceID)
	writeString(buf, slice.Owner)
	buf.WriteByte(slice.Flags)
	for _, value := range []uint16{slice.Backlog, slice.Todo, slice.InProgress, slice.Done, slice.Blocked, slice.Notes, slice.Files} {
		binary.Write(buf, binary.BigEndian, value)
	}
	binary.Write(buf, binary.BigEndian, slice.OldestActiveAt)
	binary.Write(buf, binary.BigEndian, slice.LastMovedAt)
}

// writeSliceFrame writes one frame with a single slice, so a malformed-frame test
// only has to mutate the part it is about.
func writeSliceFrame(buf *bytes.Buffer, slice TaskSlice, hasMore uint8, cursor SliceCursor, total, assigned, unassigned uint32) {
	binary.Write(buf, binary.BigEndian, uint64(7))
	buf.WriteByte(1)
	binary.Write(buf, binary.BigEndian, uint16(1))
	writeSlice(buf, slice)
	buf.WriteByte(hasMore)
	if cursor.Closed {
		buf.WriteByte(1)
	} else {
		buf.WriteByte(0)
	}
	binary.Write(buf, binary.BigEndian, cursor.SortAt)
	binary.Write(buf, binary.BigEndian, cursor.SliceID)
	binary.Write(buf, binary.BigEndian, total)
	binary.Write(buf, binary.BigEndian, assigned)
	binary.Write(buf, binary.BigEndian, unassigned)
	writeString(buf, "")
	binary.Write(buf, binary.BigEndian, uint32(2))
}

func TestDecodeTaskSliceList(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint64(7))
	buf.WriteByte(1)
	binary.Write(buf, binary.BigEndian, uint16(2))
	writeSlice(buf, TaskSlice{
		Name: "Alpha", SliceID: 77, Owner: "rene", Flags: TaskSliceFlagClosed,
		Backlog: 1, Todo: 2, InProgress: 3, Done: 4, Blocked: 5, Notes: 6, Files: 7,
		OldestActiveAt: 111, LastMovedAt: 222,
	})
	writeSlice(buf, TaskSlice{Name: "Beta", SliceID: 78, Todo: 1, LastMovedAt: 333})
	buf.WriteByte(1)
	buf.WriteByte(1)
	binary.Write(buf, binary.BigEndian, int64(9000))
	binary.Write(buf, binary.BigEndian, uint64(78))
	binary.Write(buf, binary.BigEndian, uint32(9))
	binary.Write(buf, binary.BigEndian, uint32(11))
	binary.Write(buf, binary.BigEndian, uint32(15))
	writeString(buf, "")
	binary.Write(buf, binary.BigEndian, uint32(13))

	list, err := DecodeTaskSliceList(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if !list.Success || !list.HasMore || list.TotalCount != 9 || list.AssignedTasks != 11 ||
		list.UnassignedTasks != 15 || list.CorrelationID != 13 || len(list.Slices) != 2 {
		t.Fatalf("unexpected slice list: %+v", list)
	}
	if !list.NextCursor.Closed || list.NextCursor.SortAt != 9000 || list.NextCursor.SliceID != 78 {
		t.Fatalf("unexpected next cursor: %+v", list.NextCursor)
	}
	alpha := list.Slices[0]
	if alpha.Name != "Alpha" || alpha.SliceID != 77 || alpha.Owner != "rene" || !alpha.IsClosed() {
		t.Fatalf("unexpected closed slice: %+v", alpha)
	}
	// Members are tasks with a status, notes and files; the task count is the
	// subset that carries a status.
	if alpha.MemberCount() != 23 || alpha.TaskCount() != 10 || alpha.OpenCount() != 6 ||
		alpha.Blocked != 5 || alpha.Notes != 6 || alpha.Files != 7 {
		t.Fatalf("unexpected slice counters: %+v", alpha)
	}
	if alpha.OldestActiveAt != 111 || alpha.LastMovedAt != 222 {
		t.Fatalf("unexpected slice timestamps: %+v", alpha)
	}
	beta := list.Slices[1]
	if beta.IsClosed() || beta.OpenCount() != 1 || beta.MemberCount() != 1 {
		t.Fatalf("unexpected open slice: %+v", beta)
	}
}

func TestDecodeTaskSliceListRejectsMalformedFrames(t *testing.T) {
	valid := func() []byte {
		buf := bytes.NewBuffer(nil)
		writeSliceFrame(buf, TaskSlice{Name: "Alpha"}, 0, SliceCursor{}, 1, 0, 0)
		return buf.Bytes()
	}
	if _, err := DecodeTaskSliceList(valid()); err != nil {
		t.Fatalf("valid frame rejected: %v", err)
	}
	trailing := append(valid(), 0)
	if _, err := DecodeTaskSliceList(trailing); err == nil {
		t.Fatal("accepted trailing bytes")
	}

	// An unknown flag bit must be refused rather than ignored. Only bit 0
	// (closed) is defined.
	unknownFlag := bytes.NewBuffer(nil)
	writeSliceFrame(unknownFlag, TaskSlice{Name: "Alpha", Flags: 0x02}, 0, SliceCursor{}, 1, 0, 0)
	if _, err := DecodeTaskSliceList(unknownFlag.Bytes()); err == nil {
		t.Fatal("accepted an unknown slice flag")
	}

	// A slice name over the project limit cannot be addressed by a task label.
	oversizedName := bytes.NewBuffer(nil)
	writeSliceFrame(oversizedName, TaskSlice{Name: string(make([]byte, MaxProjectLength+1))}, 0, SliceCursor{}, 1, 0, 0)
	if _, err := DecodeTaskSliceList(oversizedName.Bytes()); err == nil {
		t.Fatal("accepted an oversized slice name")
	}
}
