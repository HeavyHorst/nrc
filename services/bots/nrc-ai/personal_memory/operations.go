package personalmemory

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
)

// Run IDs are supplied by the client before dispatch and survive HTTP loss.
// Recovery returns evidence, never executable plans or permission to regenerate.
type Run struct {
	ID                  string  `json:"id"`
	Segment             Segment `json:"segment"`
	UserInputGeneration int64   `json:"-"`
}

func validOperationID(id string) bool  { return len(id) > 0 && len(id) <= 128 }
func validChannel(channel string) bool { return channel == "chat" || channel == "voice" }
func operationDigest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// BeginRun atomically commits idempotency identity, original input and tree leaf.
// created=false never authorizes a second model invocation, even after a crash.
func (s *Scope) BeginRun(ctx context.Context, id, channel string, request []byte, records []Record) (run Run, created bool, err error) {
	if !validOperationID(id) || !validChannel(channel) || len(request) == 0 || len(request) > 2<<20 {
		return run, false, errors.New("invalid run")
	}
	body, err := encodeRecords(records)
	if err != nil {
		return run, false, err
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	tx, err := s.store.db.BeginTx(ctx, nil)
	if err != nil {
		return run, false, err
	}
	defer tx.Rollback()
	var digest string
	var seq int64
	err = tx.QueryRowContext(ctx, `SELECT digest,seq FROM runs WHERE owner=? AND workspace=? AND channel=? AND id=?`, s.owner, s.workspace, channel, id).Scan(&digest, &seq)
	if err == nil {
		if digest != operationDigest(request) {
			return run, false, ErrConflict
		}
		segment, err := readSegment(ctx, tx, s, seq)
		return Run{ID: id, Segment: segment}, false, err
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return run, false, err
	}
	segment, err := s.appendSegment(ctx, tx, "run/"+channel+"/"+id, channel, "active", body, records)
	if err != nil {
		return run, false, err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO runs VALUES(?,?,?,?,?,?)`, s.owner, s.workspace, channel, id, operationDigest(request), segment.Sequence); err != nil {
		return run, false, err
	}
	generation, err := s.userInputGeneration(ctx, tx)
	if err != nil {
		return run, false, err
	}
	if err = tx.Commit(); err != nil {
		return run, false, err
	}
	segment.RunID = id
	return Run{ID: id, Segment: segment, UserInputGeneration: generation}, true, nil
}

// ReplayRun checks an existing request without accepting new input. A missing
// or deleted original is never permission to regenerate it.
func (s *Scope) ReplayRun(ctx context.Context, channel, id string, request []byte) (Run, error) {
	return s.readRun(ctx, channel, id, operationDigest(request))
}

func (s *Scope) ReadRun(ctx context.Context, channel, id string) (Run, error) {
	return s.readRun(ctx, channel, id, "")
}

func (s *Scope) readRun(ctx context.Context, channel, id, expectedDigest string) (Run, error) {
	if err := s.checkEpoch(ctx, s.store.db); err != nil {
		return Run{}, err
	}
	var seq int64
	var digest string
	err := s.store.db.QueryRowContext(ctx, `SELECT seq,digest FROM runs WHERE owner=? AND workspace=? AND channel=? AND id=?`, s.owner, s.workspace, channel, id).Scan(&seq, &digest)
	if errors.Is(err, sql.ErrNoRows) {
		return Run{}, ErrNotFound
	}
	if err != nil {
		return Run{}, err
	}
	if expectedDigest != "" && digest != expectedDigest {
		return Run{}, ErrConflict
	}
	segment, err := s.Read(ctx, seq)
	return Run{ID: id, Segment: segment}, err
}

// Receipt contains minimal operation metadata, not the action's private text.
// outcome_unknown is written BEFORE any external dispatch. It is not replayable.
// Result is bounded application-defined metadata (IDs/statuses, no content).
type Receipt struct {
	Channel   string          `json:"channel"`
	SessionID string          `json:"session_id"`
	PlanID    string          `json:"plan_id"`
	ActionID  string          `json:"action_id"`
	State     string          `json:"state"`
	Result    json.RawMessage `json:"result,omitempty"`
}

func (s *Scope) ConsumeApproval(ctx context.Context, channel, session, plan, action string, proposal []byte, inputGeneration ...int64) (Receipt, bool, error) {
	r := Receipt{Channel: channel, SessionID: session, PlanID: plan, ActionID: action}
	if !validChannel(channel) || !validOperationID(session) || !validOperationID(plan) || !validOperationID(action) || len(proposal) == 0 || len(proposal) > 2<<20 {
		return r, false, errors.New("invalid approval")
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	if err := s.checkEpoch(ctx, s.store.db); err != nil {
		return r, false, err
	}
	// The process owns the database, and every captured user input also holds mu.
	// Compare and consume under that same lock: a newer input cannot slip between.
	if len(inputGeneration) != 0 {
		current, err := s.userInputGeneration(ctx, s.store.db)
		if err != nil {
			return r, false, err
		}
		if current != inputGeneration[0] {
			return r, false, ErrConflict
		}
	}
	result, err := s.store.db.ExecContext(ctx, `INSERT OR IGNORE INTO receipts(owner,workspace,channel,session,plan,action,digest,state,result) VALUES(?,?,?,?,?,?,?,'outcome_unknown','')`, s.owner, s.workspace, channel, session, plan, action, operationDigest(proposal))
	if err != nil {
		return r, false, err
	}
	n, err := result.RowsAffected()
	if err != nil {
		return r, false, err
	}
	var digest string
	var data string
	err = s.store.db.QueryRowContext(ctx, `SELECT digest,state,result FROM receipts WHERE owner=? AND workspace=? AND channel=? AND session=? AND plan=? AND action=?`, s.owner, s.workspace, channel, session, plan, action).Scan(&digest, &r.State, &data)
	if err != nil {
		return r, false, err
	}
	if digest != operationDigest(proposal) {
		return r, false, ErrConflict
	}
	if data != "" {
		r.Result = json.RawMessage(data)
	}
	return r, n == 1, nil
}

func (s *Scope) CompleteApproval(ctx context.Context, r Receipt, state string, result json.RawMessage) error {
	if state != "applied" && state != "failed" && state != "outcome_unknown" {
		return errors.New("invalid receipt state")
	}
	if len(result) > 16<<10 || !json.Valid(result) {
		return errors.New("invalid receipt result")
	}
	res, err := s.store.db.ExecContext(ctx, `UPDATE receipts SET state=?,result=? WHERE owner=? AND workspace=? AND channel=? AND session=? AND plan=? AND action=? AND state='outcome_unknown' AND result=''`, state, string(result), s.owner, s.workspace, r.Channel, r.SessionID, r.PlanID, r.ActionID)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err == nil && n != 1 {
		return ErrConflict
	}
	return err
}

func (s *Scope) ReadReceipt(ctx context.Context, channel, session, plan, action string) (Receipt, error) {
	r := Receipt{Channel: channel, SessionID: session, PlanID: plan, ActionID: action}
	var result string
	err := s.store.db.QueryRowContext(ctx, `SELECT state,result FROM receipts WHERE owner=? AND workspace=? AND channel=? AND session=? AND plan=? AND action=?`, s.owner, s.workspace, channel, session, plan, action).Scan(&r.State, &result)
	if errors.Is(err, sql.ErrNoRows) {
		return r, ErrNotFound
	}
	if result != "" {
		r.Result = json.RawMessage(result)
	}
	return r, err
}

type ReceiptEntry struct {
	Receipt
	Position int64 `json:"position"`
}

// Receipt history contains evidence only, including unresolved approvals. It
// remains available after forgetting; no original text or executable plan lives here.
func (s *Scope) Receipts(ctx context.Context, before int64, limit int) ([]ReceiptEntry, error) {
	if before < -1 || limit < 1 || limit > 100 {
		return nil, errors.New("invalid receipt page")
	}
	if before == -1 {
		before = 1<<63 - 1
	}
	rows, err := s.store.db.QueryContext(ctx, `SELECT rowid,channel,session,plan,action,state,result FROM receipts WHERE owner=? AND workspace=? AND rowid<? ORDER BY rowid DESC LIMIT ?`, s.owner, s.workspace, before, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]ReceiptEntry, 0)
	for rows.Next() {
		var entry ReceiptEntry
		var result string
		if err := rows.Scan(&entry.Position, &entry.Channel, &entry.SessionID, &entry.PlanID, &entry.ActionID, &entry.State, &result); err != nil {
			return nil, err
		}
		if result != "" {
			entry.Result = json.RawMessage(result)
		}
		out = append(out, entry)
	}
	return out, rows.Err()
}
