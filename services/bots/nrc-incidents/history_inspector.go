package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/url"
	"strconv"
	"strings"
)

const inspectorRunBatch = 128

const inspectorMetadataQuery = `SELECT
 (SELECT value FROM history_meta WHERE key='raw_floor'),
 (SELECT value FROM history_meta WHERE key='uptime_now'),
 (SELECT count(*) FROM history_dirty_hours WHERE hour_ns < ? AND hour_ns + ? > ?),
 (SELECT count(*) FROM uptime_dirty_hours WHERE hour_ns < ? AND hour_ns + ? > ?)`

const inspectorCandidateQuery = `SELECT run_id,observed_at,revision,sequence,acceptance FROM runs
 WHERE workspace=? AND monitor_id=CAST(? AS UBIGINT) AND observed_at>=? AND observed_at<?
 AND (observed_at<? OR (observed_at=? AND run_id<?))
 ORDER BY observed_at DESC,run_id DESC LIMIT 128`

// DuckDB 2.0 only index-scans a table with one pushed-down column filter.
// OFFSET 0 keeps identity filtering above the run-ID index access.
var inspectorSamplesQuery = `WITH selected_samples AS MATERIALIZED (
 SELECT * FROM samples WHERE run_id IN (` + strings.TrimSuffix(strings.Repeat("?,", inspectorRunBatch), ",") + `) OFFSET 0)
 SELECT run_id,condition,value FROM selected_samples WHERE identity=?`

// Keep one statement shape even when fewer than twenty samples are available.
const inspectorRunsQuery = `WITH filtered AS MATERIALIZED (
 SELECT * FROM runs WHERE workspace=? AND monitor_id=CAST(? AS UBIGINT) AND observed_at>=? AND observed_at<?),
 selected AS MATERIALIZED (SELECT r.* FROM filtered r
 WHERE r.run_id=(SELECT run_id FROM filtered WHERE acceptance='confirmed' AND revision=CAST(? AS BIGINT) AND sequence=CAST(? AS UBIGINT) ORDER BY observed_at DESC,run_id DESC LIMIT 1)
 OR r.run_id=(SELECT run_id FROM filtered ORDER BY observed_at DESC,run_id DESC LIMIT 1)
 OR r.run_id IN (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?))
 SELECT r.run_id,r.revision,r.sequence,r.observed_at AS observed_at_ns,r.duration_ns,r.failed,r.acceptance,d.diagnostics
 FROM selected r LEFT JOIN check_diagnostics d USING(run_id) ORDER BY r.observed_at,r.run_id`

var inspectorUptimeQuery = `SELECT revision,sum(healthy_ns) AS healthy_ns,sum(failing_ns) AS failing_ns,
 sum(unknown_ns) AS unknown_ns,sum(paused_ns) AS paused_ns
 FROM uptime_buckets WHERE workspace=? AND monitor_id=CAST(? AS UBIGINT) AND bucket_ns>=? AND bucket_ns<?
 AND resolution_ns=? AND identity=? GROUP BY revision ORDER BY revision LIMIT ` + strconv.Itoa(historyReadRows+1)

// Prepare outside the request transaction: all three pool connections may be
// occupied by the writer and two readers. DB statements survive transactions;
// database/sql binds them to each transaction's connection and closes them with DB.
func (a *historyAPI) inspectorStatements(ctx context.Context, db *sql.DB) (map[string]*sql.Stmt, error) {
	a.statementsMu.Lock()
	defer a.statementsMu.Unlock()
	if a.statementsDB == db {
		return a.statements, nil
	}
	statements := make(map[string]*sql.Stmt)
	for _, query := range []string{inspectorMetadataQuery, inspectorCandidateQuery, inspectorSamplesQuery, inspectorRunsQuery, inspectorUptimeQuery} {
		stmt, err := db.PrepareContext(ctx, query)
		if err != nil {
			for _, prepared := range statements {
				prepared.Close()
			}
			return nil, err
		}
		statements[query] = stmt
	}
	for _, stmt := range a.statements {
		stmt.Close()
	}
	a.statementsDB, a.statements = db, statements
	return statements, nil
}

