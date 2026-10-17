package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"
)

func reply(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}
func fail(w http.ResponseWriter, status int, msg string) {
	reply(w, status, map[string]string{"error": msg})
}
func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	d := json.NewDecoder(r.Body)
	var raw json.RawMessage
	if d.Decode(&raw) != nil || len(raw) == 0 || raw[0] != '{' {
		fail(w, 400, "invalid JSON input")
		return false
	}
	if d.Decode(new(any)) != io.EOF {
		fail(w, 400, "expected one JSON object")
		return false
	}
	fields := json.NewDecoder(bytes.NewReader(raw))
	fields.DisallowUnknownFields()
	if fields.Decode(v) != nil {
		fail(w, 400, "invalid JSON fields")
		return false
	}
	return true
}
func now() string { return time.Now().UTC().Format(time.RFC3339) }
func (a *app) approved(id string) bool {
	for _, v := range a.cfg.TemplateIDs {
		if v == id {
			return true
		}
	}
	return false
}
func (a *app) status(email string) string {
	if !validEmail(email) {
		return "blocked"
	}
	if c := a.s.Consent[email]; c != nil {
		return c.Status
	}
	return "not_subscribed"
}
func (a *app) adminHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if !a.authorized(r.Header.Get("X-NRC-Newsletter-Auth")) {
			fail(w, 401, "private proxy assertion required")
			return
		}
		a.admin(w, r)
	})
}

type draft struct {
	Kind          string         `json:"kind"`
	Audience      string         `json:"audience"`
	CustomerIDs   []string       `json:"customer_ids"`
	ServiceReason string         `json:"service_reason"`
	Title         string         `json:"title"`
	TemplateID    string         `json:"template_id"`
	Subject       string         `json:"subject"`
	Variables     map[string]any `json:"variables"`
	Revision      int            `json:"revision"`
}

