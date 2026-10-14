package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	protocol "github.com/heavyhorst/nrc/protocol-go"
	bolt "go.etcd.io/bbolt"
)

var (
	slugPattern = regexp.MustCompile(`^[a-z0-9]+(?:-[a-z0-9]+)*$`)
	filePattern = regexp.MustCompile(`^att_[A-Za-z0-9_-]{1,124}$`)
	errConflict = errors.New("Der Veröffentlichungsstand hat sich geändert. Bitte erneut vergleichen.")
	errNotFound = errors.New("Nicht gefunden")
)

type revision struct {
	ID                                             string
	SourceID                                       uint64
	SourceUpdated                                  int64
	Slug, Title, Summary, Category, Kind, Markdown string
	Attachments                                    []protocol.Attachment
	CreatedAt                                      time.Time
	CreatedBy                                      string
	// Only public titles and URLs, frozen for human review.
	NoteReferences map[string]articleReference
	// Publication generation seen when preparing this draft. Approval uses CAS.
	Base string
	// Navigation metadata is loaded separately from the approved snapshot.
	Subtopic string `json:"-"`
}

type publication struct {
	Slug, Revision, Actor string
	At                    time.Time
}

type store struct {
	db        *bolt.DB
	workspace string
}

func openStore(path, workspace string) (*store, error) {
	if workspace == "" {
		return nil, errors.New("Workspace ist erforderlich")
	}
	db, err := bolt.Open(path, 0600, &bolt.Options{Timeout: time.Second})
	if err != nil {
		return nil, err
	}
	err = db.Update(func(tx *bolt.Tx) error {
		for _, name := range []string{"revisions", "drafts", "published", "heads", "media", "audit", "meta", "reviews", "redirects", "ordering", "subtopics"} {
			if _, err := tx.CreateBucketIfNotExists([]byte(name)); err != nil {
				return err
			}
		}
		meta := tx.Bucket([]byte("meta"))
		if existing := meta.Get([]byte("workspace")); existing != nil && string(existing) != workspace {
			return errors.New("Die Publishing-Datenbank gehört zu einem anderen Workspace.")
		}
		return meta.Put([]byte("workspace"), []byte(workspace))
	})
	if err != nil {
		db.Close()
		return nil, err
	}
	return &store{db, workspace}, nil
}

func randomID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}

func putJSON(b *bolt.Bucket, key string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return b.Put([]byte(key), data)
}

func readRevision(tx *bolt.Tx, id string) (revision, error) {
	var r revision
	data := tx.Bucket([]byte("revisions")).Get([]byte(id))
	if data == nil {
		return r, errNotFound
	}
	err := json.Unmarshal(data, &r)
	return r, err
}

func (s *store) revision(id string) (revision, error) {
	var r revision
	err := s.db.View(func(tx *bolt.Tx) error { var err error; r, err = readRevision(tx, id); return err })
	return r, err
}

func (s *store) current(slug string) (revision, error) {
	var r revision
	err := s.db.View(func(tx *bolt.Tx) error {
		var err error
		r, err = readCurrent(tx, slug)
		return err
	})
	return r, err
}

func readCurrent(tx *bolt.Tx, slug string) (revision, error) {
	if id := tx.Bucket([]byte("published")).Get([]byte(slug)); id != nil {
		return readRevision(tx, string(id))
	}
	id, err := strconv.ParseUint(string(tx.Bucket([]byte("redirects")).Get([]byte(slug))), 10, 64)
	if err != nil {
		return revision{}, errNotFound
	}
	return readSource(tx, id)
}

func readSource(tx *bolt.Tx, id uint64) (revision, error) {
	var found revision
	err := tx.Bucket([]byte("published")).ForEach(func(_, v []byte) error {
		r, err := readRevision(tx, string(v))
		if err == nil && r.SourceID == id {
			found = r
		}
		return err
	})
	if err == nil && found.ID == "" {
		err = errNotFound
	}
	return found, err
}

func (s *store) currentForSource(id uint64) (revision, error) {
	var found revision
	err := s.db.View(func(tx *bolt.Tx) error {
		var err error
		found, err = readSource(tx, id)
		return err
	})
	return found, err
}

func revisionHead(tx *bolt.Tx, r revision) string {
	heads := tx.Bucket([]byte("heads"))
	if head := heads.Get([]byte(fmt.Sprintf("note:%d", r.SourceID))); head != nil {
		return string(head)
	}
	// Existing drafts recorded the URL's generation before source-ID ownership.
	return string(heads.Get([]byte(r.Slug)))
}

