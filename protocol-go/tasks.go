package protocol

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"unicode/utf8"
)

// Attachment represents a file attachment
type Attachment struct {
	FileId     string
	Filename   string
	Size       int64
	MimeType   string
	UploadedAt int64
}

// Task represents a kanban task matching server wire format
type Task struct {
	ID          uint64
	ConvID      int64
	Title       string
	Description string
	Status      uint8
	OrderIndex  uint16
	Assignee    string
	Priority    uint8
	Color       uint8
	CreatedBy   string
	CreatedAt   int64
	UpdatedAt   int64
	ExternalRef string
	DueAt       int64
	BlockedBy   uint64
	CompletedAt int64
	CompletedBy string
	Project     string
	Attachments []Attachment
}

// TaskCreatedResponse represents a decoded S_TaskCreated payload.
// Wire format: task(...) + correlation_id(4)
type TaskCreatedResponse struct {
	Task          *Task
	CorrelationID uint32
}

// TaskUpdatedResponse represents a decoded S_TaskUpdated payload.
// Wire format: task(...) + correlation_id(4)
type TaskUpdatedResponse struct {
	Task          *Task
	CorrelationID uint32
}

// TaskDeletedResponse represents a decoded S_TaskDeleted payload.
// Wire format: task_id(8) + conv_id(8) + correlation_id(4)
type TaskDeletedResponse struct {
	TaskID        uint64
	ConvID        uint64
	CorrelationID uint32
}

// TaskMovedResponse represents a decoded S_TaskMoved payload.
// Wire format: task_id(8) + conv_id(8) + status(1) + order_index(2) + completed_at(8) + completed_by_len(2) + completed_by + correlation_id(4)
type TaskMovedResponse struct {
	TaskID        uint64
	ConvID        uint64
	Status        uint8
	OrderIndex    uint16
	CompletedAt   int64
	CompletedBy   string
	CorrelationID uint32
}

// EncodeTaskCreate encodes a task for C_CreateTask.
// Wire format: conv_id(8) + title_len(2) + title + desc_len(2) + desc + priority(1) +
// color(1) + ext_ref_len(2) + ext_ref + due_at(8) + att_count(2) + attachments...
func EncodeTaskCreate(convID int64, title, description string, priority int32) []byte {
	return EncodeTaskCreateWithAttachments(convID, title, description, priority, nil)
}

// EncodeTaskCreateWithCorrelation encodes a task for C_CreateTask with a trailing correlation_id.
func EncodeTaskCreateWithCorrelation(convID int64, title, description string, priority int32, correlationID uint32) []byte {
	return EncodeTaskCreateWithAttachmentsAndCorrelation(convID, title, description, priority, nil, correlationID)
}

// EncodeTaskCreateWithAttachments encodes a task for C_CreateTask with attachments.
func EncodeTaskCreateWithAttachments(convID int64, title, description string, priority int32, attachments []Attachment) []byte {
	return EncodeTaskCreateWithAttachmentsAndCorrelation(convID, title, description, priority, attachments, 0)
}

// EncodeTaskCreateWithAttachmentsAndCorrelation encodes a task for C_CreateTask with attachments and a trailing correlation_id.
func EncodeTaskCreateWithAttachmentsAndCorrelation(convID int64, title, description string, priority int32, attachments []Attachment, correlationID uint32) []byte {
	return EncodeTaskCreateFullWithCorrelation(convID, title, description, priority, "", attachments, correlationID)
}

// EncodeTaskCreateFullWithCorrelation encodes C_CreateTask with all mutable create fields and a trailing correlation_id.
func EncodeTaskCreateFullWithCorrelation(convID int64, title, description string, priority int32, project string, attachments []Attachment, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	writeString(buf, title)
	writeString(buf, description)
	buf.WriteByte(byte(priority))                  // priority (1 byte)
	buf.WriteByte(0)                               // color (1 byte, default 0)
	binary.Write(buf, binary.BigEndian, uint16(0)) // ext_ref_len = 0
	binary.Write(buf, binary.BigEndian, int64(0))  // due_at = 0 (no due date)

	if len(attachments) > 0 {
		buf.Write(EncodeAttachments(attachments))
	} else {
		binary.Write(buf, binary.BigEndian, uint16(0)) // att_count = 0
	}

	// Server expects status before trailing correlation_id.
	buf.WriteByte(TaskStatusBacklog)
	binary.Write(buf, binary.BigEndian, correlationID)
	writeString(buf, project)

	return buf.Bytes()
}

// EncodeTaskUpdate encodes a task update for C_UpdateTask.
// Wire format: conv_id(8) + task_id(8) + title_len(2) + title + desc_len(2) + desc +
// status(1) + assignee_len(2) + assignee + priority(1) + color(1) + ext_ref_len(2) +
// ext_ref + due_at(8) + blocked_by(8) + att_count(2) + attachments...
func EncodeTaskUpdate(convID, taskID int64, title, description string, status, priority int32, blockedBy uint64) []byte {
	return EncodeTaskUpdateWithAttachmentsAndCorrelation(convID, taskID, title, description, status, priority, blockedBy, nil, 0)
}

// EncodeTaskUpdateWithCorrelation encodes a task update with a trailing correlation_id.
func EncodeTaskUpdateWithCorrelation(convID, taskID int64, title, description string, status, priority int32, blockedBy uint64, correlationID uint32) []byte {
	return EncodeTaskUpdateWithAttachmentsAndCorrelation(convID, taskID, title, description, status, priority, blockedBy, nil, correlationID)
}

