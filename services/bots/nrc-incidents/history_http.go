package main

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const historyReadRows = 5000
const historyReadBytes = 4 << 20

type historyAPI struct {
	history           *historyWriter
	workspace, secret string
	monitors          *monitorSet
	readers           chan struct{}
	statementsMu      sync.Mutex
	statementsDB      *sql.DB
	statements        map[string]*sql.Stmt
}

func newHistoryAPI(h *historyWriter, workspace, secret string, ids *monitorSet) *historyAPI {
	return &historyAPI{history: h, workspace: workspace, secret: secret, monitors: ids, readers: make(chan struct{}, 2)}
}

// Fixed projections only: callers supply values, never SQL identifiers or clauses.
func (a *historyAPI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if a.secret == "" || subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+a.secret)) != 1 {
		w.Header().Set("WWW-Authenticate", "Bearer")
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/v1/history/"), "/")
	if !strings.HasPrefix(r.URL.Path, "/v1/history/") || len(parts) != 2 {
		http.NotFound(w, r)
		return
	}
	id, err := strconv.ParseUint(parts[0], 10, 64)
	kind := parts[1]
	batch := parts[0] == "batch" && kind == "uptime"
	inspector := kind == "inspector"
	if !batch && (err != nil || !a.monitors.contains(id) || (kind != "samples" && kind != "runs" && kind != "uptime" && !inspector)) {
		http.NotFound(w, r)
		return
	}
	bad := func() {
		http.Error(w, "invalid query: require from, to and resolution; see history API contract", http.StatusBadRequest)
	}
	if len(r.URL.RawQuery) > 8192 {
		bad()
		return
	}
	q, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		bad()
		return
	}
	for key, values := range q {
		if len(values) != 1 || (key != "from" && key != "to" && key != "resolution" && key != "identity" && key != "acceptance" && !(batch && key == "ids") && !(inspector && (key == "view" || key == "revision" || key == "sequence"))) {
			bad()
			return
		}
	}
	parseTime := func(s string) (int64, bool) {
		t, err := time.Parse(time.RFC3339Nano, s)
		n := t.UnixNano()
		return n, err == nil && n >= 0 && time.Unix(0, n).Equal(t)
	}
	from, okFrom := parseTime(q.Get("from"))
	to, okTo := parseTime(q.Get("to"))
	resolution := q.Get("resolution")
	step := int64(0)
	switch resolution {
	case "raw":
		if kind == "uptime" {
			bad()
			return
		}
	case "5m":
		step = historyFiveMinutes
	case "1h":
		step = historyHour
	default:
		bad()
		return
	}
	if !okFrom || !okTo || to <= from || to-from > int64(400*24*time.Hour) || step != 0 && (from%step != 0 || to%step != 0) {
		bad()
		return
	}
	identity, hasIdentity := q["identity"]
	if hasIdentity && (batch || kind == "runs" || identity[0] == "" || len(identity[0]) > 4096) {
		bad()
		return
	}
	acceptance := q.Get("acceptance")
	if inspector && (resolution != "raw" || to-from > historyHour || to < int64(24*time.Hour) || !hasIdentity || acceptance != "all") {
		bad()
		return
	}
	if inspector {
		view := q.Get("view")
		if view != "" && view != "checks" && view != "chart" || q.Has("view") && view == "" {
			bad()
			return
		}
		if view == "checks" {
			revision, revisionErr := strconv.ParseInt(q.Get("revision"), 10, 64)
			sequence, sequenceErr := strconv.ParseUint(q.Get("sequence"), 10, 64)
			if revisionErr != nil || revision <= 0 || strconv.FormatInt(revision, 10) != q.Get("revision") || sequenceErr != nil || strconv.FormatUint(sequence, 10) != q.Get("sequence") {
				bad()
				return
			}
		} else if q.Has("revision") || q.Has("sequence") {
			bad()
			return
		}
	}
	if kind == "uptime" {
		if _, exists := q["acceptance"]; exists {
			bad()
			return
		}
	} else if acceptance != "confirmed" && acceptance != "rejected" && acceptance != "unknown" && acceptance != "all" {
		bad()
		return
	}
	var ids []string
	if batch {
		ids = strings.Split(q.Get("ids"), ",")
		seen := make(map[string]bool)
		if len(ids) > 16 {
			bad()
			return
		}
		for _, text := range ids {
			value, err := strconv.ParseUint(text, 10, 64)
			if err != nil || value == 0 || strconv.FormatUint(value, 10) != text || seen[text] {
				bad()
				return
			}
			seen[text] = true
		}
	}

	select {
	case a.readers <- struct{}{}:
		defer func() { <-a.readers }()
	default:
		w.Header().Set("Retry-After", "1")
		http.Error(w, "history busy", http.StatusServiceUnavailable)
		return
	}
	db := a.history.db.Load()
	if db == nil {
		http.Error(w, "history unavailable", http.StatusServiceUnavailable)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	var statements map[string]*sql.Stmt
	if inspector {
		statements, err = a.inspectorStatements(ctx, db)
		if err != nil {
			http.Error(w, "history unavailable", http.StatusServiceUnavailable)
			return
		}
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		http.Error(w, "history unavailable", http.StatusServiceUnavailable)
		return
	}
	defer tx.Rollback()
	if inspector {
		a.serveInspector(w, ctx, tx, statements, id, q, from, to)
		return
	}
	var floor, pending, lastMaintenance int64
	dirtyTable := "history_dirty_hours"
	if kind == "uptime" {
		dirtyTable = "uptime_dirty_hours"
	}
	err = tx.QueryRowContext(ctx, `SELECT
 (SELECT value FROM history_meta WHERE key='raw_floor'),
 (SELECT count(*) FROM `+dirtyTable+` WHERE hour_ns < ? AND hour_ns + ? > ?),
 (SELECT value FROM history_meta WHERE key='uptime_now')`, to, historyHour, from).Scan(&floor, &pending, &lastMaintenance)
	if err != nil {
		http.Error(w, "history unavailable", http.StatusServiceUnavailable)
		return
	}
	if step == 0 && from < floor {
		http.Error(w, "range predates raw retention; choose an aggregate resolution", http.StatusUnprocessableEntity)
		return
	}
	if batch {
		a.serveUptimeBatch(w, ctx, tx, ids, from, to, step, pending)
		return
	}
	data, tooLarge, err := readHistoryRows(ctx, tx, a.workspace, id, kind, q.Get("identity"), acceptance, from, to, step)
	if tooLarge {
		http.Error(w, "history result too large; narrow range, filter identity or choose coarser resolution", http.StatusUnprocessableEntity)
		return
	}
	if err != nil || tx.Commit() != nil {
		http.Error(w, "history unavailable", http.StatusServiceUnavailable)
		return
	}
	result, err := json.Marshal(map[string]any{
		"version": 1, "workspace": a.workspace, "monitor_id": strconv.FormatUint(id, 10),
		"kind": kind, "resolution": resolution, "from": time.Unix(0, from).UTC().Format(time.RFC3339Nano), "to": time.Unix(0, to).UTC().Format(time.RFC3339Nano),
		"raw_floor_ns": strconv.FormatInt(floor, 10), "pending_rollup_hours_global": strconv.FormatInt(pending, 10),
		"uptime_last_maintenance_ns": strconv.FormatInt(lastMaintenance, 10),
		"dropped_process_total":      strconv.FormatUint(a.history.dropped.Load(), 10), "rows": data,
		"availability_process": a.history.availabilityDiagnostics(),
	})
	if err != nil {
		http.Error(w, "history unavailable", http.StatusServiceUnavailable)
		return
	}
	if len(result) > historyReadBytes {
		http.Error(w, "history result too large", http.StatusUnprocessableEntity)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(result)
}

func readHistoryRows(ctx context.Context, tx *sql.Tx, workspace string, id uint64, kind, identity, acceptance string, from, to, step int64) ([]json.RawMessage, bool, error) {
	var query, order string
	args := []any{workspace, strconv.FormatUint(id, 10), from, to}
	if step == 0 {
		if kind == "runs" {
			query = `SELECT r.run_id,r.revision,r.sequence,r.observed_at AS observed_at_ns,r.duration_ns,r.failed,r.acceptance,d.diagnostics FROM runs r LEFT JOIN check_diagnostics d USING(run_id)`
			order = "r.observed_at,r.run_id"
		} else {
			query = `SELECT r.run_id,r.revision,r.sequence,r.observed_at AS observed_at_ns,r.acceptance,s.identity,s.condition,s.value FROM runs r JOIN samples s USING(run_id)`
			order = "r.observed_at,r.run_id,s.identity"
		}
		query += " WHERE r.workspace=? AND r.monitor_id=CAST(? AS UBIGINT) AND r.observed_at>=? AND r.observed_at<?"
	} else {
		switch kind {
		case "samples":
			query = `SELECT bucket_ns,revision,acceptance,identity,value_count,min_value,max_value,sum_value,last_value,last_at AS last_at_ns,last_run_id,passing_count,failing_count,between_count FROM sample_buckets`
			order = "bucket_ns,revision,acceptance,identity"
		case "runs":
			query = `SELECT bucket_ns,revision,acceptance,run_count,failed_count,duration_sum_ns,duration_max_ns FROM run_buckets`
			order = "bucket_ns,revision,acceptance"
		case "uptime":
			query = `SELECT bucket_ns,revision,identity,healthy_ns,failing_ns,unknown_ns,paused_ns,uptime,coverage FROM uptime_summary`
			order = "bucket_ns,revision,identity"
		}
		query += " WHERE workspace=? AND monitor_id=CAST(? AS UBIGINT) AND bucket_ns>=? AND bucket_ns<? AND resolution_ns=?"
		args = append(args, step)
	}
	if identity != "" {
		query += " AND identity=?"
		args = append(args, identity)
	}
	if kind != "uptime" && acceptance != "all" {
		query += " AND acceptance=?"
		args = append(args, acceptance)
	}
	query += " ORDER BY " + order + " LIMIT " + strconv.Itoa(historyReadRows+1)
	rows, err := tx.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, false, err
	}
	return historyJSONRows(rows)
}

