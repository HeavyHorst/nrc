package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"net/url"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

func importRow(email string) consentImportRecord {
	return consentImportRecord{Email: email, Source: "Legacy signup form", ConfirmedAt: "2020-01-02T03:04:05Z", Evidence: "Double opt-in log entry 123", Scope: "Company newsletter", ExternalID: "legacy-123"}
}

func TestImportCannotBypassOptoutAfterReinvitation(t *testing.T) {
	for _, outcome := range []string{"success", "error"} {
		for _, origin := range []string{"admin", "public"} {
			t.Run(outcome+"/"+origin, func(t *testing.T) {
				f := setup(t)
				row := importRow("one@example.com")
				if origin == "admin" {
					expect(t, f.req("POST", "/api/subscribers/1/unsubscribe", `{}`), 200)
				} else {
					u, _ := url.Parse(f.a.unsubscribeLink(row.Email))
					expect(t, public(f.a, "POST", u.RequestURI()), 200)
				}
				f.outcome = outcome
				want := 200
				if outcome != "success" {
					want = 502
				}
				expect(t, f.req("POST", "/api/subscribers/1/invite", `{"source":"New individual request"}`), want)
				f.a.s.db.Close()
				s, err := openStore(f.path, "w")
				if err != nil {
					t.Fatal(err)
				}
				f.a.s = s
				for _, confirm := range []bool{false, true} {
					results, counts := importResults(t, importRequest(f.a, importBody([]consentImportRecord{row}, confirm)))
					if results[0].Status != "skipped" || results[0].Reason != "unsubscribed" || counts["eligible"] != 0 || counts["imported"] != 0 {
						t.Fatalf("import bypassed prior optout: %+v %+v", results, counts)
					}
				}
				if len(f.calls) != 1 {
					t.Fatal("import sent mail")
				}
				if outcome == "success" {
					msg := f.calls[0]["Messages"].([]any)[0].(map[string]any)
					token := regexp.MustCompile(`confirm\?token=([a-f0-9]+)`).FindStringSubmatch(msg["TextPart"].(string))[1]
					expect(t, public(f.a, "POST", "/confirm?token="+token), 200)
					results, _ := importResults(t, importRequest(f.a, importBody([]consentImportRecord{row}, true)))
					if results[0].Reason != "subscribed" {
						t.Fatal("fresh DOI did not reactivate subscription")
					}
				}
			})
		}
	}
}

func TestImportedProofSurvivesNewInvitations(t *testing.T) {
	for _, outcome := range []string{"success", "error"} {
		t.Run(outcome, func(t *testing.T) {
			f := setup(t)
			row := importRow("one@example.com")
			importResults(t, importRequest(f.a, importBody([]consentImportRecord{row}, true)))
			proof := *f.a.s.Consent[row.Email].Imported
			expect(t, f.req("POST", "/api/subscribers/1/unsubscribe", `{}`), 200)
			f.outcome = outcome
			want := 200
			if outcome != "success" {
				want = 502
			}
			expect(t, f.req("POST", "/api/subscribers/1/invite", `{"source":"New individual request"}`), want)
			results, _ := importResults(t, importRequest(f.a, importBody([]consentImportRecord{row}, true)))
			if results[0].Reason != "previous_import" {
				t.Fatal("import replaced pending DOI or original proof")
			}
			f.a.s.db.Close()
			s, err := openStore(f.path, "w")
			if err != nil {
				t.Fatal(err)
			}
			f.a.s = s
			c := s.Consent[row.Email]
			if c.Imported == nil || *c.Imported != proof || c.Source != "New individual request" || c.Status != "pending" {
				t.Fatalf("original proof lost: %+v", c)
			}
			if outcome == "success" {
				msg := f.calls[0]["Messages"].([]any)[0].(map[string]any)
				token := regexp.MustCompile(`confirm\?token=([a-f0-9]+)`).FindStringSubmatch(msg["TextPart"].(string))[1]
				expect(t, public(f.a, "POST", "/confirm?token="+token), 200)
				if *c.Imported != proof || c.ConfirmedAt == row.ConfirmedAt || c.Status != "subscribed" {
					t.Fatal("new confirmation mutated original proof")
				}
			}
		})
	}
}