func (a *app) validDraft(d draft) bool {
	return validServiceDraft(d) && strings.TrimSpace(d.Title) != "" && len(d.Title) <= 200 && strings.TrimSpace(d.Subject) != "" && len(d.Subject) <= 250 && !strings.ContainsAny(d.Subject, "\r\n") && a.approved(d.TemplateID) && d.Variables != nil
}
func (a *app) admin(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/api/consents/import" {
		a.importConsents(w, r)
		return
	}
	if r.URL.Path == "/api/state" && r.Method == "GET" {
		a.getState(w, r)
		return
	}
	if r.URL.Path == "/api/campaigns" && r.Method == "POST" {
		var d draft
		if !decode(w, r, &d) {
			return
		}
		if !a.validDraft(d) || d.Revision != 0 {
			fail(w, 400, "invalid draft")
			return
		}
		a.s.mu.Lock()
		defer a.s.mu.Unlock()
		c := &campaign{ID: random(), Title: d.Title, TemplateID: d.TemplateID, Subject: d.Subject, Variables: d.Variables, Revision: 1, Status: "draft", CreatedAt: now(), UpdatedAt: now(), Recipients: []recipient{}}
		c.Kind, c.Audience, c.CustomerIDs, c.ServiceReason = d.Kind, d.Audience, d.CustomerIDs, d.ServiceReason
		a.s.Campaigns[c.ID] = c
		a.s.mustSave()
		reply(w, 201, c)
		return
	}
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) == 4 && parts[0] == "api" && parts[1] == "subscribers" && r.Method == "POST" {
		a.subscriberAction(w, r, parts[2], parts[3])
		return
	}
	if len(parts) < 3 || len(parts) > 4 || parts[0] != "api" || parts[1] != "campaigns" {
		fail(w, 404, "not found")
		return
	}
	if len(parts) == 3 && r.Method == "PUT" {
		var d draft
		if !decode(w, r, &d) {
			return
		}
		if !a.validDraft(d) {
			fail(w, 400, "invalid draft")
			return
		}
		a.s.mu.Lock()
		defer a.s.mu.Unlock()
		c := a.s.Campaigns[parts[2]]
		if c == nil {
			fail(w, 404, "campaign not found")
			return
		}
		if c.Status != "draft" || d.Revision != c.Revision {
			fail(w, 409, "revision or status conflict")
			return
		}
		c.Title, c.TemplateID, c.Subject, c.Variables = d.Title, d.TemplateID, d.Subject, d.Variables
		c.Kind, c.Audience, c.CustomerIDs, c.ServiceReason = d.Kind, d.Audience, d.CustomerIDs, d.ServiceReason
		c.Revision++
		c.TestedRevision = 0
		c.TemplateHTML = ""
		c.TemplateText = ""
		c.UpdatedAt = now()
		a.s.mustSave()
		reply(w, 200, c)
		return
	}
	if len(parts) != 4 || r.Method != "POST" {
		fail(w, 405, "method not allowed")
		return
	}
	var input struct {
		Revision      int    `json:"revision"`
		Email         string `json:"email"`
		ContactID     string `json:"contact_id"`
		Confirmation  string `json:"confirmation"`
		AudienceToken string `json:"audience_token"`
	}
	if !decode(w, r, &input) {
		return
	}
	// Serialize campaign mutations, provider tests and optouts. Background dispatch uses the same lock.
	a.s.mu.Lock()
	defer a.s.mu.Unlock()
	c := a.s.Campaigns[parts[2]]
	if c == nil {
		fail(w, 404, "campaign not found")
		return
	}
	if input.Revision != c.Revision || (c.Status != "draft" && parts[3] != "preview") || !a.approved(c.TemplateID) {
		fail(w, 409, "revision or status conflict")
		return
	}
	switch parts[3] {
	case "audience":
		report, err := a.campaignAudience(r.Context(), c)
		if err != nil {
			fail(w, 503, err.Error())
			return
		}
		reply(w, 200, map[string]any{"audience": report, "token": audienceToken(report)})
	case "preview":
		if !a.configured() {
			fail(w, 503, "Mailjet is not configured")
			return
		}
		t := templateInfo{HTML: c.TemplateHTML, Text: c.TemplateText}
		if c.TestedRevision != c.Revision {
			var err error
			t, err = a.provider.template(r.Context(), c.TemplateID)
			if err != nil {
				fail(w, 502, err.Error())
				return
			}
		}
		// The browser sandboxes raw provider content. Do not emulate Mailjet's
		// template language or imply that this is its final personalized render.
		reply(w, 200, map[string]any{"html": t.HTML, "text": t.Text, "exact": false, "notice": "Mailjet-Vorlagenansicht · Platzhalter bleiben unverändert; die verbindliche Darstellung prüfen Sie per Testmail. Externe Inhalte sind blockiert."})
	case "test":
		if !validEmail(input.Email) || !a.configured() {
			fail(w, 400, "valid test email and sending configuration required")
			return
		}
		input.Email = normalize(input.Email)
		if status := a.status(input.Email); status == "blocked" || (status == "unsubscribed" && c.Kind != "service") {
			fail(w, 422, "Testadresse ist gesperrt oder abgemeldet. Bitte eine andere Testadresse wählen.")
			return
		}
		t, e := a.provider.template(r.Context(), c.TemplateID)
		if e != nil {
			fail(w, 502, e.Error())
			return
		}
		a.s.Known[normalize(input.Email)] = true
		link := a.campaignLink(c, input.Email)
		a.s.mustSave()
		status := a.mail(r.Context(), input.Email, "", c.Subject, t, c.Variables, link)
		if e := providerError(status); e != nil {
			fail(w, 502, e.Error())
			return
		}
		c.TestedRevision = c.Revision
		c.TemplateHTML, c.TemplateText = t.HTML, t.Text
		c.UpdatedAt = now()
		a.s.mustSave()
		reply(w, 200, c)
	case "send":
		if !a.configured() || c.TestedRevision != c.Revision || input.Confirmation != c.Subject {
			fail(w, 409, "test this revision and confirm the exact subject before sending")
			return
		}
		report, e := a.campaignAudience(r.Context(), c)
		if e != nil {
			fail(w, 503, e.Error())
			return
		}
		if c.Kind == "service" && input.AudienceToken != audienceToken(report) {
			fail(w, 409, "audience changed; review recipients again")
			return
		}
		if len(report.Recipients) == 0 {
			fail(w, 409, "no eligible recipients")
			return
		}
		c.Recipients = report.Recipients
		c.Status = "queued"
		c.UpdatedAt = now()
		a.s.mustSave()
		reply(w, 202, c)
	default:
		fail(w, 404, "not found")
	}
}
func (a *app) getState(w http.ResponseWriter, r *http.Request) {
	contacts, e := a.source.contacts(r.Context())
	if e != nil {
		fail(w, 503, "contact register unavailable")
		return
	}
	customers := []customer{}
	if src, ok := a.source.(interface {
		directory(context.Context) ([]customer, error)
	}); ok {
		customers, e = src.directory(r.Context())
	} else if src, ok := a.source.(customerSource); ok {
		customers, e = src.customers(r.Context())
	}
	if e != nil {
		fail(w, 503, "customer register unavailable")
		return
	}
	companies := map[string][]map[string]string{}
	for _, co := range customers {
		for _, ct := range co.Members {
			companies[ct.ID] = append(companies[ct.ID], map[string]string{"customer_id": co.ID, "name": co.Name})
		}
	}
	templates := []templateInfo{}
	if a.configured() {
		for _, id := range a.cfg.TemplateIDs {
			t, e := a.provider.template(r.Context(), id)
			if e != nil {
				fail(w, 502, e.Error())
				return
			}
			templates = append(templates, t)
		}
	}
	a.s.mu.Lock()
	defer a.s.mu.Unlock()
	subs := []map[string]any{}
	counts := map[string]int{"total": len(contacts), "eligible": 0, "duplicates": 0, "not_subscribed": 0, "unsubscribed": 0, "blocked": 0}
	seen := map[string]bool{}
	for _, ct := range contacts {
		ct.Email = normalize(ct.Email)
		s := a.status(ct.Email)
		v := map[string]any{"contact_id": ct.ID, "name": ct.Name, "email": ct.Email, "status": s}
		v["companies"] = companies[ct.ID]
		if c := a.s.Consent[ct.Email]; c != nil {
			v["source"] = c.Source
			v["confirmed_at"] = c.ConfirmedAt
			v["import_proof"] = c.Imported
		}
		subs = append(subs, v)
		if s == "subscribed" {
			if !seen[ct.Email] {
				counts["eligible"]++
				seen[ct.Email] = true
			} else {
				counts["duplicates"]++
			}
		} else if s == "pending" {
			counts["not_subscribed"]++
		} else {
			counts[s]++
		}
	}
	campaigns := []*campaign{}
	for _, c := range a.s.Campaigns {
		copy := *c
		copy.TemplateHTML = ""
		copy.TemplateText = ""
		campaigns = append(campaigns, &copy)
	}
	reply(w, 200, map[string]any{"customers": customers, "configured": a.configured(), "from_email": a.cfg.FromEmail, "from_name": a.cfg.FromName, "reply_to": a.cfg.ReplyTo, "templates": templates, "campaigns": campaigns, "subscribers": subs, "audience": counts})
}
func (a *app) worker(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			a.dispatch(ctx)
		}
	}
}
func (a *app) dispatch(ctx context.Context) {
	a.s.mu.Lock()
	defer a.s.mu.Unlock()
	for _, c := range a.s.Campaigns {
		if c.Status != "queued" && c.Status != "sending" {
			continue
		}
		if !a.configured() || !a.approved(c.TemplateID) {
			continue
		}
		c.Status = "sending"
		for i := range c.Recipients {
			rc := &c.Recipients[i]
			if rc.Status != "pending" {
				continue
			}
			valid, e := a.recipientEligible(ctx, c, *rc)
			if e != nil {
				c.Error = "contact register unavailable; pending recipients paused"
				a.s.mustSave()
				return
			}
			if !valid {
				rc.Status = "skipped"
				a.s.mustSave()
				continue
			}
			rc.Status = "inflight"
			a.s.Known[rc.Email] = true
			link := a.campaignLink(c, rc.Email)
			a.s.mustSave()
			rc.Status = a.mail(ctx, rc.Email, rc.Name, c.Subject, templateInfo{HTML: c.TemplateHTML, Text: c.TemplateText}, c.Variables, link)
			if rc.Status != "sent" {
				rc.Error = "provider " + rc.Status + "; no automatic retry"
			}
			a.s.mustSave()
			// Yield between recipients so optouts/webhooks are applied before the next send.
			return
		}
		c.Status = "sent"
		c.Error = ""
		for _, rc := range c.Recipients {
			if rc.Status == "unknown" || rc.Status == "failed" {
				c.Status = "completed_with_errors"
				c.Error = "Inspect recipient results; unknown delivery is not safe to retry"
			}
		}
		c.UpdatedAt = now()
		a.s.mustSave()
	}
}
