package main

import (
	"context"
	"database/sql"
	"time"
)

const historyHour = int64(time.Hour)
const historyFiveMinutes = int64(5 * time.Minute)

const historyRollupSchema = `
CREATE TABLE IF NOT EXISTS history_meta (key VARCHAR PRIMARY KEY, value BIGINT NOT NULL);
CREATE TABLE IF NOT EXISTS history_dirty_hours (hour_ns BIGINT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS sample_buckets (
 resolution_ns BIGINT, bucket_ns BIGINT, workspace VARCHAR, monitor_id UBIGINT,
 revision BIGINT, acceptance VARCHAR, identity VARCHAR,
 value_count BIGINT, min_value DOUBLE, max_value DOUBLE, sum_value DOUBLE,
 last_value DOUBLE, last_at BIGINT, last_run_id VARCHAR,
 passing_count BIGINT, failing_count BIGINT, between_count BIGINT);
CREATE TABLE IF NOT EXISTS run_buckets (
 resolution_ns BIGINT, bucket_ns BIGINT, workspace VARCHAR, monitor_id UBIGINT,
 revision BIGINT, acceptance VARCHAR, run_count BIGINT, failed_count BIGINT,
 duration_sum_ns HUGEINT, duration_max_ns BIGINT);
`

func initializeHistoryRollups(ctx context.Context, db *sql.DB) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, historyRollupSchema); err != nil {
		return err
	}
	// Adopt the timestamp-keyed availability schema atomically. Legacy evidence
	// retains identity zero; new server capture IDs never use that namespace.
	var legacyAvailability bool
	if err = tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name='uptime_snapshots')
 AND NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='uptime_snapshots' AND column_name='snapshot_id')`).Scan(&legacyAvailability); err != nil {
		return err
	}
	if legacyAvailability {
		if _, err = tx.ExecContext(ctx, `ALTER TABLE uptime_snapshots RENAME TO uptime_snapshots_legacy;
 ALTER TABLE uptime_states RENAME TO uptime_states_legacy`); err != nil {
			return err
		}
	}
	if _, err = tx.ExecContext(ctx, historyAvailabilitySchema); err != nil {
		return err
	}
	if legacyAvailability {
		if _, err = tx.ExecContext(ctx, `INSERT INTO uptime_snapshots SELECT *,0,'' FROM uptime_snapshots_legacy;
 INSERT INTO uptime_states SELECT *,0 FROM uptime_states_legacy;
 DROP TABLE uptime_states_legacy; DROP TABLE uptime_snapshots_legacy`); err != nil {
			return err
		}
	}
	// One-time adoption of files from the raw-only writer. Reopening must not
	// scan every retained sample or reset the late-arrival watermark.
	var initialized bool
	if err = tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM history_meta WHERE key='rollup_version')").Scan(&initialized); err != nil {
		return err
	}
	if !initialized {
		if _, err = tx.ExecContext(ctx, `INSERT INTO history_dirty_hours SELECT DISTINCT observed_at // ? * ? FROM runs ON CONFLICT DO NOTHING`, historyHour, historyHour); err != nil {
			return err
		}
		if _, err = tx.ExecContext(ctx, "INSERT INTO history_meta VALUES ('rollup_version',1),('raw_floor',0)"); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// A maintenance transaction processes one dirty UTC hour and retires at most
// one raw hour and one bucket timestamp per aggregate resolution. The writer
// serializes all writes, so inserts cannot race recomputation/deletion.
func maintainHistory(ctx context.Context, db *sql.DB, now time.Time) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	rawFloor := now.UTC().Add(-14 * 24 * time.Hour).Truncate(time.Hour).UnixNano()
	fiveFloor := now.UTC().Add(-90 * 24 * time.Hour).Truncate(5 * time.Minute).UnixNano()
	var hourFloor int64
	if err = tx.QueryRowContext(ctx, "SELECT epoch_ns(make_timestamp_ns(?) - INTERVAL '13 months')", now.UnixNano()).Scan(&hourFloor); err != nil {
		return err
	}
	hourFloor = time.Unix(0, hourFloor).UTC().Truncate(time.Hour).UnixNano()
	if _, err = tx.ExecContext(ctx, "UPDATE history_meta SET value=greatest(value,?) WHERE key='raw_floor'", rawFloor); err != nil {
		return err
	}
	var hour sql.NullInt64
	if err = tx.QueryRowContext(ctx, "SELECT min(hour_ns) FROM history_dirty_hours").Scan(&hour); err != nil {
		return err
	}
	if hour.Valid {
		if err = aggregateHistoryHour(ctx, tx, hour.Int64, fiveFloor, hourFloor); err != nil {
			return err
		}
		if _, err = tx.ExecContext(ctx, "DELETE FROM history_dirty_hours WHERE hour_ns=?", hour.Int64); err != nil {
			return err
		}
	}
	// Never delete an unaggregated hour, even after a long shutdown or failed batch.
	if _, err = tx.ExecContext(ctx, `CREATE OR REPLACE TEMP TABLE history_expired_runs AS
 SELECT run_id FROM runs WHERE observed_at // ? * ? = (
 SELECT min(observed_at // ? * ?) FROM runs r
 WHERE observed_at < ? AND NOT EXISTS (
 SELECT 1 FROM history_dirty_hours d WHERE d.hour_ns = r.observed_at // ? * ?))`,
		historyHour, historyHour, historyHour, historyHour, rawFloor, historyHour, historyHour); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM samples WHERE run_id IN (SELECT run_id FROM history_expired_runs)"); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM check_diagnostics WHERE run_id IN (SELECT run_id FROM history_expired_runs)"); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM runs WHERE run_id IN (SELECT run_id FROM history_expired_runs)"); err != nil {
		return err
	}
	if err = maintainAvailability(ctx, tx, now.UnixNano(), rawFloor, fiveFloor, hourFloor); err != nil {
		return err
	}
	for _, table := range []string{"sample_buckets", "run_buckets", "uptime_buckets"} {
		for _, tier := range []struct{ resolution, floor int64 }{{historyFiveMinutes, fiveFloor}, {historyHour, hourFloor}} {
			if _, err = tx.ExecContext(ctx, "DELETE FROM "+table+" WHERE resolution_ns=? AND bucket_ns=(SELECT min(bucket_ns) FROM "+table+" WHERE resolution_ns=? AND bucket_ns<?)", tier.resolution, tier.resolution, tier.floor); err != nil {
				return err
			}
		}
	}
	return tx.Commit()
}