// Enumerate runs newest first, then give the sample ART index explicit keys.
// A join-only dynamic Bloom filter still scans the entire sample table. Continue
// across pages when newer runs lack this identity; limiting runs to twenty would
// silently lose older samples. All pages use the same request snapshot.
func (a *historyAPI) readInspectorSamples(ctx context.Context, tx *sql.Tx, statements map[string]*sql.Stmt, id uint64, identity string, from, to int64) ([]json.RawMessage, bool, error) {
	candidates := tx.StmtContext(ctx, statements[inspectorCandidateQuery])
	defer candidates.Close()
	samples := tx.StmtContext(ctx, statements[inspectorSamplesQuery])
	defer samples.Close()
	result := make([]json.RawMessage, 0)
	beforeTime, beforeID := to, ""
	for {
		rows, err := candidates.QueryContext(ctx, a.workspace, strconv.FormatUint(id, 10), from, to, beforeTime, beforeTime, beforeID)
		if err != nil {
			return nil, false, err
		}
		var keys [inspectorRunBatch]any
		type run struct {
			at, rev    int64
			seq        uint64
			acceptance string
		}
		var runs [inspectorRunBatch]run
		count := 0
		for rows.Next() {
			r := &runs[count]
			if err = rows.Scan(&beforeID, &beforeTime, &r.rev, &r.seq, &r.acceptance); err != nil {
				rows.Close()
				return nil, false, err
			}
			keys[count] = beforeID
			r.at = beforeTime
			count++
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return nil, false, err
		}
		if count == 0 {
			return result, false, nil
		}
		// Repeating an existing key preserves IN semantics. NULL padding prevents
		// DuckDB from pushing the IN predicate into the ART index scan.
		for i := count; i < len(keys); i++ {
			keys[i] = beforeID
		}
		args := append(keys[:], identity)
		rows, err = samples.QueryContext(ctx, args...)
		if err != nil {
			return nil, false, err
		}
		type sample struct {
			condition uint8
			value     *float64
		}
		byID := make(map[string][]sample)
		for rows.Next() {
			var key string
			var s sample
			if err := rows.Scan(&key, &s.condition, &s.value); err != nil {
				rows.Close()
				return nil, false, err
			}
			byID[key] = append(byID[key], s)
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return nil, false, err
		}
		page := make([]json.RawMessage, 0, 20)
		for i := 0; i < count && len(page)+len(result) < 20; i++ {
			key := keys[i].(string)
			r := runs[i]
			for _, s := range byID[key] {
				b, err := json.Marshal(map[string]any{"run_id": key, "identity": identity, "condition": strconv.Itoa(int(s.condition)), "value": s.value, "revision": strconv.FormatInt(r.rev, 10), "sequence": strconv.FormatUint(r.seq, 10), "observed_at_ns": strconv.FormatInt(r.at, 10), "acceptance": r.acceptance})
				if err != nil {
					return nil, false, err
				}
				page = append(page, b)
				if len(page)+len(result) == 20 {
					break
				}
			}
		}
		for i, j := 0, len(page)-1; i < j; i, j = i+1, j-1 {
			page[i], page[j] = page[j], page[i]
		}
		result = append(page, result...)
		if len(result) >= 20 {
			return result[len(result)-20:], false, nil
		}
		if count < inspectorRunBatch {
			return result, false, nil
		}
	}
}

// Compact views retain only what the Inspector displays. The default API keeps
// its complete, bounded raw-history contract for existing readers.
func (a *historyAPI) readInspectorRows(ctx context.Context, tx *sql.Tx, statements map[string]*sql.Stmt, id uint64, kind string, q url.Values, from, to, step int64, sampleIDs []string) ([]json.RawMessage, bool, error) {
	view, identity := q.Get("view"), q.Get("identity")
	if view == "" || view == "chart" && kind == "samples" {
		if kind == "runs" {
			identity = ""
		}
		return readHistoryRows(ctx, tx, a.workspace, id, kind, identity, "all", from, to, step)
	}
	if view == "chart" && kind == "runs" {
		return []json.RawMessage{}, false, nil
	}
	args := []any{a.workspace, strconv.FormatUint(id, 10), from, to}
	var query string
	switch kind {
	case "samples":
		return a.readInspectorSamples(ctx, tx, statements, id, identity, from, to)
	case "runs":
		// The current confirmed evaluation may be older than the last 20 checks.
		// Retain it independently, along with the latest run used as fallback.
		query = inspectorRunsQuery
		var keys [20]any
		for i, id := range sampleIDs {
			keys[i] = id
		}
		args = append(args, q.Get("revision"), q.Get("sequence"))
		args = append(args, keys[:]...)
	case "uptime":
		// Never merge revisions: the client excludes previous configurations.
		query = inspectorUptimeQuery
		args = append(args, step, identity)
	}
	stmt := tx.StmtContext(ctx, statements[query])
	defer stmt.Close()
	rows, err := stmt.QueryContext(ctx, args...)
	if err != nil {
		return nil, false, err
	}
	return historyJSONRows(rows)
}