func (s *store) head(r revision) (string, error) {
	var head string
	err := s.db.View(func(tx *bolt.Tx) error { head = revisionHead(tx, r); return nil })
	return head, err
}

func (s *store) entries(bucket string) ([]revision, error) {
	rows := []revision{}
	ranks := map[string]map[uint64]int{}
	err := s.db.View(func(tx *bolt.Tx) error {
		if bucket == "published" {
			if err := tx.Bucket([]byte("ordering")).ForEach(func(k, v []byte) error {
				var ids []string
				if err := json.Unmarshal(v, &ids); err != nil {
					return err
				}
				ranks[string(k)] = map[uint64]int{}
				for i, id := range ids {
					n, _ := strconv.ParseUint(id, 10, 64)
					ranks[string(k)][n] = i + 1
				}
				return nil
			}); err != nil {
				return err
			}
		}
		return tx.Bucket([]byte(bucket)).ForEach(func(_, v []byte) error {
			r, err := readRevision(tx, string(v))
			if err != nil {
				return err
			}
			if bucket == "published" {
				r.Subtopic = string(tx.Bucket([]byte("subtopics")).Get([]byte(r.Category + "\x00" + strconv.FormatUint(r.SourceID, 10))))
			}
			rows = append(rows, r)
			return nil
		})
	})
	sort.Slice(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if bucket == "published" && a.Category != b.Category {
			return a.Category < b.Category
		}
		x, y := ranks[a.Category][a.SourceID], ranks[b.Category][b.SourceID]
		if x != y {
			return x != 0 && (y == 0 || x < y)
		}
		if a.Title != b.Title {
			return a.Title < b.Title
		}
		return a.SourceID < b.SourceID
	})
	return rows, err
}

// Ordering changes navigation only, never article snapshots or approval state.
func (s *store) setOrder(category string, ids []string) error {
	if strings.TrimSpace(category) == "" {
		return errors.New("Thema fehlt")
	}
	return s.db.Update(func(tx *bolt.Tx) error {
		seen := map[uint64]bool{}
		for _, id := range ids {
			n, err := strconv.ParseUint(id, 10, 64)
			if err != nil || n == 0 || strconv.FormatUint(n, 10) != id || seen[n] {
				return errors.New("Notiz-IDs müssen eindeutig und gültig sein")
			}
			r, err := readSource(tx, n)
			if err != nil || r.Category != category {
				return fmt.Errorf("Notiz #%s ist kein veröffentlichter Artikel im Thema %s", id, category)
			}
			seen[n] = true
		}
		return putJSON(tx.Bucket([]byte("ordering")), category, ids)
	})
}

// Assignments affect navigation only. Empty names remove a grouping.
func (s *store) setSubtopics(category string, assignments map[string]string) error {
	if strings.TrimSpace(category) == "" || assignments == nil {
		return errors.New("Thema und Zuordnungen fehlen")
	}
	return s.db.Update(func(tx *bolt.Tx) error {
		for id, name := range assignments {
			n, err := strconv.ParseUint(id, 10, 64)
			if err != nil || n == 0 || strconv.FormatUint(n, 10) != id {
				return errors.New("Ungültige Notiz-ID")
			}
			r, err := readSource(tx, n)
			if err != nil || r.Category != category {
				return fmt.Errorf("Notiz #%s ist kein veröffentlichter Artikel im Thema %s", id, category)
			}
			name = strings.TrimSpace(name)
			if !utf8.ValidString(name) || utf8.RuneCountInString(name) > 80 || strings.ContainsAny(name, "\n\r\x00") {
				return errors.New("Unterthemen dürfen höchstens 80 Zeichen ohne Zeilenumbrüche enthalten")
			}
			key := []byte(category + "\x00" + id)
			if name == "" {
				err = tx.Bucket([]byte("subtopics")).Delete(key)
			} else {
				err = tx.Bucket([]byte("subtopics")).Put(key, []byte(name))
			}
			if err != nil {
				return err
			}
		}
		return nil
	})
}

