package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	p "github.com/heavyhorst/nrc/protocol-go"
	bolt "go.etcd.io/bbolt"
)

// NRC remains authoritative for tickets. This private journal holds transport
// state, including quarantined originals and uncertain acknowledgements.
type mailJob struct {
	ID, Direction, State, Reason, Sender, Recipient string
	Raw                                             []byte `json:",omitempty"`
	Ticket, Asset                                   uint64
	StatusSynced                                    bool
}
type mailChannel struct {
	mu                sync.Mutex
	db                *bolt.DB
	portal            *portal
	secret, workspace string
	smtp              smtpMailConfig
	send              func(context.Context, smtpMailConfig, string, []byte) (string, error)
}

func mailHash(value string) string {
	h := sha256.Sum256([]byte(value))
	return hex.EncodeToString(h[:])
}
func mailJSON(v any) string { b, _ := json.Marshal(v); return string(b) }
func mailFields(a p.Asset) map[string]any {
	var m map[string]any
	_ = json.Unmarshal([]byte(a.Preview), &m)
	return m
}
func mailString(m map[string]any, k string) string { v, _ := m[k].(string); return v }
func mailAddress(value string) string {
	a, err := smtpAddress(value)
	if err != nil || a.Address != value || !strings.Contains(value, "@") || len(value) > 320 {
		return ""
	}
	return strings.ToLower(a.Address)
}

func openMailChannel(path, workspace, secret string, portal *portal, smtp smtpMailConfig) (*mailChannel, error) {
	if len(secret) < 32 || path == "" || smtp.From == "" || mailAddress(smtp.From) != smtp.From || len(strings.Split(smtp.From, "@")[0]) > 31 {
		return nil, errors.New("mail requires private journal and at least 32-byte gateway secret")
	}
	if st, err := os.Stat(path); err == nil && st.Mode().Perm()&0077 != 0 {
		return nil, errors.New("mail journal must be private")
	}
	db, err := bolt.Open(path, 0600, &bolt.Options{Timeout: time.Second})
	if err != nil {
		return nil, err
	}
	c := &mailChannel{db: db, portal: portal, secret: secret, workspace: workspace, smtp: smtp, send: sendSMTP}
	var recoverIDs []string
	err = db.Update(func(tx *bolt.Tx) error {
		b, err := tx.CreateBucketIfNotExists([]byte("mail-v1"))
		if err != nil {
			return err
		}
		if _, err := tx.CreateBucketIfNotExists([]byte("mail-raw-v1")); err != nil {
			return err
		}
		binding := workspace + "\n" + smtp.From
		if old := b.Get([]byte("binding")); old != nil && string(old) != binding {
			return errors.New("mail journal belongs to another workspace or mailbox")
		}
		if err := b.Put([]byte("binding"), []byte(binding)); err != nil {
			return err
		}
		return b.ForEach(func(k, v []byte) error {
			if !bytes.HasPrefix(k, []byte("job:")) {
				return nil
			}
			var job mailJob
			if err := json.Unmarshal(v, &job); err != nil {
				return err
			}
			if job.State == "inflight" || job.State == "processing" || job.Raw != nil {
				recoverIDs = append(recoverIDs, job.ID)
			}
			return nil
		})
	})
	if err != nil {
		db.Close()
		return nil, err
	}
	// Never mutate a bbolt bucket while enumerating it. Recover/migrate one
	// original at a time, without holding the complete archive in memory.
	for _, id := range recoverIDs {
		j, err := c.job(id)
		if err == nil {
			if j.State == "inflight" || j.State == "processing" {
				j.State, j.Reason = "unknown", "interrupted operation; inspect NRC or mail relay before any further action"
			}
			err = c.put(j)
		}
		if err != nil {
			db.Close()
			return nil, err
		}
	}
	return c, nil
}
func (c *mailChannel) put(j mailJob) error {
	return c.db.Update(func(tx *bolt.Tx) error {
		return putMailJob(tx, j)
	})
}

// Raw originals are immutable and separate from the frequently scanned metadata.
// A metadata-only state update must never erase the retained original.
func putMailJob(tx *bolt.Tx, j mailJob) error {
	if j.Raw != nil {
		if err := tx.Bucket([]byte("mail-raw-v1")).Put([]byte(j.ID), j.Raw); err != nil {
			return err
		}
		j.Raw = nil
	}
	return tx.Bucket([]byte("mail-v1")).Put([]byte("job:"+j.ID), []byte(mailJSON(j)))
}

