package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"regexp"
	"sort"
	"strings"
)

type templateInfo struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	Variables []string `json:"variables"`
	HTML      string   `json:"-"`
	Text      string   `json:"-"`
}
type provider struct {
	client            *http.Client
	base, key, secret string
}

func (p provider) request(ctx context.Context, method, path string, v any) ([]byte, int, error) {
	var body []byte
	if v != nil {
		body, _ = json.Marshal(v)
	}
	r, e := http.NewRequestWithContext(ctx, method, p.base+path, bytes.NewReader(body))
	if e != nil {
		return nil, 0, e
	}
	r.SetBasicAuth(p.key, p.secret)
	r.Header.Set("Content-Type", "application/json")
	res, e := p.client.Do(r)
	if e != nil {
		return nil, 0, errors.New("provider transport outcome unknown")
	}
	defer res.Body.Close()
	b, e := io.ReadAll(io.LimitReader(res.Body, 2<<20))
	return b, res.StatusCode, e
}

var variableRE = regexp.MustCompile(`(?:var:)([A-Za-z_][A-Za-z0-9_]*)`)

func (p provider) template(ctx context.Context, id string) (templateInfo, error) {
	t := templateInfo{ID: id, Variables: []string{}}
	b, status, e := p.request(ctx, "GET", "/v3/REST/template/"+id, nil)
	if e != nil || status != 200 {
		return t, errors.New("template metadata unavailable")
	}
	var meta struct{ Data []struct{ Name string } }
	if json.Unmarshal(b, &meta) != nil || len(meta.Data) != 1 {
		return t, errors.New("invalid template metadata")
	}
	t.Name = meta.Data[0].Name
	b, status, e = p.request(ctx, "GET", "/v3/REST/template/"+id+"/detailcontent", nil)
	if e != nil || status != 200 {
		return t, errors.New("template content unavailable")
	}
	var content struct {
		Data []struct {
			HTML string `json:"Html-part"`
			Text string `json:"Text-part"`
		}
	}
	if json.Unmarshal(b, &content) != nil || len(content.Data) != 1 {
		return t, errors.New("invalid template content")
	}
	t.HTML, t.Text = content.Data[0].HTML, content.Data[0].Text
	seen := map[string]bool{}
	for _, m := range variableRE.FindAllStringSubmatch(t.HTML+t.Text, -1) {
		seen[m[1]] = true
	}
	for k := range seen {
		t.Variables = append(t.Variables, k)
	}
	sort.Strings(t.Variables)
	return t, nil
}

// Stored template content is submitted to Mailjet's renderer with an unconditional footer.
// Mailjet documents TemplateID and inline parts as alternative content modes.
func (a *app) mail(ctx context.Context, email, name, subject string, t templateInfo, vars map[string]any, link string) string {
	if !a.configured() {
		return "failed"
	}
	msg := map[string]any{"From": map[string]string{"Email": a.cfg.FromEmail, "Name": a.cfg.FromName}, "ReplyTo": map[string]string{"Email": a.cfg.ReplyTo}, "To": []map[string]string{{"Email": email, "Name": name}}, "Subject": subject, "TemplateLanguage": true, "TemplateErrorDeliver": false, "HTMLPart": t.HTML + `<p><a href="` + html.EscapeString(link) + `">Newsletter abmelden</a></p>`, "TextPart": t.Text + "\nNewsletter abmelden: " + link, "Variables": vars, "Headers": map[string]string{"List-Unsubscribe": "<" + link + ">"}}
	if link == "" {
		msg["HTMLPart"], msg["TextPart"] = t.HTML, t.Text
		delete(msg, "Headers")
	}
	b, status, e := a.provider.request(ctx, "POST", "/v3.1/send", map[string]any{"Messages": []any{msg}})
	if e != nil || status >= 500 || status == 0 {
		return "unknown"
	}
	if status < 200 || status >= 300 {
		return "failed"
	}
	var result struct{ Messages []struct{ Status string } }
	if json.Unmarshal(b, &result) != nil || len(result.Messages) != 1 {
		return "unknown"
	}
	if strings.EqualFold(result.Messages[0].Status, "success") {
		return "sent"
	}
	return "failed"
}
func providerError(status string) error {
	if status == "sent" {
		return nil
	}
	return fmt.Errorf("provider result: %s; unknown outcomes must not be retried automatically", status)
}
