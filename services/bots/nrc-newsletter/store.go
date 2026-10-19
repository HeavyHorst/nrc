package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"sync"
	"time"

	bolt "go.etcd.io/bbolt"
)

type recipient struct {
	contact
	Status string `json:"status"`
	Error  string `json:"error,omitempty"`
}
type campaign struct {
	Kind           string         `json:"kind"`
	Audience       string         `json:"audience"`
	CustomerIDs    []string       `json:"customer_ids"`
	ServiceReason  string         `json:"service_reason"`
	TemplateHTML   string         `json:"template_html,omitempty"`
	TemplateText   string         `json:"template_text,omitempty"`
	ID             string         `json:"id"`
	Title          string         `json:"title"`
	TemplateID     string         `json:"template_id"`
	Subject        string         `json:"subject"`
	Variables      map[string]any `json:"variables"`
	Status         string         `json:"status"`
	Archived       bool           `json:"archived"`
	Revision       int            `json:"revision"`
	TestedRevision int            `json:"tested_revision"`
	CreatedAt      string         `json:"created_at"`
	UpdatedAt      string         `json:"updated_at"`
	Recipients     []recipient    `json:"recipients"`
	Error          string         `json:"error,omitempty"`
}
type consent struct {
	Imported         *importedConsent
	ImportSuppressed bool
	Status           string
	Source           string
	ConfirmedAt      string
	TokenHash        string
	Expires          int64
	Invited          int64
}
type state struct {
	Workspace string
	Campaigns map[string]*campaign
	Consent   map[string]*consent
	Known     map[string]bool
	Key       string
}
type store struct {
	mu sync.Mutex
	db *bolt.DB
	state
}

func random() string {
	b := make([]byte, 32)
	if _, e := rand.Read(b); e != nil {
		panic(e)
	}
	return hex.EncodeToString(b)
}
func openStore(path, workspace string) (*store, error) {
	db, e := bolt.Open(path, 0600, &bolt.Options{Timeout: time.Second})
	if e != nil {
		return nil, e
	}
	s := &store{db: db, state: state{Workspace: workspace, Campaigns: map[string]*campaign{}, Consent: map[string]*consent{}, Known: map[string]bool{}, Key: random()}}
	e = db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte("state"))
		if b == nil {
			return nil
		}
		return json.Unmarshal(b.Get([]byte("v1")), &s.state)
	})
	if e != nil {
		db.Close()
		return nil, e
	}
	if s.Workspace != workspace {
		db.Close()
		return nil, errors.New("newsletter data belongs to another workspace")
	}
	for _, c := range s.Campaigns {
		for i := range c.Recipients {
			if c.Recipients[i].Status == "inflight" {
				c.Recipients[i].Status = "unknown"
				c.Recipients[i].Error = "interrupted provider call; do not automatically resend"
			}
		}
	}
	if e = s.save(); e != nil {
		db.Close()
		return nil, e
	}
	return s, nil
}

// A failed durable write must stop all dispatch, not leave an uncertain in-memory state active.
func (s *store) save() error {
	return s.db.Update(func(tx *bolt.Tx) error {
		b, e := tx.CreateBucketIfNotExists([]byte("state"))
		if e != nil {
			return e
		}
		v, e := json.Marshal(s.state)
		if e != nil {
			return e
		}
		return b.Put([]byte("v1"), v)
	})
}
func (s *store) mustSave() {
	if e := s.save(); e != nil {
		log.Fatal("newsletter durable state write failed; dispatch stopped")
	}
}