func (c *mailChannel) job(id string) (mailJob, error) {
	var j mailJob
	err := c.db.View(func(tx *bolt.Tx) error {
		raw := tx.Bucket([]byte("mail-v1")).Get([]byte("job:" + id))
		if raw == nil {
			return nil
		}
		if err := json.Unmarshal(raw, &j); err != nil {
			return err
		}
		if original := tx.Bucket([]byte("mail-raw-v1")).Get([]byte(id)); original != nil {
			j.Raw = bytes.Clone(original)
		}
		return nil
	})
	return j, err
}

func (c *mailChannel) jobs() ([]mailJob, error) {
	var jobs []mailJob
	err := c.db.View(func(tx *bolt.Tx) error {
		return tx.Bucket([]byte("mail-v1")).ForEach(func(k, v []byte) error {
			if !bytes.HasPrefix(k, []byte("job:")) {
				return nil
			}
			var job mailJob
			if err := json.Unmarshal(v, &job); err != nil {
				return err
			}
			jobs = append(jobs, job)
			return nil
		})
	})
	return jobs, err
}
func (c *mailChannel) messageID(id uint64) string {
	return fmt.Sprintf("<nrc-%s-%d@%s>", mailHash(c.workspace)[:16], id, strings.Split(c.smtp.From, "@")[1])
}

// One durable, random reply address per ticket; all addresses deliver to the
// same mailbox through provider-supported plus addressing.
func (c *mailChannel) replyAddress(ticket uint64) (string, error) {
	var token string
	err := c.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte("mail-v1"))
		key := []byte("ticket-reply:" + strconv.FormatUint(ticket, 10))
		token = string(b.Get(key))
		if token == "" {
			var random [16]byte
			if _, err := rand.Read(random[:]); err != nil {
				return err
			}
			token = hex.EncodeToString(random[:])
			if err := b.Put(key, []byte(token)); err != nil {
				return err
			}
			return b.Put([]byte("reply-token:"+mailHash(token)), []byte(strconv.FormatUint(ticket, 10)))
		}
		return nil
	})
	local, domain, _ := strings.Cut(c.smtp.From, "@")
	return local + "+" + token + "@" + domain, err
}

func (c *mailChannel) replyTicket(recipients []string) (uint64, error) {
	var ticket uint64
	local, domain, _ := strings.Cut(c.smtp.From, "@")
	err := c.db.View(func(tx *bolt.Tx) error {
		for _, address := range recipients {
			to, host, _ := strings.Cut(address, "@")
			if host != domain || !strings.HasPrefix(to, local+"+") {
				continue
			}
			token := strings.TrimPrefix(to, local+"+")
			if len(token) != 32 {
				return errors.New("invalid ticket reply address")
			}
			value := tx.Bucket([]byte("mail-v1")).Get([]byte("reply-token:" + mailHash(token)))
			id, err := strconv.ParseUint(string(value), 10, 64)
			if err != nil || id == 0 {
				return errors.New("unknown ticket reply address")
			}
			if ticket != 0 && ticket != id {
				return errors.New("ambiguous ticket reply addresses")
			}
			ticket = id
		}
		return nil
	})
	return ticket, err
}

// Caller holds mu. Both transports share duplicate and quarantine rules.
func (c *mailChannel) receive(raw []byte) (mailJob, int, error) {
	m, err := parseMail(raw)
	if err != nil || mailAddress(m.From) == "" {
		return mailJob{}, 400, errors.New("invalid MIME mail")
	}
	id := m.ID
	if id == "" {
		id = mailHash(string(raw))
	}
	key := "in-" + mailHash(id)
	old, err := c.job(key)
	if err != nil {
		return mailJob{}, 503, errors.New("journal unavailable")
	}
	if old.ID != "" {
		if !bytes.Equal(old.Raw, raw) {
			return mailJob{}, 409, errors.New("Message-ID collision; manual review required")
		}
		return old, 200, nil
	}
	j := mailJob{ID: key, Direction: "in", State: "queued", Sender: m.From, Raw: raw}
	if m.Auto {
		j.State, j.Reason = "ignored", "automatic reply or delivery report; no reply generated"
	}
	if m.From == c.smtp.From {
		j.State, j.Reason = "ignored", "own mailbox; no reply generated"
	}
	if err := c.put(j); err != nil {
		return mailJob{}, 503, errors.New("journal unavailable")
	}
	return j, 202, nil
}

