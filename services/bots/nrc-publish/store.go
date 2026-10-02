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
	// Publication generation seen when preparing this draft. Approval uses CAS.
	Base string
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
		for _, name := range []string{"revisions", "drafts", "published", "heads", "media", "audit", "meta"} {
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
		r, err = readRevision(tx, string(tx.Bucket([]byte("published")).Get([]byte(slug))))
		return err
	})
	return r, err
}

func (s *store) head(slug string) (string, error) {
	var head string
	err := s.db.View(func(tx *bolt.Tx) error { head = string(tx.Bucket([]byte("heads")).Get([]byte(slug))); return nil })
	return head, err
}

func (s *store) entries(bucket string) ([]revision, error) {
	rows := []revision{}
	err := s.db.View(func(tx *bolt.Tx) error {
		return tx.Bucket([]byte(bucket)).ForEach(func(_, v []byte) error {
			r, err := readRevision(tx, string(v))
			if err != nil {
				return err
			}
			rows = append(rows, r)
			return nil
		})
	})
	sort.Slice(rows, func(i, j int) bool { return rows[i].Title < rows[j].Title })
	return rows, err
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
	// Validate every rendered link before any draft can be approved.
	if _, _, err := renderMarkdown(r); err != nil {
		return r, err
	}
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
		r.Base = string(tx.Bucket([]byte("heads")).Get([]byte(r.Slug)))
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
		if tx.Bucket([]byte("drafts")).Get([]byte(id)) == nil {
			return errNotFound
		}
		r, err := readRevision(tx, id)
		if err != nil {
			return err
		}
		b := tx.Bucket([]byte("published"))
		if string(tx.Bucket([]byte("heads")).Get([]byte(r.Slug))) != r.Base {
			return errConflict
		}
		if err := b.Put([]byte(r.Slug), []byte(id)); err != nil {
			return err
		}
		if err := tx.Bucket([]byte("heads")).Put([]byte(r.Slug), []byte(randomID())); err != nil {
			return err
		}
		if err := tx.Bucket([]byte("drafts")).Delete([]byte(id)); err != nil {
			return err
		}
		return putJSON(tx.Bucket([]byte("audit")), randomID(), publication{r.Slug, id, actor, time.Now().UTC()})
	})
}

func (s *store) withdraw(slug, expected, actor string) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte("published"))
		if expected == "" || string(b.Get([]byte(slug))) != expected {
			return errConflict
		}
		if err := b.Delete([]byte(slug)); err != nil {
			return err
		}
		if err := tx.Bucket([]byte("heads")).Put([]byte(slug), []byte(randomID())); err != nil {
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
