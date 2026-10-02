package protocol

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestEncodeListTasksPaged(t *testing.T) {
	cursor := &TaskPageCursor{SortAt: -42, TaskID: 99}
	got, err := EncodeListTasksPaged(7, 0x05, 250, cursor, 123)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 32 {
		t.Fatalf("length = %d, want 32", len(got))
	}
	if binary.BigEndian.Uint64(got[:8]) != 7 || got[8] != 5 || binary.BigEndian.Uint16(got[9:11]) != 250 || got[11] != 1 {
		t.Fatalf("incorrect request prefix: %x", got[:12])
	}
	if int64(binary.BigEndian.Uint64(got[12:20])) != -42 || binary.BigEndian.Uint64(got[20:28]) != 99 || binary.BigEndian.Uint32(got[28:]) != 123 {
		t.Fatalf("incorrect cursor/correlation: %x", got[12:])
	}
	without, err := EncodeListTasksPaged(7, 0x1f, 1000, nil, 8)
	if err != nil {
		t.Fatal(err)
	}
	if len(without) != 16 || without[11] != 0 || binary.BigEndian.Uint32(without[12:]) != 8 {
		t.Fatalf("incorrect cursorless request: %x", without)
	}
	for _, tc := range []struct {
		mask  uint8
		limit uint16
	}{{0, 0}, {0, 1001}, {0x20, 1}} {
		if _, err := EncodeListTasksPaged(1, tc.mask, tc.limit, nil, 0); err == nil {
			t.Fatalf("accepted mask=%x limit=%d", tc.mask, tc.limit)
		}
	}
}

func TestEncodeGetTask(t *testing.T) {
	got := EncodeGetTask(1, 2, 3)
	if len(got) != 20 || binary.BigEndian.Uint64(got[:8]) != 1 || binary.BigEndian.Uint64(got[8:16]) != 2 || binary.BigEndian.Uint32(got[16:]) != 3 {
		t.Fatalf("incorrect get payload: %x", got)
	}
}

func TestTaskQueryWire(t *testing.T) {
	assignee, project := "Åsa", "Alpha"
	payload, err := EncodeTaskQuery(TaskQuery{ConvID: 7, StatusMask: 0x0f, Limit: 25, Sort: TaskQuerySortTitle, Descending: true, Color: 255, Blocked: 2, OverdueBefore: 99, Assignee: &assignee, Project: &project, Cursor: &TaskQueryCursor{Text: "next", TaskID: 42}, CorrelationID: 8})
	if err != nil {
		t.Fatal(err)
	}
	if len(payload) != 52+len(assignee)+len(project)+len("next") || payload[11] != byte(TaskQuerySortTitle) || payload[12] != 1 {
		t.Fatalf("unexpected query wire: %x", payload)
	}
	if _, err := EncodeTaskQuery(TaskQuery{StatusMask: 0x10, Limit: 1, Color: 255}); err == nil {
		t.Fatal("accepted invalid status mask")
	}
	if _, err := EncodeTaskQuery(TaskQuery{StatusMask: 1, Limit: 1, Sort: TaskQuerySortPriority, Color: 255, Cursor: &TaskQueryCursor{Text: "wrong"}}); err == nil {
		t.Fatal("accepted textual numeric cursor")
	}
	if _, err := EncodeTaskQuery(TaskQuery{StatusMask: 1, Limit: 1, Sort: TaskQuerySortTitle, Color: 255, Cursor: &TaskQueryCursor{Text: string(make([]byte, MaxTaskTitleLength+1))}}); err == nil {
		t.Fatal("accepted oversized cursor text")
	}
	projects := EncodeListTaskProjects(12, 34)
	if len(projects) != 12 || binary.BigEndian.Uint64(projects) != 12 || binary.BigEndian.Uint32(projects[8:]) != 34 {
		t.Fatalf("unexpected projects request: %x", projects)
	}
}