// This listener is private; provider spam/malware protection remains upstream.
func (c *mailChannel) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+c.secret)) != 1 {
		http.Error(w, "Unauthorized", 401)
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if r.URL.Path == "/inbound" && r.Method == "POST" {
		raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, mailRawLimit))
		if err != nil {
			http.Error(w, "Mail too large", 413)
			return
		}
		j, status, err := c.receive(raw)
		if err != nil {
			http.Error(w, err.Error(), status)
			return
		}
		w.WriteHeader(status)
		json.NewEncoder(w).Encode(map[string]string{"id": j.ID, "state": j.State})
		return
	}
	jobs, err := c.jobs()
	if err != nil {
		http.Error(w, "Journal unavailable", 503)
		return
	}
	if r.URL.Path == "/jobs" && r.Method == "GET" {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(jobs)
		return
	}
	for _, j := range jobs {
		if r.URL.Path == "/jobs/"+j.ID+"/raw" && r.Method == "GET" {
			j, err := c.job(j.ID)
			if err != nil {
				http.Error(w, "Journal unavailable", 503)
				return
			}
			w.Header().Set("Content-Type", "message/rfc822")
			w.Header().Set("Content-Disposition", "attachment; filename=original.eml")
			w.Write(j.Raw)
			return
		}
		if r.URL.Path == "/jobs/"+j.ID+"/retry" && r.Method == "POST" {
			if j.Direction != "out" || j.State != "failed" {
				http.Error(w, "Only definite outbound failures may be retried", 409)
				return
			}
			j.State, j.Reason = "queued", ""
			j.StatusSynced = false
			if c.put(j) != nil {
				http.Error(w, "Journal unavailable", 503)
				return
			}
			w.WriteHeader(204)
			return
		}
	}
	http.NotFound(w, r)
}

