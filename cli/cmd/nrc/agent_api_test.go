package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestRoomFlagIsOnlyForChatAndPresence(t *testing.T) {
	for _, name := range []string{"task", "asset", "note", "customer", "file", "edge", "graph", "agenda", "reminder", "appointment", "search", "retrieve"} {
		cmd, _, err := rootCmd.Find([]string{name})
		if err != nil || cmd == rootCmd {
			t.Fatalf("missing data command %s: %v", name, err)
		}
		if cmd.Flags().Lookup("room") != nil || cmd.PersistentFlags().Lookup("room") != nil {
			t.Errorf("data command %s advertises a room selector", name)
		}
	}
	if chatCmd.PersistentFlags().Lookup("room") == nil || usersCmd.Flags().Lookup("room") == nil {
		t.Fatal("chat/presence lost their room selectors")
	}
	for _, doc := range []batchDocument{
		{Room: "7", Operations: []batchOperation{{Op: "task.delete", ID: "42"}}},
		{Operations: []batchOperation{{Op: "task.delete", ID: "42", Room: "-9223372036854775799"}}},
	} {
		if err := validateBatch(doc); err == nil {
			t.Fatal("legacy scoped batch could silently publish private data")
		}
	}
}

func TestTaskFiltersCompose(t *testing.T) {
	tasks := []*protocol.Task{{ID: 1, Title: "Fix API", Project: "P", Status: 1, Priority: 3, CreatedBy: "a"}, {ID: 2, Title: "other", Project: "P", Status: 3, Priority: 3, CreatedBy: "a"}}
	got := filterTasks(tasks, taskFilters{Project: "P", Statuses: []string{"todo,done"}, Priority: 3, HasPriority: true, CreatedBy: "a", TitleContains: "api"})
	if len(got) != 1 || got[0].ID != 1 {
		t.Fatalf("got %#v", got)
	}
}

func TestBatchValidation(t *testing.T) {
	var d batchDocument
	dec := json.NewDecoder(strings.NewReader(`{"operations":[{"op":"task.create","title":"x"},{"op":"edge.delete","id":4}]}`))
	dec.UseNumber()
	if err := dec.Decode(&d); err != nil {
		t.Fatal(err)
	}
	if err := validateBatch(d); err != nil {
		t.Fatal(err)
	}
	d.Operations[0].Op = "attachment.create"
	if validateBatchOperation(d.Operations[0]) == nil {
		t.Fatal("unsupported operation accepted")
	}
}

func TestBatchPerOperationValidation(t *testing.T) {
	badPriority := 255
	title := "x"
	if validateBatchOperation(batchOperation{Op: "task.create", Title: &title, Priority: &badPriority}) == nil {
		t.Fatal("priority accepted")
	}
	if validateBatchOperation(batchOperation{Op: "task.update", ID: "4", Status: "bogus"}) == nil {
		t.Fatal("status accepted")
	}
	if validateBatchOperation(batchOperation{Op: "task.update", ID: "4", Status: "progress"}) != nil {
		t.Fatal("status alias rejected")
	}
}