func TestDecodeTaskQueryPageAndProjects(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint64(7))
	buf.WriteByte(1)
	binary.Write(buf, binary.BigEndian, uint16(0))
	buf.WriteByte(0)
	binary.Write(buf, binary.BigEndian, int64(3))
	binary.Write(buf, binary.BigEndian, uint64(9))
	writeString(buf, "cursor")
	binary.Write(buf, binary.BigEndian, uint32(11))
	writeString(buf, "")
	binary.Write(buf, binary.BigEndian, uint32(13))
	page, err := DecodeTaskQueryPage(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if page.NextCursor.Text != "cursor" || page.NextCursor.TaskID != 9 || page.TotalCount != 11 || page.CorrelationID != 13 {
		t.Fatalf("unexpected query page: %+v", page)
	}
	buf.Reset()
	binary.Write(buf, binary.BigEndian, uint64(7))
	binary.Write(buf, binary.BigEndian, uint16(2))
	writeString(buf, "Alpha")
	writeString(buf, "βeta")
	buf.WriteByte(1)
	binary.Write(buf, binary.BigEndian, uint32(4))
	projects, err := DecodeTaskProjects(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if len(projects.Projects) != 2 || projects.Projects[1] != "βeta" || projects.CorrelationID != 4 || !projects.HasMore {
		t.Fatalf("unexpected projects: %+v", projects)
	}
}

func TestDecodeTaskListPage(t *testing.T) {
	task := Task{ID: 9, ConvID: 7, Title: "page"}
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint64(7))
	buf.WriteByte(1)
	binary.Write(buf, binary.BigEndian, uint16(1))
	buf.Write(buildTaskBinary(task))
	buf.WriteByte(1)
	binary.Write(buf, binary.BigEndian, int64(88))
	binary.Write(buf, binary.BigEndian, uint64(9))
	binary.Write(buf, binary.BigEndian, uint32(12))
	writeString(buf, "")
	binary.Write(buf, binary.BigEndian, uint32(55))
	page, err := DecodeTaskListPage(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if !page.Success || !page.HasMore || len(page.Tasks) != 1 || page.NextCursor.SortAt != 88 || page.TotalCount != 12 || page.CorrelationID != 55 {
		t.Fatalf("incorrect page: %+v", page)
	}
}

func TestDecodeTaskFull(t *testing.T) {
	task := Task{ID: 9, ConvID: 7, Title: "full"}
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint64(7))
	buf.WriteByte(1)
	buf.WriteByte(1)
	buf.Write(buildTaskBinary(task))
	writeString(buf, "")
	binary.Write(buf, binary.BigEndian, uint32(66))
	full, err := DecodeTaskFull(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if !full.Success || full.Task == nil || full.Task.ID != 9 || full.CorrelationID != 66 {
		t.Fatalf("incorrect full response: %+v", full)
	}
}

func TestTaskPaginationMalformed(t *testing.T) {
	for _, payload := range [][]byte{nil, make([]byte, 8), append(make([]byte, 8), 2)} {
		if _, err := DecodeTaskListPage(payload); err == nil {
			t.Fatalf("page accepted malformed payload %x", payload)
		}
		if _, err := DecodeTaskFull(payload); err == nil {
			t.Fatalf("full accepted malformed payload %x", payload)
		}
	}
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint64(1))
	buf.WriteByte(1)
	binary.Write(buf, binary.BigEndian, uint16(MaxTaskPageSize+1))
	if _, err := DecodeTaskListPage(buf.Bytes()); err == nil {
		t.Fatal("accepted oversized page")
	}

	full := bytes.NewBuffer(nil)
	binary.Write(full, binary.BigEndian, uint64(1))
	full.WriteByte(1)
	full.WriteByte(0)
	writeString(full, "")
	binary.Write(full, binary.BigEndian, uint32(0))
	full.WriteByte(1)
	if _, err := DecodeTaskFull(full.Bytes()); err == nil {
		t.Fatal("accepted trailing full byte")
	}
}
