package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	p "github.com/heavyhorst/nrc/protocol-go"
)

type mailTestSource struct {
	*fakeSource
	failStatus  bool
	beforeClaim func()
}

type changingMailFiles struct {
	fileStore
	change     func()
	failUpload bool
}

func (f changingMailFiles) open(context.Context, string) (*http.Response, error) {
	f.change()
	return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader("abc"))}, nil
}

func (f changingMailFiles) upload(ctx context.Context, h *multipart.FileHeader) (p.Attachment, error) {
	if f.failUpload {
		return p.Attachment{}, errors.New("temporary outage")
	}
	return f.fileStore.upload(ctx, h)
}

func (s *mailTestSource) create(ctx context.Context, a p.Asset) (p.Asset, error) {
	a.PayloadRawLen = uint32(len(a.Payload))
	if a.CreatedAt == 0 {
		a.CreatedAt = 1
	}
	a.UpdatedAt = 1
	return s.fakeSource.create(ctx, a)
}

func (s *mailTestSource) createReply(ctx context.Context, a p.Asset, version int64) (p.Asset, error) {
	parent, err := s.get(ctx, a.ParentID)
	if err != nil || parent.UpdatedAt != version {
		return p.Asset{}, errors.New("parent changed")
	}
	return s.create(ctx, a)
}

