package protocol

import (
	"bytes"
	"encoding/binary"
	"testing"
)

// buildTaskBinary builds a task in server serializeTask wire format.
func buildTaskBinary(t Task) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, t.ID)
	binary.Write(buf, binary.BigEndian, t.ConvID)
	writeString(buf, t.Title)
	writeString(buf, t.Description)
	buf.WriteByte(t.Status)
	binary.Write(buf, binary.BigEndian, t.OrderIndex)
	writeString(buf, t.Assignee)
	buf.WriteByte(t.Priority)
	buf.WriteByte(t.Color)
	writeString(buf, t.CreatedBy)
	binary.Write(buf, binary.BigEndian, t.CreatedAt)
	binary.Write(buf, binary.BigEndian, t.UpdatedAt)
	writeString(buf, t.ExternalRef)
	binary.Write(buf, binary.BigEndian, t.DueAt)
	binary.Write(buf, binary.BigEndian, t.BlockedBy)
	binary.Write(buf, binary.BigEndian, t.CompletedAt)
	writeString(buf, t.CompletedBy)
	writeString(buf, t.Project)
	buf.Write(EncodeAttachments(t.Attachments))
	return buf.Bytes()
}

func TestEncodeTaskCreateWireFormat(t *testing.T) {
	data := EncodeTaskCreate(42, "title", "desc", 3)

	off := 0
	convID := int64(binary.BigEndian.Uint64(data[off:]))
	off += 8
	if convID != 42 {
		t.Errorf("convID = %d, want 42", convID)
	}
	titleLen := binary.BigEndian.Uint16(data[off:])
	off += 2
	if titleLen != 5 {
		t.Errorf("titleLen = %d, want 5", titleLen)
	}
	title := string(data[off : off+int(titleLen)])
	off += int(titleLen)
	if title != "title" {
		t.Errorf("title = %q, want %q", title, "title")
	}
	descLen := binary.BigEndian.Uint16(data[off:])
	off += 2
	if descLen != 4 {
		t.Errorf("descLen = %d, want 4", descLen)
	}
	off += int(descLen)
	// priority: 1 byte (NOT 4!)
	priority := data[off]
	off += 1
	if priority != 3 {
		t.Errorf("priority = %d, want 3", priority)
	}
	// color: 1 byte
	color := data[off]
	off += 1
	if color != 0 {
		t.Errorf("color = %d, want 0", color)
	}
	// ext_ref_len: 2 bytes
	extRefLen := binary.BigEndian.Uint16(data[off:])
	off += 2
	if extRefLen != 0 {
		t.Errorf("extRefLen = %d, want 0", extRefLen)
	}
	// due_at: 8 bytes
	dueAt := int64(binary.BigEndian.Uint64(data[off:]))
	off += 8
	if dueAt != 0 {
		t.Errorf("dueAt = %d, want 0", dueAt)
	}
	// att_count: 2 bytes
	attCount := binary.BigEndian.Uint16(data[off:])
	off += 2
	if attCount != 0 {
		t.Errorf("attCount = %d, want 0", attCount)
	}
	// status + correlation_id
	status := data[off]
	off += 1
	if status != TaskStatusBacklog {
		t.Errorf("status = %d, want %d", status, TaskStatusBacklog)
	}
	corr := binary.BigEndian.Uint32(data[off:])
	off += 4
	if corr != 0 {
		t.Errorf("correlation_id = %d, want 0", corr)
	}
	projectLen := binary.BigEndian.Uint16(data[off:])
	off += 2
	if projectLen != 0 {
		t.Errorf("projectLen = %d, want 0", projectLen)
	}
	if off != len(data) {
		t.Errorf("consumed %d bytes, but data is %d bytes", off, len(data))
	}
}

