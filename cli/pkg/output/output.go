package output

import (
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"strconv"
	"strings"

	"github.com/heavyhorst/nrc/protocol-go"
	"github.com/olekukonko/tablewriter"
)

type Task struct {
	ID          uint64       `json:"id"`
	Title       string       `json:"title"`
	Description string       `json:"description"`
	Status      string       `json:"status"`
	Assignee    string       `json:"assignee"`
	Priority    string       `json:"priority"`
	Project     string       `json:"project"`
	BlockedBy   uint64       `json:"blocked_by"`
	CreatedBy   string       `json:"created_by"`
	Timestamp   int64        `json:"timestamp"`
	Attachments []Attachment `json:"attachments"`
}

type Attachment struct {
	FileID     string `json:"FileId"`
	Filename   string `json:"Filename"`
	Size       int64  `json:"Size"`
	MimeType   string `json:"MimeType"`
	UploadedAt int64  `json:"UploadedAt"`
	URL        string `json:"url"`
}

type TaskList struct {
	Tasks []Task `json:"tasks"`
}

type User struct {
	ID       string `json:"id"`
	Nickname string `json:"nickname"`
	Status   string `json:"status"`
}

type UserList struct {
	Users []User `json:"users"`
}

var (
	human  bool
	pretty bool
	fields []string
)

// Configure sets the process-wide output contract for one CLI invocation.
func Configure(humanOutput, prettyOutput bool, selectedFields string) error {
	human, pretty = humanOutput, prettyOutput
	fields = fields[:0]
	for _, field := range strings.Split(selectedFields, ",") {
		field = strings.TrimSpace(field)
		if field != "" {
			fields = append(fields, field)
		}
	}
	if human && len(fields) != 0 {
		return fmt.Errorf("--fields cannot be used with --human")
	}
	return nil
}

func Human() bool { return human }

func HasFieldProjection() bool { return len(fields) != 0 }

// Envelope keys whose arrays take item projection for --fields. A list command
// that invents a new envelope key must be added here, or --fields falls through
// to projecting the envelope itself and rejects every item field.
var collectionKeys = []string{"tasks", "notes", "rooms", "users", "results", "edges", "reminders", "appointments", "entries", "projects", "tags", "slices", "members"}

func fieldSet(names ...string) map[string]bool {
	s := make(map[string]bool, len(names))
	for _, name := range names {
		s[name] = true
	}
	return s
}

func jsonFields(t reflect.Type) map[string]bool {
	if t == nil {
		return nil
	}
	for t.Kind() == reflect.Pointer || t.Kind() == reflect.Slice || t.Kind() == reflect.Array {
		t = t.Elem()
	}
	if t.Kind() != reflect.Struct {
		return nil
	}
	r := map[string]bool{}
	for i := 0; i < t.NumField(); i++ {
		name := strings.Split(t.Field(i).Tag.Get("json"), ",")[0]
		if name == "" {
			name = t.Field(i).Name
		}
		if name != "-" {
			r[name] = true
		}
	}
	return r
}

func envelopeCollectionType(t reflect.Type, key string) reflect.Type {
	for t != nil && t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	if t == nil {
		return nil
	}
	if t.Kind() == reflect.Struct {
		for i := 0; i < t.NumField(); i++ {
			f := t.Field(i)
			name := strings.Split(f.Tag.Get("json"), ",")[0]
			if name == "" {
				name = f.Name
			}
			if name == key {
				return f.Type
			}
		}
	}
	if t.Kind() == reflect.Map && t.Key().Kind() == reflect.String {
		return t.Elem()
	}
	return nil
}

func envelopeValueType(v any, key string) reflect.Type {
	rv := reflect.ValueOf(v)
	for rv.IsValid() && (rv.Kind() == reflect.Pointer || rv.Kind() == reflect.Interface) {
		rv = rv.Elem()
	}
	if !rv.IsValid() {
		return nil
	}
	if rv.Kind() == reflect.Map && rv.Type().Key().Kind() == reflect.String {
		value := rv.MapIndex(reflect.ValueOf(key).Convert(rv.Type().Key()))
		if value.IsValid() {
			return value.Type()
		}
	}
	return envelopeCollectionType(rv.Type(), key)
}

func itemFields(t reflect.Type, items []any) map[string]bool {
	valid := jsonFields(t)
	if valid != nil {
		return valid
	}
	if len(items) > 0 {
		if m, ok := items[0].(map[string]any); ok {
			valid = make(map[string]bool, len(m))
			for key := range m {
				valid[key] = true
			}
		}
	}
	return valid
}

