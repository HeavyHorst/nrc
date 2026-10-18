package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestParseMailHeadersAndCharset(t *testing.T) {
	m, e := parseMail([]byte("From: =?ISO-8859-1?Q?Andr=E9?= <USER@Example.COM>\r\nMessage-ID: <one@example>\r\nReferences: <root@example>\r\nIn-Reply-To: <root@example> <parent@example>\r\nSubject: =?UTF-8?B?SGVsbG8=?=\r\nContent-Type: text/plain; charset=windows-1252\r\n\r\ncaf\xe9"))
	if e != nil || m.From != "user@example.com" || m.Name != "André" || m.Subject != "Hello" || m.Body != "café" || len(m.References) != 2 || m.ID != "<one@example>" {
		t.Fatalf("%+v %v", m, e)
	}
	for _, tc := range []struct{ from, address, name string }{
		{"=?UTF-8?Q?Doe=2C_John?= <john@example.com>", "john@example.com", "Doe, John"},
		{"=?UTF-8?Q?victim=40trusted=2Etest_=28?= <attacker@evil.test> (=?UTF-8?Q?=29?=)", "attacker@evil.test", "victim@trusted.test ("},
	} {
		m, e := parseMail([]byte("From: " + tc.from + "\r\n\r\nHelp"))
		if e != nil || m.From != tc.address || m.Name != tc.name {
			t.Fatalf("structured From changed: %+v %v", m, e)
		}
	}
}

func mailTestMultipart(kind string, parts ...string) string {
	return "From: Forwarder <STAFF@example.com>\r\nContent-Type: multipart/" + kind + "; boundary=b\r\n\r\n--b\r\n" + strings.Join(parts, "\r\n--b\r\n") + "\r\n--b--\r\n"
}

func TestParseMailAlternativesAndAttachments(t *testing.T) {
	plain := "Content-Type: text/plain\r\n\r\nplain only"
	html := "Content-Type: text/html\r\n\r\n<p>different &amp; text</p><script>bad()</script>"
	for _, parts := range [][]string{{plain, html}, {html, plain}} {
		m, e := parseMail([]byte(mailTestMultipart("alternative", parts...)))
		if e != nil || m.Body != "plain only" {
			t.Fatalf("%+v %v", m, e)
		}
	}
	m, e := parseMail([]byte(mailTestMultipart("mixed", html, "Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=bytes.bin\r\nContent-Transfer-Encoding: base64\r\n\r\nAAEC/w==")))
	if e != nil || m.Body != "different & text" || len(m.Files) != 1 || !bytes.Equal(m.Files[0].Data, []byte{0, 1, 2, 255}) {
		t.Fatalf("%+v %v", m, e)
	}
}

func TestParseMailForwards(t *testing.T) {
	original := "From: Customer <CUSTOMER@example.org>\r\nTo: support@example.com\r\nDate: Tue, 1 Jan 2030 12:00:00 +0000\r\nSubject: Help\r\n\r\ncustomer body"
	eml := "Content-Type: message/rfc822\r\nContent-Disposition: attachment; filename=original.eml\r\n\r\n" + original
	m, e := parseMail([]byte(mailTestMultipart("mixed", "Content-Type: text/plain\r\n\r\nplease handle", eml)))
	if e != nil || m.From != "staff@example.com" || m.Body != "please handle" || len(m.Files) != 1 || m.Files[0].Name != "original.eml" || string(m.Files[0].Data) != original {
		t.Fatalf("%+v %v", m, e)
	}
	if multiple, e := parseMail([]byte(mailTestMultipart("mixed", eml, eml))); e != nil || len(multiple.Files) != 2 {
		t.Fatal("forwarded originals must remain attachments", e)
	}
	for _, marker := range []string{"---------- Forwarded message ---------", "-----Original Message-----", "Begin forwarded message:"} {
		body := "please handle\r\n" + marker + "\r\n" + original
		m, e = parseMail([]byte("From: staff@example.com\r\n\r\n" + body))
		if e != nil || m.From != "staff@example.com" || m.Body != body || len(m.Files) != 0 {
			t.Fatalf("%+v %v", m, e)
		}
	}
}

func TestParseMailRejectsMalformedAndLimits(t *testing.T) {
	bad := []string{
		"From: a@example.com, b@example.com\r\n\r\nx",
		"From: a@example.com\r\nFrom: b@example.com\r\n\r\nx",
		"From: a@example.com\r\nSubject: a\r\nSubject: b\r\n\r\nx",
		"From: a@example.com\r\nContent-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\n\r\ntruncated",
		"From: a@example.com\r\nContent-Transfer-Encoding: base64\r\n\r\n!!!",
		"From: a@example.com\r\n\r\n" + strings.Repeat("é", 16001),
		mailTestMultipart("mixed", "Content-Disposition: attachment; filename=\"../evil\"\r\n\r\nx"),
	}
	parts := make([]string, 11)
	for i := range parts {
		parts[i] = "Content-Disposition: attachment; filename=x.txt\r\n\r\nx"
	}
	bad = append(bad, mailTestMultipart("mixed", parts...))
	nested := "Content-Type: text/plain\r\n\r\nx"
	for i := 0; i < 14; i++ {
		nested = "Content-Type: multipart/mixed; boundary=z" + strings.Repeat("x", i) + "\r\n\r\n--z" + strings.Repeat("x", i) + "\r\n" + nested + "\r\n--z" + strings.Repeat("x", i) + "--\r\n"
	}
	bad = append(bad, "From: a@example.com\r\n"+nested)
	for i, raw := range bad {
		if _, e := parseMail([]byte(raw)); e == nil {
			t.Errorf("accepted invalid case %d", i)
		}
	}
	if _, e := parseMail(make([]byte, mailRawLimit+1)); e == nil {
		t.Fatal("accepted oversized mail")
	}
	if _, e := parseMail([]byte("From: a@example.com\r\n\r\n" + strings.Repeat("x", 32000))); e != nil {
		t.Fatal(e)
	}
}

func TestParseMailAuto(t *testing.T) {
	for _, tc := range []struct {
		header string
		want   bool
	}{{"Auto-Submitted: auto-replied\r\n", true}, {"Auto-Submitted: no\r\n", false}, {"Content-Type: message/delivery-status\r\n", true}, {"", false}} {
		m, e := parseMail([]byte("From: robot@example.com\r\n" + tc.header + "\r\nstatus"))
		if e != nil || m.Auto != tc.want {
			t.Fatalf("%+v %v", m, e)
		}
	}
}
