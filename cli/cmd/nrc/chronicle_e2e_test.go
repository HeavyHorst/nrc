package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/gorilla/websocket"
	"github.com/heavyhorst/nrc/cli/pkg/config"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

// Always disposable: a private in-process WebSocket fixture, never an NRC server.
// This exercises the built CLI, public output and actual connection/retry path.
func TestHistoryChronicleCLIEndToEnd(t *testing.T) {
	dir := t.TempDir()
	binaryPath := filepath.Join(dir, "nrc")
	if data, err := exec.Command("go", "build", "-o", binaryPath, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, data)
	}
	const huge = "9007199254740993"
	var mu sync.Mutex
	counts := map[string]int{}
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/disposable-chronicle" {
			t.Errorf("wrong workspace: %s", r.URL.Path)
		}
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer ws.Close()
		for {
			_, data, err := ws.ReadMessage()
			if err != nil {
				return
			}
			message, err := protocol.ReadMessage(data)
			if err != nil {
				t.Error(err)
				return
			}
			var op, note, body string
			var correlation uint32
			responseOpcode := uint16(protocol.S_Chronicle)
			if message.Opcode == 62 {
				if len(message.Data) != 31 || binary.BigEndian.Uint64(message.Data) != 0 {
					t.Errorf("history scope/body: %x", message.Data)
					return
				}
				correlation = binary.BigEndian.Uint32(message.Data[27:])
				op, note, responseOpcode = "technical", "", 168
				before := binary.BigEndian.Uint64(message.Data[17:])
				body = `{"events":[{"id":"9007199254740993","timestamp":"9007199254740993","actorId":"human","actorName":"Ada","entityType":"asset","entityId":"9007199254740993","action":"updated","fields":["payload"]}],"nextBefore":"9007199254740993"}`
				if before != 0 {
					body = `{"events":[],"nextBefore":"0"}`
				}
				if message.Data[8] == 2 && binary.BigEndian.Uint64(message.Data[9:]) != 9007199254740993 {
					t.Error("lost entity ID precision")
				}
			} else if message.Opcode == protocol.C_Chronicle {
				var q protocol.ChronicleRequest
				if len(message.Data) < 4 || json.Unmarshal(message.Data[:len(message.Data)-4], &q) != nil {
					t.Error("invalid request")
					return
				}
				correlation = binary.BigEndian.Uint32(message.Data[len(message.Data)-4:])
				op, note = q.Op, q.NoteID
				if q.Op == "status" {
					body = `{"status":"ok","note_id":"` + note + `","enabled":true,"can_delete":true,"pending":1,"processing":2,"failed":3,"acknowledged":4,"gap_count":5,"expired":6,"raw_bytes":18446744073709551615,"calls":7,"input_tokens":8,"output_tokens":9}`
					if note == "1" {
						body = `{"status":"ok","can_delete":false}`
					}
					if note == "6" {
						body = `{"status":"ok"}`
					} // Old server: fail closed.
				} else if q.Op == "history" {
					if q.Limit < 1 || q.Limit > 16 {
						t.Error("unbounded history request")
					}
					body = `{"status":"ok","entries":[{"generation":"9007199254740993","note_id":"9007199254740993","summary":"A human-readable AI result","source_available":false}],"cursor":"9007199254740993","more":true}`
					if q.Cursor != "0" {
						body = `{"status":"ok","entries":[],"cursor":"","more":false}`
					}
				} else if q.Op == "gaps" {
					if q.NoteID != huge || q.Limit != 1 {
						t.Error("gaps filters lost")
					}
					body = `{"status":"ok","gaps":[{"first_source":"9007199254740993","last_source":"18446744073709551615","note_id":"9007199254740993","first_at":"9007199254740993","last_at":"18446744073709551615","reason":"expired","input_count":12,"source_available":false}],"cursor":"9007199254740993","more":true}`
					if q.Cursor != "0" {
						body = `{"status":"ok","gaps":[],"cursor":"","more":false}`
					}
				} else if q.Op == "delete" {
					body = `{"status":"deleted","deleted_through":"18446744073709551615"}`
				} else {
					t.Errorf("unexpected operation: %s", q.Op)
					return
				}
				if note == "3" {
					body = `{`
				}
				if note == "4" {
					body = `{"status":"forbidden"}`
				}
			} else {
				t.Errorf("unexpected opcode: %d", message.Opcode)
				return
			}
			mu.Lock()
			counts[op+":"+note]++
			count := counts[op+":"+note]
			mu.Unlock()
			if op == "delete" && note == "2" {
				return
			} // Unknown outcome: never replay.
			if (op == "status" && note == "5" && count == 1) || (op == "delete" && note == "7") {
				code := protocol.DBWorkerOverloaded
				failure := make([]byte, 10+len(code))
				binary.BigEndian.PutUint16(failure, protocol.S_ErrorResponse)
				binary.BigEndian.PutUint16(failure[2:], protocol.C_Chronicle)
				binary.BigEndian.PutUint16(failure[4:], uint16(len(code)))
				copy(failure[6:], code)
				binary.BigEndian.PutUint32(failure[6+len(code):], correlation)
				_ = ws.WriteMessage(websocket.BinaryMessage, failure)
				continue
			}
			frame := make([]byte, 6+len(body))
			binary.BigEndian.PutUint16(frame, responseOpcode)
			binary.BigEndian.PutUint32(frame[2:], correlation)
			copy(frame[6:], body)
			if err := ws.WriteMessage(websocket.BinaryMessage, frame); err != nil {
				return
			}
		}
	}))
	defer server.Close()
	t.Setenv("HOME", dir)
	cfg := &config.Config{Server: "ws" + strings.TrimPrefix(server.URL, "http") + "/", WorkspaceID: "disposable-chronicle", RoomID: 17}
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	run := func(ok bool, args ...string) string {
		t.Helper()
		cmd := exec.Command(binaryPath, args...)
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		data, err := cmd.Output()
		if ok && err != nil {
			t.Fatalf("%v: %v: %s", args, err, stderr.String())
		}
		if !ok {
			if err == nil {
				t.Fatalf("unexpected success: %v: %s", args, data)
			}
			if len(data) != 0 {
				t.Fatalf("failure wrote stdout: %s", data)
			}
			data = stderr.Bytes()
			human, _ := earlyOutputMode(args)
			if !human && !json.Valid(data) {
				t.Fatalf("failure not JSON: %s", data)
			}
		}
		return string(data)
	}
	assertContains := func(data string, values ...string) {
		t.Helper()
		for _, v := range values {
			if !strings.Contains(data, v) {
				t.Fatalf("missing %q in %s", v, data)
			}
		}
	}
	assertContains(run(true, "capabilities"), `"name":"history"`, `"name":"chronicle"`, `"name":"gaps"`, `"name":"yes"`)
	assertContains(run(true, "history", "list", "--kind", "asset", "--id", huge, "--limit", "1", "--fields", "id,entityId"), `"id":"`+huge+`"`, `"entityId":"`+huge+`"`, `"nextBefore":"`+huge+`"`)
	assertContains(run(true, "history", "list", "--before", huge, "--fields", "id"), `"events":[]`, `"nextBefore":"0"`)
	assertContains(run(true, "history", "list", "--human"), "Technical events", huge, "updated")
	assertContains(run(true, "chronicle", "history", "--note", huge, "--limit", "1", "--fields", "generation,source_available"), `"generation":"`+huge+`"`, `"source_available":false`, `"more":true`)
	assertContains(run(true, "chronicle", "history", "--cursor", huge, "--fields", "generation"), `"entries":[]`, `"more":false`)
	assertContains(run(true, "chronicle", "history", "--human"), "AI results", "human-readable AI result", "source_available=false")
	assertContains(run(true, "chronicle", "gaps", "--note", huge, "--limit", "1", "--fields", "first_source,reason"), `"first_source":"`+huge+`"`, `"reason":"expired"`, `"more":true`)
	assertContains(run(true, "chronicle", "gaps", "--note", huge, "--limit", "1", "--cursor", huge, "--fields", "reason"), `"gaps":[]`, `"more":false`)
	assertContains(run(true, "chronicle", "gaps", "--note", huge, "--limit", "1", "--human"), "expired", "inputs=12", "source_available=false")
	assertContains(run(true, "chronicle", "status", "--note", huge, "--fields", "can_delete,pending,processing,failed,acknowledged,gap_count,expired,raw_bytes"), `"can_delete":true`, `"processing":2`, `"gap_count":5`, `"expired":6`, `"raw_bytes":18446744073709551615`)
	assertContains(run(true, "chronicle", "status", "--note", huge, "--human"), "Workspace totals", "can_delete=true", "processing=2")
	assertContains(run(true, "chronicle", "status", "--note", "5"), `"status":"ok"`)
	assertContains(run(true, "chronicle", "delete", huge, "--yes"), `"status":"deleted"`, `"deleted_through":"18446744073709551615"`)
	for _, note := range []string{"1", "6"} {
		assertContains(run(false, "chronicle", "delete", note, "--yes"), `"code":"forbidden"`, `"retryable":false`)
	}
	for _, note := range []string{"2", "7"} {
		assertContains(run(false, "chronicle", "delete", note, "--yes"), `"code":"delete_not_confirmed"`, `"retryable":false`, "no automatic retry")
	}
	assertContains(run(false, "chronicle", "status", "--note", "4"), `"code":"forbidden"`)
	assertContains(run(false, "chronicle", "status", "--note", "3"), `"code":"unexpected_response"`)
	for _, args := range [][]string{
		{"chronicle", "delete", huge}, {"chronicle", "delete", huge, "--yes", "--fields", "status"},
		{"chronicle", "history", "--limit", "17"}, {"chronicle", "gaps", "--limit", "0"},
		{"chronicle", "status", "--note", "01"}, {"chronicle", "history", "--cursor", "18446744073709551616"},
		{"chronicle", "status", "--room", "engineering"}, {"history", "list", "--room", "engineering"},
		{"history", "list", "--kind", "asset"}, {"history", "list", "--id", "1"}, {"history", "list", "--limit", "101"},
	} {
		assertContains(run(false, args...), `"code":"invalid_argument"`)
	}
	assertContains(run(false, "chronicle", "status", "--human", "--fields", "pending"), "--fields cannot be used with --human")
	assertContains(run(false, "chronicle", "gaps", "--note", huge, "--limit", "1", "--fields", "nonesuch"), `"code":"invalid_argument"`)
	mu.Lock()
	if counts["status:5"] != 2 || counts["delete:1"] != 0 || counts["delete:6"] != 0 || counts["delete:2"] != 1 || counts["delete:7"] != 1 || counts["delete:"+huge] != 1 {
		t.Errorf("unsafe retries/permission check: %+v", counts)
	}
	mu.Unlock()
	server.Close()
	assertContains(run(false, "chronicle", "status"), `"code":"connection_failed"`, `"retryable":true`)
	assertContains(run(false, "history", "list"), `"code":"connection_failed"`)
}