func TestEncodeTaskCreateWithCorrelationWireFormat(t *testing.T) {
	data := EncodeTaskCreateWithCorrelation(42, "title", "desc", 3, 0xA1B2C3D4)

	if len(data) < 6 {
		t.Fatalf("encoded task create payload too short: %d", len(data))
	}
	gotCorr := binary.BigEndian.Uint32(data[len(data)-6:])
	if gotCorr != 0xA1B2C3D4 {
		t.Fatalf("correlation_id = 0x%08X, want 0xA1B2C3D4", gotCorr)
	}
}

func TestEncodeTaskUpdateWireFormat(t *testing.T) {
	data := EncodeTaskUpdate(10, 20, "newtitle", "newdesc", 2, 5, 42)

	off := 0
	convID := int64(binary.BigEndian.Uint64(data[off:]))
	off += 8
	if convID != 10 {
		t.Errorf("convID = %d, want 10", convID)
	}
	taskID := int64(binary.BigEndian.Uint64(data[off:]))
	off += 8
	if taskID != 20 {
		t.Errorf("taskID = %d, want 20", taskID)
	}
	titleLen := binary.BigEndian.Uint16(data[off:])
	off += 2
	off += int(titleLen)
	descLen := binary.BigEndian.Uint16(data[off:])
	off += 2
	off += int(descLen)
	// status: 1 byte (NOT 4!)
	status := data[off]
	off += 1
	if status != 2 {
		t.Errorf("status = %d, want 2", status)
	}
	// assignee_len(2) = 0
	assigneeLen := binary.BigEndian.Uint16(data[off:])
	off += 2
	if assigneeLen != 0 {
		t.Errorf("assigneeLen = %d, want 0", assigneeLen)
	}
	// priority: 1 byte
	priority := data[off]
	off += 1
	if priority != 5 {
		t.Errorf("priority = %d, want 5", priority)
	}
	// color(1) + ext_ref_len(2)
	off += 1 + 2

	// due_at(8)
	dueAt := int64(binary.BigEndian.Uint64(data[off:]))
	if dueAt != 0 {
		t.Errorf("dueAt = %d, want 0", dueAt)
	}
	off += 8

	// blocked_by(8)
	blockedBy := binary.BigEndian.Uint64(data[off:])
	if blockedBy != 42 {
		t.Errorf("blockedBy = %d, want 42", blockedBy)
	}
	off += 8

	// att_count(2)
	attCount := binary.BigEndian.Uint16(data[off:])
	if attCount != ^uint16(0) {
		t.Errorf("attCount = %d, want %d (preserve)", attCount, ^uint16(0))
	}
	off += 2

	corr := binary.BigEndian.Uint32(data[off:])
	off += 4
	if corr != 0 {
		t.Errorf("correlation_id = %d, want 0", corr)
	}
	projectLen := binary.BigEndian.Uint16(data[off:])
	off += 2
	if projectLen != 0 {
		t.Errorf("projectLen = %d, want 0", projectLen)
	}

	if off != len(data) {
		t.Errorf("consumed %d bytes, but data is %d bytes", off, len(data))
	}
}

func taskUpdateAttachmentCount(data []byte) uint16 {
	off := 16     // conv_id + task_id
	for range 2 { // title, description
		fieldLen := int(binary.BigEndian.Uint16(data[off:]))
		off += 2 + fieldLen
	}
	off++ // status
	assigneeLen := int(binary.BigEndian.Uint16(data[off:]))
	off += 2 + assigneeLen
	off += 2 // priority + color
	externalRefLen := int(binary.BigEndian.Uint16(data[off:]))
	off += 2 + externalRefLen
	off += 16 // due_at + blocked_by
	return binary.BigEndian.Uint16(data[off:])
}

