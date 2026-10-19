package protocol

import (
	"bytes"
	"encoding/binary"
	"reflect"
	"testing"
)

func dependentsPayload(tasks []Task, success, more byte, next uint64, message string) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint64(7))
	binary.Write(buf, binary.BigEndian, uint64(42))
	buf.WriteByte(success)
	binary.Write(buf, binary.BigEndian, uint16(len(tasks)))
	for _, task := range tasks {
		buf.Write(buildTaskBinary(task))
	}
	buf.WriteByte(more)
	binary.Write(buf, binary.BigEndian, next)
	writeString(buf, message)
	binary.Write(buf, binary.BigEndian, uint32(99))
	return buf.Bytes()
}

func TestTaskDependentsRequestWire(t *testing.T) {
	if C_ListTaskDependents != 64 || S_TaskDependentsPage != 170 {
		t.Fatal("incorrect opcodes")
	}
	for _, limit := range []uint16{1, 100, 1000} {
		for _, after := range []uint64{0, 123, ^uint64(0)} {
			payload, err := EncodeListTaskDependents(7, 42, limit, after, 99)
			if err != nil {
				t.Fatal(err)
			}
			frame, err := (&Message{Opcode: C_ListTaskDependents, Data: payload}).Write()
			if err != nil {
				t.Fatal(err)
			}
			msg, err := ReadMessage(frame)
			if err != nil || len(frame) != 32 || msg.Opcode != 64 || len(msg.Data) != 30 {
				t.Fatalf("incorrect request frame: %x, %v", frame, err)
			}
			p := msg.Data
			if binary.BigEndian.Uint64(p) != 7 || binary.BigEndian.Uint64(p[8:]) != 42 || binary.BigEndian.Uint16(p[16:]) != limit || binary.BigEndian.Uint64(p[18:]) != after || binary.BigEndian.Uint32(p[26:]) != 99 {
				t.Fatalf("incorrect request layout: %x", p)
			}
		}
	}
	for _, limit := range []uint16{0, 1001, 65535} {
		if _, err := EncodeListTaskDependents(7, 42, limit, 0, 99); err == nil {
			t.Fatalf("accepted limit %d", limit)
		}
	}
}

func TestTaskDependentsPageRoundtrip(t *testing.T) {
	for _, count := range []int{0, 1, 100} {
		tasks := make([]Task, count)
		for i := range tasks {
			tasks[i] = Task{ID: uint64(i + 50), ConvID: 7, Title: "dependent ✓", Description: "body", BlockedBy: 42, Project: "project", Attachments: []Attachment{{FileId: "file", Filename: "name", Size: 123}}}
		}
		var next uint64
		if count > 0 {
			next = tasks[count-1].ID
		}
		for _, more := range []byte{0, 1} {
			if count == 0 && more == 1 {
				continue
			}
			payload := dependentsPayload(tasks, 1, more, next, "")
			frame, err := (&Message{Opcode: S_TaskDependentsPage, Data: payload}).Write()
			if err != nil {
				t.Fatal(err)
			}
			wantLen := 36
			for _, task := range tasks {
				wantLen += len(buildTaskBinary(task))
			}
			if len(frame) != wantLen {
				t.Fatalf("frame length %d, want %d", len(frame), wantLen)
			}
			msg, err := ReadMessage(frame)
			if err != nil {
				t.Fatal(err)
			}
			page, err := DecodeTaskDependentsPage(msg.Data)
			if err != nil || !page.Success || page.ConvID != 7 || page.TaskID != 42 || page.CorrelationID != 99 || page.NextTaskID != next || page.HasMore != (more == 1) || len(page.Tasks) != count {
				t.Fatalf("incorrect page: %+v, %v", page, err)
			}
			for i, task := range page.Tasks {
				if !reflect.DeepEqual(*task, tasks[i]) {
					t.Fatalf("task mismatch: %+v, want %+v", task, tasks[i])
				}
			}
			for n := 0; n < len(payload); n++ {
				if _, err := DecodeTaskDependentsPage(payload[:n]); err == nil {
					t.Fatalf("accepted truncation at %d", n)
				}
			}
		}
	}
	page, err := DecodeTaskDependentsPage(dependentsPayload(nil, 0, 0, 0, "not found"))
	if err == nil || page == nil || page.Success || page.ErrorMessage != "not found" || page.CorrelationID != 99 {
		t.Fatalf("lost server error: %+v, %v", page, err)
	}
}

func TestTaskDependentsPageBounds(t *testing.T) {
	valid := dependentsPayload(nil, 1, 0, 0, "")
	badSuccess := bytes.Clone(valid)
	badSuccess[16] = 2
	badCount := bytes.Clone(valid)
	binary.BigEndian.PutUint16(badCount[17:], 1001)
	badMore := bytes.Clone(valid)
	badMore[19] = 2
	for _, payload := range [][]byte{
		badSuccess, badCount, badMore, append(bytes.Clone(valid), 0),
		dependentsPayload(nil, 1, 1, 0, ""),
		dependentsPayload(nil, 1, 0, 1, ""),
		dependentsPayload([]Task{{ID: 5}}, 1, 0, 0, ""),
		dependentsPayload([]Task{{ID: 5}, {ID: 5}}, 1, 0, 5, ""),
		dependentsPayload([]Task{{ID: 6}, {ID: 5}}, 1, 0, 5, ""),
	} {
		if _, err := DecodeTaskDependentsPage(payload); err == nil {
			t.Fatalf("accepted malformed page: %x", payload)
		}
	}
}
