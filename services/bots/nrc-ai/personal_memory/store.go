// Package personalmemory owns private originals and a revisable binary summary
// forest. It has no NRC connection and cannot publish records or execute plans.
package personalmemory

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"syscall"
	"unicode/utf8"

	_ "modernc.org/sqlite"
)

var (
	ErrScope         = errors.New("personal memory requires an owner, workspace and explicit retention consent")
	ErrConflict      = errors.New("memory revision or idempotency conflict")
	ErrNotFound      = errors.New("memory not found")
	ErrOriginalLimit = errors.New("segment exceeds original byte budget")
)

const MaxOriginalBytes = 64 << 10
const MaxSummaryBytes = 2048

type Store struct {
	db         *sql.DB
	path       string
	mu         sync.Mutex
	lock       *os.File
	executions map[*Scope]context.CancelFunc
}

// Scope is an internal capability. The HTTP boundary must supply the verified
// principal, never a model argument. Temporary execution must not obtain one.
type Scope struct {
	store            *Store
	owner, workspace string
	epoch            int64
	fenced           bool
}

type Record struct {
	Role            string `json:"role"`
	Text            string `json:"text"`
	EventID         string `json:"event_id,omitempty"`
	ProviderSession string `json:"provider_session,omitempty"`
	StartMS         *int64 `json:"start_ms,omitempty"`
	EndMS           *int64 `json:"end_ms,omitempty"`
}

type Segment struct {
	Sequence int64    `json:"sequence"`
	Revision int64    `json:"revision"`
	Channel  string   `json:"channel"`
	State    string   `json:"state"`
	Records  []Record `json:"records"`
	RunID    string   `json:"run_id,omitempty"`
}