func TestEncodeTaskUpdateAttachmentSemantics(t *testing.T) {
	tests := []struct {
		name        string
		attachments []Attachment
		wantCount   uint16
	}{
		{name: "nil preserves", attachments: nil, wantCount: ^uint16(0)},
		{name: "empty clears", attachments: []Attachment{}, wantCount: 0},
		{
			name:        "populated replaces",
			attachments: []Attachment{{FileId: "file1", Filename: "trace.txt", Size: 64, MimeType: "text/plain", UploadedAt: 123}},
			wantCount:   1,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			data := EncodeTaskUpdateFullWithProjectAndCorrelation(
				10, 20, "", "newdesc", 255, "", 255, TaskColorNone, "", 0, 0,
				test.attachments, "", 99,
			)
			if got := taskUpdateAttachmentCount(data); got != test.wantCount {
				t.Fatalf("attachment count = %d, want %d", got, test.wantCount)
			}
		})
	}
}

func TestEncodeTaskDeleteWireFormat(t *testing.T) {
	data := EncodeTaskDelete(100, 200)
	if len(data) != 20 {
		t.Fatalf("expected 20 bytes, got %d", len(data))
	}
	convID := int64(binary.BigEndian.Uint64(data[0:8]))
	taskID := int64(binary.BigEndian.Uint64(data[8:16]))
	corr := binary.BigEndian.Uint32(data[16:20])
	if convID != 100 {
		t.Errorf("convID = %d, want 100", convID)
	}
	if taskID != 200 {
		t.Errorf("taskID = %d, want 200", taskID)
	}
	if corr != 0 {
		t.Errorf("correlation_id = %d, want 0", corr)
	}
}

func TestEncodeGetTasksWireFormat(t *testing.T) {
	data := EncodeGetTasks(77)
	if len(data) != 12 {
		t.Fatalf("expected 12 bytes, got %d", len(data))
	}
	roomID := int64(binary.BigEndian.Uint64(data[0:8]))
	corr := binary.BigEndian.Uint32(data[8:12])
	if roomID != 77 {
		t.Errorf("roomID = %d, want 77", roomID)
	}
	if corr != 0 {
		t.Errorf("correlation_id = %d, want 0", corr)
	}
}

func TestDecodeTaskBinary(t *testing.T) {
	want := Task{
		ID:          12345,
		ConvID:      42,
		Title:       "Fix the build",
		Description: "It's broken",
		Status:      TaskStatusInProgress,
		OrderIndex:  3,
		Assignee:    "alice",
		Priority:    2,
		Color:       TaskColorCyan,
		CreatedBy:   "bob",
		CreatedAt:   1700000000,
		UpdatedAt:   1700001000,
		ExternalRef: "PROJ-123",
		DueAt:       1700100000,
		BlockedBy:   99,
		CompletedAt: 0,
		CompletedBy: "",
		Project:     "heavyhorst/nrc",
		Attachments: nil,
	}

	data := buildTaskBinary(want)
	buf := bytes.NewReader(data)
	got, err := DecodeTaskBinary(buf)
	if err != nil {
		t.Fatalf("DecodeTaskBinary error: %v", err)
	}

	if got.ID != want.ID {
		t.Errorf("ID = %d, want %d", got.ID, want.ID)
	}
	if got.ConvID != want.ConvID {
		t.Errorf("ConvID = %d, want %d", got.ConvID, want.ConvID)
	}
	if got.Title != want.Title {
		t.Errorf("Title = %q, want %q", got.Title, want.Title)
	}
	if got.Description != want.Description {
		t.Errorf("Description = %q, want %q", got.Description, want.Description)
	}
	if got.Status != want.Status {
		t.Errorf("Status = %d, want %d", got.Status, want.Status)
	}
	if got.OrderIndex != want.OrderIndex {
		t.Errorf("OrderIndex = %d, want %d", got.OrderIndex, want.OrderIndex)
	}
	if got.Assignee != want.Assignee {
		t.Errorf("Assignee = %q, want %q", got.Assignee, want.Assignee)
	}
	if got.Priority != want.Priority {
		t.Errorf("Priority = %d, want %d", got.Priority, want.Priority)
	}
	if got.Color != want.Color {
		t.Errorf("Color = %d, want %d", got.Color, want.Color)
	}
	if got.CreatedBy != want.CreatedBy {
		t.Errorf("CreatedBy = %q, want %q", got.CreatedBy, want.CreatedBy)
	}
	if got.CreatedAt != want.CreatedAt {
		t.Errorf("CreatedAt = %d, want %d", got.CreatedAt, want.CreatedAt)
	}
	if got.UpdatedAt != want.UpdatedAt {
		t.Errorf("UpdatedAt = %d, want %d", got.UpdatedAt, want.UpdatedAt)
	}
	if got.ExternalRef != want.ExternalRef {
		t.Errorf("ExternalRef = %q, want %q", got.ExternalRef, want.ExternalRef)
	}
	if got.DueAt != want.DueAt {
		t.Errorf("DueAt = %d, want %d", got.DueAt, want.DueAt)
	}
	if got.BlockedBy != want.BlockedBy {
		t.Errorf("BlockedBy = %d, want %d", got.BlockedBy, want.BlockedBy)
	}
	if got.CompletedAt != want.CompletedAt {
		t.Errorf("CompletedAt = %d, want %d", got.CompletedAt, want.CompletedAt)
	}
	if got.CompletedBy != want.CompletedBy {
		t.Errorf("CompletedBy = %q, want %q", got.CompletedBy, want.CompletedBy)
	}
	if got.Project != want.Project {
		t.Errorf("Project = %q, want %q", got.Project, want.Project)
	}
	if len(got.Attachments) != 0 {
		t.Errorf("Attachments len = %d, want 0", len(got.Attachments))
	}
}