func project(v any) (any, error) {
	if len(fields) == 0 {
		return v, nil
	}
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	var decoded any
	decoder := json.NewDecoder(strings.NewReader(string(b)))
	decoder.UseNumber()
	if err = decoder.Decode(&decoded); err != nil {
		return nil, err
	}
	projectMap := func(m map[string]any, valid map[string]bool) (map[string]any, error) {
		p := make(map[string]any, len(fields))
		for _, f := range fields {
			val, ok := m[f]
			if !ok && (valid == nil || !valid[f]) {
				return nil, fmt.Errorf("unknown field %q", f)
			}
			if !ok {
				// Preserve omitempty semantics when a valid selected field is absent.
				continue
			}
			p[f] = val
		}
		return p, nil
	}
	var projectArray func([]any, map[string]bool) ([]any, error)
	projectArray = func(a []any, valid map[string]bool) ([]any, error) {
		if valid == nil {
			return nil, fmt.Errorf("--fields requires a typed object collection")
		} else {
			for _, f := range fields {
				if !valid[f] {
					return nil, fmt.Errorf("unknown field %q", f)
				}
			}
		}
		out := make([]any, len(a))
		for i, item := range a {
			m, ok := item.(map[string]any)
			if !ok {
				return nil, fmt.Errorf("--fields requires object collection items")
			}
			out[i], err = projectMap(m, valid)
			if err != nil {
				return nil, err
			}
		}
		return out, nil
	}
	switch x := decoded.(type) {
	case []any:
		return projectArray(x, itemFields(reflect.TypeOf(v), x))
	case map[string]any:
		// Only named collection envelopes project their items. Other objects,
		// even if they contain arrays, are single resources.
		for _, key := range collectionKeys {
			if value, exists := x[key]; exists {
				if a, ok := value.([]any); ok {
					valid := itemFields(envelopeValueType(v, key), a)
					if valid == nil {
						continue
					}
					x[key], err = projectArray(a, valid)
					return x, err
				}
			}
		}
		return projectMap(x, jsonFields(reflect.TypeOf(v)))
	default:
		return nil, fmt.Errorf("--fields requires an object or object collection")
	}
}

// RenderJSON projects and marshals a document without writing or exiting.
func RenderJSON(v any, jsonLine bool) ([]byte, error) {
	if !jsonLine {
		var err error
		v, err = project(v)
		if err != nil {
			return nil, err
		}
	}
	if pretty && !jsonLine {
		return json.MarshalIndent(v, "", "  ")
	}
	return json.Marshal(v)
}

// JSON output
func OutputJSON(v interface{}) {
	data, err := RenderJSON(v, false)
	if err != nil {
		Error("invalid_argument", err.Error(), false)
	}
	fmt.Println(string(data))
}

// OutputTopLevelJSON applies --fields to a document itself rather than to a
// nested collection. This is used for documents with multiple collections.
func OutputTopLevelJSON(v interface{}) {
	b, err := json.Marshal(v)
	if err != nil {
		Error("unexpected_response", err.Error(), false)
	}
	var decoded map[string]any
	if err := json.Unmarshal(b, &decoded); err != nil {
		Error("unexpected_response", err.Error(), false)
	}
	if len(fields) != 0 {
		projected := make(map[string]any, len(fields))
		valid := jsonFields(reflect.TypeOf(v))
		for _, field := range fields {
			value, exists := decoded[field]
			if !exists && (valid == nil || !valid[field]) {
				Error("invalid_argument", fmt.Sprintf("unknown field %q", field), false)
			}
			projected[field] = value
		}
		decoded = projected
	}
	var data []byte
	if pretty {
		data, err = json.MarshalIndent(decoded, "", "  ")
	} else {
		data, err = json.Marshal(decoded)
	}
	if err != nil {
		Error("unexpected_response", err.Error(), false)
	}
	fmt.Println(string(data))
}

// OutputJSONLine emits one compact JSON event, regardless of --pretty.
func OutputJSONLine(v interface{}) {
	data, err := RenderJSON(v, true)
	if err != nil {
		Error("command_failed", err.Error(), false)
	}
	fmt.Println(string(data))
}

func Error(code, message string, retryable bool) {
	if human {
		fmt.Fprintln(os.Stderr, message)
	} else {
		data, _ := RenderError(code, message, retryable)
		fmt.Fprintln(os.Stderr, string(data))
	}
	os.Exit(1)
}

type ErrorDocument struct {
	Error ErrorDetail `json:"error"`
}
type ErrorDetail struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	Retryable bool   `json:"retryable"`
}

// RenderError deliberately bypasses --fields: projection applies to success DTOs only.
func RenderError(code, message string, retryable bool) ([]byte, error) {
	v := ErrorDocument{Error: ErrorDetail{Code: code, Message: message, Retryable: retryable}}
	if pretty {
		return json.MarshalIndent(v, "", "  ")
	}
	return json.Marshal(v)
}

// Table output for tasks
func OutputTasksTable(tasks []Task) {
	table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"ID", "TITLE", "DESCRIPTION", "STATUS", "PRIORITY", "PROJECT", "BLK", "CREATED BY"}))

	for _, task := range tasks {
		blockedBy := "---"
		if task.BlockedBy != 0 {
			blockedBy = fmt.Sprintf("#%d", task.BlockedBy)
		}

		table.Append(
			fmt.Sprintf("%d", task.ID),
			truncate(task.Title, 20),
			truncate(task.Description, 20),
			task.Status,
			task.Priority,
			truncate(task.Project, 20),
			blockedBy,
			task.CreatedBy,
		)
	}

	table.Render()
}