func TestHistoryChronicleDecimalValidation(t *testing.T) {
	for _, v := range []string{"", "01", "+1", "-1", " 1", "1.0", "18446744073709551616"} {
		if _, err := historyDecimal(v, false); err == nil {
			t.Errorf("accepted %q", v)
		}
	}
	for _, v := range []string{"0", "9007199254740993", "18446744073709551615"} {
		if _, err := historyDecimal(v, false); err != nil {
			t.Errorf("rejected %q: %v", v, err)
		}
	}
	if _, err := historyDecimal("0", true); err == nil {
		t.Error("zero note accepted")
	}
	// Keep the no-confirmation guard callable without any live connection.
	if _, err := deleteChronicle(nil, "1", false); err == nil {
		t.Error("missing confirmation accepted")
	}
}

func TestHistoryChroniclePagingGuards(t *testing.T) {
	for _, op := range []string{"history", "gaps"} {
		q := protocol.ChronicleRequest{Op: op, NoteID: "9", Cursor: "9007199254740993", Limit: 2}
		for _, tc := range []struct {
			name         string
			ids          []string
			cursor, note string
			more, valid  bool
		}{
			{"terminal", nil, "", "9", false, true},
			{"valid", []string{"9007199254740994", "18446744073709551615"}, "18446744073709551615", "9", true, true},
			{"inclusive", []string{"9007199254740993"}, "9007199254740993", "9", false, false},
			{"descending", []string{"9007199254740995", "9007199254740994"}, "9007199254740994", "9", false, false},
			{"oversized", []string{"9007199254740994", "9007199254740995", "9007199254740996"}, "9007199254740996", "9", false, false},
			{"empty_more", nil, "9007199254740994", "9", true, false},
			{"cursor_mismatch", []string{"9007199254740994"}, "9007199254740995", "9", false, false},
			{"wrong_note", []string{"9007199254740994"}, "9007199254740994", "10", false, false},
			{"invalid_cursor", nil, "01", "9", false, false},
		} {
			t.Run(op+"/"+tc.name, func(t *testing.T) {
				r := &protocol.ChronicleResponse{Cursor: tc.cursor, More: tc.more}
				for _, id := range tc.ids {
					if op == "gaps" {
						r.Gaps = append(r.Gaps, protocol.ChronicleGap{FirstSource: id, NoteID: tc.note})
					} else {
						r.Entries = append(r.Entries, protocol.ChronicleEntry{Generation: id, NoteID: tc.note})
					}
				}
				if err := validateChroniclePage(q, r); (err == nil) != tc.valid {
					t.Fatalf("valid=%t: %v", tc.valid, err)
				}
				if tc.name == "terminal" && r.Cursor != q.Cursor {
					t.Fatal("terminal cursor reset")
				}
			})
		}
	}
}