func TestDecodeTaskBinaryWithAttachments(t *testing.T) {
	want := Task{
		ID: 1, ConvID: 2, Title: "test", Status: TaskStatusDone,
		CreatedBy: "sys", CreatedAt: 100, UpdatedAt: 200,
		CompletedAt: 150, CompletedBy: "sys",
		Attachments: []Attachment{
			{FileId: "att_abc123", Filename: "report.pdf", Size: 1024, MimeType: "application/pdf", UploadedAt: 100},
			{FileId: "att_def456", Filename: "img.png", Size: 2048, MimeType: "image/png", UploadedAt: 200},
		},
	}

	data := buildTaskBinary(want)
	got, err := DecodeTaskBinary(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("DecodeTaskBinary error: %v", err)
	}

	if len(got.Attachments) != 2 {
		t.Fatalf("Attachments len = %d, want 2", len(got.Attachments))
	}
	if got.Attachments[0].FileId != "att_abc123" {
		t.Errorf("att[0].FileId = %q, want %q", got.Attachments[0].FileId, "att_abc123")
	}
	if got.Attachments[0].Size != 1024 {
		t.Errorf("att[0].Size = %d, want 1024", got.Attachments[0].Size)
	}
	if got.Attachments[1].MimeType != "image/png" {
		t.Errorf("att[1].MimeType = %q, want %q", got.Attachments[1].MimeType, "image/png")
	}
	if got.CompletedAt != 150 {
		t.Errorf("CompletedAt = %d, want 150", got.CompletedAt)
	}
	if got.CompletedBy != "sys" {
		t.Errorf("CompletedBy = %q, want %q", got.CompletedBy, "sys")
	}
}

func TestDecodeTaskBinaryAllStatuses(t *testing.T) {
	statuses := []uint8{TaskStatusBacklog, TaskStatusTodo, TaskStatusInProgress, TaskStatusDone, TaskStatusNote}
	for _, s := range statuses {
		task := Task{ID: 1, Status: s}
		data := buildTaskBinary(task)
		got, err := DecodeTaskBinary(bytes.NewReader(data))
		if err != nil {
			t.Fatalf("status %d: %v", s, err)
		}
		if got.Status != s {
			t.Errorf("status round-trip: got %d, want %d", got.Status, s)
		}
	}
}