// Table output for users
func OutputUsersTable(users []User) {
	table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"ID", "NICKNAME", "STATUS"}))

	for _, user := range users {
		statusColor := user.Status
		if supportsColor() {
			if user.Status == "online" {
				statusColor = "\033[32m" + user.Status + "\033[0m" // Green
			} else if user.Status == "offline" {
				statusColor = "\033[31m" + user.Status + "\033[0m" // Red
			}
		}
		table.Append(user.ID, user.Nickname, statusColor)
	}

	table.Render()
}

// Helpers
func supportsColor() bool {
	// Check if output is a terminal and TERM is not "dumb"
	term := os.Getenv("TERM")
	if term == "dumb" {
		return false
	}
	// Could add more checks for NO_COLOR env var, etc.
	return true
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen-3] + "..."
}

// ParseTaskList parses server response (binary protocol) into TaskList
// Format: ConvID(8) + Success(1) + TaskCount(2) + [Tasks...] + [ErrorLen(2) + Error]
func ParseTaskList(data []byte) (*TaskList, error) {
	resp, err := protocol.DecodeTaskListResponse(data)
	if err != nil {
		return nil, err
	}

	tasks := make([]Task, 0, len(resp.Tasks))
	for _, pt := range resp.Tasks {
		attachments := make([]Attachment, 0, len(pt.Attachments))
		for _, attachment := range pt.Attachments {
			attachments = append(attachments, Attachment{
				FileID:     attachment.FileId,
				Filename:   attachment.Filename,
				Size:       attachment.Size,
				MimeType:   attachment.MimeType,
				UploadedAt: attachment.UploadedAt,
			})
		}
		tasks = append(tasks, Task{
			ID:          pt.ID,
			Title:       pt.Title,
			Description: pt.Description,
			Status:      StatusName(int32(pt.Status)),
			Priority:    fmt.Sprintf("%d", pt.Priority),
			Project:     pt.Project,
			BlockedBy:   pt.BlockedBy,
			CreatedBy:   pt.CreatedBy,
			Timestamp:   pt.CreatedAt,
			Attachments: attachments,
		})
	}

	return &TaskList{Tasks: tasks}, nil
}

// ParseUserList parses server response into UserList
func ParseUserList(data []byte) (*UserList, error) {
	var ul UserList
	if err := json.Unmarshal(data, &ul); err != nil {
		return nil, err
	}
	return &ul, nil
}

// StatusName converts status code to string
func StatusName(status int32) string {
	switch status {
	case 0:
		return "backlog"
	case 1:
		return "todo"
	case 2:
		return "in-progress"
	case 3:
		return "done"
	case 4:
		return "note"
	default:
		return "unknown"
	}
}

// PriorityName converts priority code to string
func PriorityName(priority int32) string {
	return fmt.Sprintf("%d", priority)
}

// StatusCode converts string to status code
func StatusCode(s string) int32 {
	switch strings.ToLower(s) {
	case "backlog":
		return 0
	case "todo":
		return 1
	case "in-progress", "progress":
		return 2
	case "done":
		return 3
	case "note":
		return 4
	default:
		return 0
	}
}

// PriorityCode converts string to priority code
func PriorityCode(s string) int32 {
	n, err := strconv.ParseInt(s, 10, 32)
	if err != nil {
		return 0
	}
	return int32(n)
}

// PrintError prints error message and exits
func PrintError(format string, args ...interface{}) {
	Error("unexpected_response", fmt.Sprintf(format, args...), false)
}

// PrintSuccess prints success message
func PrintSuccess(format string, args ...interface{}) {
	message := fmt.Sprintf(format, args...)
	if human {
		fmt.Println(message)
	}
}

// PrintCreatedID prints a stable success line for commands that create resources.
func PrintCreatedID(kind string, id uint64) {
	if human {
		fmt.Printf("%s created: %d\n", kind, id)
		return
	}
	Mutation("created", strings.ToLower(kind), id, "", nil, nil)
}

type MutationResult struct {
	Operation    string `json:"operation"`
	ResourceType string `json:"resource_type"`
	ID           uint64 `json:"id,omitempty"`
	Message      string `json:"message,omitempty"`
	Resource     any    `json:"resource,omitempty"`
	Details      any    `json:"details,omitempty"`
}

// Mutation preserves existing human prose while providing a stable machine contract.
func Mutation(operation, resourceType string, id uint64, message string, resource, details any) {
	if human {
		if message != "" {
			fmt.Println(message)
		}
		return
	}
	OutputJSON(MutationResult{Operation: operation, ResourceType: resourceType, ID: id, Message: message, Resource: resource, Details: details})
}