func (c *mailChannel) upload(ctx context.Context, files []mailAttachment) ([]p.Attachment, error) {
	var out []p.Attachment
	for _, file := range files {
		// Adapt parsed MIME bytes through the existing bounded private uploader.
		var b bytes.Buffer
		form := multipart.NewWriter(&b)
		part, err := form.CreateFormFile("files", file.Name)
		if err != nil {
			return nil, err
		}
		part.Write(file.Data)
		form.Close()
		reader := multipart.NewReader(&b, form.Boundary())
		data, err := reader.ReadForm(mailRawLimit)
		if err != nil {
			return nil, err
		}
		a, err := c.portal.files.upload(ctx, data.File["files"][0])
		data.RemoveAll()
		if err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, nil
}

func (c *mailChannel) create(ctx context.Context, j *mailJob, a p.Asset, key string, parentVersion ...int64) (p.Asset, error) {
	m := mailFields(a)
	m["mail_key"] = key
	a.Preview = mailJSON(m)
	// Positive reconciliation is safe; absence after a lost ACK is not proof
	// that a write failed, so unknown jobs are never automatically replayed.
	j.State = "inflight"
	if err := c.put(*j); err != nil {
		return p.Asset{}, err
	}
	var v p.Asset
	var err error
	if len(parentVersion) > 0 {
		s, ok := c.portal.source.(interface {
			createReply(context.Context, p.Asset, int64) (p.Asset, error)
		})
		if !ok {
			return v, errors.New("guarded mail replies unsupported")
		}
		v, err = s.createReply(ctx, a, parentVersion[0])
	} else {
		v, err = c.portal.source.create(ctx, a)
	}
	if err != nil {
		j.State, j.Reason = "unknown", "NRC acknowledgement uncertain; inspect saved records"
		if e := c.put(*j); e != nil {
			return v, e
		}
		return v, err
	}
	j.State = "processing"
	return v, c.put(*j)
}

func (c *mailChannel) inbound(ctx context.Context, j *mailJob) error {
	stored, err := c.job(j.ID)
	if err != nil {
		return err
	}
	// Keep only metadata across subsequent state writes.
	j.Raw = nil
	original, err := parseMail(stored.Raw)
	if err != nil {
		return err
	}
	if mailAddress(original.From) == "" {
		j.State, j.Reason = "quarantine", "invalid original requester"
		return c.put(*j)
	}
	if original.Subject == "" {
		original.Subject = "Support request"
	}
	if len(original.Subject) > 200 || strings.TrimSpace(original.Body) == "" || len(original.Name) > 256 {
		j.State, j.Reason = "quarantine", "subject/body/name requires manual review"
		return c.put(*j)
	}
	// Only possession of the random reply address identifies an existing ticket.
	// From, subject numbers and message references alone confer no thread access.
	parent, err := c.replyTicket(original.Recipients)
	if err != nil {
		j.State, j.Reason = "quarantine", "invalid, unknown or ambiguous ticket reply address"
		return c.put(*j)
	}
	if parent != 0 {
		a, e := c.portal.source.get(ctx, parent)
		if e != nil {
			return e
		}
		v := mailFields(a)
		who := account{Requester: original.From, Name: original.Name}
		for _, candidate := range c.portal.accounts {
			if candidate.Requester == original.From {
				who = candidate
				break
			}
		}
		if _, ok := c.portal.project(a, who, c.portal.sharedContacts(ctx, who)); !ok {
			j.State, j.Reason = "quarantine", "sender no longer has ticket access"
			return c.put(*j)
		}
		if mailString(v, "requester") == "" {
			return errors.New("invalid parent")
		}
	}
	contactID, companyID := "", ""
	if parent == 0 {
		contacts, e := c.portal.source.list(ctx, p.AssetTypeCustomerContact)
		if e != nil {
			return e
		}
		for _, contact := range contacts {
			meta := mailFields(contact)
			if strings.EqualFold(mailString(meta, "email"), original.From) {
				if contactID != "" {
					j.State, j.Reason = "quarantine", "multiple contacts match sender"
					return c.put(*j)
				}
				contactID = strconv.FormatUint(contact.AssetID, 10)
			}
		}
		if contactID == "" {
			name := original.Name
			if name == "" {
				name = original.From
			}
			a, e := c.create(ctx, j, p.Asset{AssetType: p.AssetTypeCustomerContact, Preview: mailJSON(map[string]any{"version": 1, "title": name, "email": original.From, "source": "email", "review_status": "pending"})}, j.ID+"-contact")
			if e != nil {
				return e
			}
			contactID = strconv.FormatUint(a.AssetID, 10)
		}
		// Reuse only an explicit existing account company/contact mapping. New
		// addresses never acquire a customer company through domain inference.
		for _, who := range c.portal.accounts {
			if who.Requester == original.From && who.ContactID == contactID {
				companyID = who.CompanyID
			}
		}
	}
	attachments, err := c.upload(ctx, original.Files)
	if err != nil {
		return err
	}
	var parentVersion []int64
	if parent != 0 {
		current, e := c.portal.source.get(ctx, parent)
		if e != nil {
			return e
		}
		who := account{Requester: original.From, Name: original.Name}
		for _, candidate := range c.portal.accounts {
			if candidate.Requester == original.From {
				who = candidate
				break
			}
		}
		if _, ok := c.portal.project(current, who, c.portal.sharedContacts(ctx, who)); !ok {
			j.State, j.Reason = "quarantine", "ticket access changed during upload"
			return c.put(*j)
		}
		parentVersion = []int64{current.UpdatedAt}
	}
	a := p.Asset{AssetType: ticketType, Payload: original.Body, Attachments: attachments}
	if parent == 0 {
		meta := map[string]any{"version": 1, "title": original.Subject, "requester": original.From, "requester_name": original.Name, "company_id": companyID, "contact_id": contactID, "status": "open", "assignee": "", "channel": "email"}
		a.Preview = mailJSON(meta)
	} else {
		a.AssetType = entryType
		a.ParentType = 2
		a.ParentID = parent
		a.Preview = mailJSON(map[string]any{"version": 1, "kind": "customer_reply", "author": original.Name, "channel": "email", "sender": original.From})
	}
	saved, err := c.create(ctx, j, a, j.ID, parentVersion...)
	if err != nil {
		return err
	}
	j.Asset = saved.AssetID
	j.Ticket = parent
	if parent == 0 {
		j.Ticket = saved.AssetID
	}
	// Preserve the saved parent before scheduling the acknowledgement.
	if err := c.put(*j); err != nil {
		return err
	}
	if parent == 0 {
		ack := mailJob{ID: "ack-" + j.ID, Direction: "out", State: "queued", Ticket: j.Ticket, Asset: j.Asset, Recipient: original.From}
		if err := c.put(ack); err != nil {
			return err
		}
	}
	j.State, j.Reason = "done", ""
	return c.put(*j)
}

func (c *mailChannel) patchStatus(ctx context.Context, id uint64, status string) error {
	s, ok := c.portal.source.(interface {
		patchPreview(context.Context, p.Asset, string, ...p.Asset) error
	})
	if !ok {
		return errors.New("mail status patch unsupported")
	}
	a, err := c.portal.source.get(ctx, id)
	if err != nil {
		return err
	}
	meta := mailFields(a)
	if meta == nil {
		return errors.New("invalid asset metadata")
	}
	if mailString(meta, "mail_delivery") == status {
		return nil
	}
	meta["mail_delivery"] = status
	return s.patchPreview(ctx, a, mailJSON(meta))
}
func (c *mailChannel) scan(ctx context.Context) error {
	entries, err := c.portal.source.list(ctx, entryType)
	if err != nil {
		return err
	}
	var primed bool
	var cutoff int64
	err = c.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte("mail-v1"))
		primed = b.Get([]byte("primed")) != nil
		if value := b.Get([]byte("activation-cutoff")); value != nil {
			var err error
			cutoff, err = strconv.ParseInt(string(value), 10, 64)
			return err
		}
		// The live updated-at cursor can skip records edited between pages.
		// Persist a server-time watermark before writing any baseline jobs;
		// immutable creation time also excludes historical entries found later.
		for _, entry := range entries {
			if entry.UpdatedAt > cutoff {
				cutoff = entry.UpdatedAt
			}
		}
		return b.Put([]byte("activation-cutoff"), []byte(strconv.FormatInt(cutoff, 10)))
	})
	if err != nil {
		return err
	}
	jobs, err := c.jobs()
	if err != nil {
		return err
	}
	known := map[string]bool{}
	for _, j := range jobs {
		known[j.ID] = true
	}
	for _, entry := range entries {
		if mailString(mailFields(entry), "kind") != "public_reply" || entry.ParentType != 2 || entry.ParentID == 0 {
			continue
		}
		id := "out-" + strconv.FormatUint(entry.AssetID, 10)
		if known[id] {
			continue
		}
		job := mailJob{ID: id, Direction: "out", State: "queued", Ticket: entry.ParentID, Asset: entry.AssetID, Recipient: mailString(mailFields(entry), "recipient")}
		if !primed || entry.CreatedAt <= cutoff {
			job.State, job.Reason = "ignored", "predates mail-channel activation"
		}
		if err := c.put(job); err != nil {
			return err
		}
	}
	return c.db.Update(func(tx *bolt.Tx) error { return tx.Bucket([]byte("mail-v1")).Put([]byte("primed"), []byte("1")) })
}
func (c *mailChannel) outbound(ctx context.Context, j *mailJob) error {
	ticket, err := c.portal.source.get(ctx, j.Ticket)
	if err != nil {
		return err
	}
	meta := mailFields(ticket)
	if ticket.AssetType != ticketType || mailAddress(j.Recipient) == "" || mailString(meta, "requester") != j.Recipient {
		j.State, j.Reason = "failed", "recipient missing or changed; inspect before retry"
		return c.put(*j)
	}
	body := "Ihre Anfrage wurde aufgenommen. Antworten Sie auf diese E-Mail, um weitere Informationen hinzuzufügen."
	var files []mailAttachment
	var prepared p.Asset
	if !strings.HasPrefix(j.ID, "ack-") {
		a, err := c.portal.source.get(ctx, j.Asset)
		if err != nil {
			return err
		}
		if a.AssetType != entryType || a.ParentType != 2 || a.ParentID != j.Ticket || mailString(mailFields(a), "kind") != "public_reply" || mailString(mailFields(a), "recipient") != j.Recipient {
			j.State, j.Reason = "failed", "public reply or recipient changed"
			return c.put(*j)
		}
		body, err = p.DecodeAssetPayload(a)
		prepared = a
		if err != nil {
			return err
		}
		var total int
		for _, attachment := range a.Attachments {
			if !validAttachment(attachment) || len(files) >= 10 {
				return errors.New("invalid mail attachment")
			}
			resp, err := c.portal.files.open(ctx, attachment.FileId)
			if err != nil {
				return err
			}
			data, e := io.ReadAll(io.LimitReader(resp.Body, mailRawLimit+1))
			resp.Body.Close()
			total += len(data)
			if e != nil || resp.StatusCode != 200 || int64(len(data)) != attachment.Size || total > mailRawLimit {
				return errors.New("mail attachment unavailable or too large")
			}
			files = append(files, mailAttachment{attachment.Filename, attachment.MimeType, data})
		}
	}
	var references []string
	if j.Asset != j.Ticket {
		references = []string{c.messageID(j.Ticket)}
	}
	replyTo, err := c.replyAddress(j.Ticket)
	if err != nil {
		return err
	}
	raw, err := buildMail(c.smtp.From, j.Recipient, replyTo, fmt.Sprintf("Re: [NRC #%d] %s", j.Ticket, mailString(meta, "title")), c.messageID(j.Asset), references, body, files)
	if err != nil {
		return err
	}
	// Attachment reads may take time. Revalidate the exact prepared records;
	// the conditional preview patch claims this version before SMTP starts.
	current, err := c.portal.source.get(ctx, j.Ticket)
	if err != nil {
		return err
	}
	if mailJSON(current) != mailJSON(ticket) {
		j.State, j.Reason = "failed", "ticket changed while preparing mail"
		return c.put(*j)
	}
	if prepared.AssetID != 0 {
		current, err = c.portal.source.get(ctx, j.Asset)
		if err != nil {
			return err
		}
		if mailJSON(current) != mailJSON(prepared) {
			j.State, j.Reason = "failed", "reply changed while preparing mail"
			return c.put(*j)
		}
	}
	statusSource, ok := c.portal.source.(interface {
		patchPreview(context.Context, p.Asset, string, ...p.Asset) error
	})
	if !ok {
		return errors.New("mail status patch unsupported")
	}
	status := mailFields(current)
	status["mail_delivery"] = "queued"
	var guards []p.Asset
	if current.AssetID != ticket.AssetID {
		guards = []p.Asset{ticket}
	}
	if err := statusSource.patchPreview(ctx, current, mailJSON(status), guards...); err != nil {
		return err
	}
	j.State = "inflight"
	if err := c.put(*j); err != nil {
		return err
	}
	state, sendErr := c.send(ctx, c.smtp, j.Recipient, raw)
	j.State = state
	j.StatusSynced = false
	j.Reason = ""
	if sendErr != nil {
		j.Reason = "SMTP " + state + "; inspect relay before retrying an uncertain send"
	}
	if err := c.put(*j); err != nil {
		return err
	}
	return c.syncStatus(ctx, j)
}