// EncodeTaskUpdateWithAttachments encodes a task update with attachments.
func EncodeTaskUpdateWithAttachments(convID, taskID int64, title, description string, status, priority int32, blockedBy uint64, attachments []Attachment) []byte {
	return EncodeTaskUpdateWithAttachmentsAndCorrelation(convID, taskID, title, description, status, priority, blockedBy, attachments, 0)
}

// EncodeTaskUpdateWithAttachmentsAndCorrelation encodes a task update with attachments and trailing correlation_id.
func EncodeTaskUpdateWithAttachmentsAndCorrelation(convID, taskID int64, title, description string, status, priority int32, blockedBy uint64, attachments []Attachment, correlationID uint32) []byte {
	return EncodeTaskUpdateFullWithCorrelation(convID, taskID, title, description, uint8(status), "", uint8(priority), TaskColorNone, "", 0, blockedBy, attachments, correlationID)
}

// EncodeTaskUpdateFullWithCorrelation encodes C_UpdateTask with all mutable fields and trailing correlation_id.
func EncodeTaskUpdateFullWithCorrelation(convID, taskID int64, title, description string, status uint8, assignee string, priority uint8, color uint8, externalRef string, dueAt int64, blockedBy uint64, attachments []Attachment, correlationID uint32) []byte {
	return EncodeTaskUpdateFullWithProjectAndCorrelation(convID, taskID, title, description, status, assignee, priority, color, externalRef, dueAt, blockedBy, attachments, "", correlationID)
}

// EncodeTaskUpdateFullWithProjectAndCorrelation encodes C_UpdateTask with all mutable fields and trailing correlation_id.
// A nil attachment slice preserves the current server-side list; a non-nil
// empty slice clears it, and a populated slice replaces it.
func EncodeTaskUpdateFullWithProjectAndCorrelation(convID, taskID int64, title, description string, status uint8, assignee string, priority uint8, color uint8, externalRef string, dueAt int64, blockedBy uint64, attachments []Attachment, project string, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, taskID)
	writeString(buf, title)
	writeString(buf, description)
	buf.WriteByte(status)
	writeString(buf, assignee)
	buf.WriteByte(priority)
	buf.WriteByte(color)
	writeString(buf, externalRef)
	binary.Write(buf, binary.BigEndian, dueAt)
	binary.Write(buf, binary.BigEndian, blockedBy)

	if attachments == nil {
		binary.Write(buf, binary.BigEndian, ^uint16(0)) // preserve existing attachments
	} else {
		buf.Write(EncodeAttachments(attachments))
	}

	binary.Write(buf, binary.BigEndian, correlationID)
	writeString(buf, project)

	return buf.Bytes()
}

// EncodeTaskDelete encodes a task delete for C_DeleteTask. Format: conv_id(8) + task_id(8)
func EncodeTaskDelete(convID, taskID int64) []byte {
	return EncodeTaskDeleteWithCorrelation(convID, taskID, 0)
}

// EncodeTaskDeleteWithCorrelation encodes a task delete for C_DeleteTask with a trailing correlation_id.
func EncodeTaskDeleteWithCorrelation(convID, taskID int64, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, taskID)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// EncodeTaskMove encodes C_MoveTask request with a named position.
// Wire format: conv_id(8) + task_id(8) + status(1) + flags(1) + order_index(2)
func EncodeTaskMove(convID, taskID int64, status uint8, orderIndex uint16) []byte {
	return EncodeTaskMoveWithCorrelation(convID, taskID, status, orderIndex, 0)
}

// TaskMoveAppend asks the server to put the task at the end of the target status
// column and ignore the named position: a client that draws one page of a
// register does not hold the column, and the column order is the server's to
// fold. It mirrors protocol MoveTaskFlags.Append, and the acknowledgement carries
// the position the server folded.
const TaskMoveAppend uint8 = 1 << 0

// EncodeTaskMoveAppend encodes C_MoveTask that asks for the end of the target column.
func EncodeTaskMoveAppend(convID, taskID int64, status uint8) []byte {
	return EncodeTaskMoveAppendWithCorrelation(convID, taskID, status, 0)
}

// EncodeTaskMoveAppendWithCorrelation encodes an append move with a trailing correlation_id.
func EncodeTaskMoveAppendWithCorrelation(convID, taskID int64, status uint8, correlationID uint32) []byte {
	return encodeTaskMove(convID, taskID, status, TaskMoveAppend, 0, correlationID)
}

// EncodeTaskMoveWithCorrelation encodes C_MoveTask request with a trailing correlation_id.
func EncodeTaskMoveWithCorrelation(convID, taskID int64, status uint8, orderIndex uint16, correlationID uint32) []byte {
	return encodeTaskMove(convID, taskID, status, 0, orderIndex, correlationID)
}

func encodeTaskMove(convID, taskID int64, status uint8, flags uint8, orderIndex uint16, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, convID)
	binary.Write(buf, binary.BigEndian, taskID)
	buf.WriteByte(status)
	buf.WriteByte(flags)
	binary.Write(buf, binary.BigEndian, orderIndex)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// EncodeGetTasks encodes a C_GetTasks request. Format: room_id(8)