// Inspector reads share one admission slot, deadline and database snapshot.
// A section that exceeds retention/row limits is explicit, never a partial list.
func (a *historyAPI) serveInspector(w http.ResponseWriter, ctx context.Context, tx *sql.Tx, statements map[string]*sql.Stmt, id uint64, q url.Values, from, to int64) {
	identity := q.Get("identity")
	uptimeTo := to / historyFiveMinutes * historyFiveMinutes
	uptimeFrom := uptimeTo - int64(24*time.Hour)
	var floor, maintenance, historyPending, uptimePending int64
	metadata := tx.StmtContext(ctx, statements[inspectorMetadataQuery])
	defer metadata.Close()
	if err := metadata.QueryRowContext(ctx,
		to, historyHour, from, uptimeTo, historyHour, uptimeFrom).Scan(&floor, &maintenance, &historyPending, &uptimePending); err != nil {
		http.Error(w, "history unavailable", http.StatusServiceUnavailable)
		return
	}
	sections := make(map[string]any)
	var sampleIDs []string
	for _, kind := range []string{"samples", "runs", "uptime"} {
		start, end, step, pending := from, to, int64(0), historyPending
		if kind == "uptime" {
			step = historyFiveMinutes
			start, end, pending = uptimeFrom, uptimeTo, uptimePending
		}
		data := []json.RawMessage{}
		status := http.StatusOK
		if step == 0 && start < floor {
			status = http.StatusUnprocessableEntity
		} else {
			rows, tooLarge, err := a.readInspectorRows(ctx, tx, statements, id, kind, q, start, end, step, sampleIDs)
			if err != nil {
				http.Error(w, "history unavailable", http.StatusServiceUnavailable)
				return
			}
			if tooLarge {
				status = http.StatusUnprocessableEntity
			} else {
				data = rows
			}
		}
		if kind == "samples" && q.Get("view") == "checks" {
			for _, row := range data {
				var sample struct {
					RunID string `json:"run_id"`
				}
				if err := json.Unmarshal(row, &sample); err != nil {
					http.Error(w, "history unavailable", http.StatusServiceUnavailable)
					return
				}
				sampleIDs = append(sampleIDs, sample.RunID)
			}
		}
		sections[kind] = map[string]any{"status": status, "rows": data, "from": time.Unix(0, start).UTC().Format(time.RFC3339Nano), "to": time.Unix(0, end).UTC().Format(time.RFC3339Nano), "pending_rollup_hours_global": strconv.FormatInt(pending, 10)}
	}
	body, err := json.Marshal(map[string]any{"version": 1, "workspace": a.workspace, "monitor_id": strconv.FormatUint(id, 10), "kind": "inspector", "identity": identity, "sections": sections, "raw_floor_ns": strconv.FormatInt(floor, 10), "uptime_last_maintenance_ns": strconv.FormatInt(maintenance, 10), "dropped_process_total": strconv.FormatUint(a.history.dropped.Load(), 10), "availability_process": a.history.availabilityDiagnostics()})
	if err != nil {
		http.Error(w, "history unavailable", http.StatusServiceUnavailable)
		return
	}
	if len(body) > historyReadBytes {
		http.Error(w, "history result too large; use individual history reads", http.StatusUnprocessableEntity)
		return
	}
	if tx.Commit() != nil {
		http.Error(w, "history unavailable", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(body)
}

// A page shares one admission slot and one snapshot. Each monitor retains the
// single-read row bound; the whole response retains the existing byte bound.
func (a *historyAPI) serveUptimeBatch(w http.ResponseWriter, ctx context.Context, tx *sql.Tx, ids []string, from, to, step, pending int64) {
	results := make([]json.RawMessage, 0, len(ids))
	size := 0
	for _, text := range ids {
		id, _ := strconv.ParseUint(text, 10, 64)
		result := map[string]any{"monitor_id": text, "status": 404, "rows": []json.RawMessage{}}
		if a.monitors.contains(id) {
			rows, err := tx.QueryContext(ctx, `SELECT bucket_ns,revision,identity,healthy_ns,failing_ns,unknown_ns,paused_ns,uptime,coverage FROM uptime_summary WHERE workspace=? AND monitor_id=CAST(? AS UBIGINT) AND bucket_ns>=? AND bucket_ns<? AND resolution_ns=? ORDER BY bucket_ns,revision,identity LIMIT `+strconv.Itoa(historyReadRows+1), a.workspace, text, from, to, step)
			if err != nil {
				http.Error(w, "history unavailable", http.StatusServiceUnavailable)
				return
			}
			data, tooLarge, err := historyJSONRows(rows)
			if err != nil {
				http.Error(w, "history unavailable", http.StatusServiceUnavailable)
				return
			}
			if tooLarge {
				result["status"] = 422
			} else {
				result["status"], result["rows"] = 200, data
			}
		}
		// Bound accumulated data before reading another monitor.
		encoded, err := json.Marshal(result)
		if err != nil {
			http.Error(w, "history unavailable", http.StatusServiceUnavailable)
			return
		}
		size += len(encoded) + 1
		if size > historyReadBytes-16384 {
			http.Error(w, "history result too large; split batch", http.StatusUnprocessableEntity)
			return
		}
		results = append(results, encoded)
	}
	if tx.Commit() != nil {
		http.Error(w, "history unavailable", http.StatusServiceUnavailable)
		return
	}
	body, err := json.Marshal(map[string]any{"version": 1, "workspace": a.workspace, "monitor_id": "batch", "monitor_ids": ids, "pending_rollup_hours_global": strconv.FormatInt(pending, 10), "availability_process": a.history.availabilityDiagnostics(), "results": results})
	if err != nil {
		http.Error(w, "history unavailable", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(body)
}

// Buffer the entire bounded result before publishing: no successful partial page.
func historyJSONRows(rows *sql.Rows) ([]json.RawMessage, bool, error) {
	defer rows.Close()
	columns, err := rows.Columns()
	if err != nil {
		return nil, false, err
	}
	result := make([]json.RawMessage, 0)
	size := 0
	for rows.Next() {
		if len(result) == historyReadRows {
			return nil, true, nil
		}
		values := make([]any, len(columns))
		pointers := make([]any, len(columns))
		for i := range values {
			pointers[i] = &values[i]
		}
		if err := rows.Scan(pointers...); err != nil {
			return nil, false, err
		}
		row := make(map[string]any, len(columns))
		for i, value := range values {
			// Decimal strings preserve nanoseconds, UBIGINT IDs and HUGEINT sums
			// across JavaScript consumers; floating measurements remain numbers.
			switch v := value.(type) {
			case int64:
				value = strconv.FormatInt(v, 10)
			case uint64:
				value = strconv.FormatUint(v, 10)
			case uint8:
				value = strconv.FormatUint(uint64(v), 10)
			case *big.Int:
				value = v.String()
			case nil, string, bool, float64:
			default:
				return nil, false, fmt.Errorf("unsupported history result type %T", value)
			}
			if columns[i] == "diagnostics" && value != nil {
				text, ok := value.(string)
				if !ok || !json.Valid([]byte(text)) {
					return nil, false, fmt.Errorf("invalid diagnostics")
				}
				value = json.RawMessage(text)
			}
			row[columns[i]] = value
		}
		encoded, err := json.Marshal(row)
		if err != nil {
			return nil, false, err
		}
		size += len(encoded) + 1
		// Leave space for the response envelope.
		if size > historyReadBytes-16384 {
			return nil, true, nil
		}
		result = append(result, encoded)
	}
	return result, false, rows.Err()
}