// Selected revisions override the public version of the same NRC note.
func resolveReference(tx *bolt.Tx, id string, selected []revision) (articleReference, error) {
	targets := make(map[string]articleReference)
	for _, target := range selected {
		if strconv.FormatUint(target.SourceID, 10) == id {
			targets[target.Slug] = articleReference{Slug: target.Slug, Title: target.Title, URL: "/articles/by-note/" + id}
		}
	}
	hasSelected := len(targets) != 0
	err := tx.Bucket([]byte("published")).ForEach(func(_, v []byte) error {
		if hasSelected {
			return nil
		}
		target, err := readRevision(tx, string(v))
		if err != nil {
			return err
		}
		if strconv.FormatUint(target.SourceID, 10) == id {
			targets[target.Slug] = articleReference{Slug: target.Slug, Title: target.Title, URL: "/articles/by-note/" + id}
		}
		return nil
	})
	if err != nil {
		return articleReference{}, err
	}
	if len(targets) > 1 {
		return articleReference{}, fmt.Errorf("Notiz [note:%s] hat mehrere Artikel. Bitte eine explizite /articles/<slug>-Verknüpfung verwenden.", id)
	}
	for _, ref := range targets {
		return ref, nil
	}
	return articleReference{}, nil
}

func (s *store) create(r revision, filesDir string) (revision, error) {
	r.Slug = strings.TrimSpace(r.Slug)
	r.Title = strings.TrimSpace(r.Title)
	r.Category = strings.TrimSpace(r.Category)
	r.Summary = strings.TrimSpace(r.Summary)
	if !slugPattern.MatchString(r.Slug) || len(r.Slug) > 100 {
		return r, errors.New("URL muss aus Kleinbuchstaben, Ziffern und Bindestrichen bestehen (max. 100 Zeichen).")
	}
	for _, value := range []string{r.Title, r.Category, r.Kind} {
		if strings.TrimSpace(value) == "" || utf8.RuneCountInString(value) > 200 {
			return r, errors.New("Titel, Kategorie und Inhaltstyp sind erforderlich (max. 200 Zeichen).")
		}
	}
	if utf8.RuneCountInString(r.Summary) > 500 {
		return r, errors.New("Kurzbeschreibung darf höchstens 500 Zeichen enthalten.")
	}
	if r.Kind != "Anleitung" && r.Kind != "Referenz" && r.Kind != "Fehlerbehebung" {
		return r, errors.New("Unbekannter Inhaltstyp")
	}
	if len(r.Attachments) > 10 {
		return r, errors.New("Zu viele Anhänge")
	}
	r.ID = randomID()
	r.CreatedAt = time.Now().UTC()
	files := map[string][]byte{}
	if len(r.Attachments) > 0 {
		if filesDir == "" {
			return r, errors.New("Für diese Notiz muss PUBLISH_FILES_DIR konfiguriert sein.")
		}
		root, err := os.OpenRoot(filesDir)
		if err != nil {
			return r, err
		}
		defer root.Close()
		total := 0
		for _, a := range r.Attachments {
			if !filePattern.MatchString(a.FileId) {
				return r, errors.New("Ungültige Anhang-ID")
			}
			// Same grant format as tailscale-proxy/fileWorkspaceMarker. Merely
			// putting a shared blob ID on a note must not grant workspace access.
			hash := sha256.Sum256([]byte(s.workspace))
			grant, err := root.ReadFile(filepath.Join(".workspace-access", a.FileId, hex.EncodeToString(hash[:])))
			if err != nil || string(grant) != s.workspace {
				return r, fmt.Errorf("Anhang %s hat keine lesbare Freigabe für diesen Workspace.", a.Filename)
			}
			f, err := root.Open(a.FileId)
			if err != nil {
				return r, fmt.Errorf("Anhang %s: %w", a.Filename, err)
			}
			data, err := io.ReadAll(io.LimitReader(f, (20<<20)+1))
			f.Close()
			if err != nil {
				return r, err
			}
			total += len(data)
			if len(data) > 20<<20 || total > 64<<20 {
				return r, errors.New("Anhänge überschreiten das Limit (20 MiB je Datei, 64 MiB insgesamt).")
			}
			files[a.FileId] = data
		}
	}
	err := s.db.Update(func(tx *bolt.Tx) error {
		r.Base = revisionHead(tx, r)
		r.NoteReferences = map[string]articleReference{}
		// Resolve and store links in the same transaction as the draft snapshot.
		if _, _, _, err := renderMarkdownWithReferences(r, func(id string) (articleReference, error) {
			if ref, ok := r.NoteReferences[id]; ok {
				return ref, nil
			}
			ref, err := resolveReference(tx, id, nil)
			if err != nil {
				return ref, err
			}
			r.NoteReferences[id] = ref
			return ref, nil
		}); err != nil {
			return err
		}
		// A slug is permanently tied to its source, even after withdrawal.
		if err := tx.Bucket([]byte("revisions")).ForEach(func(_, v []byte) error {
			var previous revision
			if err := json.Unmarshal(v, &previous); err != nil {
				return err
			}
			if previous.Slug == r.Slug && previous.SourceID != r.SourceID {
				return errors.New("Diese URL gehört bereits zu einer anderen Notiz.")
			}
			return nil
		}); err != nil {
			return err
		}
		for id, data := range files {
			if err := tx.Bucket([]byte("media")).Put([]byte(r.ID+"/"+id), data); err != nil {
				return err
			}
		}
		if err := putJSON(tx.Bucket([]byte("revisions")), r.ID, r); err != nil {
			return err
		}
		return tx.Bucket([]byte("drafts")).Put([]byte(r.ID), []byte(r.ID))
	})
	return r, err
}