func EncodeGetTasks(roomID int64) []byte {
	return EncodeGetTasksWithCorrelation(roomID, 0)
}

// EncodeGetTasksWithCorrelation encodes a C_GetTasks request with a trailing correlation_id.
func EncodeGetTasksWithCorrelation(roomID int64, correlationID uint32) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, roomID)
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes()
}

// TaskPageCursor is the keyset cursor used by C_ListTasksPaged.
type TaskPageCursor struct {
	SortAt int64
	TaskID uint64
}

type TaskQuerySort uint8

const (
	TaskQuerySortPriority TaskQuerySort = iota
	TaskQuerySortStatus
	TaskQuerySortAssignee
	TaskQuerySortDueAt
	TaskQuerySortCreatedAt
	TaskQuerySortTitle
	TaskQuerySortColor
	TaskQuerySortProject
)

type TaskQueryCursor struct {
	Number int64
	Text   string
	TaskID uint64
}
type TaskQuery struct {
	ConvID        uint64
	StatusMask    uint8
	Limit         uint16
	Sort          TaskQuerySort
	Descending    bool
	Color         uint8
	Blocked       uint8
	OverdueBefore int64
	Assignee      *string
	Project       *string
	Cursor        *TaskQueryCursor
	CorrelationID uint32
}

// EncodeTaskQuery encodes C_QueryTasks. Cursor fields are present even without a cursor.
func EncodeTaskQuery(q TaskQuery) ([]byte, error) {
	if q.StatusMask == 0 || q.StatusMask&^0x0f != 0 || q.Limit == 0 || q.Limit > MaxTaskPageSize || q.Sort > TaskQuerySortProject || q.Color != 255 && q.Color > 5 || q.Blocked > 2 {
		return nil, fmt.Errorf("invalid task query")
	}
	if q.Assignee != nil && len(*q.Assignee) > MaxAssigneeLength || q.Project != nil && len(*q.Project) > MaxProjectLength || q.Cursor != nil && len(q.Cursor.Text) > MaxTaskTitleLength {
		return nil, fmt.Errorf("task query filter too long")
	}
	if q.Assignee != nil && !utf8.ValidString(*q.Assignee) || q.Project != nil && !utf8.ValidString(*q.Project) || q.Cursor != nil && !utf8.ValidString(q.Cursor.Text) {
		return nil, fmt.Errorf("task query text is not UTF-8")
	}
	textualSort := q.Sort == TaskQuerySortAssignee || q.Sort == TaskQuerySortTitle || q.Sort == TaskQuerySortProject
	if q.Cursor != nil && (textualSort && q.Cursor.Number != 0 || !textualSort && q.Cursor.Text != "") {
		return nil, fmt.Errorf("cursor value does not match task query sort")
	}
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, q.ConvID)
	buf.WriteByte(q.StatusMask)
	binary.Write(buf, binary.BigEndian, q.Limit)
	buf.WriteByte(byte(q.Sort))
	if q.Descending {
		buf.WriteByte(1)
	} else {
		buf.WriteByte(0)
	}
	buf.WriteByte(q.Color)
	buf.WriteByte(q.Blocked)
	binary.Write(buf, binary.BigEndian, q.OverdueBefore)
	if q.Assignee != nil {
		buf.WriteByte(1)
		writeString(buf, *q.Assignee)
	} else {
		buf.WriteByte(0)
		writeString(buf, "")
	}
	if q.Project != nil {
		buf.WriteByte(1)
		writeString(buf, *q.Project)
	} else {
		buf.WriteByte(0)
		writeString(buf, "")
	}
	if q.Cursor != nil {
		buf.WriteByte(1)
		binary.Write(buf, binary.BigEndian, q.Cursor.Number)
		writeString(buf, q.Cursor.Text)
		binary.Write(buf, binary.BigEndian, q.Cursor.TaskID)
	} else {
		buf.WriteByte(0)
		binary.Write(buf, binary.BigEndian, int64(0))
		writeString(buf, "")
		binary.Write(buf, binary.BigEndian, uint64(0))
	}
	binary.Write(buf, binary.BigEndian, q.CorrelationID)
	return buf.Bytes(), nil
}

func EncodeListTaskProjects(convID uint64, correlationID uint32) []byte {
	payload := make([]byte, 12)
	binary.BigEndian.PutUint64(payload, convID)
	binary.BigEndian.PutUint32(payload[8:], correlationID)
	return payload
}

// EncodeListTasksPaged encodes C_ListTasksPaged.
func EncodeListTasksPaged(convID uint64, statusMask uint8, limit uint16, cursor *TaskPageCursor, correlationID uint32) ([]byte, error) {
	if limit == 0 || limit > MaxTaskPageSize {
		return nil, fmt.Errorf("task page limit must be between 1 and %d", MaxTaskPageSize)
	}
	if statusMask == 0 || statusMask&^uint8(0x1f) != 0 {
		return nil, fmt.Errorf("invalid task status mask: 0x%02x", statusMask)
	}
	buf := bytes.NewBuffer(make([]byte, 0, 32))
	binary.Write(buf, binary.BigEndian, convID)
	buf.WriteByte(statusMask)
	binary.Write(buf, binary.BigEndian, limit)
	if cursor == nil {
		buf.WriteByte(0)
	} else {
		buf.WriteByte(1)
		binary.Write(buf, binary.BigEndian, cursor.SortAt)
		binary.Write(buf, binary.BigEndian, cursor.TaskID)
	}
	binary.Write(buf, binary.BigEndian, correlationID)
	return buf.Bytes(), nil
}

