package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	p "github.com/heavyhorst/nrc/protocol-go"
)

// Only use the disposable identity-bypassing customer-workspace-dev fixture.
// Never point this test at production; it intentionally persists test records.
func TestMailNRCIntegration(t *testing.T) {
	base := os.Getenv("NRC_MAIL_TEST_URL")
	if base == "" {
		t.Skip("set NRC_MAIL_TEST_URL to disposable customer-workspace-dev fixture")
	}
	workspace := fmt.Sprintf("email-review-%d", time.Now().UnixNano())
	s := nrcSource{server: strings.Replace(base, "http", "ws", 1), workspace: workspace, secret: "fixture-only"}
	portal := &portal{source: s, files: httpFiles{base: base, workspace: workspace, secret: "fixture-only"}}
	c, err := openMailChannel(filepath.Join(t.TempDir(), "journal.db"), workspace, strings.Repeat("t", 32), portal, smtpMailConfig{From: "support@our.test"})
	if err != nil {
		t.Fatal(err)
	}
	defer c.db.Close()
	var sent []mailMessage
	c.send = func(_ context.Context, _ smtpMailConfig, recipient string, raw []byte) (string, error) {
		m, e := parseMail(raw)
		if e != nil {
			t.Fatal(e)
		}
		if recipient != "anna@customer.test" {
			t.Fatal(recipient)
		}
		sent = append(sent, m)
		return "sent", nil
	}
	mailTick(t, c)
	inner := mailTestMultipart("mixed", "Content-Type: text/plain\r\n\r\nLogin fails after the update. Please investigate.", "Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=trace.bin\r\nContent-Transfer-Encoding: base64\r\n\r\nAAEC/w==")
	inner = strings.Replace(inner, "Forwarder <STAFF@example.com>", "Anna <anna@customer.test>", 1)
	inner = strings.Replace(inner, "Content-Type: multipart/", "Subject: Customer login issue\r\nMessage-ID: <original@customer.test>\r\nContent-Type: multipart/", 1)
	if w := mailHTTP(c, "/inbound", inner); w.Code != 202 {
		t.Fatal(w.Code, w.Body.String())
	}
	mailTick(t, c)
	mailTick(t, c)
	tickets, err := s.list(context.Background(), ticketType)
	if err != nil || len(tickets) != 1 {
		t.Fatal(tickets, err)
	}
	ticket, err := s.get(context.Background(), tickets[0].AssetID)
	if err != nil {
		t.Fatal(err)
	}
	if mailString(mailFields(ticket), "requester") != "anna@customer.test" || len(ticket.Attachments) != 1 || len(sent) != 1 {
		t.Fatalf("incorrect incoming record %+v %v", ticket, sent)
	}
	attachments, err := c.upload(context.Background(), []mailAttachment{{Name: "answer.bin", Type: "application/octet-stream", Data: []byte{9, 8, 7, 0, 255}}})
	if err != nil {
		t.Fatal(err)
	}
	entry, err := s.createReply(context.Background(), p.Asset{AssetType: entryType, ParentType: 2, ParentID: ticket.AssetID, Preview: mailJSON(map[string]any{"version": 1, "kind": "public_reply", "author": "Support", "recipient": "anna@customer.test"}), Payload: "Please try again; the issue is fixed.", Attachments: attachments}, ticket.UpdatedAt)
	if err != nil {
		t.Fatal(err)
	}
	// The final SMTP claim must reject a stale ticket and leave its entry
	// untouched, not merely guard the reply independently.
	updated := mailFields(ticket)
	updated["title"] = "Customer login issue (triaged)"
	if err := s.patchPreview(context.Background(), ticket, mailJSON(updated)); err != nil {
		t.Fatal(err)
	}
	queued := mailFields(entry)
	queued["mail_delivery"] = "queued"
	if err := s.patchPreview(context.Background(), entry, mailJSON(queued), ticket); err == nil {
		t.Fatal("stale ticket claim committed")
	}
	unchanged, err := s.get(context.Background(), entry.AssetID)
	if err != nil || mailString(mailFields(unchanged), "mail_delivery") != "" {
		t.Fatal("rejected claim partially changed entry", err)
	}
	mailTick(t, c)
	if len(sent) != 2 || len(sent[1].Files) != 1 || !bytes.Equal(sent[1].Files[0].Data, []byte{9, 8, 7, 0, 255}) {
		t.Fatalf("outbound attachment mismatch %+v", sent)
	}
	current, err := s.get(context.Background(), entry.AssetID)
	if err != nil || mailString(mailFields(current), "mail_delivery") != "sent" {
		t.Fatal("status not persisted", current, err)
	}
	followup := "From: Anna <anna@customer.test>\r\nTo: " + sent[1].ReplyTo + "\r\nMessage-ID: <followup@customer.test>\r\nSubject: Solved!\r\n\r\nThanks, I can log in now."
	mailHTTP(c, "/inbound", followup)
	mailTick(t, c)
	entries, err := s.list(context.Background(), entryType)
	if err != nil || len(entries) != 2 {
		t.Fatal("expected public reply and customer reply", entries, err)
	}
	contactList, err := s.list(context.Background(), p.AssetTypeCustomerContact)
	if err != nil || len(contactList) != 1 || mailString(mailFields(contactList[0]), "review_status") != "pending" {
		t.Fatal(contactList, err)
	}
	t.Logf("PASS real NRC mail roundtrip: workspace=%s ticket=%d contact=%d; direct customer mail, binary attachments, public mail and token-addressed followup without References", workspace, ticket.AssetID, contactList[0].AssetID)
}
