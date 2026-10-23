package protocol

import (
	"bytes"
	"encoding/binary"
	"fmt"
)

// EncodeListTaskDependents encodes the 30-byte C_ListTaskDependents payload
// (without the opcode). Results are ascending by task ID, exclusively after
// afterTaskID; zero requests the initial page.
func EncodeListTaskDependents(convID, taskID uint64, limit uint16, afterTaskID uint64, correlationID uint32) ([]byte, error) {
	if limit == 0 || limit > MaxTaskPageSize {
		return nil, fmt.Errorf("task dependents limit must be between 1 and %d", MaxTaskPageSize)
	}
	payload := make([]byte, 30)
	binary.BigEndian.PutUint64(payload, convID)
	binary.BigEndian.PutUint64(payload[8:], taskID)
	binary.BigEndian.PutUint16(payload[16:], limit)
	binary.BigEndian.PutUint64(payload[18:], afterTaskID)
	binary.BigEndian.PutUint32(payload[26:], correlationID)
	return payload, nil
}

// TaskDependentsPage represents S_TaskDependentsPage. There is no total count.
// NextTaskID is the last returned task ID, or zero for an empty page, even when
// HasMore is false.
type TaskDependentsPage struct {
	ConvID        uint64
	TaskID        uint64
	Success       bool
	Tasks         []*Task
	HasMore       bool
	NextTaskID    uint64
	ErrorMessage  string
	CorrelationID uint32
}

// DecodeTaskDependentsPage strictly decodes a payload without its opcode.
// As with DecodeTaskListPage, a server failure returns both the page and an error.
func DecodeTaskDependentsPage(payload []byte) (*TaskDependentsPage, error) {
	buf := bytes.NewReader(payload)
	page := &TaskDependentsPage{}
	var success, more uint8
	var count uint16
	if binary.Read(buf, binary.BigEndian, &page.ConvID) != nil || binary.Read(buf, binary.BigEndian, &page.TaskID) != nil || binary.Read(buf, binary.BigEndian, &success) != nil || success > 1 || binary.Read(buf, binary.BigEndian, &count) != nil || count > MaxTaskPageSize {
		return nil, fmt.Errorf("invalid task dependents header")
	}
	page.Tasks = make([]*Task, 0, recordCapacity(int(count)))
	var lastID uint64
	for i := 0; i < int(count); i++ {
		task, err := DecodeTaskBinary(buf)
		if err != nil {
			return nil, fmt.Errorf("task dependent %d: %w", i, err)
		}
		if task.ID <= lastID {
			return nil, fmt.Errorf("task dependents must have ascending IDs")
		}
		page.Tasks = append(page.Tasks, task)
		lastID = task.ID
	}
	if binary.Read(buf, binary.BigEndian, &more) != nil || more > 1 || binary.Read(buf, binary.BigEndian, &page.NextTaskID) != nil {
		return nil, fmt.Errorf("invalid task dependents continuation")
	}
	message, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("task dependents error: %w", err)
	}
	page.ErrorMessage = message
	if binary.Read(buf, binary.BigEndian, &page.CorrelationID) != nil || buf.Len() != 0 {
		return nil, fmt.Errorf("invalid task dependents tail")
	}
	page.Success, page.HasMore = success == 1, more == 1
	if page.NextTaskID != lastID || page.HasMore && count == 0 {
		return nil, fmt.Errorf("invalid task dependents cursor")
	}
	if !page.Success {
		return page, fmt.Errorf("server error: %s", page.ErrorMessage)
	}
	return page, nil
}