// EncodeGetTask encodes C_GetTask.
func EncodeGetTask(convID, taskID uint64, correlationID uint32) []byte {
	payload := make([]byte, 20)
	binary.BigEndian.PutUint64(payload[0:8], convID)
	binary.BigEndian.PutUint64(payload[8:16], taskID)
	binary.BigEndian.PutUint32(payload[16:20], correlationID)
	return payload
}

// DecodeTaskBinary decodes a single task from a binary reader matching server serializeTask format.
func DecodeTaskBinary(buf *bytes.Reader) (*Task, error) {
	task := &Task{}

	if err := binary.Read(buf, binary.BigEndian, &task.ID); err != nil {
		return nil, fmt.Errorf("failed to read ID: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &task.ConvID); err != nil {
		return nil, fmt.Errorf("failed to read convID: %w", err)
	}

	title, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read title: %w", err)
	}
	task.Title = title

	desc, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read description: %w", err)
	}
	task.Description = desc

	if err := binary.Read(buf, binary.BigEndian, &task.Status); err != nil {
		return nil, fmt.Errorf("failed to read status: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &task.OrderIndex); err != nil {
		return nil, fmt.Errorf("failed to read orderIndex: %w", err)
	}

	assignee, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read assignee: %w", err)
	}
	task.Assignee = assignee

	if err := binary.Read(buf, binary.BigEndian, &task.Priority); err != nil {
		return nil, fmt.Errorf("failed to read priority: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &task.Color); err != nil {
		return nil, fmt.Errorf("failed to read color: %w", err)
	}

	createdBy, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read createdBy: %w", err)
	}
	task.CreatedBy = createdBy

	if err := binary.Read(buf, binary.BigEndian, &task.CreatedAt); err != nil {
		return nil, fmt.Errorf("failed to read createdAt: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &task.UpdatedAt); err != nil {
		return nil, fmt.Errorf("failed to read updatedAt: %w", err)
	}

	extRef, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read externalRef: %w", err)
	}
	task.ExternalRef = extRef

	if err := binary.Read(buf, binary.BigEndian, &task.DueAt); err != nil {
		return nil, fmt.Errorf("failed to read dueAt: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &task.BlockedBy); err != nil {
		return nil, fmt.Errorf("failed to read blockedBy: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &task.CompletedAt); err != nil {
		return nil, fmt.Errorf("failed to read completedAt: %w", err)
	}

	completedBy, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read completedBy: %w", err)
	}
	task.CompletedBy = completedBy

	project, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read project: %w", err)
	}
	task.Project = project

	attachments, err := DecodeAttachments(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read attachments: %w", err)
	}
	task.Attachments = attachments

	return task, nil
}

// DecodeTaskCreated decodes an S_TaskCreated payload.
// Wire format: task(...) + correlation_id(4)
func DecodeTaskCreated(payload []byte) (*TaskCreatedResponse, error) {
	task, correlationID, err := decodeTaskWithCorrelation(payload)
	if err != nil {
		return nil, err
	}

	return &TaskCreatedResponse{
		Task:          task,
		CorrelationID: correlationID,
	}, nil
}

// DecodeTaskUpdated decodes an S_TaskUpdated payload.
// Wire format: task(...) + correlation_id(4)
func DecodeTaskUpdated(payload []byte) (*TaskUpdatedResponse, error) {
	task, correlationID, err := decodeTaskWithCorrelation(payload)
	if err != nil {
		return nil, err
	}

	return &TaskUpdatedResponse{
		Task:          task,
		CorrelationID: correlationID,
	}, nil
}

// DecodeTaskDeleted decodes an S_TaskDeleted payload.
// Wire format: task_id(8) + conv_id(8) + correlation_id(4)
func DecodeTaskDeleted(payload []byte) (*TaskDeletedResponse, error) {
	if len(payload) != 20 {
		return nil, fmt.Errorf("task deleted payload size mismatch: got %d want 20", len(payload))
	}

	return &TaskDeletedResponse{
		TaskID:        binary.BigEndian.Uint64(payload[0:8]),
		ConvID:        binary.BigEndian.Uint64(payload[8:16]),
		CorrelationID: binary.BigEndian.Uint32(payload[16:20]),
	}, nil
}

