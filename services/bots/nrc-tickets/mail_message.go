package main

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net/mail"
	"net/textproto"
	"strings"
	"unicode/utf8"

	"golang.org/x/net/html"
	"golang.org/x/net/html/charset"
)

type mailMessage struct {
	ID, From, Name, Subject, Body string
	Recipients                    []string
	ReplyTo                       string
	References                    []string
	Auto                          bool
	Files                         []mailAttachment
}

type mailAttachment struct {
	Name, Type string
	Data       []byte
}

const mailRawLimit = 32 << 20
const mailBodyLimit = 32000

type mailBudget struct{ parts, files int }

func mailHeaders(h textproto.MIMEHeader) error {
	for _, k := range []string{"From", "To", "Cc", "Reply-To", "Subject", "Message-Id", "In-Reply-To", "References", "Auto-Submitted", "Content-Type", "Content-Disposition", "Content-Transfer-Encoding"} {
		if len(h.Values(k)) > 1 {
			return fmt.Errorf("ambiguous %s", k)
		}
	}
	return nil
}

func mailWords(s string) (string, error) {
	d := mime.WordDecoder{CharsetReader: charset.NewReaderLabel}
	v, err := d.DecodeHeader(s)
	if err == nil && !utf8.ValidString(v) {
		err = fmt.Errorf("invalid UTF-8 header")
	}
	return v, err
}

func mailIDs(s string) ([]string, error) {
	var ids []string
	for strings.TrimSpace(s) != "" {
		s = strings.TrimSpace(s)
		i := strings.IndexByte(s, '>')
		if !strings.HasPrefix(s, "<") || i < 2 || strings.ContainsAny(s[1:i], "<> \t\r\n") {
			return nil, fmt.Errorf("invalid message ID")
		}
		ids = append(ids, s[:i+1])
		s = s[i+1:]
	}
	return ids, nil
}

func parseMail(raw []byte) (out mailMessage, err error) {
	if len(raw) > mailRawLimit {
		return out, fmt.Errorf("mail exceeds 32 MiB")
	}
	m, err := mail.ReadMessage(bytes.NewReader(raw))
	if err != nil {
		return out, err
	}
	h := textproto.MIMEHeader(m.Header)
	if err = mailHeaders(h); err != nil {
		return out, err
	}
	// Decode display names within the structured address grammar, never before
	// parsing: decoded punctuation must not become mailbox syntax.
	parser := mail.AddressParser{WordDecoder: &mime.WordDecoder{CharsetReader: charset.NewReaderLabel}}
	as, err := parser.ParseList(h.Get("From"))
	if err != nil || len(as) != 1 {
		return out, fmt.Errorf("mail requires exactly one From")
	}
	if !utf8.ValidString(as[0].Name) {
		return out, fmt.Errorf("invalid UTF-8 sender name")
	}
	out.From, out.Name = strings.ToLower(as[0].Address), as[0].Name
	for _, field := range []string{"To", "Cc", "Reply-To"} {
		if h.Get(field) == "" {
			continue
		}
		addresses, e := mail.ParseAddressList(h.Get(field))
		if e != nil || len(addresses) > 100 || field == "Reply-To" && len(addresses) != 1 {
			return out, fmt.Errorf("invalid mail recipients")
		}
		for _, address := range addresses {
			value := mailAddress(strings.ToLower(address.Address))
			if value == "" {
				return out, fmt.Errorf("invalid mail recipient address")
			}
			if field == "Reply-To" {
				out.ReplyTo = value
			} else {
				out.Recipients = append(out.Recipients, value)
			}
		}
	}
	out.Subject, err = mailWords(h.Get("Subject"))
	if err != nil {
		return out, err
	}
	ids, err := mailIDs(h.Get("Message-Id"))
	if err != nil || len(ids) > 1 {
		return out, fmt.Errorf("invalid Message-ID")
	}
	if len(ids) == 1 {
		out.ID = ids[0]
	}
	seenIDs := make(map[string]bool)
	for _, k := range []string{"References", "In-Reply-To"} {
		ids, err = mailIDs(h.Get(k))
		if err != nil {
			return out, err
		}
		for _, id := range ids {
			if !seenIDs[id] {
				seenIDs[id] = true
				out.References = append(out.References, id)
			}
		}
	}
	auto := strings.TrimSpace(h.Get("Auto-Submitted"))
	out.Auto = auto != "" && !strings.EqualFold(strings.TrimSpace(strings.SplitN(auto, ";", 2)[0]), "no")
	out.Body, err = mailPart(h, m.Body, 0, &mailBudget{}, &out)
	return out, err
}

