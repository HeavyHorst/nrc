package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"fmt"
	"mime"
	"mime/multipart"
	"net"
	"net/mail"
	"net/smtp"
	"net/textproto"
	"strings"
	"time"
	"unicode/utf8"
)

type smtpMailConfig struct {
	Address, Host, Username, Password, From string
	ImplicitTLS                             bool
	OAuth2                                  *mailOAuthConfig
}

func smtpAddress(s string) (*mail.Address, error) {
	if !safeMailHeader(s) {
		return nil, fmt.Errorf("invalid address")
	}
	a, err := mail.ParseAddress(s)
	if err != nil || !safeMailHeader(a.Address) {
		return nil, fmt.Errorf("invalid address")
	}
	return a, nil
}

func safeMailHeader(s string) bool {
	if !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if r < 32 || r == 127 {
			return false
		}
	}
	return true
}

// sent means the relay accepted DATA, not that the recipient received it.
// Once DATA starts, transport errors cannot prove that the relay did not accept it.
func sendSMTP(ctx context.Context, c smtpMailConfig, recipient string, raw []byte) (string, error) {
	from, err := smtpAddress(c.From)
	if err != nil {
		return "failed", err
	}
	to, err := smtpAddress(recipient)
	if err != nil {
		return "failed", err
	}
	if c.Host == "" || len(raw) > mailRawLimit {
		return "failed", fmt.Errorf("invalid SMTP configuration or message size")
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	conn, err := (&net.Dialer{Timeout: 15 * time.Second}).DialContext(ctx, "tcp", c.Address)
	if err != nil {
		return "failed", err
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	deadline, _ := ctx.Deadline()
	conn.SetDeadline(deadline)
	tc := &tls.Config{ServerName: c.Host, MinVersion: tls.VersionTLS12}
	var wire net.Conn = conn
	if c.ImplicitTLS {
		t := tls.Client(conn, tc)
		if err := t.HandshakeContext(ctx); err != nil {
			return "failed", err
		}
		wire = t
	}
	client, err := smtp.NewClient(wire, c.Host)
	if err != nil {
		return "failed", err
	}
	defer client.Close()
	if !c.ImplicitTLS {
		if ok, _ := client.Extension("STARTTLS"); !ok {
			return "failed", fmt.Errorf("SMTP requires STARTTLS")
		}
		if err := client.StartTLS(tc); err != nil {
			return "failed", err
		}
	}
	if c.Username != "" {
		var auth smtp.Auth = smtp.PlainAuth("", c.Username, c.Password, c.Host)
		if c.OAuth2 != nil {
			token, err := c.OAuth2.token(ctx)
			if err != nil {
				return "failed", err
			}
			auth = mailSMTPAuth{mailXOAUTH2{c.Username, token}}
		}
		if err := client.Auth(auth); err != nil {
			return "failed", err
		}
	}
	if err := client.Mail(from.Address); err != nil {
		return "failed", err
	}
	if err := client.Rcpt(to.Address); err != nil {
		return "failed", err
	}
	w, err := client.Data()
	if err != nil {
		return "failed", err
	}
	if _, err := w.Write(raw); err != nil {
		return "unknown", err
	}
	if err := w.Close(); err != nil {
		if e, ok := err.(*textproto.Error); ok && e.Code >= 400 && e.Code <= 599 {
			return "failed", err
		}
		return "unknown", err
	}
	return "sent", nil
}

func buildMail(from, to, replyTo, subject, id string, references []string, body string, files []mailAttachment) ([]byte, error) {
	f, err := smtpAddress(from)
	if err != nil {
		return nil, err
	}
	t, err := smtpAddress(to)
	if err != nil {
		return nil, err
	}
	reply, err := smtpAddress(replyTo)
	if err != nil {
		return nil, err
	}
	if !safeMailHeader(subject) || !utf8.ValidString(body) || len(body) > mailBodyLimit || len(files) > 10 {
		return nil, fmt.Errorf("invalid mail content")
	}
	for _, s := range append([]string{id}, references...) {
		ids, e := mailIDs(s)
		if !safeMailHeader(s) || e != nil || len(ids) != 1 || ids[0] != s {
			return nil, fmt.Errorf("invalid message ID")
		}
	}
	var b bytes.Buffer
	m := multipart.NewWriter(&b)
	fmt.Fprintf(&b, "From: %s\r\nTo: %s\r\nReply-To: %s\r\nSubject: %s\r\nMessage-ID: %s\r\nMIME-Version: 1.0\r\n", f.String(), t.String(), reply.String(), mime.QEncoding.Encode("utf-8", subject), id)
	fmt.Fprintf(&b, "Date: %s\r\nAuto-Submitted: auto-generated\r\n", time.Now().Format(time.RFC1123Z))
	if len(references) > 0 {
		fmt.Fprintf(&b, "References: %s\r\nIn-Reply-To: %s\r\n", strings.Join(references, " "), references[len(references)-1])
	}
	fmt.Fprintf(&b, "Content-Type: multipart/mixed; boundary=%q\r\n\r\n", m.Boundary())
	part := func(h textproto.MIMEHeader, data []byte) error {
		if len(data) > mailRawLimit || b.Len()+base64.StdEncoding.EncodedLen(len(data))*78/76+1024 > mailRawLimit {
			return fmt.Errorf("mail exceeds 32 MiB")
		}
		h.Set("Content-Transfer-Encoding", "base64")
		w, e := m.CreatePart(h)
		if e != nil {
			return e
		}
		encoded := base64.StdEncoding.EncodeToString(data)
		for len(encoded) > 0 {
			n := min(76, len(encoded))
			if _, e := fmt.Fprintf(w, "%s\r\n", encoded[:n]); e != nil {
				return e
			}
			encoded = encoded[n:]
		}
		return nil
	}
	if err := part(textproto.MIMEHeader{"Content-Type": {"text/plain; charset=utf-8"}}, []byte(body)); err != nil {
		return nil, err
	}
	for _, file := range files {
		if file.Name == "" || file.Name == "." || file.Name == ".." || !validFilename(file.Name) || !safeMailHeader(file.Name) || strings.ContainsAny(file.Name, "/\\") || !safeMailHeader(file.Type) {
			return nil, fmt.Errorf("invalid attachment")
		}
		typ, params, e := mime.ParseMediaType(file.Type)
		if e != nil {
			return nil, fmt.Errorf("invalid attachment media type")
		}
		h := textproto.MIMEHeader{"Content-Type": {mime.FormatMediaType(typ, params)}, "Content-Disposition": {mime.FormatMediaType("attachment", map[string]string{"filename": file.Name})}}
		if e := part(h, file.Data); e != nil {
			return nil, e
		}
	}
	if err := m.Close(); err != nil {
		return nil, err
	}
	if b.Len() > mailRawLimit {
		return nil, fmt.Errorf("mail exceeds 32 MiB")
	}
	return b.Bytes(), nil
}
