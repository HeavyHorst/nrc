package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/gorilla/websocket"
	p "github.com/heavyhorst/nrc/protocol-go"
)

// Exercise the actual executable against a disposable protocol peer, including
// CAS rejection. This verifies CLI requests/results, not Odin server execution.
func TestMonitorCLI(t *testing.T) {
	dir := t.TempDir()
	binaryPath := filepath.Join(dir, "nrc")
	if b, err := exec.Command("go", "build", "-o", binaryPath, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v %s", err, b)
	}
	var mu sync.Mutex
	assets := map[uint64]p.Asset{}
	var writes int
	conflict := false
	dropIncidentReceipt := false
	controlMode := ""
	controlActions := []byte{}
	statusMode := ""
	discardMode := ""
	discardApplied := false
	discardRequests := 0
	writeAsset := func(b *bytes.Buffer, a p.Asset, full bool) {
		for _, v := range []any{a.AssetType, a.AssetID, uint16(0), uint64(0), uint16(0), int64(100), a.UpdatedAt, uint64(0), uint8(0), uint32(len(a.Payload)), uint16(len(a.Preview))} {
			_ = binary.Write(b, binary.BigEndian, v)
		}
		b.WriteString(a.Preview)
		if full {
			_ = binary.Write(b, binary.BigEndian, uint16(len(a.Payload)))
			b.WriteString(a.Payload)
		}
		_ = binary.Write(b, binary.BigEndian, uint16(0))
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		up := websocket.Upgrader{}
		ws, err := up.Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer ws.Close()
		for {
			_, wire, err := ws.ReadMessage()
			if err != nil {
				return
			}
			m, err := p.ReadMessage(wire)
			if err != nil {
				t.Error(err)
				return
			}
			mu.Lock()
			var b bytes.Buffer
			code := p.S_AssetFull
			switch m.Opcode {
			case p.C_GetAsset:
				id := binary.BigEndian.Uint64(m.Data[8:])
				writeAsset(&b, assets[id], true)
			case p.C_ListAssetsPaged:
				code = p.S_AssetListPage
				kind := binary.BigEndian.Uint16(m.Data[8:])
				limit := int(binary.BigEndian.Uint16(m.Data[11:]))
				var cursor uint64
				if m.Data[13] != 0 {
					cursor = binary.BigEndian.Uint64(m.Data[22:])
				}
				all := []p.Asset{}
				for _, a := range assets {
					if a.AssetType == kind {
						all = append(all, a)
					}
				}
				sort.Slice(all, func(i, j int) bool { return all[i].UpdatedAt > all[j].UpdatedAt })
				total := len(all)
				rows := []p.Asset{}
				for _, a := range all {
					if cursor == 0 || a.UpdatedAt < assets[cursor].UpdatedAt {
						rows = append(rows, a)
					}
				}
				more := uint8(0)
				if len(rows) > limit {
					more = 1
					rows = rows[:limit]
				}
				last := p.Asset{}
				if more != 0 {
					last = rows[len(rows)-1]
				}
				for _, v := range []any{uint64(0), uint8(0), more, last.UpdatedAt, last.AssetID, uint32(total), uint16(len(rows)), uint32(0)} {
					_ = binary.Write(&b, binary.BigEndian, v)
				}
				for _, a := range rows {
					writeAsset(&b, a, false)
				}
			case p.C_MonitorDelivery:
				code = p.S_MonitorDelivery
				if binary.BigEndian.Uint64(m.Data[4:]) != 3 || m.Data[12] != 1 {
					t.Error("wrong delivery target")
				}
				result := p.MonitorDeliveryResult{Version: 1, State: 3, ID: "99", Generation: "4", CreatedAt: "1", AvailableAt: "1", LeaseUntil: "0"}
				switch m.Data[13] {
				case 6:
					result.State = 5
					result.ID = "0"
					result.Routes = []string{"9"}
				case 0:
				case 5:
					if binary.BigEndian.Uint64(m.Data[14:]) != 99 || binary.BigEndian.Uint64(m.Data[22:]) != 4 || string(m.Data[31:]) != "9" {
						t.Error("discard lost exact event fence")
					}
					discardRequests++
					if !discardApplied {
						writes++
						discardApplied = true
					}
					result.State = 4
					switch discardMode {
					case "lost":
						discardMode = ""
						mu.Unlock()
						return // Applied once; the exact retry receives the saved receipt.
					case "wrong-id":
						result.ID = "100"
					case "wrong-generation":
						result.Generation = "5"
					}
				default:
					t.Error("CLI must not claim delivery")
				}
				data, _ := json.Marshal(result)
				b.Write([]byte{0, 0, 0, 0})
				b.Write(data)
			case p.C_QueryMonitorStatus:
				code = p.S_MonitorStatusPage
				if len(m.Data) != 31 || binary.BigEndian.Uint64(m.Data[4:]) != 3 {
					t.Error("invalid instance query")
				}
				cursor := binary.BigEndian.Uint64(m.Data[12:])
				if cursor != 0 && ((cursor != 9007199254740993 || m.Data[20] != 1) && (cursor != 71 || m.Data[20] != 6) || binary.BigEndian.Uint64(m.Data[21:]) != 1234567890123456789) {
					t.Error("pagination lost cursor, rank or page time")
				}
				if statusMode == "expired" {
					if cursor == 0 {
						t.Error("expected continuation request")
					}
					code = p.S_ErrorResponse
					message := "monitor_status_failed"
					_ = binary.Write(&b, binary.BigEndian, p.C_QueryMonitorStatus)
					_ = binary.Write(&b, binary.BigEndian, uint16(len(message)))
					b.WriteString(message)
					_ = binary.Write(&b, binary.BigEndian, uint32(0))
					break
				}
				value := 17.25
				rows := []p.MonitorStatusRow{
					{ID: "9007199254740993", MonitorID: "3", Status: "failing", Identity: `{"host":"a","mount":"/"}`, IncidentID: "0"},
					{ID: "71", MonitorID: "3", Status: "healthy", Identity: `{"host":"b","mount":"/data"}`, Value: &value, IncidentID: "0"},
				}
				if m.Data[30] == 1 {
					rows = append(rows, p.MonitorStatusRow{ID: "90", MonitorID: "3", Status: "retired", Retired: true, Identity: "old-host"})
				}
				if cursor == 71 {
					rows = rows[2:]
				} else if cursor != 0 {
					rows = rows[1:]
				}
				limit := int(m.Data[29])
				more := len(rows) > limit
				if more {
					rows = rows[:limit]
				}
				page := p.MonitorStatusPage{Version: 1, MonitorID: "3", At: "1234567890123456789", CursorID: "0", HasMore: more, Rows: rows}
				if len(rows) > 0 {
					page.CursorID = rows[len(rows)-1].ID
				}
				if more {
					page.CursorRank = 1
					if page.CursorID == "71" {
						page.CursorRank = 6
					}
				}
				if statusMode == "empty" {
					page.Rows, page.HasMore = []p.MonitorStatusRow{}, false
				}
				if statusMode == "wrong-monitor" {
					page.MonitorID = "4"
				}
				switch statusMode {
				case "bad-cursor":
					page.CursorID = "not-an-id"
				case "zero-cursor":
					page.CursorID = "0"
				case "bad-time":
					page.At = "not-a-time"
				case "zero-time":
					page.At = "0"
				case "wrong-opcode":
					code = p.S_MonitorDelivery
				}
				data, _ := json.Marshal(page)
				if statusMode == "malformed" {
					data = []byte(`{"version":`)
				}
				correlation := uint32(0)
				if statusMode == "wrong-correlation" {
					correlation = 123
				}
				_ = binary.Write(&b, binary.BigEndian, correlation)
				b.Write(data)
			case p.C_ControlMonitorInstance:
				code = p.S_MonitorInstanceControlled
				id := binary.BigEndian.Uint64(m.Data[4:])
				instance := binary.BigEndian.Uint64(m.Data[20:])
				a := assets[id]
				if len(m.Data) != 29 || id != 3 || instance != 71 || int64(binary.BigEndian.Uint64(m.Data[12:])) != a.UpdatedAt {
					t.Error("control lost monitor revision or instance identity")
				}
				if controlMode == "conflict" {
					code = p.S_ErrorResponse
					message := "monitor_control_failed"
					_ = binary.Write(&b, binary.BigEndian, p.C_ControlMonitorInstance)
					_ = binary.Write(&b, binary.BigEndian, uint16(len(message)))
					b.WriteString(message)
					_ = binary.Write(&b, binary.BigEndian, uint32(0))
					break
				}
				controlActions = append(controlActions, m.Data[28])
				a.UpdatedAt++
				assets[id] = a
				writes++
				if controlMode == "lost" {
					mu.Unlock()
					return
				}
				correlation := uint32(0)
				revision := a.UpdatedAt
				switch controlMode {
				case "wrong-monitor":
					id++
				case "wrong-instance":
					instance++
				case "wrong-correlation":
					correlation++
				case "old-revision":
					revision--
				case "wrong-opcode":
					code = p.S_IncidentActionApplied
				}
				for _, v := range []any{correlation, id, instance, revision, uint8(0)} {
					_ = binary.Write(&b, binary.BigEndian, v)
				}
				if controlMode == "truncated" {
					b.Truncate(b.Len() - 1)
				}
			case p.C_ActOnIncident:
				code = p.S_IncidentActionApplied
				id := binary.BigEndian.Uint64(m.Data[4:])
				a := assets[id]
				if conflict {
					conflict = false
					a.UpdatedAt++
					assets[id] = a
				}
				if int64(binary.BigEndian.Uint64(m.Data[12:])) != a.UpdatedAt {
					code = p.S_ErrorResponse
					message := "incident_action_failed"
					_ = binary.Write(&b, binary.BigEndian, p.C_ActOnIncident)
					_ = binary.Write(&b, binary.BigEndian, uint16(len(message)))
					b.WriteString(message)
					_ = binary.Write(&b, binary.BigEndian, uint32(0))
					break
				}
				var record map[string]any
				if err := json.Unmarshal([]byte(a.Preview), &record); err != nil {
					t.Error(err)
				}
				if m.Data[20] == byte(p.AcknowledgeIncident) {
					record["acknowledged_by"], record["acknowledged_at"] = "operator", "2000"
				} else {
					record["assigned_to"] = string(m.Data[23:])
				}
				preview, _ := json.Marshal(record)
				a.Preview = string(preview)
				a.UpdatedAt++
				assets[id] = a
				writes++
				if dropIncidentReceipt {
					dropIncidentReceipt = false
					mu.Unlock()
					return // Commit succeeded; close the socket without its receipt.
				}
				for _, v := range []any{uint32(0), id, a.UpdatedAt, uint8(0)} {
					_ = binary.Write(&b, binary.BigEndian, v)
				}
			case p.C_ApplyTransaction:
				code = p.S_TransactionResult
				if binary.BigEndian.Uint16(m.Data[2:]) != 1 {
					t.Error("expected one atomic operation")
				}
				op := m.Data[8]
				rd := bytes.NewReader(m.Data[14:])
				read := func(v any) {
					if err := binary.Read(rd, binary.BigEndian, v); err != nil {
						t.Error(err)
					}
				}
				text := func() string {
					var n uint16
					read(&n)
					data := make([]byte, n)
					if _, err := io.ReadFull(rd, data); err != nil {
						t.Error(err)
					}
					return string(data)
				}
				var workspace uint64
				read(&workspace)
				if workspace != 0 {
					t.Error("not workspace scoped")
				}
				a := p.Asset{}
				rejected := false
				if op == p.TransactionOpAssetCreate {
					a.AssetID = uint64(len(assets) + 1)
					read(&a.AssetType)
					var parent uint16
					read(&parent)
					if parent != 0 {
						t.Error("unexpected parent")
					}
					read(&a.PayloadEncoding)
					read(&a.PayloadRawLen)
					a.Preview = text()
					a.Payload = text()
				} else if op == p.TransactionOpAssetPatch {
					var ref [12]byte
					read(&ref)
					id := binary.BigEndian.Uint64(ref[4:])
					a = assets[id]
					var expected int64
					read(&expected)
					if conflict {
						conflict = false
						a.UpdatedAt++
						assets[id] = a
					}
					rejected = expected != a.UpdatedAt
					var present uint8
					read(&present)
					if present&1 != 0 {
						a.Preview = text()
					}
					if present&2 != 0 {
						read(&a.PayloadEncoding)
						read(&a.PayloadRawLen)
						a.Payload = text()
					}
				} else {
					t.Errorf("unexpected mutation %d", op)
				}
				if rd.Len() != 0 || a.PayloadRawLen != uint32(len(a.Payload)) {
					t.Error("invalid mutation body")
				}
				if rejected {
					for _, v := range []any{uint8(1), uint8(p.TransactionStatusRejected), uint32(1), uint16(0), uint16(0)} {
						_ = binary.Write(&b, binary.BigEndian, v)
					}
				} else {
					writes++
					a.UpdatedAt = int64(1000 + writes)
					assets[a.AssetID] = a
					for _, v := range []any{uint8(1), uint8(p.TransactionStatusCommitted), uint32(1), uint16(p.TransactionFailedNone), uint16(1), op, uint8(0), a.AssetID} {
						_ = binary.Write(&b, binary.BigEndian, v)
					}
				}
			default:
				t.Errorf("unexpected request %d", m.Opcode)
			}
			mu.Unlock()
			response, _ := (&p.Message{Opcode: code, Data: b.Bytes()}).Write()
			if ws.WriteMessage(websocket.BinaryMessage, response) != nil {
				return
			}
		}
	}))
	defer server.Close()
	configDir := filepath.Join(dir, ".config", "nrc")
	if err := os.MkdirAll(configDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "config.yaml"), []byte(fmt.Sprintf("server: %q\nworkspace_id: monitor-test\n", "ws"+strings.TrimPrefix(server.URL, "http")+"/")), 0600); err != nil {
		t.Fatal(err)
	}
	run := func(stdin string, ok bool, args ...string) string {
		t.Helper()
		c := exec.Command(binaryPath, args...)
		c.Env = append(os.Environ(), "HOME="+dir)
		c.Stdin = strings.NewReader(stdin)
		b, err := c.CombinedOutput()
		if (err == nil) != ok {
			t.Fatalf("%v: %v %s", args, err, b)
		}
		return string(b)
	}
	get := func(id string) monitorRecord {
		t.Helper()
		var r monitorRecord
		if err := json.Unmarshal([]byte(run("", true, "monitor", "get", id)), &r); err != nil {
			t.Fatal(err)
		}
		return r
	}
	for _, tc := range []struct{ name, kind string }{{"Metrics", "victoriametrics"}, {"Logs", "victorialogs"}} {
		run("", true, "monitor", "source", "create", tc.name, "--kind", tc.kind, "--url", "http://victoria:8428")
	}
	query := "100 * node_filesystem_avail_bytes\n/ node_filesystem_size_bytes\n"
	path := filepath.Join(dir, "disk.metricsql")
	if err := os.WriteFile(path, []byte(query), 0600); err != nil {
		t.Fatal(err)
	}
	run("", true, "monitor", "create", "Disk", "--source", "1", "--query-file", path, "--identity", "instance,mountpoint", "--trigger", "<10", "--recovery", ">15", "--interval", "30s", "--failures", "7", "--unit", "percent")
	r := get("3")
	var policy monitorPolicy
	_ = json.Unmarshal(r.Config, &policy)
	var check struct {
		Query, SourceID, SourceRevision string
		Trigger                         struct{ Value json.Number }
	}
	var d map[string]json.RawMessage
	_ = json.Unmarshal(r.Check, &d)
	if string(d["source_id"]) != `"1"` || string(d["source_revision"]) != `"1001"` || policy.Interval != 30e9 || policy.Failures != 7 || policy.Recoveries != 5 || policy.Timeout != 10e9 {
		t.Fatalf("bad defaults/config: %s %s", r.Config, r.Check)
	}
	_ = json.Unmarshal(r.Check, &check)
	if check.Query != query || policy.Unit != "percent" || check.Trigger.Value != "10" {
		t.Fatal("query, display unit or raw trigger changed")
	}
	run("", true, "monitor", "source", "update", "1", "--secret-ref", "READ_METRICS", "--retention", "90d")
	run("", true, "monitor", "update", "3", "--name", "Disk space")
	r = get("3")
	_ = json.Unmarshal(r.Config, &policy)
	if policy.Unit != "percent" {
		t.Fatal("unrelated update lost display unit")
	}
	_ = json.Unmarshal(r.Check, &d)
	if string(d["source_revision"]) != `"1001"` {
		t.Fatal("unrelated edit silently repinned source")
	}
	run("", true, "monitor", "update", "3", "--refresh-source", "--trigger", ">18446744073709551615", "--recovery", "", "--unit", "bytes")
	r = get("3")
	_ = json.Unmarshal(r.Config, &policy)
	if policy.Unit != "bytes" {
		t.Fatal("unit update not applied")
	}
	_ = json.Unmarshal(r.Check, &d)
	if string(d["source_revision"]) != `"1004"` || !strings.Contains(string(d["trigger"]), "18446744073709551615") || bytes.Contains(r.Check, []byte(`"recovery"`)) {
		t.Fatalf("repin/decimal/clear failed: %s", r.Check)
	}
	run("", true, "monitor", "source", "update", "1", "--secret-ref", "")
	var sourceRecord monitorRecord
	_ = json.Unmarshal([]byte(run("", true, "monitor", "source", "get", "1")), &sourceRecord)
	if bytes.Contains(sourceRecord.Config, []byte("secret_ref")) || !bytes.Contains(sourceRecord.Config, []byte("90d")) {
		t.Fatalf("source partial update lost data: %s", sourceRecord.Config)
	}
	mu.Lock()
	before := writes
	mu.Unlock()
	for _, unit := range []string{"", "number", "percent", "bytes"} {
		var proposed struct {
			Record monitorRecord `json:"record"`
		}
		out := run("", true, "monitor", "update", "3", "--unit", unit, "--dry-run")
		if err := json.Unmarshal([]byte(out), &proposed); err != nil {
			t.Fatal(err)
		}
		var config monitorPolicy
		if err := json.Unmarshal(proposed.Record.Config, &config); err != nil || config.Unit != unit || !bytes.Equal(proposed.Record.Check, r.Check) {
			t.Fatalf("display-only update changed check or lost unit %q: %s", unit, out)
		}
	}
	dry := run("_time:5m | stats by (host) count()", true, "monitor", "create", "Errors", "--source", "2", "--query-file", "-", "--identity", "host", "--trigger", ">0", "--dry-run")
	if !strings.Contains(dry, `"kind":"victorialogs"`) || !strings.Contains(dry, `"dry_run":true`) {
		t.Fatal(dry)
	}
	for _, args := range [][]string{
		{"monitor", "update", "3"},
		{"monitor", "update", "3", "--unit", "kilobytes"},
		{"monitor", "update", "3", "--trigger", "<=10", "--recovery", ">=10"},
		{"monitor", "update", "3", "--identity", "host,host"},
		{"monitor", "update", "3", "--timeout", "2m"},
		{"monitor", "update", "3", "--query", "x", "--query-file", "-"},
		{"monitor", "source", "update", "1", "--url", "http://host:abc"},
	} {
		if out := run("", false, args...); !strings.Contains(out, `"error"`) {
			t.Fatal(out)
		}
	}
	run(strings.Repeat("x", 32769), false, "monitor", "update", "3", "--query-file", "-")
	run(string([]byte{0xff}), false, "monitor", "update", "3", "--query-file", "-")
	mu.Lock()
	if writes != before {
		t.Errorf("dry-run/invalid input wrote %d changes", writes-before)
	}
	conflict = true
	mu.Unlock()
	old := get("3")
	run("", false, "monitor", "update", "3", "--name", "Lost update")
	if now := get("3"); now.Name != old.Name {
		t.Fatal("concurrent edit overwritten")
	}
	var page struct {
		Entries []monitorRecord
		HasMore bool   `json:"has_more"`
		Next    string `json:"next_cursor"`
	}
	if err := json.Unmarshal([]byte(run("", true, "monitor", "source", "list", "--limit", "1")), &page); err != nil || len(page.Entries) != 1 || !page.HasMore {
		t.Fatalf("bad page %+v %v", page, err)
	}
	first := page.Entries[0].ID
	if err := json.Unmarshal([]byte(run("", true, "monitor", "source", "list", "--limit", "1", "--cursor", page.Next)), &page); err != nil || len(page.Entries) != 1 || page.HasMore || page.Entries[0].ID == first {
		t.Fatalf("bad next page %+v %v", page, err)
	}
	if out := run("", true, "monitor", "list", "--human"); !strings.Contains(out, "Disk space") || !strings.Contains(out, "REVISION") {
		t.Fatal(out)
	}
	if out := run("", true, "monitor", "get", "3", "--fields", "id,name"); !strings.Contains(out, `"id":`+strconv.Itoa(3)) || strings.Contains(out, `"check"`) {
		t.Fatal(out)
	}
	mu.Lock()
	assets[40] = p.Asset{AssetType: p.AssetTypeIncident, AssetID: 40, UpdatedAt: 2000, Preview: `{"version":1,"title":"Disk full","monitor_id":"3","instance_id":"7","episode":"2","status":"firing","opened_at":"1000"}`}
	mu.Unlock()
	incident := func() incidentRecord {
		t.Helper()
		var r incidentRecord
		if err := json.Unmarshal([]byte(run("", true, "incident", "get", "40")), &r); err != nil {
			t.Fatal(err)
		}
		return r
	}
	run("", true, "incident", "assign", "40", "alice")
	run("", true, "incident", "ack", "40")
	if r := incident(); r.AssignedTo != "alice" || r.AcknowledgedBy != "operator" || r.Status != "firing" || r.Episode != "2" {
		t.Fatalf("bad incident: %+v", r)
	}
	if out := run("", true, "incident", "list", "--human"); !strings.Contains(out, "Disk full") || !strings.Contains(out, "alice") {
		t.Fatal(out)
	}
	run("", true, "incident", "assign", "40", "--clear")
	if r := incident(); r.AssignedTo != "" || r.AcknowledgedBy != "operator" {
		t.Fatalf("bad cleared incident: %+v", r)
	}
	run("", false, "incident", "assign", "40")
	run("", false, "incident", "assign", "40", "alice", "--clear")
	run("", false, "incident", "ack", "3")
	mu.Lock()
	conflict = true
	mu.Unlock()
	if out := run("", false, "incident", "assign", "40", "bob"); !strings.Contains(out, `"code":"server_error"`) || !strings.Contains(out, "incident_action_failed") {
		t.Fatal(out)
	}
	if r := incident(); r.AssignedTo != "" {
		t.Fatalf("conflicting assignment applied: %+v", r)
	}
	for _, args := range [][]string{{"incident", "assign", "40", "bob"}, {"incident", "ack", "40"}} {
		mu.Lock()
		dropIncidentReceipt = true
		before := writes
		mu.Unlock()
		out := run("", false, args...)
		if !strings.Contains(out, `"retryable":false`) || !strings.Contains(out, "outcome unconfirmed") {
			t.Fatalf("lost receipt must not encourage retry: %s", out)
		}
		if r := incident(); r.AssignedTo != "bob" || r.AcknowledgedBy != "operator" || r.Status != "firing" {
			t.Fatalf("action did not persist before lost receipt: %+v", r)
		}
		mu.Lock()
		if writes != before+1 {
			t.Errorf("expected exactly one applied action, got %d", writes-before)
		}
		mu.Unlock()
	}
	mu.Lock()
	routeID := strconv.Itoa(len(assets) + 1)
	mu.Unlock()
	run("", true, "monitor", "source", "create", "ops-v1", "--kind", "webhook", "--url", "http://receiver/hook")
	run("", true, "monitor", "update", "3", "--webhooks", routeID)
	if r := get("3"); !strings.Contains(string(r.Config), `"webhooks":["`+routeID+`"]`) {
		t.Fatal(string(r.Config))
	}
	run("", false, "monitor", "source", "update", routeID, "--url", "http://elsewhere/hook")
	run("", false, "monitor", "source", "update", "1", "--kind", "webhook")
	run("", false, "monitor", "update", "3", "--source", routeID)
	run("", false, "monitor", "update", "3", "--webhooks", "1")
	run("", false, "monitor", "update", "3", "--webhooks", "ops-v1")
	run("", true, "monitor", "update", "3", "--webhooks", "")
	mu.Lock()
	httpID := strconv.Itoa(len(assets) + 1)
	mu.Unlock()
	run("", true, "monitor", "create", "Health", "--kind", "http", "--url", "https://example.net/health", "--max-latency", "2s", "--certificate-valid-for", "72h")
	r = get(httpID)
	var network struct {
		Kind, URL, Address string
		Conditions         []monitorHTTPCondition
	}
	if err := json.Unmarshal(r.Check, &network); err != nil || network.Kind != "http" || len(network.Conditions) != 3 {
		t.Fatalf("HTTP definition: %s %v", r.Check, err)
	}
	run("", true, "monitor", "update", httpID, "--interval", "20s", "--max-latency", "0")
	r = get(httpID)
	network.Conditions = nil
	_ = json.Unmarshal(r.Check, &network)
	if len(network.Conditions) != 2 || !strings.Contains(string(r.Check), "certificate_remaining_ns") {
		t.Fatal("partial HTTP update lost conditions", string(r.Check))
	}
	conditions := `[{"field":"status","op":"==","value":204},{"field":"json","path":"/healthy","op":"==","value":true}]`
	run(conditions, true, "monitor", "update", httpID, "--conditions-file", "-")
	if r := get(httpID); !strings.Contains(string(r.Check), `"path":"/healthy"`) {
		t.Fatal(string(r.Check))
	}
	conditions = `[{"field":"json","path":"/bytes","op":">","value":9007199254740993,"unit":"bytes"}]`
	run(conditions, true, "monitor", "update", httpID, "--conditions-file", "-")
	run("", true, "monitor", "update", httpID, "--interval", "30s")
	if r := get(httpID); !strings.Contains(string(r.Check), `"unit":"bytes"`) || !strings.Contains(string(r.Check), `9007199254740993`) {
		t.Fatal("condition display metadata or exact threshold lost", string(r.Check))
	}
	run(`[{"field":"json","op":"==","value":true,"unit":"bytes"}]`, false, "monitor", "update", httpID, "--conditions-file", "-")
	run(`[{"field":"json","op":">","value":1,"unit":"kilobytes"}]`, false, "monitor", "update", httpID, "--conditions-file", "-")
	mu.Lock()
	tcpID := strconv.Itoa(len(assets) + 1)
	before = writes
	mu.Unlock()
	run("", true, "monitor", "create", "DB", "--kind", "tcp", "--address", "db.internal:5432", "--dry-run")
	for _, args := range [][]string{
		{"monitor", "create", "Bad", "--kind", "tcp", "--address", "db:0"},
		{"monitor", "create", "Bad", "--kind", "tcp", "--address", "db:5432", "--status", "200"},
		{"monitor", "create", "Bad", "--kind", "http", "--url", "https://u:p@example.net"},
		{"monitor", "create", "Bad", "--kind", "http", "--url", "https://example.net", "--source", "1"},
		{"monitor", "update", httpID, "--kind", "tcp"},
		{"monitor", "update", httpID, "--conditions-file", "-", "--status", "201"},
		{"monitor", "webhook", "discard", "3", "9", "--event", "99", "--generation", "4"},
	} {
		run(conditions, false, args...)
	}
	run(`[{"field":"json","op":"==","value":{}}]`, false, "monitor", "update", httpID, "--conditions-file", "-")
	mu.Lock()
	if writes != before {
		t.Error("invalid/dry run commands mutated data")
	}
	mu.Unlock()
	run("", true, "monitor", "create", "DB", "--kind", "tcp", "--address", "db.internal:5432")
	run("", true, "monitor", "update", tcpID, "--address", "[::1]:5433", "--enabled=false")
	if r := get(tcpID); !strings.Contains(string(r.Check), `"address":"[::1]:5433"`) || !strings.Contains(string(r.Config), `"enabled":false`) {
		t.Fatal(r)
	}
	if out := run("", true, "monitor", "webhook", "list", "3"); !strings.Contains(out, `"routes":["9"]`) {
		t.Fatal(out)
	}
	if out := run("", true, "monitor", "webhook", "get", "3", "9"); !strings.Contains(out, `"state":3`) {
		t.Fatal(out)
	}
	discard := []string{"monitor", "webhook", "discard", "3", "9", "--event", "99", "--generation", "4", "--confirm"}
	mu.Lock()
	discardMode = "lost"
	before = writes
	mu.Unlock()
	if out := run("", false, discard...); !strings.Contains(out, `"error"`) {
		t.Fatal("lost discard receipt reported success", out)
	}
	mu.Lock()
	if writes != before+1 || discardRequests != 1 {
		t.Errorf("lost response must apply once without automatic retry: writes=%d requests=%d", writes-before, discardRequests)
	}
	mu.Unlock()
	run("", true, discard...)
	for _, mode := range []string{"wrong-id", "wrong-generation"} {
		mu.Lock()
		discardMode = mode
		mu.Unlock()
		if out := run("", false, discard...); !strings.Contains(out, "discard not confirmed") {
			t.Fatal("mismatched receipt accepted", out)
		}
	}
	mu.Lock()
	if writes != before+1 || discardRequests != 4 {
		t.Errorf("receipt replay changed head or lost request: writes=%d requests=%d", writes-before, discardRequests)
	}
	mu.Unlock()
	for _, action := range []string{"pause", "resume", "retire"} {
		mu.Lock()
		expectedRevision := strconv.FormatInt(assets[3].UpdatedAt+1, 10)
		mu.Unlock()
		args := []string{"monitor", action, "3", "71"}
		if action == "retire" {
			args = append(args, "--confirm")
		}
		out := run("", true, args...)
		var result struct {
			Operation    string `json:"operation"`
			ResourceType string `json:"resource_type"`
			ID           uint64 `json:"id"`
			Details      struct {
				MonitorID uint64 `json:"monitor_id"`
				Revision  string `json:"revision"`
				Replayed  *bool  `json:"replayed"`
			} `json:"details"`
		}
		if err := json.Unmarshal([]byte(out), &result); err != nil || result.Operation != action || result.ResourceType != "monitor_instance" || result.ID != 71 || result.Details.MonitorID != 3 || result.Details.Revision != expectedRevision || result.Details.Replayed == nil || *result.Details.Replayed {
			t.Fatal(out)
		}
	}
	mu.Lock()
	if !bytes.Equal(controlActions, []byte{0, 1, 2}) {
		t.Errorf("wrong control actions: %v", controlActions)
	}
	before = writes
	mu.Unlock()
	for _, args := range [][]string{
		{"monitor", "retire", "3", "71"},
		{"monitor", "pause", "0", "71"},
		{"monitor", "resume", "3", "0"},
		{"monitor", "pause", "3"},
		{"monitor", "pause", "40", "71"},
	} {
		run("", false, args...)
	}
	mu.Lock()
	if writes != before {
		t.Error("invalid control wrote changes")
	}
	controlMode = "conflict"
	mu.Unlock()
	if out := run("", false, "monitor", "pause", "3", "71"); !strings.Contains(out, `"code":"server_error"`) {
		t.Fatal(out)
	}
	for _, mode := range []string{"lost", "wrong-monitor", "wrong-instance", "wrong-correlation", "old-revision", "wrong-opcode", "truncated"} {
		mu.Lock()
		controlMode = mode
		before = writes
		mu.Unlock()
		out := run("", false, "monitor", "pause", "3", "71")
		if !strings.Contains(out, "outcome unconfirmed") || !strings.Contains(out, `"retryable":false`) {
			t.Fatalf("%s: %s", mode, out)
		}
		mu.Lock()
		if writes != before+1 {
			t.Errorf("%s: control retried automatically", mode)
		}
		mu.Unlock()
	}
	mu.Lock()
	controlMode = ""
	mu.Unlock()
	if out := run("", true, "monitor", "resume", "3", "71", "--human"); strings.TrimSpace(out) != "Monitor 3 instance 71: resume accepted" {
		t.Fatal(out)
	}
	var instances struct {
		MonitorID string               `json:"monitor_id"`
		At        string               `json:"at"`
		Entries   []p.MonitorStatusRow `json:"entries"`
		HasMore   bool                 `json:"has_more"`
		Next      string               `json:"next_cursor"`
	}
	out := run("", true, "monitor", "instances", "3", "--limit", "1")
	if err := json.Unmarshal([]byte(out), &instances); err != nil || instances.MonitorID != "3" || instances.At != "1234567890123456789" || len(instances.Entries) != 1 || instances.Entries[0].ID != "9007199254740993" || !instances.HasMore || instances.Next == "" {
		t.Fatal(out)
	}
	cursor := instances.Next
	out = run("", true, "monitor", "instances", "3", "--cursor", cursor)
	if err := json.Unmarshal([]byte(out), &instances); err != nil || len(instances.Entries) != 1 || instances.Entries[0].ID != "71" || instances.Entries[0].IncidentID != "0" || instances.Entries[0].Value == nil || *instances.Entries[0].Value != 17.25 || instances.HasMore || instances.Next != "" {
		t.Fatal(out)
	}
	out = run("", true, "monitor", "instances", "3", "--include-retired")
	if err := json.Unmarshal([]byte(out), &instances); err != nil || len(instances.Entries) != 3 || instances.Entries[2].ID != "90" || !instances.Entries[2].Retired {
		t.Fatal(out)
	}
	retiredCursor := ""
	for i, want := range []string{"9007199254740993", "71", "90"} {
		args := []string{"monitor", "instances", "3", "--include-retired", "--limit", "1"}
		if retiredCursor != "" {
			args = append(args, "--cursor", retiredCursor)
		}
		out = run("", true, args...)
		if err := json.Unmarshal([]byte(out), &instances); err != nil || len(instances.Entries) != 1 || instances.Entries[0].ID != want || instances.HasMore != (i < 2) || (instances.Next != "") != (i < 2) {
			t.Fatal(out)
		}
		retiredCursor = instances.Next
	}
	out = run("", true, "monitor", "instances", "3", "--limit", "1", "--fields", "id,status")
	var projection struct {
		Entries []map[string]any `json:"entries"`
		HasMore bool             `json:"has_more"`
		Next    string           `json:"next_cursor"`
	}
	if err := json.Unmarshal([]byte(out), &projection); err != nil || len(projection.Entries) != 1 || len(projection.Entries[0]) != 2 || projection.Entries[0]["id"] != "9007199254740993" || projection.Entries[0]["status"] != "failing" || !projection.HasMore || projection.Next == "" {
		t.Fatal(out)
	}
	if out := run("", true, "monitor", "instances", "3", "--human"); !strings.Contains(out, "INSTANCE ID") || !strings.Contains(out, "71") || !strings.Contains(out, "healthy") || !strings.Contains(out, "failing") || !strings.Contains(out, "17.25") || strings.Contains(out, "old-host") || strings.Index(out, "failing") > strings.Index(out, "healthy") {
		t.Fatal(out)
	}
	for _, args := range [][]string{
		{"monitor", "instances", "0"},
		{"monitor", "instances", "3", "--limit", "0"},
		{"monitor", "instances", "3", "--limit", "17"},
		{"monitor", "instances", "3", "--cursor", "garbage"},
		{"monitor", "instances", "4", "--cursor", cursor},
		{"monitor", "instances", "3", "--include-retired", "--cursor", cursor},
	} {
		run("", false, args...)
	}
	mu.Lock()
	statusMode = "empty"
	mu.Unlock()
	out = run("", true, "monitor", "instances", "3")
	if err := json.Unmarshal([]byte(out), &instances); err != nil || len(instances.Entries) != 0 || instances.HasMore || instances.Next != "" {
		t.Fatal(out)
	}
	out = run("", true, "monitor", "instances", "3", "--fields", "id,status")
	var projected map[string]json.RawMessage
	if err := json.Unmarshal([]byte(out), &projected); err != nil || string(projected["entries"]) != "[]" || string(projected["monitor_id"]) != `"3"` || string(projected["at"]) != `"1234567890123456789"` || string(projected["has_more"]) != "false" || string(projected["next_cursor"]) != `""` {
		t.Fatal(out)
	}
	mu.Lock()
	statusMode = "wrong-monitor"
	mu.Unlock()
	if out := run("", false, "monitor", "instances", "3"); !strings.Contains(out, "does not match request") {
		t.Fatal(out)
	}
	for _, tc := range []struct{ mode, message string }{
		{"wrong-correlation", "does not match request"},
		{"wrong-opcode", "unexpected instance response"},
		{"malformed", "unexpected end of JSON input"},
		{"bad-cursor", "invalid instance page cursor"},
		{"zero-cursor", "invalid instance page cursor"},
		{"bad-time", "invalid instance page time"},
		{"zero-time", "invalid instance page time"},
	} {
		mu.Lock()
		statusMode = tc.mode
		mu.Unlock()
		if out := run("", false, "monitor", "instances", "3", "--limit", "1"); !strings.Contains(out, tc.message) {
			t.Fatalf("%s: %s", tc.mode, out)
		}
	}
	mu.Lock()
	statusMode = "expired"
	mu.Unlock()
	if out := run("", false, "monitor", "instances", "3", "--cursor", cursor); !strings.Contains(out, `"code":"server_error"`) || !strings.Contains(out, "monitor_status_failed") {
		t.Fatal(out)
	}
}