func mailPart(h textproto.MIMEHeader, r io.Reader, depth int, budget *mailBudget, out *mailMessage) (string, error) {
	budget.parts++
	if depth > 12 || budget.parts > 256 {
		return "", fmt.Errorf("MIME complexity limit")
	}
	if err := mailHeaders(h); err != nil {
		return "", err
	}
	ct := h.Get("Content-Type")
	if ct == "" {
		ct = "text/plain"
	}
	typ, params, err := mime.ParseMediaType(ct)
	if err != nil {
		return "", err
	}
	disp := ""
	var dp map[string]string
	if v := h.Get("Content-Disposition"); v != "" {
		disp, dp, err = mime.ParseMediaType(v)
		if err != nil {
			return "", err
		}
	}
	name := dp["filename"]
	if name == "" {
		name = params["name"]
	}
	if name != "" {
		name, err = mailWords(name)
		if err != nil {
			return "", err
		}
		if !validFilename(name) || name == "." || name == ".." {
			return "", fmt.Errorf("unsafe filename")
		}
	}
	switch strings.ToLower(strings.TrimSpace(h.Get("Content-Transfer-Encoding"))) {
	case "", "7bit", "8bit", "binary":
	case "base64":
		r = base64.NewDecoder(base64.StdEncoding, r)
	case "quoted-printable":
		r = quotedprintable.NewReader(r)
	default:
		return "", fmt.Errorf("unsupported transfer encoding")
	}
	if strings.HasPrefix(typ, "multipart/") {
		if params["boundary"] == "" {
			return "", fmt.Errorf("missing MIME boundary")
		}
		if typ == "multipart/report" {
			out.Auto = true
		}
		mr := multipart.NewReader(r, params["boundary"])
		var bodies []string
		plain := ""
		hasPlain := false
		for {
			p, e := mr.NextRawPart()
			if e == io.EOF {
				break
			}
			if e != nil {
				return "", e
			}
			body, e := mailPart(p.Header, p, depth+1, budget, out)
			if e != nil {
				return "", e
			}
			pt, pp, _ := mime.ParseMediaType(p.Header.Get("Content-Type"))
			if pt == "" {
				pt = "text/plain"
			}
			pd, pdp, _ := mime.ParseMediaType(p.Header.Get("Content-Disposition"))
			if typ == "multipart/alternative" && pt == "text/plain" && pd != "attachment" && pdp["filename"] == "" && pp["name"] == "" {
				plain = body
				hasPlain = true
			}
			if body != "" {
				bodies = append(bodies, body)
			}
		}
		body := strings.Join(bodies, "\n\n")
		if typ == "multipart/alternative" {
			if hasPlain {
				body = plain
			} else if len(bodies) > 0 {
				body = bodies[len(bodies)-1]
			}
		}
		return mailCheckBody(body)
	}
	data, err := io.ReadAll(io.LimitReader(r, mailRawLimit+1))
	if err != nil {
		return "", err
	}
	if len(data) > mailRawLimit {
		return "", fmt.Errorf("decoded part too large")
	}
	if typ == "message/rfc822" {
		// A forwarded message is an opaque attachment, never another identity.
		if name == "" {
			name = "forwarded.eml"
		}
	}
	if typ == "message/delivery-status" || typ == "message/global-delivery-status" {
		out.Auto = true
		return "", nil
	}
	if name != "" || disp == "attachment" || (typ != "text/plain" && typ != "text/html") {
		if name == "" {
			return "", fmt.Errorf("attachment requires safe filename")
		}
		budget.files++
		if budget.files > 10 {
			return "", fmt.Errorf("too many attachments")
		}
		out.Files = append(out.Files, mailAttachment{name, typ, data})
		return "", nil
	}
	if label := params["charset"]; label != "" && !strings.EqualFold(label, "utf-8") {
		cr, e := charset.NewReaderLabel(label, bytes.NewReader(data))
		if e != nil {
			return "", e
		}
		data, e = io.ReadAll(io.LimitReader(cr, mailRawLimit+1))
		if e != nil {
			return "", e
		}
		if len(data) > mailRawLimit {
			return "", fmt.Errorf("decoded text too large")
		}
	}
	if !utf8.Valid(data) {
		return "", fmt.Errorf("invalid UTF-8 body")
	}
	body := string(data)
	if typ == "text/html" {
		body = mailHTML(body)
	}
	return mailCheckBody(body)
}

func mailCheckBody(s string) (string, error) {
	if len(s) > mailBodyLimit {
		return "", fmt.Errorf("body exceeds 32000 bytes")
	}
	return s, nil
}

// Tokenization never renders active markup; suppress executable and hidden containers.
func mailHTML(s string) string {
	z := html.NewTokenizer(strings.NewReader(s))
	var b strings.Builder
	hidden := 0
	for {
		tt := z.Next()
		if tt == html.ErrorToken {
			break
		}
		t := z.Token()
		switch tt {
		case html.StartTagToken:
			if t.Data == "script" || t.Data == "style" || t.Data == "template" || t.Data == "head" {
				hidden++
			}
			if hidden == 0 && (t.Data == "br" || t.Data == "p" || t.Data == "div" || t.Data == "li") {
				b.WriteByte('\n')
			}
		case html.EndTagToken:
			if t.Data == "script" || t.Data == "style" || t.Data == "template" || t.Data == "head" {
				if hidden > 0 {
					hidden--
				}
			}
			if hidden == 0 && (t.Data == "p" || t.Data == "div" || t.Data == "li") {
				b.WriteByte('\n')
			}
		case html.TextToken:
			if hidden == 0 {
				b.WriteString(t.Data)
			}
		}
	}
	return strings.TrimSpace(b.String())
}