func (c *mailChannel) syncStatus(ctx context.Context, j *mailJob) error {
	if err := c.patchStatus(ctx, j.Asset, j.State); err != nil {
		return err
	}
	j.StatusSynced = true
	return c.put(*j)
}

func (c *mailChannel) tick(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.scan(ctx); err != nil {
		return err
	}
	jobs, err := c.jobs()
	if err != nil {
		return err
	}
	sort.Slice(jobs, func(i, j int) bool { return jobs[i].ID < jobs[j].ID })
	for _, job := range jobs {
		if err := ctx.Err(); err != nil {
			return err
		}
		if job.State != "queued" {
			continue
		}
		var err error
		if job.Direction == "in" {
			err = c.inbound(ctx, &job)
		} else {
			err = c.outbound(ctx, &job)
		}
		if err != nil {
			if job.Direction == "in" && job.State == "queued" {
				// No NRC mutation has begun: retry transient reads/uploads next pass.
				continue
			}
			if job.State == "sent" || job.State == "done" {
				continue
			}
			if job.State == "inflight" || job.State == "unknown" {
				job.State = "unknown"
			} else {
				job.State = "failed"
			}
			job.Reason = "processing failed; inspect journal and NRC before retry"
			if e := c.put(job); e != nil {
				return e
			}
			if job.Direction == "out" {
				_ = c.syncStatus(ctx, &job)
			}
		}
	}
	// Repairs run after queued work, at most one per pass. A durable rotating
	// cursor prevents one unavailable record from starving other repairs.
	jobs, err = c.jobs()
	if err != nil {
		return err
	}
	sort.Slice(jobs, func(i, j int) bool { return jobs[i].ID < jobs[j].ID })
	var after string
	if err := c.db.View(func(tx *bolt.Tx) error {
		after = string(tx.Bucket([]byte("mail-v1")).Get([]byte("repair-after")))
		return nil
	}); err != nil {
		return err
	}
	var pending []mailJob
	for _, j := range jobs {
		if j.Direction == "out" && !j.StatusSynced && (j.State == "sent" || j.State == "unknown" || j.State == "failed") {
			pending = append(pending, j)
		}
	}
	if len(pending) > 0 && ctx.Err() == nil {
		job := pending[0]
		for _, j := range pending {
			if j.ID > after {
				job = j
				break
			}
		}
		if err := c.db.Update(func(tx *bolt.Tx) error {
			return tx.Bucket([]byte("mail-v1")).Put([]byte("repair-after"), []byte(job.ID))
		}); err != nil {
			return err
		}
		_ = c.syncStatus(ctx, &job)
	}
	return nil
}
