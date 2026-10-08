package protocol

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

func TestMessageWriteRead(t *testing.T) {
	msg := &Message{Opcode: C_CreateTask, Data: []byte("hello")}
	data, err := msg.Write()
	if err != nil {
		t.Fatal(err)
	}
	if len(data) != 2+5 {
		t.Fatalf("expected 7 bytes, got %d", len(data))
	}
	got, err := ReadMessage(data)
	if err != nil {
		t.Fatal(err)
	}
	if got.Opcode != C_CreateTask {
		t.Errorf("opcode = %d, want %d", got.Opcode, C_CreateTask)
	}
	if string(got.Data) != "hello" {
		t.Errorf("data = %q, want %q", got.Data, "hello")
	}
}

func TestReadMessageTooShort(t *testing.T) {
	_, err := ReadMessage([]byte{0x00})
	if err == nil {
		t.Error("expected error for 1-byte message")
	}
}

func TestReadMessageOpcodeOnly(t *testing.T) {
	got, err := ReadMessage([]byte{0x00, 0x14}) // opcode 20 = C_CreateTask
	if err != nil {
		t.Fatal(err)
	}
	if got.Opcode != C_CreateTask {
		t.Errorf("opcode = %d, want %d", got.Opcode, C_CreateTask)
	}
	if len(got.Data) != 0 {
		t.Errorf("expected empty data, got %d bytes", len(got.Data))
	}
}

func TestOpcodeValues(t *testing.T) {
	tests := []struct {
		name string
		got  uint16
		want uint16
	}{
		{"C_SetNickname", C_SetNickname, 0},
		{"C_SendMessage", C_SendMessage, 1},
		{"C_Stats", C_Stats, 8},
		{"C_Authenticate", C_Authenticate, 9},
		{"C_Ping", C_Ping, 19},
		{"C_CreateTask", C_CreateTask, 20},
		{"C_UpdateTask", C_UpdateTask, 21},
		{"C_DeleteTask", C_DeleteTask, 22},
		{"C_MoveTask", C_MoveTask, 23},
		{"C_GetTasks", C_GetTasks, 24},
		{"C_ListTasksPaged", C_ListTasksPaged, 25},
		{"C_GetTask", C_GetTask, 26},
		{"C_CreateAsset", C_CreateAsset, 30},
		{"C_UpdateAsset", C_UpdateAsset, 31},
		{"C_DeleteAsset", C_DeleteAsset, 32},
		{"C_GetAsset", C_GetAsset, 33},
		{"C_ListAssets", C_ListAssets, 34},
		{"C_CreateEdge", C_CreateEdge, 40},
		{"C_DeleteEdge", C_DeleteEdge, 41},
		{"C_ListEdges", C_ListEdges, 42},
		{"C_ListAllEdges", C_ListAllEdges, 43},
		{"C_GraphQuery", C_GraphQuery, 44},
		{"C_GraphRank", C_GraphRank, 52},
		{"S_ServerReady", S_ServerReady, 100},
		{"S_NewMessage", S_NewMessage, 102},
		{"S_ErrorResponse", S_ErrorResponse, 104},
		{"S_StatsResponse", S_StatsResponse, 110},
		{"S_Pong", S_Pong, 126},
		{"S_AckUnsubscribeConvs", S_AckUnsubscribeConvs, 127},
		{"S_TaskCreated", S_TaskCreated, 130},
		{"S_TaskUpdated", S_TaskUpdated, 131},
		{"S_TaskDeleted", S_TaskDeleted, 132},
		{"S_TaskMoved", S_TaskMoved, 133},
		{"S_TaskListResponse", S_TaskListResponse, 134},
		{"S_TaskListPage", S_TaskListPage, 135},
		{"S_TaskFull", S_TaskFull, 136},
		{"S_AssetCreated", S_AssetCreated, 140},
		{"S_AssetUpdated", S_AssetUpdated, 141},
		{"S_AssetDeleted", S_AssetDeleted, 142},
		{"S_AssetFull", S_AssetFull, 143},
		{"S_AssetList", S_AssetList, 144},
		{"S_EdgeCreated", S_EdgeCreated, 150},
		{"S_EdgeDeleted", S_EdgeDeleted, 151},
		{"S_EdgeList", S_EdgeList, 152},
		{"S_AllEdgeList", S_AllEdgeList, 153},
		{"S_GraphQueryResult", S_GraphQueryResult, 154},
		{"S_GraphRankResult", S_GraphRankResult, 160},
	}
	for _, tt := range tests {
		if tt.got != tt.want {
			t.Errorf("%s = %d, want %d", tt.name, tt.got, tt.want)
		}
	}
}