func aggregateHistoryHour(ctx context.Context, tx *sql.Tx, hour, fiveFloor, hourFloor int64) error {
	// Revision and NRC acceptance are dimensions, not values to merge. No sample
	// index is required: dirty-hour receipts trigger replacement, never addition.
	_, err := tx.ExecContext(ctx, `CREATE OR REPLACE TEMP TABLE history_sample_stage AS
 SELECT ?::BIGINT resolution_ns, r.observed_at // ? * ? bucket_ns,
 r.workspace,r.monitor_id,r.revision,r.acceptance,s.identity,
 count(*)::BIGINT value_count,min(value) min_value,max(value) max_value,sum(value) sum_value,
 last(value ORDER BY observed_at,r.run_id) last_value,max(observed_at) last_at,
 last(r.run_id ORDER BY observed_at,r.run_id) last_run_id,
 count(*) FILTER(WHERE condition=0)::BIGINT passing_count,
 count(*) FILTER(WHERE condition=1)::BIGINT failing_count,
 count(*) FILTER(WHERE condition=2)::BIGINT between_count
 FROM runs r JOIN samples s USING(run_id)
 WHERE r.observed_at>=? AND r.observed_at<?
 GROUP BY ALL`, historyFiveMinutes, historyFiveMinutes, historyFiveMinutes, hour, hour+historyHour)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `CREATE OR REPLACE TEMP TABLE history_run_stage AS
 SELECT ?::BIGINT resolution_ns, observed_at // ? * ? bucket_ns,
 workspace,monitor_id,revision,acceptance,count(*)::BIGINT run_count,
 count(*) FILTER(WHERE failed)::BIGINT failed_count,sum(duration_ns) duration_sum_ns,max(duration_ns) duration_max_ns
 FROM runs WHERE observed_at>=? AND observed_at<? GROUP BY ALL`, historyFiveMinutes, historyFiveMinutes, historyFiveMinutes, hour, hour+historyHour)
	if err != nil {
		return err
	}
	for _, table := range []string{"sample_buckets", "run_buckets"} {
		if _, err = tx.ExecContext(ctx, "DELETE FROM "+table+" WHERE bucket_ns>=? AND bucket_ns<?", hour, hour+historyHour); err != nil {
			return err
		}
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO sample_buckets SELECT * FROM history_sample_stage WHERE bucket_ns>=?", fiveFloor); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO run_buckets SELECT * FROM history_run_stage WHERE bucket_ns>=?", fiveFloor); err != nil {
		return err
	}
	if hour >= hourFloor {
		_, err = tx.ExecContext(ctx, `INSERT INTO sample_buckets
 SELECT ?::BIGINT,?::BIGINT,workspace,monitor_id,revision,acceptance,identity,
 sum(value_count),min(min_value),max(max_value),sum(sum_value),
 last(last_value ORDER BY last_at,last_run_id),max(last_at),last(last_run_id ORDER BY last_at,last_run_id),
 sum(passing_count),sum(failing_count),sum(between_count)
 FROM history_sample_stage GROUP BY workspace,monitor_id,revision,acceptance,identity`, historyHour, hour)
		if err != nil {
			return err
		}
		_, err = tx.ExecContext(ctx, `INSERT INTO run_buckets
 SELECT ?::BIGINT,?::BIGINT,workspace,monitor_id,revision,acceptance,
 sum(run_count),sum(failed_count),sum(duration_sum_ns),max(duration_max_ns)
 FROM history_run_stage GROUP BY workspace,monitor_id,revision,acceptance`, historyHour, hour)
	}
	return err
}