func (s *mailTestSource) patchPreview(_ context.Context, a p.Asset, preview string, guards ...p.Asset) error {
	if len(guards) > 0 && s.beforeClaim != nil {
		s.beforeClaim()
		s.beforeClaim = nil
	}
	if s.failStatus && strings.Contains(preview, `"mail_delivery":"sent"`) {
		return errors.New("lost patch")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, expected := range append([]p.Asset{a}, guards...) {
		current, ok := s.assets[expected.AssetID]
		if !ok || current.UpdatedAt != expected.UpdatedAt {
			return errors.New("version conflict")
		}
	}
	current := s.assets[a.AssetID]
	current.Preview = preview
	current.UpdatedAt++
	s.assets[a.AssetID] = current
	for _, guard := range guards {
		current := s.assets[guard.AssetID]
		current.UpdatedAt++
		s.assets[guard.AssetID] = current
	}
	return nil
}
func mailFixture(t *testing.T) (*mailChannel, *mailTestSource, *[]mailMessage) {
	t.Helper()
	source := &mailTestSource{fakeSource: &fakeSource{assets: map[uint64]p.Asset{}, next: 20}}
	portal := &portal{source: source, files: testFiles(t)}
	c, err := openMailChannel(filepath.Join(t.TempDir(), "mail.db"), "tickets", strings.Repeat("x", 32), portal, smtpMailConfig{From: "support@our.test"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.db.Close() })
	var sent []mailMessage
	c.send = func(_ context.Context, _ smtpMailConfig, to string, raw []byte) (string, error) {
		m, e := parseMail(raw)
		if e != nil {
			t.Fatal(e)
		}
		if to != "anna@customer.test" {
			t.Fatalf("wrong recipient %s", to)
		}
		sent = append(sent, m)
		return "sent", nil
	}
	if err := c.scan(context.Background()); err != nil {
		t.Fatal(err)
	}
	return c, source, &sent
}
func mailHTTP(c *mailChannel, path, raw string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", path, strings.NewReader(raw))
	r.Header.Set("Authorization", "Bearer "+c.secret)
	w := httptest.NewRecorder()
	c.ServeHTTP(w, r)
	return w
}
func mailTick(t *testing.T, c *mailChannel) {
	t.Helper()
	if err := c.tick(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestMailChannelRoundTrip(t *testing.T) {
	c, s, sent := mailFixture(t)
	raw := "From: Anna <anna@customer.test>\r\nMessage-ID: <new@customer.test>\r\nSubject: Login issue\r\n\r\nCannot sign in"
	if w := mailHTTP(c, "/inbound", raw); w.Code != 202 {
		t.Fatal(w.Code, w.Body.String())
	}
	mailTick(t, c)
	mailTick(t, c)
	if len(*sent) != 1 {
		t.Fatal("missing acknowledgement")
	}
	var ticket, contact p.Asset
	for _, a := range s.assets {
		if a.AssetType == ticketType {
			ticket = a
		}
		if a.AssetType == p.AssetTypeCustomerContact {
			contact = a
		}
	}
	if ticket.Payload != "Cannot sign in" || mailString(mailFields(contact), "review_status") != "pending" || mailString(mailFields(ticket), "company_id") != "" {
		t.Fatalf("wrong persisted records: %+v %+v", ticket, contact)
	}
	if w := mailHTTP(c, "/inbound", raw); w.Code != 200 {
		t.Fatal(w.Code)
	}
	mailTick(t, c)
	if s.writes != 2 || len(*sent) != 1 {
		t.Fatal("duplicate processing")
	}
	public, _ := s.create(context.Background(), p.Asset{AssetType: entryType, ParentType: 2, ParentID: ticket.AssetID, Payload: "Try resetting your password", Preview: mailJSON(map[string]any{"version": 1, "kind": "public_reply", "author": "Support", "recipient": "anna@customer.test"})})
	_, _ = s.create(context.Background(), p.Asset{AssetType: entryType, ParentType: 2, ParentID: ticket.AssetID, Payload: "PRIVATE", Preview: mailJSON(map[string]any{"version": 1, "kind": "internal_note", "author": "Support"})})
	s.failStatus = true
	mailTick(t, c)
	mailTick(t, c)
	if len(*sent) != 2 || (*sent)[1].Body != "Try resetting your password" {
		t.Fatalf("wrong outbound replies %+v", *sent)
	}
	s.failStatus = false
	mailTick(t, c)
	if mailString(mailFields(s.assets[public.AssetID]), "mail_delivery") != "sent" || len(*sent) != 2 {
		t.Fatal("lost status patch resent mail")
	}
	if (*sent)[0].ReplyTo == "" || (*sent)[0].ReplyTo != (*sent)[1].ReplyTo {
		t.Fatal("missing or unstable ticket reply address")
	}
	path := c.db.Path()
	c.db.Close()
	reopened, err := openMailChannel(path, "tickets", c.secret, c.portal, c.smtp)
	if err != nil {
		t.Fatal(err)
	}
	c.db = reopened.db
	followup := "From: Anna <anna@customer.test>\r\nTo: " + (*sent)[1].ReplyTo + "\r\nMessage-ID: <reply@customer.test>\r\nSubject: Completely changed subject\r\n\r\nThat worked"
	if w := mailHTTP(c, "/inbound", followup); w.Code != 202 {
		t.Fatal(w.Code)
	}
	mailTick(t, c)
	entries, _ := s.list(context.Background(), entryType)
	found := false
	for _, a := range entries {
		if a.Payload == "That worked" && a.ParentID == ticket.AssetID {
			found = true
		}
	}
	if !found {
		t.Fatal("reply did not join same ticket")
	}
	evil := strings.Replace(followup, "Anna <anna@customer.test>", "Evil <evil@customer.test>", 1)
	evil = strings.Replace(evil, "<reply@customer.test>", "<evil@customer.test>", 1)
	if w := mailHTTP(c, "/inbound", evil); w.Code != 202 {
		t.Fatal(w.Code)
	}
	before := s.writes
	mailTick(t, c)
	if s.writes != before {
		t.Fatal("unauthorized sender wrote ticket")
	}
}

func TestMailChannelForwardingAndUnknown(t *testing.T) {
	c, s, sent := mailFixture(t)
	original := "From: Bob <bob@other.test>\r\nSubject: Broken\r\n\r\nCustomer text"
	raw := mailTestMultipart("mixed", "Content-Type: text/plain\r\n\r\nPlease check this", "Content-Type: message/rfc822\r\n\r\n"+original)
	raw = strings.Replace(raw, "STAFF@example.com", "anna@customer.test", 1)
	if w := mailHTTP(c, "/inbound", raw); w.Code != 202 {
		t.Fatal(w.Code, w.Body.String())
	}
	mailTick(t, c)
	mailTick(t, c)
	var ticket p.Asset
	for _, a := range s.assets {
		if a.AssetType == ticketType {
			ticket = a
		}
	}
	if mailString(mailFields(ticket), "requester") != "anna@customer.test" || mailString(mailFields(ticket), "submitted_by") != "" || ticket.Payload != "Please check this" || len(ticket.Attachments) != 1 || len(*sent) != 1 {
		t.Fatalf("bad forwarded ticket %+v", ticket)
	}
	attachment, err := c.portal.files.open(context.Background(), ticket.Attachments[0].FileId)
	if err != nil {
		t.Fatal(err)
	}
	data, err := io.ReadAll(attachment.Body)
	attachment.Body.Close()
	if err != nil || string(data) != original {
		t.Fatal("forwarded original not preserved as attachment")
	}
	entries, _ := s.list(context.Background(), entryType)
	if len(entries) != 0 {
		t.Fatal("forwarding created a private impersonation note")
	}
	s.fail = true
	if w := mailHTTP(c, "/inbound", "From: Anna <anna@customer.test>\r\nMessage-ID: <uncertain@test>\r\nSubject: Another\r\n\r\nSecond request"); w.Code != 202 {
		t.Fatal(w.Code)
	}
	mailTick(t, c)
	before := s.writes
	s.fail = false
	mailTick(t, c)
	if s.writes != before {
		t.Fatal("unknown write replayed")
	}
}

func TestMailChannelRecoveryAndAuthorization(t *testing.T) {
	c, s, _ := mailFixture(t)
	if err := c.put(mailJob{ID: "interrupted", Direction: "out", State: "inflight", Asset: 99}); err != nil {
		t.Fatal(err)
	}
	path := c.db.Path()
	c.db.Close()
	reopened, err := openMailChannel(path, "tickets", c.secret, c.portal, c.smtp)
	if err != nil {
		t.Fatal(err)
	}
	c.db = reopened.db
	jobs, err := c.jobs()
	if err != nil || jobs[0].State != "unknown" {
		t.Fatal(jobs, err)
	}
	if w := mailHTTP(c, "/jobs/interrupted/retry", ""); w.Code != 409 {
		t.Fatal("uncertain SMTP allowed retry", w.Code)
	}
	r := httptest.NewRequest("GET", "/jobs", nil)
	w := httptest.NewRecorder()
	c.ServeHTTP(w, r)
	if w.Code != 401 {
		t.Fatal("unauthenticated journal", w.Code)
	}
	raw := "From: Anna <anna@customer.test>\r\nTo: support+unknown@our.test\r\nMessage-ID: <same@test>\r\nSubject: Request\r\n\r\nBody"
	mailHTTP(c, "/inbound", raw)
	if w := mailHTTP(c, "/inbound", raw+"changed"); w.Code != 409 {
		t.Fatal("ID collision accepted", w.Code)
	}
	request := httptest.NewRequest("GET", "/jobs", nil)
	request.Header.Set("Authorization", "Bearer "+c.secret)
	w = httptest.NewRecorder()
	c.ServeHTTP(w, request)
	if bytes.Contains(w.Body.Bytes(), []byte("Body")) {
		t.Fatal("journal list includes raw mail")
	}
	mailTick(t, c)
	if s.writes != 0 {
		t.Fatal("quarantine created records")
	}
}

func TestMailChangedDuringDownloadDoesNotSend(t *testing.T) {
	for _, change := range []string{"requester", "kind", "attachment"} {
		t.Run(change, func(t *testing.T) {
			c, s, sent := mailFixture(t)
			ticket, _ := s.create(context.Background(), p.Asset{AssetType: ticketType, Preview: `{"version":1,"requester":"anna@customer.test","title":"Help"}`})
			entry, _ := s.create(context.Background(), p.Asset{AssetType: entryType, ParentType: 2, ParentID: ticket.AssetID, Payload: "Public text", Preview: `{"version":1,"kind":"public_reply","recipient":"anna@customer.test"}`, Attachments: []p.Attachment{{FileId: "att_00000000000000000000000000000000", Filename: "x.txt", MimeType: "text/plain", Size: 3}}})
			c.portal.files = changingMailFiles{fileStore: c.portal.files, change: func() {
				s.mu.Lock()
				defer s.mu.Unlock()
				if change == "requester" {
					a := s.assets[ticket.AssetID]
					a.Preview = `{"version":1,"requester":"other@customer.test"}`
					s.assets[a.AssetID] = a
				} else {
					a := s.assets[entry.AssetID]
					if change == "kind" {
						a.Preview = `{"version":1,"kind":"internal_note"}`
					} else {
						a.Attachments = nil
					}
					s.assets[a.AssetID] = a
				}
			}}
			mailTick(t, c)
			if len(*sent) != 0 {
				t.Fatal("sent stale public content")
			}
			jobs, _ := c.jobs()
			if len(jobs) != 1 || jobs[0].State != "failed" {
				t.Fatalf("wrong delivery state %+v", jobs)
			}
		})
	}
}

func TestMailPreMutationUploadRetriesSafely(t *testing.T) {
	c, s, _ := mailFixture(t)
	s.create(context.Background(), p.Asset{AssetType: p.AssetTypeCustomerContact, Preview: `{"version":1,"email":"anna@customer.test","title":"Anna"}`})
	files := c.portal.files
	c.portal.files = changingMailFiles{fileStore: files, failUpload: true}
	raw := mailTestMultipart("mixed", "Content-Type: text/plain\r\n\r\nHelp", "Content-Disposition: attachment; filename=x.txt\r\n\r\nabc")
	// The shared MIME fixture's outer sender is supplied explicitly here.
	raw = strings.Replace(raw, "STAFF@example.com", "anna@customer.test", 1)
	if w := mailHTTP(c, "/inbound", raw); w.Code != 202 {
		t.Fatal(w.Code)
	}
	mailTick(t, c)
	jobs, _ := c.jobs()
	if len(jobs) != 1 || jobs[0].State != "queued" || s.writes != 1 {
		t.Fatalf("not safely queued %+v writes=%d", jobs, s.writes)
	}
	c.portal.files = files
	mailTick(t, c)
	mailTick(t, c)
	tickets, _ := s.list(context.Background(), ticketType)
	if len(tickets) != 1 || len(tickets[0].Attachments) != 1 {
		t.Fatalf("lost or duplicated ticket %+v", tickets)
	}
}

func TestMailReplyAddressAuthorization(t *testing.T) {
	c, s, sent := mailFixture(t)
	var tickets []p.Asset
	for _, title := range []string{"First", "Second"} {
		ticket, _ := s.create(context.Background(), p.Asset{AssetType: ticketType, Preview: mailJSON(map[string]any{"version": 1, "requester": "anna@customer.test", "title": title, "status": "open"})})
		tickets = append(tickets, ticket)
		s.create(context.Background(), p.Asset{AssetType: entryType, ParentType: 2, ParentID: ticket.AssetID, Payload: title, Preview: `{"version":1,"kind":"public_reply","recipient":"anna@customer.test"}`})
	}
	mailTick(t, c)
	if len(*sent) != 2 || (*sent)[0].ReplyTo == (*sent)[1].ReplyTo {
		t.Fatal("tickets share a reply capability")
	}
	first, second := (*sent)[0].ReplyTo, (*sent)[1].ReplyTo
	for _, tc := range []struct {
		name, from, recipients string
		accepted               bool
	}{
		{"cc", "anna@customer.test", "To: support@our.test\r\nCc: Support <" + first + ">\r\n", true},
		{"foreign", "evil@customer.test", "To: " + first + "\r\n", false},
		{"encoded-identity", "=?UTF-8?Q?anna=40customer=2Etest_=28?= <attacker@evil.test> (=?UTF-8?Q?=29?=)", "To: " + first + "\r\n", false},
		{"unknown", "anna@customer.test", "To: support+" + strings.Repeat("0", 32) + "@our.test\r\n", false},
		{"ambiguous", "anna@customer.test", "To: " + first + ", " + second + "\r\n", false},
	} {
		raw := "From: " + tc.from + "\r\n" + tc.recipients + "Message-ID: <" + tc.name + "@customer.test>\r\nIn-Reply-To: " + c.messageID(tickets[1].AssetID) + "\r\n\r\n" + tc.name
		before := s.writes
		if w := mailHTTP(c, "/inbound", raw); w.Code != 202 {
			t.Fatal(w.Code)
		}
		mailTick(t, c)
		if (s.writes > before) != tc.accepted {
			t.Fatal("incorrect reply authorization", tc.name)
		}
	}
	entries, _ := s.list(context.Background(), entryType)
	for _, entry := range entries {
		if entry.Payload == "cc" && entry.ParentID != tickets[0].AssetID {
			t.Fatal("References overrode reply address")
		}
	}
	// A known Message-ID and a matching From must not grant existing-thread access.
	raw := "From: anna@customer.test\r\nTo: support@our.test\r\nIn-Reply-To: " + c.messageID(tickets[0].AssetID) + "\r\n\r\nNew request, not an authorized reply"
	mailHTTP(c, "/inbound", raw)
	mailTick(t, c)
	all, _ := s.list(context.Background(), ticketType)
	if len(all) != 3 {
		t.Fatal("reference-only message joined an existing ticket")
	}
}

func TestMailRequesterChangeBeforeClaimDoesNotSend(t *testing.T) {
	c, s, sent := mailFixture(t)
	ticket, _ := s.create(context.Background(), p.Asset{AssetType: ticketType, Preview: `{"version":1,"requester":"anna@customer.test","title":"Help"}`})
	s.create(context.Background(), p.Asset{AssetType: entryType, ParentType: 2, ParentID: ticket.AssetID, Payload: "Public text", Preview: `{"version":1,"kind":"public_reply","recipient":"anna@customer.test"}`})
	s.beforeClaim = func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		a := s.assets[ticket.AssetID]
		a.Preview = `{"version":1,"requester":"other@customer.test"}`
		a.UpdatedAt++
		s.assets[a.AssetID] = a
	}
	mailTick(t, c)
	if len(*sent) != 0 {
		t.Fatal("sent after requester changed before claim")
	}
	jobs, _ := c.jobs()
	if len(jobs) != 1 || jobs[0].State != "failed" {
		t.Fatalf("wrong claim result %+v", jobs)
	}
}

func TestMailRejectsEmptyMailbox(t *testing.T) {
	if c, err := openMailChannel(filepath.Join(t.TempDir(), "mail.db"), "tickets", strings.Repeat("x", 32), nil, smtpMailConfig{}); err == nil {
		c.db.Close()
		t.Fatal("empty mailbox accepted")
	}
}

func TestMailRetainedOriginalsDoNotInflateProcessing(t *testing.T) {
	c, s, _ := mailFixture(t)
	largeID := strings.Repeat("x", 2<<20)
	for i := 0; i < 16; i++ {
		raw := fmt.Sprintf("From: anna@customer.test\r\nTo: support+unknown@our.test\r\nMessage-ID: <%d-%s@customer.test>\r\n\r\nHelp", i, largeID)
		if w := mailHTTP(c, "/inbound", raw); w.Code != 202 {
			t.Fatal("large-ID mail was not retained in quarantine", w.Code)
		}
	}
	mailTick(t, c)
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	request := httptest.NewRequest("GET", "/jobs", nil)
	request.Header.Set("Authorization", "Bearer "+c.secret)
	response := httptest.NewRecorder()
	c.ServeHTTP(response, request)
	var jobs []mailJob
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &jobs) != nil || len(jobs) != 16 {
		t.Fatal("incorrect administration list")
	}
	if w := mailHTTP(c, "/inbound", "From: anna@customer.test\r\nMessage-ID: <bounded@customer.test>\r\n\r\nHelp"); w.Code != 202 {
		t.Fatal(w.Code)
	}
	mailTick(t, c)
	runtime.ReadMemStats(&after)
	allocated := after.TotalAlloc - before.TotalAlloc
	if allocated > 8<<20 {
		t.Fatalf("processing loaded retained raw archive: %d bytes allocated for 32 MiB archive", allocated)
	}
	tickets, _ := s.list(context.Background(), ticketType)
	if len(tickets) != 1 || tickets[0].Payload != "Help" {
		t.Fatal("new mail not processed")
	}
	t.Logf("32 MiB retained archive: list, receive and processing allocated %d bytes", allocated)
}

// Models a live cursor omitting an entry moved ahead of its first page, and
// an unavailable old record whose status reads consume their context budget.
type mailArchiveSource struct {
	*mailTestSource
	hidden  uint64
	blocked map[uint64]bool
}

func (s *mailArchiveSource) list(ctx context.Context, typ uint16) ([]p.Asset, error) {
	all, err := s.mailTestSource.list(ctx, typ)
	var out []p.Asset
	for _, a := range all {
		if a.AssetID != s.hidden {
			out = append(out, a)
		}
	}
	return out, err
}
func (s *mailArchiveSource) get(ctx context.Context, id uint64) (p.Asset, error) {
	if s.blocked[id] {
		<-ctx.Done()
		return p.Asset{}, ctx.Err()
	}
	return s.mailTestSource.get(ctx, id)
}

func TestMailActivationExcludesHistoricalEntriesDiscoveredLater(t *testing.T) {
	c, s, sent := mailFixture(t)
	ticket, _ := s.create(context.Background(), p.Asset{AssetType: ticketType, Preview: `{"version":1,"requester":"anna@customer.test","status":"open","title":"Help"}`})
	var historical p.Asset
	for i := 0; i < 51; i++ {
		a, _ := s.create(context.Background(), p.Asset{AssetType: entryType, ParentType: 2, ParentID: ticket.AssetID, CreatedAt: 10, Payload: "Historical", Preview: `{"version":1,"kind":"public_reply","recipient":"anna@customer.test"}`})
		a.UpdatedAt = 100
		s.assets[a.AssetID] = a
		historical = a
	}
	archive := &mailArchiveSource{mailTestSource: s, hidden: historical.AssetID}
	c.portal.source = archive
	activated, err := openMailChannel(filepath.Join(t.TempDir(), "activation.db"), "tickets", c.secret, c.portal, c.smtp)
	if err != nil {
		t.Fatal(err)
	}
	defer activated.db.Close()
	activated.send = c.send
	mailTick(t, activated)
	// A concurrent edit makes the omitted entry visible only after activation.
	historical.UpdatedAt = 200
	s.assets[historical.AssetID] = historical
	archive.hidden = 0
	fresh, _ := s.create(context.Background(), p.Asset{AssetType: entryType, ParentType: 2, ParentID: ticket.AssetID, CreatedAt: 201, Payload: "New answer", Preview: `{"version":1,"kind":"public_reply","recipient":"anna@customer.test"}`})
	mailTick(t, activated)
	if len(*sent) != 1 || (*sent)[0].Body != "New answer" {
		t.Fatalf("historical mail sent or fresh mail skipped: %+v", *sent)
	}
	current, _ := s.get(context.Background(), fresh.AssetID)
	if mailString(mailFields(current), "mail_delivery") != "sent" {
		t.Fatal("new reply not delivered")
	}
}

func TestMailStatusRepairsDoNotStarveQueuedMail(t *testing.T) {
	c, s, sent := mailFixture(t)
	archive := &mailArchiveSource{mailTestSource: s, blocked: map[uint64]bool{900: true}}
	c.portal.source = archive
	c.put(mailJob{ID: "ack-old-blocked", Direction: "out", State: "sent", Asset: 900})
	ready, _ := s.create(context.Background(), p.Asset{AssetType: ticketType, Preview: `{"version":1,"mail_delivery":"queued"}`})
	c.put(mailJob{ID: "ack-ready", Direction: "out", State: "sent", Asset: ready.AssetID})
	mailHTTP(c, "/inbound", "From: anna@customer.test\r\n\r\nFresh request")
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	_ = c.tick(ctx)
	cancel()
	tickets, _ := s.list(context.Background(), ticketType)
	if len(tickets) != 2 {
		t.Fatal("old status repair starved new request")
	}
	mailTick(t, c) // Rotates past the blocked repair and sends the acknowledgement.
	if len(*sent) != 1 {
		t.Fatal("queued acknowledgement starved")
	}
	a, _ := s.get(context.Background(), ready.AssetID)
	if mailString(mailFields(a), "mail_delivery") != "sent" {
		t.Fatal("blocked repair starved another repair")
	}
	// Completed repairs must not re-read an unavailable old asset.
	archive.blocked[ready.AssetID] = true
	c.put(mailJob{ID: "ack-old-blocked", Direction: "out", State: "sent", Asset: 900, StatusSynced: true})
	ctx, cancel = context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if err := c.tick(ctx); err != nil || ctx.Err() != nil {
		t.Fatal("revisited synchronized delivery records", err)
	}
}

func TestMailExplicitRetryOnlyAfterDefiniteRejection(t *testing.T) {
	c, _, sent := mailFixture(t)
	accepted := c.send
	c.send = func(context.Context, smtpMailConfig, string, []byte) (string, error) {
		return "failed", errors.New("550 rejected")
	}
	mailHTTP(c, "/inbound", "From: anna@customer.test\r\n\r\nHelp")
	mailTick(t, c)
	mailTick(t, c)
	jobs, _ := c.jobs()
	var id string
	for _, j := range jobs {
		if j.Direction == "out" {
			id = j.ID
		}
	}
	c.send = accepted
	mailTick(t, c)
	if len(*sent) != 0 {
		t.Fatal("rejection retried without approval")
	}
	if w := mailHTTP(c, "/jobs/"+id+"/retry", ""); w.Code != 204 {
		t.Fatal(w.Code)
	}
	mailTick(t, c)
	mailTick(t, c)
	if len(*sent) != 1 {
		t.Fatal("explicit retry duplicated or lost")
	}
	if w := mailHTTP(c, "/jobs/"+id+"/retry", ""); w.Code != 409 {
		t.Fatal("accepted mail can be retried")
	}
}

func TestMailSharedSenderAndRevocation(t *testing.T) {
	for _, duringUpload := range []bool{false, true} {
		t.Run(fmt.Sprint(duringUpload), func(t *testing.T) {
			c, _, _ := mailFixture(t)
			portal, f := sharingFixture(t)
			portal.source = &mailTestSource{fakeSource: f}
			portal.files = testFiles(t)
			c.portal = portal
			token, err := c.replyAddress(2)
			if err != nil {
				t.Fatal(err)
			}
			revoke := func() {
				a := f.assets[123]
				a.Preview = `{"version":1,"title":"Customer","ticket_groups":[]}`
				f.assets[123] = a
			}
			// Anna may reply to Bea's ticket through their explicit shared group.
			raw := "From: anna@example.test\r\nTo: " + token + "\r\nMessage-ID: <shared@test>\r\n\r\nShared answer"
			mailHTTP(c, "/inbound", raw)
			mailTick(t, c)
			if f.writes != 1 {
				t.Fatal("shared sender refused")
			}
			if duringUpload {
				portal.files = revokingFiles{portal.files, revoke}
				raw = mailTestMultipart("mixed", "Content-Type: text/plain\r\n\r\nMust not be saved", "Content-Disposition: attachment; filename=x.txt\r\n\r\nx")
				raw = strings.Replace(raw, "Forwarder <STAFF@example.com>", "Anna <anna@example.test>", 1)
				raw = strings.Replace(raw, "Content-Type: multipart/", "To: "+token+"\r\nMessage-ID: <revoked-upload@test>\r\nContent-Type: multipart/", 1)
			} else {
				revoke()
				raw = strings.Replace(raw, "shared@test", "revoked@test", 1)
			}
			mailHTTP(c, "/inbound", raw)
			mailTick(t, c)
			if f.writes != 1 {
				t.Fatal("shared sender retained revoked access")
			}
		})
	}
}