func TestDecodeTaskBinaryMultiple(t *testing.T) {
	t1 := Task{ID: 1, ConvID: 10, Title: "first", Status: TaskStatusTodo, CreatedBy: "a"}
	t2 := Task{ID: 2, ConvID: 10, Title: "second", Status: TaskStatusDone, CreatedBy: "b", CompletedAt: 999, CompletedBy: "b"}

	var combined bytes.Buffer
	combined.Write(buildTaskBinary(t1))
	combined.Write(buildTaskBinary(t2))

	reader := bytes.NewReader(combined.Bytes())

	got1, err := DecodeTaskBinary(reader)
	if err != nil {
		t.Fatalf("task 1: %v", err)
	}
	if got1.ID != 1 || got1.Title != "first" {
		t.Errorf("task 1: ID=%d Title=%q", got1.ID, got1.Title)
	}

	got2, err := DecodeTaskBinary(reader)
	if err != nil {
		t.Fatalf("task 2: %v", err)
	}
	if got2.ID != 2 || got2.Title != "second" || got2.CompletedBy != "b" {
		t.Errorf("task 2: ID=%d Title=%q CompletedBy=%q", got2.ID, got2.Title, got2.CompletedBy)
	}
}

func TestDecodeTaskBinaryTruncated(t *testing.T) {
	task := Task{ID: 1, ConvID: 10, Title: "test", CreatedBy: "x"}
	data := buildTaskBinary(task)

	truncPoints := []int{0, 1, 8, 16, 20}
	for _, n := range truncPoints {
		if n > len(data) {
			continue
		}
		_, err := DecodeTaskBinary(bytes.NewReader(data[:n]))
		if err == nil {
			t.Errorf("expected error for %d-byte truncated data", n)
		}
	}
}

func TestDecodeTaskCreated(t *testing.T) {
	want := Task{
		ID:          987,
		ConvID:      42,
		Title:       "persist me",
		Description: "task payload",
		Status:      TaskStatusTodo,
		CreatedBy:   "alice",
		CreatedAt:   100,
		UpdatedAt:   100,
	}

	var payload bytes.Buffer
	payload.Write(buildTaskBinary(want))
	binary.Write(&payload, binary.BigEndian, uint32(1234))

	decoded, err := DecodeTaskCreated(payload.Bytes())
	if err != nil {
		t.Fatalf("DecodeTaskCreated error: %v", err)
	}

	if decoded.CorrelationID != 1234 {
		t.Fatalf("CorrelationID = %d, want 1234", decoded.CorrelationID)
	}
	if decoded.Task.ID != want.ID {
		t.Fatalf("Task.ID = %d, want %d", decoded.Task.ID, want.ID)
	}
	if decoded.Task.Title != want.Title {
		t.Fatalf("Task.Title = %q, want %q", decoded.Task.Title, want.Title)
	}
}

func TestDecodeTaskCreatedTruncatedCorrelationID(t *testing.T) {
	task := Task{ID: 1, Title: "x"}
	data := buildTaskBinary(task)

	_, err := DecodeTaskCreated(data)
	if err == nil {
		t.Fatal("expected error for missing correlation_id")
	}
}

func TestDecodeTaskCreatedTrailingData(t *testing.T) {
	task := Task{ID: 1, Title: "x"}

	var payload bytes.Buffer
	payload.Write(buildTaskBinary(task))
	binary.Write(&payload, binary.BigEndian, uint32(77))
	payload.WriteByte(0xff)

	_, err := DecodeTaskCreated(payload.Bytes())
	if err == nil {
		t.Fatal("expected error for trailing bytes")
	}
}