func TestProtocolLimitsMatchOdin(t *testing.T) {
	goLimits := map[string]int{
		"MAX_ALLOWED_CONTENT_LENGTH":         MaxAllowedContentLength,
		"MAX_TOKEN_LENGTH":                   MaxTokenLength,
		"MAX_USER_ID_LENGTH":                 MaxUserIDLength,
		"MAX_NICKNAME_LENGTH":                MaxNicknameLength,
		"MAX_USERNAME_LENGTH":                MaxUsernameLength,
		"MAX_SUBSCRIBE_CONVS":                MaxSubscribeConvs,
		"MAX_MESSAGE_PAGE_COUNT":             MaxMessagePageCount,
		"MAX_TASK_TITLE_LENGTH":              MaxTaskTitleLength,
		"MAX_TASK_DESCRIPTION_LENGTH":        MaxTaskDescriptionLength,
		"MAX_APPOINTMENT_DESCRIPTION_LENGTH": MaxAppointmentDescriptionLength,
		"MAX_APPOINTMENT_URL_LENGTH":         MaxAppointmentURLLength,
		"MAX_ASSIGNEE_LENGTH":                MaxAssigneeLength,
		"MAX_EXTERNAL_REF_LENGTH":            MaxExternalRefLength,
		"MAX_PROJECT_LENGTH":                 MaxProjectLength,
		"MAX_TASK_PAGE_SIZE":                 MaxTaskPageSize,
		"MAX_TASK_SLICE_COUNT":               MaxTaskSliceCount,
		"MAX_SLICE_OUTCOME_LENGTH":           MaxSliceOutcomeLength,
		"MAX_FILE_ID_LENGTH":                 MaxFileIDLength,
		"MAX_FILENAME_LENGTH":                MaxFilenameLength,
		"MAX_MIME_TYPE_LENGTH":               MaxMimeTypeLength,
		"MAX_ATTACHMENTS_PER_TASK":           MaxAttachmentsPerTask,
		"MAX_OWNER_LENGTH":                   MaxOwnerLength,
		"MAX_PREVIEW_LENGTH":                 MaxPreviewLength,
		"MAX_PAYLOAD_LENGTH":                 MaxPayloadLength,
	}

	odinLimits := map[string]int{}
	for _, path := range []string{"protocol/types.odin", "protocol/assets.odin", "protocol/edges.odin"} {
		for name, value := range readConstants(t, path, `(?m)^\s*(MAX_[A-Z0-9_]+)\s*::\s*([0-9]+(?:\s*\*\s*[0-9]+)?)`) {
			odinLimits[name] = value
		}
	}

	assertSameLimits(t, "Go", goLimits, "Odin", odinLimits)
}

func TestBrowserLimitsMatchProtocol(t *testing.T) {
	protocolLimits := map[string]int{
		"MAX_TASK_TITLE_LENGTH":       MaxTaskTitleLength,
		"MAX_TASK_DESCRIPTION_LENGTH": MaxTaskDescriptionLength,
		"MAX_ATTACHMENTS_PER_TASK":    MaxAttachmentsPerTask,
		"MAX_PREVIEW_LENGTH":          MaxPreviewLength,
		"MAX_PAYLOAD_LENGTH":          MaxPayloadLength,
	}
	browserLimits := map[string]int{}
	for _, path := range []string{"client/tasks.js", "client/attachments.js", "client/assets.js"} {
		for name, value := range readConstants(t, path, `(?m)^\s*const\s+(MAX_[A-Z0-9_]+)\s*=\s*([0-9]+)\s*;`) {
			if _, shared := protocolLimits[name]; shared {
				browserLimits[name] = value
			}
		}
	}

	assertSameLimits(t, "browser", browserLimits, "protocol", protocolLimits)
}

func TestProtocolLimitsFitUint16WireFields(t *testing.T) {
	limits := map[string]int{
		"MAX_ALLOWED_CONTENT_LENGTH":  MaxAllowedContentLength,
		"MAX_TOKEN_LENGTH":            MaxTokenLength,
		"MAX_USER_ID_LENGTH":          MaxUserIDLength,
		"MAX_NICKNAME_LENGTH":         MaxNicknameLength,
		"MAX_USERNAME_LENGTH":         MaxUsernameLength,
		"MAX_SUBSCRIBE_CONVS":         MaxSubscribeConvs,
		"MAX_TASK_TITLE_LENGTH":       MaxTaskTitleLength,
		"MAX_TASK_DESCRIPTION_LENGTH": MaxTaskDescriptionLength,
		"MAX_ASSIGNEE_LENGTH":         MaxAssigneeLength,
		"MAX_EXTERNAL_REF_LENGTH":     MaxExternalRefLength,
		"MAX_PROJECT_LENGTH":          MaxProjectLength,
		"MAX_FILE_ID_LENGTH":          MaxFileIDLength,
		"MAX_FILENAME_LENGTH":         MaxFilenameLength,
		"MAX_MIME_TYPE_LENGTH":        MaxMimeTypeLength,
		"MAX_ATTACHMENTS_PER_TASK":    MaxAttachmentsPerTask,
		"MAX_OWNER_LENGTH":            MaxOwnerLength,
		"MAX_PREVIEW_LENGTH":          MaxPreviewLength,
		"MAX_PAYLOAD_LENGTH":          MaxPayloadLength,
	}

	for name, value := range limits {
		if value > int(^uint16(0)) {
			t.Errorf("%s = %d exceeds its uint16 wire field", name, value)
		}
	}
}