func (s *store) approve(id, actor string) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		r, err := readRevision(tx, id)
		if err != nil {
			return err
		}
		return approveRevisions(tx, []revision{r}, actor)
	})
}

// Validate every member and dependency before making any publication visible.
func validateRevisions(tx *bolt.Tx, rows []revision) error {
	selected := make(map[string]revision)
	for _, r := range rows {
		if tx.Bucket([]byte("drafts")).Get([]byte(r.ID)) == nil {
			return errNotFound
		}
		noteID := strconv.FormatUint(r.SourceID, 10)
		if _, duplicate := selected[noteID]; duplicate {
			return errors.New("Nur eine Version je NRC-Notiz kann freigegeben werden.")
		}
		selected[noteID] = r
		if revisionHead(tx, r) != r.Base {
			return errConflict
		}
		// Old drafts with unresolved tokens must be recreated, not silently approved.
		if r.NoteReferences == nil {
			r.NoteReferences = map[string]articleReference{}
		}
		if _, _, _, err := renderMarkdown(r); err != nil {
			return err
		}
	}
	for _, r := range rows {
		for noteID, ref := range r.NoteReferences {
			if ref.Slug == "" {
				return fmt.Errorf("Linkziel [note:%s] fehlt. Bitte die zugehörigen Entwürfe gemeinsam prüfen.", noteID)
			}
			target, ok := selected[noteID]
			if !ok {
				var err error
				if ref.URL != "" {
					id, parseErr := strconv.ParseUint(noteID, 10, 64)
					if parseErr != nil {
						return parseErr
					}
					target, err = readSource(tx, id)
				} else {
					target, err = readCurrent(tx, ref.Slug)
				}
				if err != nil {
					return fmt.Errorf("Zielartikel für [note:%s] ist nicht veröffentlicht. Bitte die zugehörigen Entwürfe gemeinsam prüfen.", noteID)
				}
			}
			if strconv.FormatUint(target.SourceID, 10) != noteID {
				return errors.New("Linkziel gehört zu einer anderen Notiz.")
			}
		}
	}
	return nil
}

func approveRevisions(tx *bolt.Tx, rows []revision, actor string) error {
	if err := validateRevisions(tx, rows); err != nil {
		return err
	}
	b := tx.Bucket([]byte("published"))
	for _, r := range rows {
		var replaced []revision
		if err := b.ForEach(func(_, v []byte) error {
			previous, err := readRevision(tx, string(v))
			if err == nil && previous.SourceID == r.SourceID && previous.Slug != r.Slug {
				replaced = append(replaced, previous)
			}
			return err
		}); err != nil {
			return err
		}
		for _, previous := range replaced {
			if err := tx.Bucket([]byte("redirects")).Put([]byte(previous.Slug), []byte(strconv.FormatUint(r.SourceID, 10))); err != nil {
				return err
			}
			if err := b.Delete([]byte(previous.Slug)); err != nil {
				return err
			}
		}
		// Save exactly the resolved links shown in the stored group review.
		if err := putJSON(tx.Bucket([]byte("revisions")), r.ID, r); err != nil {
			return err
		}
		if err := b.Put([]byte(r.Slug), []byte(r.ID)); err != nil {
			return err
		}
		head := randomID()
		if err := tx.Bucket([]byte("heads")).Put([]byte(fmt.Sprintf("note:%d", r.SourceID)), []byte(head)); err != nil {
			return err
		}
		if err := tx.Bucket([]byte("heads")).Put([]byte(r.Slug), []byte(head)); err != nil {
			return err
		}
		if err := tx.Bucket([]byte("drafts")).Delete([]byte(r.ID)); err != nil {
			return err
		}
		if err := putJSON(tx.Bucket([]byte("audit")), randomID(), publication{r.Slug, r.ID, actor, time.Now().UTC()}); err != nil {
			return err
		}
	}
	return nil
}