func importRequest(a *app, body string) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/api/consents/import", strings.NewReader(body))
	r.Header.Set("X-NRC-Newsletter-Auth", assertion(a, "w"))
	a.adminHandler().ServeHTTP(w, r)
	return w
}

func importBody(rows []consentImportRecord, confirm bool) string {
	b, _ := json.Marshal(map[string]any{"records": rows, "confirm": confirm})
	return string(b)
}

func importResults(t *testing.T, w *httptest.ResponseRecorder) ([]consentImportResult, map[string]int) {
	t.Helper()
	expect(t, w, 200)
	var result struct {
		Records []consentImportResult `json:"records"`
		Counts  map[string]int        `json:"counts"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	return result.Records, result.Counts
}

func TestImportPreviewConfirmationAndReopen(t *testing.T) {
	f := setup(t)
	rows := []consentImportRecord{importRow("  ONE@Example.com  "), importRow("unknown@example.com"), importRow("one@example.com")}
	// Omitted confirmation is a preview, including normalized email deduplication.
	b, _ := json.Marshal(map[string]any{"records": rows})
	results, counts := importResults(t, importRequest(f.a, string(b)))
	if counts["eligible"] != 1 || counts["skipped"] != 2 || counts["imported"] != 0 || results[0].Email != "one@example.com" || results[0].Status != "eligible" || results[1].Reason != "unknown_contact" || results[2].Reason != "duplicate" {
		t.Fatalf("preview: %+v %+v", results, counts)
	}
	if len(f.a.s.Consent) != 0 || len(f.a.s.Known) != 0 {
		t.Fatal("preview mutated state")
	}
	results, counts = importResults(t, importRequest(f.a, importBody(rows, true)))
	if counts["imported"] != 1 || results[0].Status != "imported" || f.a.s.Consent["unknown@example.com"] != nil {
		t.Fatalf("confirmation: %+v %+v", results, counts)
	}
	f.a.s.db.Close()
	s, err := openStore(f.path, "w")
	if err != nil {
		t.Fatal(err)
	}
	f.a.s = s
	c := s.Consent["one@example.com"]
	if c == nil || c.Status != "subscribed" || c.Source != rows[0].Source || c.ConfirmedAt != rows[0].ConfirmedAt || c.Imported == nil || c.Imported.consentImportRecord != importRow("one@example.com") || !s.Known["one@example.com"] {
		t.Fatalf("lost durable provenance: %+v", c)
	}
	if _, err := time.Parse(time.RFC3339, c.Imported.ImportedAt); err != nil {
		t.Fatalf("invalid import timestamp: %q", c.Imported.ImportedAt)
	}
	before := *c
	rows[0].Evidence = "Must not replace existing evidence"
	results, _ = importResults(t, importRequest(f.a, importBody(rows[:1], true)))
	if results[0].Reason != "subscribed" || *s.Consent["one@example.com"] != before {
		t.Fatal("repeat import overwrote existing subscription")
	}
	// Imported addresses participate in the ordinary signed public optout flow.
	u, _ := url.Parse(f.a.unsubscribeLink("one@example.com"))
	expect(t, public(f.a, "POST", u.RequestURI()), 200)
	results, _ = importResults(t, importRequest(f.a, importBody(rows[:1], true)))
	if results[0].Reason != "unsubscribed" || *s.Consent["one@example.com"].Imported != *before.Imported || s.Consent["one@example.com"].Status != "unsubscribed" {
		t.Fatal("import bypassed public unsubscribe")
	}
	if len(f.calls) != 0 {
		t.Fatal("import sent mail")
	}
}

func TestImportValidationIsAtomic(t *testing.T) {
	f := setup(t)
	good := importRow("one@example.com")
	for _, field := range []string{"Email", "ConfirmedAt", "Source", "Evidence", "Scope", "ExternalID"} {
		for _, value := range []string{"", strings.Repeat("x", 4001)} {
			if field == "ExternalID" && value == "" {
				continue // External IDs are optional.
			}
			t.Run(field+"/length="+strconv.Itoa(len(value)), func(t *testing.T) {
				bad := importRow("three@example.com")
				reflect.ValueOf(&bad).Elem().FieldByName(field).SetString(value)
				expect(t, importRequest(f.a, importBody([]consentImportRecord{good, bad}, true)), 400)
				if len(f.a.s.Consent) != 0 || len(f.a.s.Known) != 0 {
					t.Fatal("invalid batch partially imported")
				}
			})
		}
	}
	future := good
	future.ConfirmedAt = time.Now().Add(time.Hour).Format(time.RFC3339)
	blank := good
	blank.Evidence = " \t\n"
	conflict := good
	conflict.Scope = "Different permission"
	tooMany := make([]consentImportRecord, 201)
	for i := range tooMany {
		tooMany[i] = good
	}
	for _, body := range []string{
		`{}`, `null`, `{"records":null}`, `{"records":[]}`, `{"records":[],"extra":true}`,
		`{"records":[{"email":"one@example.com","extra":true}]}`, `{"records":[],"confirm":"yes"}`, `{} {}`,
		importBody([]consentImportRecord{future}, true), importBody([]consentImportRecord{good, blank}, true),
		importBody([]consentImportRecord{good, conflict}, true), importBody(tooMany, true),
		`{"records":[],"padding":"` + strings.Repeat("x", 64<<10) + `"}`,
	} {
		expect(t, importRequest(f.a, body), 400)
		if len(f.a.s.Consent) != 0 || len(f.a.s.Known) != 0 {
			t.Fatal("invalid batch partially imported")
		}
	}
	w := httptest.NewRecorder()
	f.a.importConsents(w, httptest.NewRequest("GET", "/api/consents/import", nil))
	expect(t, w, 405)
}

type unavailableImportSource struct{}

func (unavailableImportSource) contacts(context.Context) ([]contact, error) {
	return nil, errors.New("unavailable")
}

func TestImportSuppressionAndSourceFailure(t *testing.T) {
	f := setup(t)
	for _, status := range []string{"unsubscribed", "blocked", "subscribed"} {
		original := consent{Status: status, Source: "Original", ConfirmedAt: "2019-01-01T00:00:00Z", TokenHash: "unchanged"}
		f.a.s.Consent["one@example.com"] = &original
		before := original
		results, counts := importResults(t, importRequest(f.a, importBody([]consentImportRecord{importRow("one@example.com")}, true)))
		if counts["skipped"] != 1 || results[0].Reason != status || *f.a.s.Consent["one@example.com"] != before {
			t.Fatalf("overwrote %s", status)
		}
	}
	delete(f.a.s.Consent, "one@example.com")
	f.a.source = unavailableImportSource{}
	expect(t, importRequest(f.a, importBody([]consentImportRecord{importRow("one@example.com")}, true)), 503)
	if len(f.a.s.Consent) != 0 || len(f.calls) != 0 {
		t.Fatal("source failure mutated consent or sent mail")
	}
}

func TestImportRechecksLiveContactsAndReplacesPending(t *testing.T) {
	f := setup(t)
	body := importBody([]consentImportRecord{importRow("three@example.com")}, true)
	importResults(t, importRequest(f.a, importBody([]consentImportRecord{importRow("three@example.com")}, false)))
	f.src.rows[2].Email = "changed@example.com"
	results, counts := importResults(t, importRequest(f.a, body))
	if counts["imported"] != 0 || results[0].Reason != "unknown_contact" {
		t.Fatal("confirmation used stale preview contacts")
	}
	f.src.rows[2].Email = "three@example.com"
	f.a.s.Consent["three@example.com"] = &consent{Status: "pending", TokenHash: "old-token", Expires: time.Now().Add(time.Hour).Unix()}
	_, counts = importResults(t, importRequest(f.a, body))
	c := f.a.s.Consent["three@example.com"]
	if counts["imported"] != 1 || c.Status != "subscribed" || c.TokenHash != "" || c.Expires != 0 {
		t.Fatal("pending invitation was not safely replaced")
	}
}
