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
	"time"
)

const historyReadRows = 5000
const historyReadBytes = 4 << 20

type historyAPI struct {
	history           *historyWriter
	workspace, secret string
	monitors          *monitorSet
	readers           chan struct{}
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
	if err != nil || !a.monitors.contains(id) || (kind != "samples" && kind != "runs" && kind != "uptime") {
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
		if len(values) != 1 || (key != "from" && key != "to" && key != "resolution" && key != "identity" && key != "acceptance") {
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
	if hasIdentity && (kind == "runs" || identity[0] == "" || len(identity[0]) > 4096) {
		bad()
		return
	}
	acceptance := q.Get("acceptance")
	if kind == "uptime" {
		if _, exists := q["acceptance"]; exists {
			bad()
			return
		}
	} else if acceptance != "confirmed" && acceptance != "rejected" && acceptance != "unknown" && acceptance != "all" {
		bad()
		return
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
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		http.Error(w, "history unavailable", http.StatusServiceUnavailable)
		return
	}
	defer tx.Rollback()
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
	var query, order string
	args := []any{a.workspace, strconv.FormatUint(id, 10), from, to}
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
	if hasIdentity {
		query += " AND identity=?"
		args = append(args, identity[0])
	}
	if kind != "uptime" && acceptance != "all" {
		query += " AND acceptance=?"
		args = append(args, acceptance)
	}
	query += " ORDER BY " + order + " LIMIT " + strconv.Itoa(historyReadRows+1)
	rows, err := tx.QueryContext(ctx, query, args...)
	if err != nil {
		http.Error(w, "history unavailable", http.StatusServiceUnavailable)
		return
	}
	data, tooLarge, err := historyJSONRows(rows)
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