func TestBatchUpdateStringSentinels(t *testing.T) {
	empty, value := "", "kept"
	for _, tc := range []struct {
		name string
		in   *string
		want string
	}{{"omitted", nil, ""}, {"clear", &empty, "\x00"}, {"value", &value, "kept"}} {
		if got := batchUpdateString(tc.in); got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestCompileAtomicBatchForwardRefs(t *testing.T) {
	title := "task"
	d := batchDocument{Room: "2", Operations: []batchOperation{
		{Op: "edge.create", SourceType: "task", SourceRef: "later", TargetType: "asset", TargetID: "9", Relation: "references"},
		{Op: "task.create", Ref: "later", Title: &title},
	}}
	ops, _, err := compileAtomicBatch(d, func(string) (int64, error) { return 2, nil })
	if err != nil {
		t.Fatal(err)
	}
	if len(ops) != 2 || ops[0].Body[8] != protocol.TransactionRefCreatedBy || binary.BigEndian.Uint64(ops[0].Body[12:20]) != 1 {
		t.Fatalf("forward ref not compiled: %x", ops[0].Body)
	}
}

func TestCompileAtomicBatchTaskPatchBlockerRefAndClear(t *testing.T) {
	title := "blocker"
	room := func(string) (int64, error) { return 2, nil }
	d := batchDocument{Operations: []batchOperation{
		{Op: "task.update", ID: "9", BlockedByRef: "new-blocker"},
		{Op: "task.create", Ref: "new-blocker", Title: &title},
		{Op: "task.update", ID: "10", BlockedByID: "0"},
	}}
	ops, _, err := compileAtomicBatch(d, room)
	if err != nil {
		t.Fatal(err)
	}
	if len(ops) != 3 || binary.BigEndian.Uint16(ops[0].Body[28:30])&protocol.TransactionTaskPatchBlockedBy == 0 {
		t.Fatalf("blocker patch not compiled: %x", ops[0].Body)
	}
	if ops[0].Body[30] != protocol.TransactionRefCreatedBy || binary.BigEndian.Uint64(ops[0].Body[34:42]) != 1 {
		t.Fatalf("blocker forward ref not compiled: %x", ops[0].Body)
	}
	if ops[2].Body[30] != protocol.TransactionRefExisting || binary.BigEndian.Uint64(ops[2].Body[34:42]) != 0 {
		t.Fatalf("blocker clear not compiled: %x", ops[2].Body)
	}
}

func TestCompileAtomicBatchIfUpdatedAt(t *testing.T) {
	stamp, title, preview := int64(123), "changed", "preview"
	d := batchDocument{Operations: []batchOperation{
		{Op: "task.update", ID: "1", IfUpdatedAt: &stamp, Title: &title},
		{Op: "asset.update", ID: "2", IfUpdatedAt: &stamp, Preview: &preview},
		{Op: "task.delete", ID: "3", IfUpdatedAt: &stamp},
		{Op: "note.delete", ID: "4", IfUpdatedAt: &stamp},
	}}
	ops, _, err := compileAtomicBatch(d, func(string) (int64, error) { return 2, nil })
	if err != nil {
		t.Fatal(err)
	}
	for i, op := range ops {
		if got := int64(binary.BigEndian.Uint64(op.Body[20:28])); got != stamp {
			t.Fatalf("operation %d if_updated_at = %d", i, got)
		}
	}
	for _, op := range []batchOperation{{Op: "task.create", Title: &title, IfUpdatedAt: &stamp}, {Op: "edge.delete", ID: "1", IfUpdatedAt: &stamp}} {
		if err := validateBatchOperation(op); err == nil {
			t.Fatalf("if_updated_at accepted for %s", op.Op)
		}
	}
}

func TestCompileAtomicBatchReferenceErrors(t *testing.T) {
	title := "task"
	room := func(string) (int64, error) { return 2, nil }
	for _, d := range []batchDocument{
		{Operations: []batchOperation{{Op: "task.create", Ref: "x", Title: &title}, {Op: "task.create", Ref: "x", Title: &title}}},
		{Operations: []batchOperation{{Op: "edge.create", SourceType: "task", SourceRef: "missing", TargetType: "task", TargetID: "1", Relation: "references"}}},
		{Operations: []batchOperation{{Op: "note.create", Ref: "asset", Title: &title}, {Op: "edge.create", SourceType: "task", SourceRef: "asset", TargetType: "task", TargetID: "1", Relation: "references"}}},
	} {
		if _, _, err := compileAtomicBatch(d, room); err == nil {
			t.Fatalf("invalid refs accepted: %#v", d)
		}
	}
}

func TestCompileAtomicBatchRejectsUnsupportedNoteFieldsAndAttachments(t *testing.T) {
	title, content := "changed", "body"
	room := func(string) (int64, error) { return 2, nil }
	for _, op := range []batchOperation{
		{Op: "note.update", ID: "1", Title: &title, Content: &content},
		{Op: "note.create", Title: &title, Attachments: json.RawMessage(`[]`)},
	} {
		if _, _, err := compileAtomicBatch(batchDocument{Operations: []batchOperation{op}}, room); err == nil {
			t.Fatalf("unsupported operation accepted: %#v", op)
		}
	}
}

func TestEarlyOutputMode(t *testing.T) {
	for _, tc := range []struct {
		args  []string
		human bool
	}{
		{[]string{"--human"}, true}, {[]string{"--human=true", "--json=true"}, false},
		{[]string{"--human=false"}, false}, {[]string{"--", "--human"}, false},
	} {
		if got, _ := earlyOutputMode(tc.args); got != tc.human {
			t.Fatalf("%v: got %v", tc.args, got)
		}
	}
}

func TestEarlyOutputModePrettyAndBooleanSpellings(t *testing.T) {
	human, pretty := earlyOutputMode([]string{"--human=TRUE", "--pretty=1"})
	if !human || !pretty {
		t.Fatalf("human=%v pretty=%v", human, pretty)
	}
}

func TestChatMessageEventStableFlatJSON(t *testing.T) {
	b, err := json.Marshal(chatMessageEvent{Event: "message", RoomID: 2, Sequence: 3, Username: "u", Timestamp: 4, ContentType: 1, Content: "c"})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"event":"message","room_id":2,"sequence":3,"username":"u","timestamp":4,"content_type":1,"content":"c"}`
	if string(b) != want {
		t.Fatalf("got %s", b)
	}
}

func TestBuildChatSendMessageSelectsProtocolAndReusesClientID(t *testing.T) {
	id, err := parseClientMessageID("00112233-4455-6677-8899-aabbccddeeff")
	if err != nil {
		t.Fatal(err)
	}
	ephemeral, err := buildChatSendMessage(42, "now", protocol.ContentTypePlainText, false, protocol.ClientMessageID{})
	if err != nil || ephemeral.Opcode != protocol.C_SendMessage {
		t.Fatalf("ephemeral message = %#v, err = %v", ephemeral, err)
	}
	retained, err := buildChatSendMessage(42, "remember this", protocol.ContentTypeMarkdown, true, id)
	if err != nil || retained.Opcode != protocol.C_SendMessageV2 {
		t.Fatalf("retained message = %#v, err = %v", retained, err)
	}
	if len(retained.Data) != 31+len("remember this") {
		t.Fatalf("payload length = %d", len(retained.Data))
	}
	if got := binary.BigEndian.Uint64(retained.Data[:8]); got != 42 {
		t.Fatalf("room ID = %d", got)
	}
	if !bytes.Equal(retained.Data[8:24], id[:]) {
		t.Fatalf("client message ID = %x", retained.Data[8:24])
	}
	if got := binary.BigEndian.Uint32(retained.Data[24:28]); got != chatSendCorrelationID {
		t.Fatalf("correlation ID = %d", got)
	}
	if retained.Data[28] != protocol.ContentTypeMarkdown || string(retained.Data[31:]) != "remember this" {
		t.Fatalf("content payload = %x", retained.Data[28:])
	}
	retry, err := buildChatSendMessage(42, "remember this", protocol.ContentTypeMarkdown, true, id)
	if err != nil || !bytes.Equal(retry.Data, retained.Data) {
		t.Fatal("retry did not reuse the exact retained payload")
	}
}

func TestParseClientMessageIDRejectsInvalidAndZero(t *testing.T) {
	for _, value := range []string{"short", strings.Repeat("z", 32), strings.Repeat("0", 32)} {
		if _, err := parseClientMessageID(value); err == nil {
			t.Fatalf("accepted invalid client message ID %q", value)
		}
	}
}

func retainedAckPayload(correlationID uint32, sequence uint64, timestamp int64) []byte {
	data := make([]byte, 20)
	binary.BigEndian.PutUint32(data, correlationID)
	binary.BigEndian.PutUint64(data[4:], sequence)
	binary.BigEndian.PutUint64(data[12:], uint64(timestamp))
	return data
}

func TestValidateRetainedChatAck(t *testing.T) {
	valid := &protocol.Message{Opcode: protocol.S_AckSendMessage, Data: retainedAckPayload(chatSendCorrelationID, 9, 10)}
	ack, err := validateRetainedChatAck(valid)
	if err != nil || ack.AssignedSeq != 9 {
		t.Fatalf("ack = %#v, err = %v", ack, err)
	}
	for name, response := range map[string]*protocol.Message{
		"opcode":        {Opcode: protocol.S_Pong, Data: valid.Data},
		"correlation":   {Opcode: protocol.S_AckSendMessage, Data: retainedAckPayload(2, 9, 10)},
		"zero sequence": {Opcode: protocol.S_AckSendMessage, Data: retainedAckPayload(chatSendCorrelationID, 0, 10)},
		"trailing data": {Opcode: protocol.S_AckSendMessage, Data: append(retainedAckPayload(chatSendCorrelationID, 9, 10), 0)},
	} {
		if _, err := validateRetainedChatAck(response); err == nil {
			t.Fatalf("%s: invalid acknowledgement accepted", name)
		}
	}
}

func TestChatSendRetainedFlagIsExplicitAndDisabledByDefault(t *testing.T) {
	flag := chatSendCmd.Flags().Lookup("retained")
	if flag == nil || flag.DefValue != "false" {
		t.Fatalf("retained flag = %#v", flag)
	}
	if chatSendCmd.Flags().Lookup("client-message-id") == nil {
		t.Fatal("client-message-id flag is missing")
	}
}

func TestRetainedSendUnknownMessageIncludesReusableID(t *testing.T) {
	id := "00112233445566778899aabbccddeeff"
	for _, outcomeErr := range []error{
		fmt.Errorf("connection closed"),
		fmt.Errorf("unexpected retained message correlation ID"),
	} {
		message := retainedSendUnknownMessage(id, outcomeErr)
		if strings.Count(message, id) != 2 || !strings.Contains(message, "--retained --client-message-id "+id) || !strings.Contains(message, "outcome is unknown") {
			t.Fatalf("unsafe retry message: %q", message)
		}
	}
}

func TestRetainedChatSuccessOutputIncludesRetryIdentity(t *testing.T) {
	ack := &protocol.AckSendMessage{ClientReqID: chatSendCorrelationID, AssignedSeq: 9, Timestamp: 10}
	id := "00112233445566778899aabbccddeeff"
	t.Cleanup(func() { _ = output.Configure(false, false, "") })
	if err := output.Configure(true, false, ""); err != nil {
		t.Fatal(err)
	}
	human := captureStdout(t, func() { outputRetainedChatSuccess(ack, id) })
	if !strings.Contains(human, "sequence 9") || !strings.Contains(human, "timestamp 10 Unix ns") || !strings.Contains(human, id) {
		t.Fatalf("incomplete human output: %q", human)
	}
	if err := output.Configure(false, false, ""); err != nil {
		t.Fatal(err)
	}
	machine := captureStdout(t, func() { outputRetainedChatSuccess(ack, id) })
	var result struct {
		ID      uint64         `json:"id"`
		Details map[string]any `json:"details"`
	}
	if err := json.Unmarshal([]byte(machine), &result); err != nil {
		t.Fatal(err)
	}
	if result.ID != 9 || result.Details["client_message_id"] != id || result.Details["retained"] != true || result.Details["sequence"] != float64(9) || result.Details["timestamp"] != float64(10) {
		t.Fatalf("incomplete machine output: %s", machine)
	}
}

func TestParseTaskFilters(t *testing.T) {
	f, err := parseTaskFilters("p", []string{"progress,in-progress", "done"}, 254, true, "u", "x")
	if err != nil || len(f.Statuses) != 3 || f.Statuses[0] != "in-progress" {
		t.Fatalf("filters=%#v err=%v", f, err)
	}
	if _, err := parseTaskFilters("", []string{"unknown"}, 0, false, "", ""); err == nil {
		t.Fatal("unknown status accepted")
	}
	if _, err := parseTaskFilters("", nil, 255, true, "", ""); err == nil {
		t.Fatal("priority 255 accepted")
	}
}

func TestTaskStatusMask(t *testing.T) {
	if got := taskStatusMask([]string{"backlog", "in-progress", "done"}); got != 0x0d {
		t.Fatalf("taskStatusMask = 0x%02x, want 0x0d", got)
	}
	if got := taskStatusMask([]string{"backlog", "todo", "in-progress", "done", "note"}); got != 0x1f {
		t.Fatalf("all-status mask = 0x%02x, want 0x1f", got)
	}
}

func TestCapabilitiesOmitsHiddenJSONFlag(t *testing.T) {
	data, _ := json.Marshal(capabilities())
	if bytes.Contains(data, []byte(`"name":"json"`)) {
		t.Fatal("hidden compatibility flag exposed")
	}
}

func TestCapabilitiesOutputContract(t *testing.T) {
	c := capabilities()
	contract, ok := c["output_contract"].(map[string]any)
	if !ok || contract["default"] != "json" || contract["chat_watch"] == nil || contract["fields"] == nil {
		t.Fatalf("incomplete output contract: %#v", contract)
	}
}
