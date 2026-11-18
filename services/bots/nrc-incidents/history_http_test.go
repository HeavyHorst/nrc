package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	p "github.com/heavyhorst/nrc/protocol-go"
)

func TestDiagnosticsHistoryLifecycle(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "diagnostics.duckdb")
	db, err := openHistory(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	base := time.Now().UTC().Truncate(time.Hour)
	r := historyRun{ID: "diagnostic", Workspace: "ops", Acceptance: "unknown", ObservedAt: base.UnixNano(), Run: p.ApplyMonitorRun{MonitorID: 2, Revision: 3, Sequence: 4, Observations: []p.MonitorObservation{{Identity: `{"target":"default"}`, Condition: 1}}}, Diagnostics: &checkDiagnostics{Version: 1, Conditions: []conditionDiagnostic{{Index: 0, State: "fail", ActualType: "number", Actual: "9007199254740993"}}}}
	for range 2 {
		if err := writeHistory(ctx, db, r); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	db, err = openHistory(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	h := newHistoryWriter()
	h.db.Store(db)
	a := newHistoryAPI(h, "ops", "secret", newMonitorSet([]uint64{2}))
	read := func(acceptance string) []map[string]any {
		q := url.Values{"from": {base.Format(time.RFC3339Nano)}, "to": {base.Add(time.Hour).Format(time.RFC3339Nano)}, "resolution": {"raw"}, "acceptance": {acceptance}}
		req := httptest.NewRequest("GET", "/v1/history/2/runs?"+q.Encode(), nil)
		req.Header.Set("Authorization", "Bearer secret")
		w := httptest.NewRecorder()
		a.ServeHTTP(w, req)
		var reply struct {
			Rows []map[string]any `json:"rows"`
		}
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &reply) != nil {
			t.Fatalf("%d %s", w.Code, w.Body.String())
		}
		return reply.Rows
	}
	rows := read("unknown")
	if len(rows) != 1 || rows[0]["revision"] != "3" || rows[0]["sequence"] != "4" {
		t.Fatal(rows)
	}
	d := rows[0]["diagnostics"].(map[string]any)
	if d["conditions"].([]any)[0].(map[string]any)["actual"] != "9007199254740993" {
		t.Fatal(d)
	}
	if len(read("confirmed")) != 0 {
		t.Fatal("unconfirmed diagnosis reported confirmed")
	}
	if err := maintainHistory(ctx, db, base.Add(15*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	var count int
	if err := db.QueryRow("SELECT count(*) FROM check_diagnostics").Scan(&count); err != nil || count != 0 {
		t.Fatalf("retention: %d %v", count, err)
	}
}

func TestHistoryHTTPContract(t *testing.T) {
	db, err := openHistory(context.Background(), filepath.Join(t.TempDir(), "history.duckdb"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	h := newHistoryWriter()
	h.db.Store(db)
	const token = "test-history-reader-secret-not-a-real-key"
	const id = "18446744073709551615"
	s := httptest.NewServer(newHistoryAPI(h, "ops", token, newMonitorSet([]uint64{^uint64(0), 2, 4})))
	defer s.Close()
	base := time.Date(2026, 11, 16, 0, 0, 0, 0, time.UTC)
	n := base.UnixNano()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.Exec(q, args...); err != nil {
			t.Fatal(err)
		}
	}
	exec(`INSERT INTO runs VALUES
 ('b','ops',18446744073709551615,9007199254740993,18446744073709551615,?,7,false,'confirmed'),
 ('a','ops',18446744073709551615,9007199254740993,2,?,11,false,'confirmed'),
 ('unknown','ops',18446744073709551615,4,3,?,13,true,'unknown'),
 ('boundary','ops',18446744073709551615,4,4,?,1,false,'confirmed'),
 ('private','other',18446744073709551615,4,5,?,1,false,'confirmed')`, n, n, n, n+historyHour, n)
	exec(`INSERT INTO samples VALUES ('a','host-b',1,10),('b','host-a',0,2),('private','secret-host',0,99)`)
	for _, step := range []int64{historyFiveMinutes, historyHour} {
		exec(`INSERT INTO sample_buckets VALUES (?,?,'ops',18446744073709551615,9007199254740993,'confirmed','host-a',2,2,10,12,10,?,'a',1,1,0)`, step, n, n)
		exec(`INSERT INTO run_buckets VALUES (?,?,'ops',18446744073709551615,9007199254740993,'confirmed',2,1,18446744073709551616,11)`, step, n)
		exec(`INSERT INTO uptime_buckets VALUES
 (?,?,'ops',18446744073709551615,3,'host-a',30,10,40,20),
 (?,?,'ops',18446744073709551615,3,'host-b',0,0,50,50),
 (?,?,'other',18446744073709551615,3,'secret-host',100,0,0,0)`, step, n, step, n, step, n)
	}
	query := func(kind, resolution string) string {
		q := url.Values{"from": {base.Format(time.RFC3339Nano)}, "to": {base.Add(time.Hour).Format(time.RFC3339Nano)}, "resolution": {resolution}}
		if kind != "uptime" {
			q.Set("acceptance", "all")
		}
		return "/v1/history/" + id + "/" + kind + "?" + q.Encode()
	}
	request := func(path, auth string, want int) map[string]any {
		t.Helper()
		r, _ := http.NewRequest("GET", s.URL+path, nil)
		r.Header.Set("Authorization", auth)
		resp, err := s.Client().Do(r)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			t.Fatal(err)
		}
		if resp.StatusCode != want {
			t.Fatalf("%s: status %d, wanted %d: %s", path, resp.StatusCode, want, body)
		}
		if resp.Header.Get("Cache-Control") != "no-store" {
			t.Fatal("cacheable history")
		}
		if want != 200 {
			if strings.Contains(string(body), "SELECT") || strings.Contains(string(body), "secret-host") {
				t.Fatal("error leaked data")
			}
			return nil
		}
		var result map[string]any
		if err := json.Unmarshal(body, &result); err != nil {
			t.Fatal(err)
		}
		if result["monitor_id"] != strings.Split(path, "/")[3] || result["workspace"] != "ops" || strings.Contains(string(body), "secret-host") {
			t.Fatalf("scope/precision: %s", body)
		}
		return result
	}
	auth := "Bearer " + token
	inspectorPath := query("inspector", "raw") + "&identity=host-a"
	inspector := request(inspectorPath, auth, 200)
	sections := inspector["sections"].(map[string]any)
	if inspector["identity"] != "host-a" || inspector["kind"] != "inspector" {
		t.Fatal(inspector)
	}
	for kind, count := range map[string]int{"runs": 3, "samples": 1, "uptime": 1} {
		section := sections[kind].(map[string]any)
		if section["status"] != float64(200) || len(section["rows"].([]any)) != count {
			t.Fatal(kind, section)
		}
	}
	if sections["samples"].(map[string]any)["rows"].([]any)[0].(map[string]any)["condition"] != "0" {
		t.Fatal(sections)
	}
	coverage := sections["uptime"].(map[string]any)
	if coverage["from"] != base.Add(-23*time.Hour).Format(time.RFC3339Nano) || coverage["to"] != base.Add(time.Hour).Format(time.RFC3339Nano) || coverage["rows"].([]any)[0].(map[string]any)["healthy_ns"] != "30" {
		t.Fatal(coverage)
	}
	request(inspectorPath, "", 401)
	for _, path := range []string{query("inspector", "raw"), query("inspector", "5m") + "&identity=host-a", strings.Replace(inspectorPath, "acceptance=all", "acceptance=confirmed", 1), strings.Replace(inspectorPath, "T01", "T02", 1), inspectorPath + "&workspace=other", inspectorPath + "&identity=host-b"} {
		request(path, auth, 400)
	}
	batchPath := strings.Replace(query("uptime", "1h"), id, "batch", 1) + "&ids=" + id + ",2,4,3"
	exec(`INSERT INTO uptime_buckets VALUES (?,?,'ops',2,9,'different-host',7,13,0,0)`, historyHour, n)
	batch := request(batchPath, auth, 200)["results"].([]any)
	if len(batch) != 4 {
		t.Fatal(batch)
	}
	for i, expected := range []struct {
		id     string
		status float64
		rows   int
	}{{id, 200, 2}, {"2", 200, 1}, {"4", 200, 0}, {"3", 404, 0}} {
		result := batch[i].(map[string]any)
		if result["monitor_id"] != expected.id || result["status"] != expected.status || len(result["rows"].([]any)) != expected.rows {
			t.Fatal(result)
		}
	}
	if batch[1].(map[string]any)["rows"].([]any)[0].(map[string]any)["healthy_ns"] != "7" {
		t.Fatal(batch)
	}
	request(batchPath, "", 401)
	for _, ids := range []string{"", "0", "02", "2,2", "18446744073709551616", strings.Repeat("2,", 16) + "4"} {
		request(strings.Replace(query("uptime", "1h"), id, "batch", 1)+"&ids="+ids, auth, 400)
	}
	request(batchPath+"&identity=host-a", auth, 400)
	request(batchPath+"&workspace=other", auth, 400)
	request(batchPath+"&acceptance=all", auth, 400)
	request(query("samples", "raw"), "", 401)
	request(query("samples", "raw"), "Bearer wrong", 401)
	request(strings.Replace(query("samples", "raw"), id, "3", 1), auth, 404)
	for _, extra := range []string{"&workspace=other", "&resolution=raw", "&identity=", "&acceptance=bogus", "&x=%zz"} {
		request(query("samples", "raw")+extra, auth, 400)
	}
	request(query("uptime", "raw"), auth, 400)
	request(query("uptime", "5m")+"&acceptance=all", auth, 400)
	request(query("runs", "raw")+"&identity=host-a", auth, 400)
	request(strings.Replace(query("samples", "5m"), "00%3A00%3A00Z", "00%3A00%3A01Z", 1), auth, 400)
	request(strings.Replace(query("runs", "raw"), "2026-11-16T01", "2400-11-16T01", 1), auth, 400)
	rows := request(query("samples", "raw"), auth, 200)["rows"].([]any)
	if len(rows) != 2 || rows[0].(map[string]any)["run_id"] != "a" || rows[1].(map[string]any)["sequence"] != id || rows[0].(map[string]any)["revision"] != "9007199254740993" {
		t.Fatalf("raw order/precision: %#v", rows)
	}
	rows = request(query("runs", "raw"), auth, 200)["rows"].([]any)
	if len(rows) != 3 || rows[2].(map[string]any)["failed"] != true {
		t.Fatalf("failed/empty runs: %#v", rows)
	}
	rows = request(strings.Replace(query("runs", "raw"), "acceptance=all", "acceptance=confirmed", 1), auth, 200)["rows"].([]any)
	if len(rows) != 2 {
		t.Fatalf("acceptance: %#v", rows)
	}
	// Process diagnostics are available on single, Inspector and batch reads, with
	// distinct decimal counters rather than folding backpressure into drops.
	h.availabilityReadFailures.Add(3)
	h.availabilityWriteFailures.Add(5)
	h.availabilityWaits.Add(7)
	h.availabilityWaitNS.Add(9007199254740993)
	for _, path := range []string{query("runs", "raw"), inspectorPath, batchPath} {
		diagnostics := request(path, auth, 200)["availability_process"].(map[string]any)
		for key, want := range map[string]string{"request_drops_total": "0", "snapshot_read_failures_total": "3", "snapshot_write_failures_total": "5", "backpressure_total": "7", "backpressure_ns_total": "9007199254740993", "requests_pending": "0", "snapshots_pending": "0"} {
			if diagnostics[key] != want {
				t.Fatalf("%s diagnostic %s=%v, want %s", path, key, diagnostics[key], want)
			}
		}
	}
	rows = request(query("samples", "raw")+"&identity="+url.QueryEscape("' OR 1=1 --"), auth, 200)["rows"].([]any)
	if len(rows) != 0 {
		t.Fatal("identity was not a literal")
	}
	for _, resolution := range []string{"5m", "1h"} {
		rows = request(query("samples", resolution)+"&identity=host-a", auth, 200)["rows"].([]any)
		if len(rows) != 1 || rows[0].(map[string]any)["sum_value"] != float64(12) || rows[0].(map[string]any)["value_count"] != "2" {
			t.Fatalf("sample bucket: %#v", rows)
		}
		rows = request(query("runs", resolution), auth, 200)["rows"].([]any)
		if len(rows) != 1 || rows[0].(map[string]any)["duration_sum_ns"] != "18446744073709551616" {
			t.Fatalf("HUGEINT: %#v", rows)
		}
		rows = request(query("uptime", resolution), auth, 200)["rows"].([]any)
		if len(rows) != 2 || rows[0].(map[string]any)["uptime"] != 0.75 || rows[0].(map[string]any)["coverage"] != 0.5 || rows[1].(map[string]any)["uptime"] != nil {
			t.Fatalf("uptime: %#v", rows)
		}
	}
	exec("INSERT INTO history_dirty_hours VALUES (?)", n)
	result := request(query("samples", "5m"), auth, 200)
	if result["pending_rollup_hours_global"] != "1" {
		t.Fatal(result)
	}
	exec("UPDATE history_meta SET value=? WHERE key='raw_floor'", n+1)
	request(query("runs", "raw"), auth, 422)
	sections = request(inspectorPath, auth, 200)["sections"].(map[string]any)
	for _, kind := range []string{"runs", "samples"} {
		section := sections[kind].(map[string]any)
		if section["status"] != float64(422) || len(section["rows"].([]any)) != 0 {
			t.Fatal(section)
		}
	}
	if sections["uptime"].(map[string]any)["status"] != float64(200) {
		t.Fatal(sections)
	}
	request(query("runs", "5m"), auth, 200)
	exec("UPDATE history_meta SET value=0 WHERE key='raw_floor'")

	// Exact row cap succeeds; the next row must fail the whole response.
	exec(`INSERT INTO runs SELECT 'bulk-'||i,'ops',2,1,i,?,1,false,'confirmed' FROM range(1,5001) t(i)`, n)
	bulk := strings.Replace(query("runs", "raw"), id, "2", 1)
	bulkRequest := func(want int) {
		r := httptest.NewRequest("GET", bulk, nil)
		r.Header.Set("Authorization", auth)
		w := httptest.NewRecorder()
		newHistoryAPI(h, "ops", token, newMonitorSet([]uint64{2})).ServeHTTP(w, r)
		if w.Code != want {
			t.Fatalf("bulk: %d %s", w.Code, w.Body.String())
		}
	}
	bulkRequest(200)
	exec(`INSERT INTO runs VALUES ('extra','ops',2,1,5001,?,1,false,'confirmed')`, n)
	bulkRequest(422)
	limited := request(strings.Replace(bulk, "/runs?", "/inspector?", 1)+"&identity=host-a", auth, 200)["sections"].(map[string]any)
	if limited["runs"].(map[string]any)["status"] != float64(422) || len(limited["runs"].(map[string]any)["rows"].([]any)) != 0 || limited["samples"].(map[string]any)["status"] != float64(200) || limited["uptime"].(map[string]any)["status"] != float64(200) {
		t.Fatal(limited)
	}
	// Fewer than 5,000 rows can still exceed the encoded byte budget.
	exec(`INSERT INTO samples SELECT 'bulk-'||i,repeat('x',4090)||i,0,1 FROM range(1,1101) t(i)`)
	bulk = strings.Replace(bulk, "/runs?", "/samples?", 1)
	bulkRequest(422)
	// Inspector: two individually valid sections can exceed the envelope budget.
	exec(`INSERT INTO runs SELECT 'inspector-'||repeat('x',4000)||i,'ops',4,1,i,?,1,false,'confirmed' FROM range(1,601) t(i)`, n)
	exec(`INSERT INTO samples SELECT run_id,'host-a',0,1 FROM runs WHERE monitor_id=4`)
	inspectorBulk := strings.Replace(query("inspector", "raw"), id, "4", 1) + "&identity=host-a"
	for _, kind := range []string{"runs", "samples"} {
		path := strings.Replace(query(kind, "raw"), id, "4", 1)
		if kind == "samples" {
			path += "&identity=host-a"
		}
		if rows := request(path, auth, 200)["rows"].([]any); len(rows) != 600 {
			t.Fatal(len(rows))
		}
	}
	request(inspectorBulk, auth, 422)
	// A byte-heavy runs section has only 1,100 rows, below the row cap. Keep
	// one sample and one uptime bucket to prove unaffected sections survive.
	exec(`DELETE FROM samples WHERE run_id IN (SELECT run_id FROM runs WHERE monitor_id=4 AND sequence!=1)`)
	exec(`INSERT INTO runs SELECT 'inspector-'||repeat('x',4000)||i,'ops',4,1,i,?,1,false,'confirmed' FROM range(601,1101) t(i)`, n)
	exec(`INSERT INTO uptime_buckets VALUES (?,?,'ops',4,1,'host-a',60,0,0,0)`, historyFiveMinutes, n)
	byteLimited := request(inspectorBulk, auth, 200)["sections"].(map[string]any)
	for kind, want := range map[string]int{"runs": 0, "samples": 1, "uptime": 1} {
		section := byteLimited[kind].(map[string]any)
		status := float64(200)
		if kind == "runs" {
			status = 422
		}
		if section["status"] != status || len(section["rows"].([]any)) != want {
			t.Fatal(kind, section)
		}
	}
	// Per-monitor row overflow must not hide other monitors in a batch.
	exec(`INSERT INTO uptime_buckets SELECT ?,?,'ops',4,1,'bulk-'||i,1,0,0,0 FROM range(1,5002) t(i)`, historyHour, n)
	batch = request(batchPath, auth, 200)["results"].([]any)
	if batch[2].(map[string]any)["status"] != float64(422) || len(batch[2].(map[string]any)["rows"].([]any)) != 0 || batch[0].(map[string]any)["status"] != float64(200) {
		t.Fatal(batch)
	}
	// Two individually bounded monitors can exceed the shared response budget.
	exec(`DELETE FROM uptime_buckets WHERE monitor_id IN (2,4)`)
	exec(`INSERT INTO uptime_buckets SELECT ?,?,'ops',m,1,repeat('x',4000)||i,1,0,0,0 FROM range(1,601) t(i), (VALUES (2),(4)) v(m)`, historyHour, n)
	request(strings.Replace(query("uptime", "1h"), id, "2", 1), auth, 200)
	request(strings.Replace(query("uptime", "1h"), id, "4", 1), auth, 200)
	request(batchPath, auth, 422)
	h.db.Store(nil)
	request(query("runs", "raw"), auth, 503)
	h.db.Store(db)

	// Two reader transactions plus the reserved third connection can coexist
	// with the serialized writer; use real HTTP while mutating an unrelated row.
	var wg sync.WaitGroup
	for range 8 {
		wg.Go(func() {
			for range 4 {
				r, _ := http.NewRequest("GET", s.URL+query("runs", "raw"), nil)
				r.Header.Set("Authorization", auth)
				resp, err := s.Client().Do(r)
				if err != nil {
					t.Error(err)
					return
				}
				io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
				if resp.StatusCode != 200 && resp.StatusCode != 503 {
					t.Errorf("concurrent read: %d", resp.StatusCode)
				}
			}
		})
	}
	for i := range 10 {
		exec("UPDATE history_meta SET value=? WHERE key='uptime_now'", i)
	}
	wg.Wait()
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	request(query("runs", "raw"), auth, 503)
}

func TestHistoryHTTPMaintenanceMetadataDuringCatchup(t *testing.T) {
	ctx := context.Background()
	db, err := openHistory(ctx, filepath.Join(t.TempDir(), "history.duckdb"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	base := time.Date(2026, 11, 10, 0, 0, 0, 0, time.UTC)
	now := base.Add(72 * time.Hour)
	snapshot := historySnapshot{Workspace: "ops", MonitorSnapshotPage: p.MonitorSnapshotPage{
		MonitorState: p.MonitorState{MonitorID: 2, Revision: 1, Sequence: 1},
		At:           base.UnixNano(), Horizon: historyHour,
		Instances: []p.MonitorAvailability{{ID: 1, Identity: "disk", State: 0, ValidUntil: base.Add(time.Minute).UnixNano()}},
	}}
	if err := writeAvailability(ctx, db, snapshot); err != nil {
		t.Fatal(err)
	}
	if err := maintainHistory(ctx, db, now); err != nil {
		t.Fatal(err)
	}
	h := newHistoryWriter()
	h.db.Store(db)
	a := newHistoryAPI(h, "ops", "secret", newMonitorSet([]uint64{2}))
	q := url.Values{"from": {now.Add(-time.Hour).Format(time.RFC3339)}, "to": {now.Format(time.RFC3339)}, "resolution": {"1h"}}
	r := httptest.NewRequest("GET", "/v1/history/2/uptime?"+q.Encode(), nil)
	r.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	a.ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatalf("%d: %s", w.Code, w.Body.String())
	}
	var response map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response["uptime_last_maintenance_ns"] != strconv.FormatInt(now.UnixNano(), 10) {
		t.Fatalf("missing maintenance timestamp: %s", w.Body.String())
	}
	if _, exists := response["uptime_scheduled_through_ns"]; exists {
		t.Fatal("misleading scheduling watermark remains")
	}
	if response["pending_rollup_hours_global"] != "0" || len(response["rows"].([]any)) != 0 {
		t.Fatal(response)
	}
	// The earlier hour was computed, but recent hours are not even scheduled.
	var tail, buckets int64
	if err := db.QueryRow("SELECT value FROM history_meta WHERE key='uptime_tail'").Scan(&tail); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow("SELECT count(*) FROM uptime_buckets WHERE resolution_ns=?", historyHour).Scan(&buckets); err != nil {
		t.Fatal(err)
	}
	if tail != base.Add(23*time.Hour).UnixNano() || buckets != 1 {
		t.Fatalf("fixture did not exercise catchup: tail=%d buckets=%d", tail, buckets)
	}
}

func TestHistoryHTTPReadDeadline(t *testing.T) {
	db, err := openHistory(context.Background(), filepath.Join(t.TempDir(), "history.duckdb"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	h := newHistoryWriter()
	h.db.Store(db)
	a := newHistoryAPI(h, "ops", "secret", newMonitorSet([]uint64{1}))
	// Hold all connections to exercise cancellation, not a mocked SQL error.
	for range 3 {
		c, err := db.Conn(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
	}
	r := httptest.NewRequest("GET", "/v1/history/1/runs?from=2026-11-16T00:00:00Z&to=2026-11-16T01:00:00Z&resolution=raw&acceptance=all", nil)
	r.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	start := time.Now()
	a.ServeHTTP(w, r)
	if w.Code != 503 || time.Since(start) > 5*time.Second {
		t.Fatalf("deadline: %s %s", strconv.Itoa(w.Code), time.Since(start))
	}
}

func TestHistoryHTTPInterruptsRunningQuery(t *testing.T) {
	db, err := openHistory(context.Background(), filepath.Join(t.TempDir(), "history.duckdb"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	// A streaming aggregate does real work without allocating a huge fixture.
	// Unlike the pool-deadline test, a connection is available throughout.
	_, err = db.Exec(`ALTER TABLE runs RENAME TO saved_runs;
 CREATE VIEW runs AS SELECT 'slow' run_id,'ops' workspace,1::UBIGINT monitor_id,
 1::BIGINT revision,1::UBIGINT sequence,1794787200000000000::BIGINT observed_at,
 (SELECT sum(i%7)::BIGINT FROM range(1000000000000) t(i)) duration_ns,
 false failed,'confirmed' acceptance`)
	if err != nil {
		t.Fatal(err)
	}
	h := newHistoryWriter()
	h.db.Store(db)
	a := newHistoryAPI(h, "ops", "secret", newMonitorSet([]uint64{1}))
	r := httptest.NewRequest("GET", "/v1/history/1/runs?from=2026-11-16T00:00:00Z&to=2026-11-17T00:00:00Z&resolution=raw&acceptance=confirmed", nil)
	r.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	start := time.Now()
	a.ServeHTTP(w, r)
	elapsed := time.Since(start)
	if w.Code != 503 || elapsed < 2*time.Second || elapsed > 8*time.Second {
		t.Fatalf("running query deadline: %d after %s: %s", w.Code, elapsed, w.Body.String())
	}
	if _, err := db.Exec(`DROP VIEW runs; ALTER TABLE saved_runs RENAME TO runs;
 INSERT INTO runs VALUES ('after-cancel','ops',1,1,1,1794787200000000000,7,false,'confirmed')`); err != nil {
		t.Fatal(err)
	}
	w = httptest.NewRecorder()
	a.ServeHTTP(w, r)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"run_id":"after-cancel"`) {
		t.Fatalf("read after interruption: %d %s", w.Code, w.Body.String())
	}
}

func TestHistoryHTTPWriterLifecycle(t *testing.T) {
	h := newHistoryWriter()
	a := newHistoryAPI(h, "ops", "secret", newMonitorSet([]uint64{2}))
	now := time.Now().UTC()
	q := url.Values{"from": {now.Add(-time.Second).Format(time.RFC3339Nano)}, "to": {now.Add(time.Second).Format(time.RFC3339Nano)}, "resolution": {"raw"}, "acceptance": {"confirmed"}}
	read := func() *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", "/v1/history/2/samples?"+q.Encode(), nil)
		r.Header.Set("Authorization", "Bearer secret")
		w := httptest.NewRecorder()
		a.ServeHTTP(w, r)
		return w
	}
	if w := read(); w.Code != 503 {
		t.Fatal(w.Code)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	path := filepath.Join(t.TempDir(), "history.duckdb")
	go func() { defer close(done); h.serve(ctx, path) }()
	defer func() { cancel(); <-done }()
	h.offer(historyRun{ID: "visible-after-write", Workspace: "ops", Acceptance: "confirmed", ObservedAt: now.UnixNano(), Run: p.ApplyMonitorRun{CorrelationID: 1, MonitorID: 2, Revision: 3, Sequence: 1, Observations: []p.MonitorObservation{{Identity: "disk", Value: 17}}}})
	deadline := time.Now().Add(5 * time.Second)
	for {
		w := read()
		if w.Code == 200 && strings.Contains(w.Body.String(), `"value":17`) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("writer never published history: %d %s", w.Code, w.Body.String())
		}
		time.Sleep(10 * time.Millisecond)
	}
	// Cancel the reader explicitly after observing the failed write, avoiding
	// a race between a wall-clock deadline and the snapshot assertion.
	readCtx, stopRead := context.WithCancel(ctx)
	defer stopRead()
	reader, err := h.db.Load().BeginTx(readCtx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Rollback()
	var count int
	if err := reader.QueryRow("SELECT count(*) FROM runs").Scan(&count); err != nil || count != 1 {
		t.Fatalf("reader snapshot: %d %v", count, err)
	}
	bad := historyRun{ID: "failed-write", Workspace: "ops", Acceptance: "invalid", ObservedAt: now.UnixNano(), Run: p.ApplyMonitorRun{CorrelationID: 1, MonitorID: 2, Revision: 3, Sequence: 2}}
	h.offer(bad)
	deadline = time.Now().Add(5 * time.Second)
	for h.dropped.Load() == 0 {
		if time.Now().After(deadline) {
			t.Fatal("writer did not report injected constraint failure")
		}
		time.Sleep(time.Millisecond)
	}
	if err := reader.QueryRow("SELECT count(*) FROM runs").Scan(&count); err != nil || count != 1 {
		t.Fatalf("reader lost its snapshot during failure: %d %v", count, err)
	}
	stopRead()
	reader.Rollback()
	good := bad
	good.ID = "after-reopen"
	good.Acceptance = "confirmed"
	good.Run.Observations = []p.MonitorObservation{{Identity: "disk", Value: 29}}
	h.offer(good)
	deadline = time.Now().Add(5 * time.Second)
	for {
		w := read()
		if w.Code != 200 && w.Code != 503 {
			t.Fatalf("recovery read: %d %s", w.Code, w.Body.String())
		}
		if w.Code == 200 && strings.Contains(w.Body.String(), `"value":29`) {
			if !strings.Contains(w.Body.String(), `"value":17`) {
				t.Fatal("recovery lost committed data", w.Body.String())
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("writer did not recover", w.Body.String())
		}
		time.Sleep(10 * time.Millisecond)
	}
	// Samples/confirmed would hide a failed run with no observations. Inspect
	// all attempts to verify the failed transaction left no run behind.
	q.Set("acceptance", "all")
	r := httptest.NewRequest("GET", "/v1/history/2/runs?"+q.Encode(), nil)
	r.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	a.ServeHTTP(w, r)
	var result struct {
		Rows []struct {
			RunID string `json:"run_id"`
		} `json:"rows"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if w.Code != 200 || len(result.Rows) != 2 || result.Rows[0].RunID != "after-reopen" || result.Rows[1].RunID != "visible-after-write" {
		t.Fatalf("unexpected persisted attempts after recovery: %d %s", w.Code, w.Body.String())
	}
	cancel()
	<-done
	if w := read(); w.Code != 503 {
		t.Fatal("closed writer served history", w.Code)
	}
}