// DecodeTaskMoved decodes an S_TaskMoved payload.
// Wire format: task_id(8) + conv_id(8) + status(1) + order_index(2) + completed_at(8) + completed_by_len(2) + completed_by + correlation_id(4)
func DecodeTaskMoved(payload []byte) (*TaskMovedResponse, error) {
	buf := bytes.NewReader(payload)
	resp := &TaskMovedResponse{}

	if err := binary.Read(buf, binary.BigEndian, &resp.TaskID); err != nil {
		return nil, fmt.Errorf("failed to read task_id: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &resp.ConvID); err != nil {
		return nil, fmt.Errorf("failed to read conv_id: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &resp.Status); err != nil {
		return nil, fmt.Errorf("failed to read status: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &resp.OrderIndex); err != nil {
		return nil, fmt.Errorf("failed to read order_index: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &resp.CompletedAt); err != nil {
		return nil, fmt.Errorf("failed to read completed_at: %w", err)
	}

	completedBy, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read completed_by: %w", err)
	}
	resp.CompletedBy = completedBy

	if buf.Len() < 4 {
		return nil, fmt.Errorf("payload too short for task moved correlation_id")
	}

	if err := binary.Read(buf, binary.BigEndian, &resp.CorrelationID); err != nil {
		return nil, fmt.Errorf("failed to decode task moved correlation_id: %w", err)
	}

	if buf.Len() != 0 {
		return nil, fmt.Errorf("unexpected trailing bytes in task moved payload: %d", buf.Len())
	}

	return resp, nil
}

func decodeTaskWithCorrelation(payload []byte) (*Task, uint32, error) {
	buf := bytes.NewReader(payload)

	task, err := DecodeTaskBinary(buf)
	if err != nil {
		return nil, 0, fmt.Errorf("failed to decode task: %w", err)
	}

	if buf.Len() < 4 {
		return nil, 0, fmt.Errorf("payload too short for task correlation_id")
	}

	var correlationID uint32
	if err := binary.Read(buf, binary.BigEndian, &correlationID); err != nil {
		return nil, 0, fmt.Errorf("failed to decode task correlation_id: %w", err)
	}

	if buf.Len() != 0 {
		return nil, 0, fmt.Errorf("unexpected trailing bytes in task payload: %d", buf.Len())
	}

	return task, correlationID, nil
}

// TaskListResponse represents a decoded S_TaskListResponse.
type TaskListResponse struct {
	ConvID        uint64
	Success       bool
	Tasks         []*Task
	ErrorMessage  string
	CorrelationID uint32
}

// DecodeTaskListResponse decodes an S_TaskListResponse payload.
// Wire format: conv_id(8) + success(1) + count(2) + tasks(N) + error_len(2) + error + correlation_id(4)
func DecodeTaskListResponse(payload []byte) (*TaskListResponse, error) {
	if len(payload) < 17 {
		return nil, fmt.Errorf("payload too short for task list response: %d bytes", len(payload))
	}

	buf := bytes.NewReader(payload)

	var convID uint64
	if err := binary.Read(buf, binary.BigEndian, &convID); err != nil {
		return nil, fmt.Errorf("failed to read convID: %w", err)
	}

	var success uint8
	if err := binary.Read(buf, binary.BigEndian, &success); err != nil {
		return nil, fmt.Errorf("failed to read success flag: %w", err)
	}

	var count uint16
	if err := binary.Read(buf, binary.BigEndian, &count); err != nil {
		return nil, fmt.Errorf("failed to read task count: %w", err)
	}

	tasks := make([]*Task, 0, count)
	for i := 0; i < int(count); i++ {
		task, err := DecodeTaskBinary(buf)
		if err != nil {
			return nil, fmt.Errorf("failed to decode task %d: %w", i, err)
		}
		tasks = append(tasks, task)
	}

	errMsg, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("failed to read error message: %w", err)
	}

	if buf.Len() < 4 {
		return nil, fmt.Errorf("payload too short for task list correlation_id")
	}

	var correlationID uint32
	if err := binary.Read(buf, binary.BigEndian, &correlationID); err != nil {
		return nil, fmt.Errorf("failed to read task list correlation_id: %w", err)
	}

	if buf.Len() != 0 {
		return nil, fmt.Errorf("unexpected trailing bytes in task list payload: %d", buf.Len())
	}

	resp := &TaskListResponse{
		ConvID:        convID,
		Success:       success == 1,
		Tasks:         tasks,
		ErrorMessage:  errMsg,
		CorrelationID: correlationID,
	}

	if !resp.Success {
		return resp, fmt.Errorf("server error: %s", errMsg)
	}

	return resp, nil
}

// TaskListPage represents S_TaskListPage.
type TaskListPage struct {
	ConvID        uint64
	Success       bool
	Tasks         []*Task
	HasMore       bool
	NextCursor    TaskPageCursor
	TotalCount    uint32
	ErrorMessage  string
	CorrelationID uint32
}

type TaskQueryPage struct {
	ConvID        uint64
	Success       bool
	Tasks         []*Task
	HasMore       bool
	NextCursor    TaskQueryCursor
	TotalCount    uint32
	ErrorMessage  string
	CorrelationID uint32
}

func DecodeTaskQueryPage(payload []byte) (*TaskQueryPage, error) {
	buf := bytes.NewReader(payload)
	page := &TaskQueryPage{}
	var success, more uint8
	var count uint16
	if binary.Read(buf, binary.BigEndian, &page.ConvID) != nil || binary.Read(buf, binary.BigEndian, &success) != nil || success > 1 || binary.Read(buf, binary.BigEndian, &count) != nil || count > MaxTaskPageSize {
		return nil, fmt.Errorf("invalid task query page header")
	}
	page.Tasks = make([]*Task, 0, count)
	for i := 0; i < int(count); i++ {
		task, err := DecodeTaskBinary(buf)
		if err != nil {
			return nil, err
		}
		page.Tasks = append(page.Tasks, task)
	}
	if binary.Read(buf, binary.BigEndian, &more) != nil || more > 1 || binary.Read(buf, binary.BigEndian, &page.NextCursor.Number) != nil || binary.Read(buf, binary.BigEndian, &page.NextCursor.TaskID) != nil {
		return nil, fmt.Errorf("invalid task query page cursor")
	}
	text, err := readString(buf)
	if err != nil {
		return nil, err
	}
	page.NextCursor.Text = text
	if binary.Read(buf, binary.BigEndian, &page.TotalCount) != nil {
		return nil, fmt.Errorf("invalid task query count")
	}
	page.ErrorMessage, err = readString(buf)
	if err != nil {
		return nil, err
	}
	if binary.Read(buf, binary.BigEndian, &page.CorrelationID) != nil || buf.Len() != 0 {
		return nil, fmt.Errorf("invalid task query page tail")
	}
	page.Success, page.HasMore = success == 1, more == 1
	if page.HasMore && count == 0 {
		return nil, fmt.Errorf("has_more on empty task query page")
	}
	if !page.Success {
		return page, fmt.Errorf("server error: %s", page.ErrorMessage)
	}
	return page, nil
}

type TaskProjects struct {
	ConvID        uint64
	Projects      []string
	HasMore       bool
	CorrelationID uint32
}

func DecodeTaskProjects(payload []byte) (*TaskProjects, error) {
	buf := bytes.NewReader(payload)
	result := &TaskProjects{}
	var count uint16
	if binary.Read(buf, binary.BigEndian, &result.ConvID) != nil || binary.Read(buf, binary.BigEndian, &count) != nil {
		return nil, fmt.Errorf("invalid task projects header")
	}
	result.Projects = make([]string, count)
	previous := ""
	for i := range result.Projects {
		value, err := readString(buf)
		if err != nil || len(value) == 0 || len(value) > MaxProjectLength || i > 0 && value <= previous {
			return nil, fmt.Errorf("invalid task project list")
		}
		result.Projects[i], previous = value, value
	}
	hasMore, err := buf.ReadByte()
	if err != nil || hasMore > 1 {
		return nil, fmt.Errorf("invalid task projects continuation")
	}
	result.HasMore = hasMore == 1
	if binary.Read(buf, binary.BigEndian, &result.CorrelationID) != nil || buf.Len() != 0 {
		return nil, fmt.Errorf("invalid task projects tail")
	}
	return result, nil
}

// DecodeTaskListPage strictly decodes S_TaskListPage.
func DecodeTaskListPage(payload []byte) (*TaskListPage, error) {
	buf := bytes.NewReader(payload)
	page := &TaskListPage{}
	var success, hasMore uint8
	var count uint16
	if err := binary.Read(buf, binary.BigEndian, &page.ConvID); err != nil {
		return nil, fmt.Errorf("task page conv_id: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &success); err != nil || success > 1 {
		return nil, fmt.Errorf("invalid task page success flag")
	}
	if err := binary.Read(buf, binary.BigEndian, &count); err != nil {
		return nil, fmt.Errorf("task page count: %w", err)
	}
	if count > MaxTaskPageSize {
		return nil, fmt.Errorf("task page count %d exceeds maximum %d", count, MaxTaskPageSize)
	}
	page.Tasks = make([]*Task, 0, count)
	for i := 0; i < int(count); i++ {
		task, err := DecodeTaskBinary(buf)
		if err != nil {
			return nil, fmt.Errorf("task page task %d: %w", i, err)
		}
		page.Tasks = append(page.Tasks, task)
	}
	if err := binary.Read(buf, binary.BigEndian, &hasMore); err != nil || hasMore > 1 {
		return nil, fmt.Errorf("invalid task page has_more flag")
	}
	if err := binary.Read(buf, binary.BigEndian, &page.NextCursor.SortAt); err != nil {
		return nil, fmt.Errorf("task page cursor sort_at: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &page.NextCursor.TaskID); err != nil {
		return nil, fmt.Errorf("task page cursor task_id: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &page.TotalCount); err != nil {
		return nil, fmt.Errorf("task page total_count: %w", err)
	}
	errMsg, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("task page error: %w", err)
	}
	page.ErrorMessage = errMsg
	if err := binary.Read(buf, binary.BigEndian, &page.CorrelationID); err != nil {
		return nil, fmt.Errorf("task page correlation_id: %w", err)
	}
	if buf.Len() != 0 {
		return nil, fmt.Errorf("unexpected trailing bytes in task page: %d", buf.Len())
	}
	page.Success, page.HasMore = success == 1, hasMore == 1
	if page.HasMore && count == 0 {
		return nil, fmt.Errorf("task page has_more set on empty page")
	}
	if !page.Success {
		return page, fmt.Errorf("server error: %s", page.ErrorMessage)
	}
	return page, nil
}

// TaskFull represents S_TaskFull.
type TaskFull struct {
	ConvID        uint64
	Success       bool
	Task          *Task
	ErrorMessage  string
	CorrelationID uint32
}

// DecodeTaskFull strictly decodes S_TaskFull.
func DecodeTaskFull(payload []byte) (*TaskFull, error) {
	buf := bytes.NewReader(payload)
	resp := &TaskFull{}
	var success, hasTask uint8
	if err := binary.Read(buf, binary.BigEndian, &resp.ConvID); err != nil {
		return nil, fmt.Errorf("task full conv_id: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &success); err != nil || success > 1 {
		return nil, fmt.Errorf("invalid task full success flag")
	}
	if err := binary.Read(buf, binary.BigEndian, &hasTask); err != nil || hasTask > 1 {
		return nil, fmt.Errorf("invalid task full has_task flag")
	}
	if hasTask == 1 {
		task, err := DecodeTaskBinary(buf)
		if err != nil {
			return nil, fmt.Errorf("task full task: %w", err)
		}
		resp.Task = task
	}
	errMsg, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("task full error: %w", err)
	}
	resp.ErrorMessage = errMsg
	if err := binary.Read(buf, binary.BigEndian, &resp.CorrelationID); err != nil {
		return nil, fmt.Errorf("task full correlation_id: %w", err)
	}
	if buf.Len() != 0 {
		return nil, fmt.Errorf("unexpected trailing bytes in task full: %d", buf.Len())
	}
	resp.Success = success == 1
	if !resp.Success {
		return resp, fmt.Errorf("server error: %s", resp.ErrorMessage)
	}
	return resp, nil
}

// EncodeAttachments encodes attachments to binary format.
func EncodeAttachments(attachments []Attachment) []byte {
	buf := bytes.NewBuffer(nil)
	binary.Write(buf, binary.BigEndian, uint16(len(attachments)))
	for _, att := range attachments {
		writeString(buf, att.FileId)
		writeString(buf, att.Filename)
		binary.Write(buf, binary.BigEndian, att.Size)
		writeString(buf, att.MimeType)
		binary.Write(buf, binary.BigEndian, att.UploadedAt)
	}
	return buf.Bytes()
}

// DecodeAttachments decodes attachments from binary format.
func DecodeAttachments(buf *bytes.Reader) ([]Attachment, error) {
	var count uint16
	if err := binary.Read(buf, binary.BigEndian, &count); err != nil {
		return nil, err
	}

	attachments := make([]Attachment, 0, count)
	for i := 0; i < int(count); i++ {
		fileId, err := readString(buf)
		if err != nil {
			return nil, err
		}
		filename, err := readString(buf)
		if err != nil {
			return nil, err
		}
		var size int64
		if err := binary.Read(buf, binary.BigEndian, &size); err != nil {
			return nil, err
		}
		mimeType, err := readString(buf)
		if err != nil {
			return nil, err
		}
		var uploadedAt int64
		if err := binary.Read(buf, binary.BigEndian, &uploadedAt); err != nil {
			return nil, err
		}
		attachments = append(attachments, Attachment{
			FileId:     fileId,
			Filename:   filename,
			Size:       size,
			MimeType:   mimeType,
			UploadedAt: uploadedAt,
		})
	}
	return attachments, nil
}

// ============================================================================
// Slices
// ============================================================================
//
// A slice is an explicit work stream: an asset of type AssetTypeSlice whose
// members are the tasks, notes and files linked to it with a MemberOf edge. The
// server reads those edges, so a client reads slices and never derives them.

// Task slice flags - matches server TaskSliceFlags.
const (
	TaskSliceFlagClosed uint8 = 1 << 0
)

type TaskSlice struct {
	Name           string
	SliceID        uint64
	Owner          string
	Flags          uint8
	Backlog        uint16
	Todo           uint16
	InProgress     uint16
	Done           uint16
	Blocked        uint16
	Notes          uint16
	Files          uint16
	OldestActiveAt int64
	LastMovedAt    int64
}

// OpenCount is the number of task members that are not Done. A slice's WIP load
// is read from this, so it is derived rather than stored.
func (s TaskSlice) OpenCount() uint32 {
	return uint32(s.Backlog) + uint32(s.Todo) + uint32(s.InProgress)
}

// MemberCount is every member the slice carries: tasks with a status, notes and
// files. The sum is widened because the counters are independent.
func (s TaskSlice) MemberCount() uint32 {
	return uint32(s.Backlog) + uint32(s.Todo) + uint32(s.InProgress) +
		uint32(s.Done) + uint32(s.Notes) + uint32(s.Files)
}

// TaskCount is the members that carry a task status.
func (s TaskSlice) TaskCount() uint32 {
	return s.OpenCount() + uint32(s.Done)
}

func (s TaskSlice) IsClosed() bool { return s.Flags&TaskSliceFlagClosed != 0 }

// SliceCursor names the last slice of a page in the register's own order:
// closure, then movement, then ID. Closure is part of the key because closed
// slices sink below the active ones.
type SliceCursor struct {
	Closed  bool
	SortAt  int64
	SliceID uint64
}

// SliceQuery is one page request of the register: the filters the reader set, the
// page bound and the cursor the previous page ended on. An empty Owner with
// HasOwner set is the slices nobody owns; Name is matched as a case-insensitive
// substring of the slice name.
type SliceQuery struct {
	IncludeClosed bool
	HasOwner      bool
	Owner         string
	HasName       bool
	Name          string
	Limit         uint16
	Cursor        *SliceCursor
}

// EncodeListTaskSlices encodes C_ListTaskSlices. The request body carries no
// opcode; the caller frames it.
func EncodeListTaskSlices(convID uint64, query SliceQuery, correlationID uint32) []byte {
	owner := []byte(query.Owner)
	name := []byte(query.Name)
	size := 22 + len(owner) + len(name)
	if query.Cursor != nil {
		size += 17
	}
	payload := make([]byte, size)
	binary.BigEndian.PutUint64(payload, convID)
	if query.IncludeClosed {
		payload[8] = 1
	}
	if query.HasOwner {
		payload[9] = 1
	}
	binary.BigEndian.PutUint16(payload[10:], uint16(len(owner)))
	offset := 12
	copy(payload[offset:], owner)
	offset += len(owner)
	if query.HasName {
		payload[offset] = 1
	}
	offset++
	binary.BigEndian.PutUint16(payload[offset:], uint16(len(name)))
	offset += 2
	copy(payload[offset:], name)
	offset += len(name)
	binary.BigEndian.PutUint16(payload[offset:], query.Limit)
	offset += 2
	if query.Cursor != nil {
		payload[offset] = 1
		offset++
		if query.Cursor.Closed {
			payload[offset] = 1
		}
		offset++
		binary.BigEndian.PutUint64(payload[offset:], uint64(query.Cursor.SortAt))
		offset += 8
		binary.BigEndian.PutUint64(payload[offset:], query.Cursor.SliceID)
		offset += 8
	} else {
		offset++
	}
	binary.BigEndian.PutUint32(payload[offset:], correlationID)
	return payload
}

type TaskSliceList struct {
	ConvID     uint64
	Success    bool
	Slices     []TaskSlice
	HasMore    bool
	NextCursor SliceCursor
	// TotalCount is every slice the filters match, not only this page's rows.
	TotalCount uint32
	// Work counters are a statement about the whole workspace, so they are zero
	// for a filtered listing and for a page that continues one.
	AssignedTasks   uint32
	UnassignedTasks uint32
	Error           string
	CorrelationID   uint32
}

// DecodeTaskSliceList strictly decodes S_TaskSliceList. Slices arrive name
// sorted and unique; a chunked listing repeats the same correlation ID.
func DecodeTaskSliceList(payload []byte) (*TaskSliceList, error) {
	buf := bytes.NewReader(payload)
	result := &TaskSliceList{}
	var success, hasMore uint8
	var count uint16
	if err := binary.Read(buf, binary.BigEndian, &result.ConvID); err != nil {
		return nil, fmt.Errorf("slice list conv_id: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &success); err != nil || success > 1 {
		return nil, fmt.Errorf("invalid slice list success flag")
	}
	if err := binary.Read(buf, binary.BigEndian, &count); err != nil || count > MaxTaskSliceCount {
		return nil, fmt.Errorf("invalid slice list count")
	}
	result.Success = success == 1
	result.Slices = make([]TaskSlice, 0, count)
	for i := 0; i < int(count); i++ {
		slice := TaskSlice{}
		name, err := readString(buf)
		if err != nil || len(name) > MaxProjectLength {
			return nil, fmt.Errorf("invalid slice name")
		}
		slice.Name = name
		if err := binary.Read(buf, binary.BigEndian, &slice.SliceID); err != nil {
			return nil, fmt.Errorf("slice id: %w", err)
		}
		owner, err := readString(buf)
		if err != nil || len(owner) > MaxAssigneeLength {
			return nil, fmt.Errorf("invalid slice owner")
		}
		slice.Owner = owner
		if err := binary.Read(buf, binary.BigEndian, &slice.Flags); err != nil || slice.Flags&^uint8(0x01) != 0 {
			return nil, fmt.Errorf("invalid slice flags")
		}
		for _, field := range []*uint16{&slice.Backlog, &slice.Todo, &slice.InProgress, &slice.Done, &slice.Blocked, &slice.Notes, &slice.Files} {
			if err := binary.Read(buf, binary.BigEndian, field); err != nil {
				return nil, fmt.Errorf("slice counters: %w", err)
			}
		}
		if err := binary.Read(buf, binary.BigEndian, &slice.OldestActiveAt); err != nil {
			return nil, fmt.Errorf("slice oldest: %w", err)
		}
		if err := binary.Read(buf, binary.BigEndian, &slice.LastMovedAt); err != nil {
			return nil, fmt.Errorf("slice last moved: %w", err)
		}
		result.Slices = append(result.Slices, slice)
	}
	if err := binary.Read(buf, binary.BigEndian, &hasMore); err != nil || hasMore > 1 {
		return nil, fmt.Errorf("invalid slice list continuation")
	}
	result.HasMore = hasMore == 1
	var nextCursorClosed uint8
	if err := binary.Read(buf, binary.BigEndian, &nextCursorClosed); err != nil || nextCursorClosed > 1 {
		return nil, fmt.Errorf("invalid slice list cursor closure")
	}
	result.NextCursor.Closed = nextCursorClosed == 1
	if err := binary.Read(buf, binary.BigEndian, &result.NextCursor.SortAt); err != nil {
		return nil, fmt.Errorf("slice list cursor sort key: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &result.NextCursor.SliceID); err != nil {
		return nil, fmt.Errorf("slice list cursor id: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &result.TotalCount); err != nil {
		return nil, fmt.Errorf("slice list total: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &result.AssignedTasks); err != nil {
		return nil, fmt.Errorf("slice list assigned tasks: %w", err)
	}
	if err := binary.Read(buf, binary.BigEndian, &result.UnassignedTasks); err != nil {
		return nil, fmt.Errorf("slice list unassigned tasks: %w", err)
	}
	message, err := readString(buf)
	if err != nil {
		return nil, fmt.Errorf("slice list error: %w", err)
	}
	result.Error = message
	if err := binary.Read(buf, binary.BigEndian, &result.CorrelationID); err != nil || buf.Len() != 0 {
		return nil, fmt.Errorf("invalid slice list tail")
	}
	return result, nil
}