func readOdinFile(t *testing.T, path string) string {
	t.Helper()
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not locate protocol-go source directory")
	}
	data, err := os.ReadFile(filepath.Join(filepath.Dir(currentFile), "..", path))
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}

func readConstants(t *testing.T, path, pattern string) map[string]int {
	t.Helper()
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not locate protocol-go source directory")
	}
	data, err := os.ReadFile(filepath.Join(filepath.Dir(currentFile), "..", path))
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}

	constants := map[string]int{}
	for _, match := range regexp.MustCompile(pattern).FindAllStringSubmatch(string(data), -1) {
		value := 1
		for _, factor := range strings.Split(match[2], "*") {
			parsed, err := strconv.Atoi(strings.TrimSpace(factor))
			if err != nil {
				t.Fatalf("parse %s in %s: %v", match[1], path, err)
			}
			value *= parsed
		}
		constants[match[1]] = value
	}
	return constants
}

func assertSameLimits(t *testing.T, leftName string, left map[string]int, rightName string, right map[string]int) {
	t.Helper()
	for name, leftValue := range left {
		rightValue, ok := right[name]
		if !ok {
			t.Errorf("%s defines %s but %s does not", leftName, name, rightName)
			continue
		}
		if leftValue != rightValue {
			t.Errorf("%s mismatch: %s=%d, %s=%d", name, leftName, leftValue, rightName, rightValue)
		}
	}
	for name := range right {
		if _, ok := left[name]; !ok {
			t.Errorf("%s defines %s but %s does not", rightName, name, leftName)
		}
	}
}

// TestAssetTypesMatchOdin keeps the Go asset-type constants equal to the Odin
// enum. A type added on the server but not here would be unencodable and
// unnameable from the CLI, which is how a half-wired asset type ships.
func TestAssetTypesMatchOdin(t *testing.T) {
	source := readOdinFile(t, "protocol/assets.odin")
	start := strings.Index(source, "AssetType :: enum u16 {")
	if start < 0 {
		t.Fatal("AssetType enum not found in protocol/assets.odin")
	}
	body := source[start:]
	if end := strings.Index(body, "\n}"); end >= 0 {
		body = body[:end]
	}

	odin := map[string]int{}
	next := 0
	explicit := regexp.MustCompile(`^\s*([A-Za-z][A-Za-z0-9_]*)\s*=\s*(\d+)\s*,?`)
	implicit := regexp.MustCompile(`^\s*([A-Za-z][A-Za-z0-9_]*)\s*,`)
	for _, line := range strings.Split(body, "\n") {
		if match := explicit.FindStringSubmatch(line); match != nil {
			value, err := strconv.Atoi(match[2])
			if err != nil {
				t.Fatalf("parse asset type %s: %v", match[1], err)
			}
			odin[match[1]] = value
			next = value + 1
			continue
		}
		if match := implicit.FindStringSubmatch(line); match != nil {
			odin[match[1]] = next
			next++
		}
	}
	if len(odin) == 0 {
		t.Fatal("no asset types parsed from protocol/assets.odin")
	}

	goTypes := map[string]int{
		"Comment":          int(AssetTypeComment),
		"Document":         int(AssetTypeDocument),
		"File":             int(AssetTypeFile),
		"Agenda":           int(AssetTypeAgenda),
		"Note":             int(AssetTypeNote),
		"Reminder":         int(AssetTypeReminder),
		"RoomMapping":      int(AssetTypeRoomMapping),
		"CustomerCompany":  int(AssetTypeCustomerCompany),
		"CustomerContact":  int(AssetTypeCustomerContact),
		"CustomerActivity": int(AssetTypeCustomerActivity),
		"Slice":            int(AssetTypeSlice),
		"Appointment":      int(AssetTypeAppointment),
	}
	for name, value := range odin {
		got, present := goTypes[name]
		if !present {
			t.Errorf("protocol/assets.odin defines AssetType.%s = %d but protocol-go has no AssetType%s", name, value, name)
			continue
		}
		if got != value {
			t.Errorf("AssetType.%s = %d in protocol/assets.odin but %d in protocol-go", name, value, got)
		}
	}
	for name, value := range goTypes {
		if _, present := odin[name]; !present {
			t.Errorf("protocol-go defines AssetType%s = %d but protocol/assets.odin does not define it", name, value)
		}
	}
}