func TestAttachmentsRoundTrip(t *testing.T) {
	atts := []Attachment{
		{FileId: "id1", Filename: "f1.txt", Size: 100, MimeType: "text/plain", UploadedAt: 1000},
		{FileId: "id2", Filename: "f2.bin", Size: 999999, MimeType: "application/octet-stream", UploadedAt: 2000},
	}

	encoded := EncodeAttachments(atts)
	decoded, err := DecodeAttachments(bytes.NewReader(encoded))
	if err != nil {
		t.Fatalf("DecodeAttachments error: %v", err)
	}

	if len(decoded) != len(atts) {
		t.Fatalf("len = %d, want %d", len(decoded), len(atts))
	}
	for i := range atts {
		if decoded[i].FileId != atts[i].FileId {
			t.Errorf("[%d] FileId = %q, want %q", i, decoded[i].FileId, atts[i].FileId)
		}
		if decoded[i].Filename != atts[i].Filename {
			t.Errorf("[%d] Filename = %q, want %q", i, decoded[i].Filename, atts[i].Filename)
		}
		if decoded[i].Size != atts[i].Size {
			t.Errorf("[%d] Size = %d, want %d", i, decoded[i].Size, atts[i].Size)
		}
		if decoded[i].MimeType != atts[i].MimeType {
			t.Errorf("[%d] MimeType = %q, want %q", i, decoded[i].MimeType, atts[i].MimeType)
		}
		if decoded[i].UploadedAt != atts[i].UploadedAt {
			t.Errorf("[%d] UploadedAt = %d, want %d", i, decoded[i].UploadedAt, atts[i].UploadedAt)
		}
	}
}

func TestAttachmentsEmpty(t *testing.T) {
	encoded := EncodeAttachments(nil)
	decoded, err := DecodeAttachments(bytes.NewReader(encoded))
	if err != nil {
		t.Fatal(err)
	}
	if len(decoded) != 0 {
		t.Errorf("expected 0 attachments, got %d", len(decoded))
	}
}

func TestEncodeTaskCreateWithAttachments(t *testing.T) {
	atts := []Attachment{
		{FileId: "file1", Filename: "test.txt", Size: 42, MimeType: "text/plain", UploadedAt: 100},
	}
	data := EncodeTaskCreateWithAttachments(10, "title", "desc", 1, atts)

	off := 0
	off += 8     // conv_id
	off += 2 + 5 // title_len + "title"
	off += 2 + 4 // desc_len + "desc"
	off += 1     // priority
	off += 1     // color
	off += 2     // ext_ref_len
	off += 8     // due_at
	attCount := binary.BigEndian.Uint16(data[off:])
	off += 2
	if attCount != 1 {
		t.Errorf("attCount = %d, want 1", attCount)
	}
	if off >= len(data) {
		t.Error("expected attachment data after att_count")
	}
}

func TestEncodeTaskUpdateWithCorrelationWireFormat(t *testing.T) {
	data := EncodeTaskUpdateWithCorrelation(10, 20, "newtitle", "newdesc", 2, 5, 42, 0x11112222)
	if len(data) < 6 {
		t.Fatalf("encoded update payload too short: %d", len(data))
	}
	gotCorr := binary.BigEndian.Uint32(data[len(data)-6:])
	if gotCorr != 0x11112222 {
		t.Fatalf("correlation_id = 0x%08X, want 0x11112222", gotCorr)
	}
}