// Persist the resolved review, so approval never silently changes reviewed links.
func (s *store) createReview(ids []string) (string, error) {
	id := randomID()
	err := s.db.Update(func(tx *bolt.Tx) error {
		if len(ids) == 0 {
			return errors.New("Bitte mindestens einen Entwurf auswählen.")
		}
		rows := make([]revision, 0, len(ids))
		sources := make(map[uint64]bool)
		for _, id := range ids {
			if tx.Bucket([]byte("drafts")).Get([]byte(id)) == nil {
				return errNotFound
			}
			r, err := readRevision(tx, id)
			if err != nil {
				return err
			}
			if sources[r.SourceID] {
				return errors.New("Bitte nur eine Version je NRC-Notiz auswählen.")
			}
			sources[r.SourceID] = true
			rows = append(rows, r)
		}
		for i := range rows {
			r := &rows[i]
			if r.NoteReferences == nil {
				r.NoteReferences = make(map[string]articleReference)
			}
			if _, _, _, err := renderMarkdownWithReferences(*r, func(noteID string) (articleReference, error) {
				if ref := r.NoteReferences[noteID]; ref.Slug != "" {
					return ref, nil
				}
				ref, err := resolveReference(tx, noteID, rows)
				if err != nil {
					return ref, err
				}
				if ref.Slug == "" {
					return ref, fmt.Errorf("Linkziel [note:%s] fehlt. Bitte auch dessen Entwurf auswählen.", noteID)
				}
				r.NoteReferences[noteID] = ref
				return ref, nil
			}); err != nil {
				return err
			}
		}
		if err := validateRevisions(tx, rows); err != nil {
			return err
		}
		return putJSON(tx.Bucket([]byte("reviews")), id, rows)
	})
	return id, err
}

func readReview(tx *bolt.Tx, id string) ([]revision, error) {
	data := tx.Bucket([]byte("reviews")).Get([]byte(id))
	if data == nil {
		return nil, errNotFound
	}
	var rows []revision
	err := json.Unmarshal(data, &rows)
	return rows, err
}

func (s *store) review(id string) ([]revision, error) {
	var rows []revision
	err := s.db.View(func(tx *bolt.Tx) error {
		var err error
		rows, err = readReview(tx, id)
		return err
	})
	return rows, err
}

func (s *store) approveReview(id, actor string) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		rows, err := readReview(tx, id)
		if err != nil {
			return err
		}
		if err := approveRevisions(tx, rows, actor); err != nil {
			return err
		}
		return tx.Bucket([]byte("reviews")).Delete([]byte(id))
	})
}

func (s *store) withdraw(slug, expected, actor string) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte("published"))
		if expected == "" || string(b.Get([]byte(slug))) != expected {
			return errConflict
		}
		r, err := readRevision(tx, expected)
		if err != nil {
			return err
		}
		if err := b.Delete([]byte(slug)); err != nil {
			return err
		}
		head := randomID()
		if err := tx.Bucket([]byte("heads")).Put([]byte(fmt.Sprintf("note:%d", r.SourceID)), []byte(head)); err != nil {
			return err
		}
		if err := tx.Bucket([]byte("heads")).Put([]byte(slug), []byte(head)); err != nil {
			return err
		}
		return putJSON(tx.Bucket([]byte("audit")), randomID(), publication{slug, "", actor, time.Now().UTC()})
	})
}

func (s *store) discard(id string) error {
	return s.db.Update(func(tx *bolt.Tx) error { return tx.Bucket([]byte("drafts")).Delete([]byte(id)) })
}

// Public media is reachable only while the exact revision is published.
func (s *store) media(id, file string, public bool) ([]byte, protocol.Attachment, error) {
	var data []byte
	var attachment protocol.Attachment
	err := s.db.View(func(tx *bolt.Tx) error {
		r, err := readRevision(tx, id)
		if err != nil {
			return err
		}
		if public && string(tx.Bucket([]byte("published")).Get([]byte(r.Slug))) != id {
			return errNotFound
		}
		found := false
		for _, a := range r.Attachments {
			if a.FileId == file {
				attachment = a
				found = true
				break
			}
		}
		if !found {
			return errNotFound
		}
		v := tx.Bucket([]byte("media")).Get([]byte(id + "/" + file))
		if v == nil {
			return errNotFound
		}
		data = append([]byte{}, v...)
		return nil
	})
	return data, attachment, err
}