// Open requires a private directory on local storage. One process owns the DB.
// WAL/FULL protects committed originals; backups must include SQLite's WAL state.
func Open(path string) (*Store, error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("memory path must be absolute")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	info, err := os.Stat(filepath.Dir(path))
	if err != nil || info.Mode().Perm()&0077 != 0 {
		return nil, errors.New("memory directory must be private (0700)")
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	info, err = f.Stat()
	opened := false
	defer func() {
		if !opened {
			f.Close()
		}
	}()
	if err != nil || info.Mode().Perm()&0077 != 0 {
		return nil, errors.New("memory file must be private (0600)")
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return nil, errors.New("memory store already owned by another instance")
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	_, err = db.Exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
PRAGMA foreign_keys=ON; PRAGMA secure_delete=ON; PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS storage_identity(id TEXT NOT NULL);
INSERT INTO storage_identity SELECT lower(hex(randomblob(16))) WHERE NOT EXISTS (SELECT 1 FROM storage_identity);
CREATE TABLE IF NOT EXISTS scopes(owner TEXT, workspace TEXT, next_seq INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(owner,workspace));
CREATE TABLE IF NOT EXISTS segments(owner TEXT, workspace TEXT, seq INTEGER, revision INTEGER NOT NULL,
 request_key TEXT NOT NULL, channel TEXT NOT NULL, state TEXT NOT NULL, body TEXT NOT NULL,
 PRIMARY KEY(owner,workspace,seq), UNIQUE(owner,workspace,request_key));
CREATE TABLE IF NOT EXISTS nodes(owner TEXT, workspace TEXT, lo INTEGER, hi INTEGER,
 revision INTEGER NOT NULL DEFAULT 1, state TEXT NOT NULL DEFAULT 'pending', summary TEXT NOT NULL DEFAULT '',
 version TEXT NOT NULL DEFAULT '', PRIMARY KEY(owner,workspace,lo,hi));
CREATE TABLE IF NOT EXISTS summary_attempts(owner TEXT, workspace TEXT, lo INTEGER, hi INTEGER,
 revision INTEGER NOT NULL, attempts INTEGER NOT NULL, PRIMARY KEY(owner,workspace,lo,hi));
CREATE TRIGGER IF NOT EXISTS summary_attempts_revision AFTER UPDATE OF revision ON nodes
WHEN NEW.revision!=OLD.revision BEGIN
 DELETE FROM summary_attempts WHERE owner=NEW.owner AND workspace=NEW.workspace AND lo=NEW.lo AND hi=NEW.hi;
END;
CREATE TABLE IF NOT EXISTS memory_views(owner TEXT, workspace TEXT, end_seq INTEGER NOT NULL,
 layout TEXT NOT NULL, PRIMARY KEY(owner,workspace));
CREATE TABLE IF NOT EXISTS summary_views(owner TEXT, workspace TEXT, end_seq INTEGER NOT NULL,
 layout TEXT NOT NULL, PRIMARY KEY(owner,workspace));
CREATE VIRTUAL TABLE IF NOT EXISTS originals_fts USING fts5(owner UNINDEXED, workspace UNINDEXED, seq UNINDEXED, body);
INSERT INTO originals_fts(originals_fts,rank) VALUES('secure-delete',1);
CREATE TABLE IF NOT EXISTS runs(owner TEXT, workspace TEXT, channel TEXT, id TEXT, digest TEXT NOT NULL, seq INTEGER NOT NULL,
 PRIMARY KEY(owner,workspace,channel,id));
CREATE INDEX IF NOT EXISTS runs_segment ON runs(owner,workspace,channel,seq);
CREATE TABLE IF NOT EXISTS receipts(owner TEXT,workspace TEXT,channel TEXT,session TEXT,plan TEXT,action TEXT,
 digest TEXT NOT NULL,state TEXT NOT NULL,result TEXT NOT NULL,PRIMARY KEY(owner,workspace,channel,session,plan,action));
CREATE TABLE IF NOT EXISTS retention(owner TEXT,workspace TEXT,epoch INTEGER NOT NULL DEFAULT 0,
 enabled INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(owner,workspace));`)
	if err == nil {
		err = migrateChanges(db)
	}
	if err == nil {
		_, err = db.Exec(`BEGIN IMMEDIATE;
UPDATE nodes SET revision=revision+1,state='pending',summary='',version='' WHERE EXISTS
 (SELECT 1 FROM segments s WHERE s.owner=nodes.owner AND s.workspace=nodes.workspace AND s.state='active' AND s.seq BETWEEN nodes.lo AND nodes.hi);
UPDATE segments SET revision=revision+1,state='incomplete' WHERE state='active';
COMMIT;`)
	}
	if err == nil {
		err = installSummaryQueue(db)
	}
	if err != nil {
		db.Close()
		return nil, err
	}
	opened = true
	return &Store{db: db, path: path, lock: f, executions: make(map[*Scope]context.CancelFunc)}, nil
}

func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for scope, cancel := range s.executions {
		cancel()
		delete(s.executions, scope)
	}
	return errors.Join(s.db.Close(), s.lock.Close())
}

func (s *Store) Personal(owner, workspace string, consent bool) (*Scope, error) {
	if !consent || owner == "" || workspace == "" {
		return nil, ErrScope
	}
	return s.Controls(owner, workspace)
}

// Controls initializes new accounts with personal memory enabled. INSERT OR
// IGNORE preserves any previously saved disablement.
func (s *Store) Controls(owner, workspace string) (*Scope, error) {
	if owner == "" || workspace == "" {
		return nil, ErrScope
	}
	_, err := s.db.Exec(`INSERT OR IGNORE INTO retention(owner,workspace,enabled) VALUES(?,?,1)`, owner, workspace)
	if err != nil {
		return nil, err
	}
	return &Scope{store: s, owner: owner, workspace: workspace}, nil
}

// Lookup never creates or enables policy, including for temporary requests.
func (s *Store) Lookup(ctx context.Context, owner, workspace string) (*Scope, error) {
	scope := &Scope{store: s, owner: owner, workspace: workspace}
	var exists int
	if err := s.db.QueryRowContext(ctx, `SELECT 1 FROM retention WHERE owner=? AND workspace=?`, owner, workspace).Scan(&exists); errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	} else if err != nil {
		return nil, err
	}
	return scope, nil
}

func encodeRecords(records []Record) (string, error) {
	if len(records) == 0 {
		return "", errors.New("original records required")
	}
	for _, r := range records {
		if !utf8.ValidString(r.Text) {
			return "", errors.New("invalid original UTF-8")
		}
		switch r.Role {
		case "user", "assistant", "backend", "receipt":
		default:
			return "", errors.New("invalid original role")
		}
	}
	body, err := json.Marshal(records)
	if len(body) > MaxOriginalBytes {
		return "", ErrOriginalLimit
	}
	return string(body), err
}

func validState(state string) bool {
	return state == "active" || state == "complete" || state == "failed" || state == "cancelled" || state == "incomplete"
}

// Append accepts originals before generation. A retry must have identical data;
// it never dispatches a model or NRC operation. Active segments remain outside
// the summary forest until Finish seals their actual outcome.
func (s *Scope) Append(ctx context.Context, key, channel, state string, records []Record) (Segment, error) {
	body, err := encodeRecords(records)
	if err != nil {
		return Segment{}, err
	}
	if key == "" || len(key) > 256 || (channel != "chat" && channel != "voice") || !validState(state) {
		return Segment{}, errors.New("invalid segment metadata")
	}
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	tx, err := s.store.db.BeginTx(ctx, nil)
	if err != nil {
		return Segment{}, err
	}
	defer tx.Rollback()
	segment, err := s.appendSegment(ctx, tx, key, channel, state, body, records)
	if err != nil {
		return Segment{}, err
	}
	if err = tx.Commit(); err != nil {
		return Segment{}, err
	}
	return segment, nil
}

func (s *Scope) appendSegment(ctx context.Context, tx *sql.Tx, key, channel, state, body string, records []Record) (Segment, error) {
	var seq int64
	var oldBody, oldChannel, oldState string
	err := tx.QueryRowContext(ctx, `SELECT seq,body,channel,state FROM segments WHERE owner=? AND workspace=? AND request_key=?`, s.owner, s.workspace, key).Scan(&seq, &oldBody, &oldChannel, &oldState)
	if err == nil {
		if oldBody != body || oldChannel != channel || oldState != state {
			return Segment{}, ErrConflict
		}
		return readSegment(ctx, tx, s, seq)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return Segment{}, err
	}
	if err := s.checkWrite(ctx, tx); err != nil {
		return Segment{}, err
	}
	if _, err = tx.ExecContext(ctx, `INSERT OR IGNORE INTO scopes(owner,workspace) VALUES(?,?)`, s.owner, s.workspace); err != nil {
		return Segment{}, err
	}
	if err = tx.QueryRowContext(ctx, `UPDATE scopes SET next_seq=next_seq+1 WHERE owner=? AND workspace=? RETURNING next_seq-1`, s.owner, s.workspace).Scan(&seq); err != nil {
		return Segment{}, err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO segments VALUES(?,?,?,1,?,?,?,?)`, s.owner, s.workspace, seq, key, channel, state, body); err != nil {
		return Segment{}, err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO originals_fts VALUES(?,?,?,?)`, s.owner, s.workspace, seq, body); err != nil {
		return Segment{}, err
	}
	if err := s.advanceUserInput(ctx, tx, records); err != nil {
		return Segment{}, err
	}
	// Allocate stable leaves and every complete aligned sibling pair. Nodes are
	// the durable job queue; pending nodes survive a crash without job replay.
	for width := int64(1); (seq+1)%width == 0; width *= 2 {
		if _, err = tx.ExecContext(ctx, `INSERT INTO nodes(owner,workspace,lo,hi) VALUES(?,?,?,?)`, s.owner, s.workspace, seq+1-width, seq); err != nil {
			return Segment{}, err
		}
		if width > (seq+1)/2 {
			break
		}
	}
	return Segment{Sequence: seq, Revision: 1, Channel: channel, State: state, Records: records}, nil
}

type rowReader interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func readSegment(ctx context.Context, db rowReader, s *Scope, seq int64) (Segment, error) {
	if err := s.checkEpoch(ctx, db); err != nil {
		return Segment{}, err
	}
	segment := Segment{Sequence: seq}
	var body string
	err := db.QueryRowContext(ctx, `SELECT revision,channel,state,body,
coalesce((SELECT id FROM runs r WHERE r.owner=s.owner AND r.workspace=s.workspace AND r.channel=s.channel AND r.seq=s.seq),'')
FROM segments s WHERE owner=? AND workspace=? AND seq=? AND state!='deleted'`, s.owner, s.workspace, seq).Scan(&segment.Revision, &segment.Channel, &segment.State, &body, &segment.RunID)
	if errors.Is(err, sql.ErrNoRows) {
		return Segment{}, ErrNotFound
	}
	if err != nil {
		return Segment{}, err
	}
	err = json.Unmarshal([]byte(body), &segment.Records)
	return segment, err
}

func (s *Scope) Read(ctx context.Context, seq int64) (Segment, error) {
	return readSegment(ctx, s.store.db, s, seq)
}

// AppendFragment commits one exact event before acknowledging capture. It cannot
// reopen sealed evidence or replace originals. The revision and execution epoch
// fence the whole read/append/index invalidation transaction.
func (s *Scope) AppendFragment(ctx context.Context, seq, revision int64, fragment Record) (Segment, error) {
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	tx, err := s.store.db.BeginTx(ctx, nil)
	if err != nil {
		return Segment{}, err
	}
	defer tx.Rollback()
	previous, err := readSegment(ctx, tx, s, seq)
	if err != nil {
		return Segment{}, err
	}
	if err := s.checkWrite(ctx, tx); err != nil {
		return Segment{}, err
	}
	if previous.State != "active" || previous.Revision != revision || fragment.EventID == "" {
		return Segment{}, ErrConflict
	}
	for _, record := range previous.Records {
		if record.EventID == fragment.EventID && record.ProviderSession == fragment.ProviderSession {
			if !reflect.DeepEqual(record, fragment) {
				return Segment{}, ErrConflict
			}
			return previous, nil
		}
	}
	previous.Records = append(previous.Records, fragment)
	body, err := encodeRecords(previous.Records)
	if err != nil {
		return Segment{}, err
	}
	if err := s.reviseSegment(ctx, tx, seq, revision, "active", body); err != nil {
		return Segment{}, err
	}
	if err := s.advanceUserInput(ctx, tx, []Record{fragment}); err != nil {
		return Segment{}, err
	}
	if err := tx.Commit(); err != nil {
		return Segment{}, err
	}
	previous.Revision++
	return previous, nil
}

// Finish atomically replaces a captured segment with a new revision, preserving
// exact original fragments supplied by the capture owner. Factual corrections
// belong in a new segment; use this for completion or late captured fragments.
func (s *Scope) Finish(ctx context.Context, seq, revision int64, state string, records []Record) error {
	body, err := encodeRecords(records)
	if err != nil {
		return err
	}
	if !validState(state) || state == "active" {
		return errors.New("terminal capture state required")
	}
	return s.revise(ctx, seq, revision, state, body)
}

func (s *Scope) Forget(ctx context.Context, seq, revision int64) error {
	return s.revise(ctx, seq, revision, "deleted", "")
}

func (s *Scope) revise(ctx context.Context, seq, revision int64, state, body string) error {
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	tx, err := s.store.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := s.reviseSegment(ctx, tx, seq, revision, state, body); err != nil {
		return err
	}
	if state == "deleted" {
		if err := s.invalidate(ctx, tx); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	if state == "deleted" {
		s.cancelExecutions()
	}
	return nil
}

func (s *Scope) reviseSegment(ctx context.Context, tx *sql.Tx, seq, revision int64, state, body string) error {
	if state != "deleted" {
		previous, err := readSegment(ctx, tx, s, seq)
		if errors.Is(err, ErrNotFound) {
			return ErrConflict
		}
		if err != nil {
			return err
		}
		if err := s.checkWrite(ctx, tx); err != nil {
			return err
		}
		var updated []Record
		if json.Unmarshal([]byte(body), &updated) != nil || len(updated) < len(previous.Records) ||
			!reflect.DeepEqual(previous.Records, updated[:len(previous.Records)]) {
			return errors.New("original evidence cannot be replaced; append a correction")
		}
	}
	r, err := tx.ExecContext(ctx, `UPDATE segments SET revision=revision+1,state=?,body=? WHERE owner=? AND workspace=? AND seq=? AND revision=? AND state!='deleted'`, state, body, s.owner, s.workspace, seq, revision)
	if err != nil {
		return err
	}
	n, _ := r.RowsAffected()
	if n != 1 {
		return ErrConflict
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM originals_fts WHERE owner=? AND workspace=? AND seq=?`, s.owner, s.workspace, seq); err != nil {
		return err
	}
	if state != "deleted" {
		if _, err = tx.ExecContext(ctx, `INSERT INTO originals_fts VALUES(?,?,?,?)`, s.owner, s.workspace, seq, body); err != nil {
			return err
		}
	}
	if _, err = tx.ExecContext(ctx, `UPDATE nodes SET revision=revision+1,state='pending',summary='',version='' WHERE owner=? AND workspace=? AND lo<=? AND hi>=?`, s.owner, s.workspace, seq, seq); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM memory_views WHERE owner=? AND workspace=? AND end_seq>?`, s.owner, s.workspace, seq); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM summary_views WHERE owner=? AND workspace=? AND end_seq>?`, s.owner, s.workspace, seq); err != nil {
		return err
	}
	return nil
}

// Search supplements tree navigation. FTS syntax is passed as data and scoped
// before results leave the store. Originals are bounded; no shared search index.
// Newest matching evidence comes first so repeated old answers cannot crowd out
// a recent correction merely by having a higher term-frequency score.
func (s *Scope) Search(ctx context.Context, query string, limit int) ([]int64, error) {
	if err := s.checkEpoch(ctx, s.store.db); err != nil {
		return nil, err
	}
	// The tool accepts 256 raw bytes; quoting up to 16 literal terms adds syntax.
	if len(query) > 512 || limit < 1 || limit > 50 {
		return nil, fmt.Errorf("invalid search budget")
	}
	rows, err := s.store.db.QueryContext(ctx, `SELECT seq FROM originals_fts WHERE originals_fts MATCH ? AND owner=? AND workspace=? ORDER BY CAST(seq AS INTEGER) DESC LIMIT ?`, query, s.owner, s.workspace, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err = rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}