func TestEncodeTaskUpdateFullWithCorrelationWireFormat(t *testing.T) {
	attachments := []Attachment{{FileId: "file1", Filename: "trace.txt", Size: 64, MimeType: "text/plain", UploadedAt: 123}}
	data := EncodeTaskUpdateFullWithProjectAndCorrelation(10, 20, "newtitle", "newdesc", TaskStatusDone, "alice", 7, TaskColorGold, "EXT-1", 99, 42, attachments, "heavyhorst/nrc", 0x11112222)

	off := 0
	off += 8 // conv_id
	off += 8 // task_id
	off += 2 + len("newtitle")
	off += 2 + len("newdesc")
	if got := data[off]; got != TaskStatusDone {
		t.Fatalf("status = %d, want %d", got, TaskStatusDone)
	}
	off++
	assigneeLen := int(binary.BigEndian.Uint16(data[off:]))
	off += 2
	if got := string(data[off : off+assigneeLen]); got != "alice" {
		t.Fatalf("assignee = %q, want alice", got)
	}
	off += assigneeLen
	if got := data[off]; got != 7 {
		t.Fatalf("priority = %d, want 7", got)
	}
	off++
	if got := data[off]; got != TaskColorGold {
		t.Fatalf("color = %d, want %d", got, TaskColorGold)
	}
	off++
	extLen := int(binary.BigEndian.Uint16(data[off:]))
	off += 2
	if got := string(data[off : off+extLen]); got != "EXT-1" {
		t.Fatalf("external_ref = %q, want EXT-1", got)
	}
	off += extLen
	if got := int64(binary.BigEndian.Uint64(data[off:])); got != 99 {
		t.Fatalf("due_at = %d, want 99", got)
	}
	off += 8
	if got := binary.BigEndian.Uint64(data[off:]); got != 42 {
		t.Fatalf("blocked_by = %d, want 42", got)
	}
	off += 8
	if got := binary.BigEndian.Uint16(data[off:]); got != 1 {
		t.Fatalf("attachment count = %d, want 1", got)
	}
	off += 2
	off += 2 + len("file1") + 2 + len("trace.txt") + 8 + 2 + len("text/plain") + 8
	if gotCorr := binary.BigEndian.Uint32(data[off:]); gotCorr != 0x11112222 {
		t.Fatalf("correlation_id = 0x%08X, want 0x11112222", gotCorr)
	}
	off += 4
	projectLen := int(binary.BigEndian.Uint16(data[off:]))
	off += 2
	if got := string(data[off : off+projectLen]); got != "heavyhorst/nrc" {
		t.Fatalf("project = %q, want heavyhorst/nrc", got)
	}
}

func TestEncodeTaskDeleteWithCorrelationWireFormat(t *testing.T) {
	data := EncodeTaskDeleteWithCorrelation(100, 200, 0xAABBCCDD)
	if len(data) != 20 {
		t.Fatalf("expected 20 bytes, got %d", len(data))
	}
	if got := binary.BigEndian.Uint32(data[16:20]); got != 0xAABBCCDD {
		t.Fatalf("correlation_id = 0x%08X, want 0xAABBCCDD", got)
	}
}

func TestEncodeTaskMoveWithCorrelationWireFormat(t *testing.T) {
	data := EncodeTaskMoveWithCorrelation(10, 20, TaskStatusDone, 3, 0x01020304)
	if len(data) != 24 {
		t.Fatalf("expected 24 bytes, got %d", len(data))
	}
	if got := binary.BigEndian.Uint64(data[0:8]); got != 10 {
		t.Fatalf("conv_id = %d, want 10", got)
	}
	if got := binary.BigEndian.Uint64(data[8:16]); got != 20 {
		t.Fatalf("task_id = %d, want 20", got)
	}
	if data[16] != TaskStatusDone {
		t.Fatalf("status = %d, want %d", data[16], TaskStatusDone)
	}
	if data[17] != 0 {
		t.Fatalf("flags = %d, want 0 for a named position", data[17])
	}
	if got := binary.BigEndian.Uint16(data[18:20]); got != 3 {
		t.Fatalf("order_index = %d, want 3", got)
	}
	if got := binary.BigEndian.Uint32(data[20:24]); got != 0x01020304 {
		t.Fatalf("correlation_id = 0x%08X, want 0x01020304", got)
	}
}

func TestEncodeTaskMoveAppendWireFormat(t *testing.T) {
	data := EncodeTaskMoveAppendWithCorrelation(10, 20, TaskStatusDone, 0x01020304)
	if len(data) != 24 {
		t.Fatalf("expected 24 bytes, got %d", len(data))
	}
	if data[17] != TaskMoveAppend {
		t.Fatalf("flags = %d, want %d", data[17], TaskMoveAppend)
	}
	// The append flag is what asks for the end of the column; the position it
	// carries is the server's to fold and is sent as zero.
	if got := binary.BigEndian.Uint16(data[18:20]); got != 0 {
		t.Fatalf("order_index = %d, want 0", got)
	}
	if got := binary.BigEndian.Uint32(data[20:24]); got != 0x01020304 {
		t.Fatalf("correlation_id = 0x%08X, want 0x01020304", got)
	}
}

func TestEncodeGetTasksWithCorrelationWireFormat(t *testing.T) {
	data := EncodeGetTasksWithCorrelation(77, 0xFEEDBEEF)
	if len(data) != 12 {
		t.Fatalf("expected 12 bytes, got %d", len(data))
	}
	if got := binary.BigEndian.Uint32(data[8:12]); got != 0xFEEDBEEF {
		t.Fatalf("correlation_id = 0x%08X, want 0xFEEDBEEF", got)
	}
}

func TestDecodeTaskUpdated(t *testing.T) {
	task := Task{ID: 5, ConvID: 1, Title: "u", CreatedBy: "bot"}
	var payload bytes.Buffer
	payload.Write(buildTaskBinary(task))
	binary.Write(&payload, binary.BigEndian, uint32(99))

	decoded, err := DecodeTaskUpdated(payload.Bytes())
	if err != nil {
		t.Fatalf("DecodeTaskUpdated error: %v", err)
	}
	if decoded.CorrelationID != 99 {
		t.Fatalf("CorrelationID = %d, want 99", decoded.CorrelationID)
	}
	if decoded.Task.ID != 5 {
		t.Fatalf("Task.ID = %d, want 5", decoded.Task.ID)
	}
}

func TestDecodeTaskDeleted(t *testing.T) {
	payload := make([]byte, 20)
	binary.BigEndian.PutUint64(payload[0:8], 111)
	binary.BigEndian.PutUint64(payload[8:16], 222)
	binary.BigEndian.PutUint32(payload[16:20], 333)

	decoded, err := DecodeTaskDeleted(payload)
	if err != nil {
		t.Fatalf("DecodeTaskDeleted error: %v", err)
	}
	if decoded.TaskID != 111 || decoded.ConvID != 222 || decoded.CorrelationID != 333 {
		t.Fatalf("unexpected decoded task deleted payload: %+v", decoded)
	}
}

func TestDecodeTaskMoved(t *testing.T) {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint64(9))
	binary.Write(buf, binary.BigEndian, uint64(1))
	buf.WriteByte(TaskStatusDone)
	binary.Write(buf, binary.BigEndian, uint16(7))
	binary.Write(buf, binary.BigEndian, int64(1234))
	writeString(buf, "alice")
	binary.Write(buf, binary.BigEndian, uint32(0xAA55AA55))

	decoded, err := DecodeTaskMoved(buf.Bytes())
	if err != nil {
		t.Fatalf("DecodeTaskMoved error: %v", err)
	}
	if decoded.CorrelationID != 0xAA55AA55 {
		t.Fatalf("CorrelationID = 0x%08X, want 0xAA55AA55", decoded.CorrelationID)
	}
	if decoded.CompletedBy != "alice" {
		t.Fatalf("CompletedBy = %q, want alice", decoded.CompletedBy)
	}
}

func TestDecodeTaskListResponseCorrelation(t *testing.T) {
	task := Task{ID: 7, ConvID: 1, Title: "t", CreatedBy: "bot"}
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint64(1)) // conv_id
	buf.WriteByte(1)                               // success
	binary.Write(buf, binary.BigEndian, uint16(1)) // count
	buf.Write(buildTaskBinary(task))
	writeString(buf, "")
	binary.Write(buf, binary.BigEndian, uint32(0x12345678))

	resp, err := DecodeTaskListResponse(buf.Bytes())
	if err != nil {
		t.Fatalf("DecodeTaskListResponse error: %v", err)
	}
	if resp.CorrelationID != 0x12345678 {
		t.Fatalf("CorrelationID = 0x%08X, want 0x12345678", resp.CorrelationID)
	}
}
