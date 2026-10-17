package main

import (
	"net/http"
	"strings"
	"time"
)

type consentImportRecord struct {
	Email       string `json:"email"`
	Source      string `json:"source"`
	ConfirmedAt string `json:"confirmed_at"`
	Evidence    string `json:"evidence"`
	Scope       string `json:"scope"`
	ExternalID  string `json:"external_id"`
}

type consentImportResult struct {
	Email  string `json:"email"`
	Status string `json:"status"`
	Reason string `json:"reason"`
}

// Original proof remains immutable across optout and subsequent DOI requests.
type importedConsent struct {
	consentImportRecord
	ImportedAt string `json:"imported_at"`
}

// importConsents is mounted only behind the authenticated admin handler. Neither
// preview nor confirmation sends mail; confirmation records existing permission.
func (a *app) importConsents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		fail(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	var input struct {
		Records []consentImportRecord `json:"records"`
		Confirm bool                  `json:"confirm"`
	}
	if !decode(w, r, &input) {
		return
	}
	if len(input.Records) == 0 || len(input.Records) > 200 {
		fail(w, 400, "between 1 and 200 consent records required")
		return
	}
	// Validate the complete batch before reading or mutating durable state.
	seen := map[string]consentImportRecord{}
	checkedAt := time.Now()
	for i := range input.Records {
		v := &input.Records[i]
		v.Email = normalize(v.Email)
		stamp, err := time.Parse(time.RFC3339, v.ConfirmedAt)
		if !validEmail(v.Email) || err != nil || stamp.After(checkedAt) ||
			strings.TrimSpace(v.Source) == "" || len(v.Source) > 1000 ||
			strings.TrimSpace(v.Evidence) == "" || len(v.Evidence) > 4000 ||
			strings.TrimSpace(v.Scope) == "" || len(v.Scope) > 1000 || len(v.ExternalID) > 256 {
			fail(w, 400, "invalid consent record: valid email, past RFC3339 confirmation, source, evidence and scope required")
			return
		}
		if previous, ok := seen[v.Email]; ok && previous != *v {
			fail(w, 400, "conflicting duplicate consent records")
			return
		}
		seen[v.Email] = *v
	}
	contacts, err := a.source.contacts(r.Context())
	if err != nil {
		fail(w, 503, "contact register unavailable")
		return
	}
	live := map[string]bool{}
	for _, ct := range contacts {
		live[normalize(ct.Email)] = true
	}
	a.s.mu.Lock()
	defer a.s.mu.Unlock()
	results := make([]consentImportResult, 0, len(input.Records))
	counts := map[string]int{"total": len(input.Records), "eligible": 0, "imported": 0, "skipped": 0}
	processed := map[string]bool{}
	importedAt := now()
	for _, v := range input.Records {
		result := consentImportResult{Email: v.Email, Status: "skipped"}
		switch {
		case processed[v.Email]:
			result.Reason = "duplicate"
		case !live[v.Email]:
			result.Reason = "unknown_contact"
		default:
			if c := a.s.Consent[v.Email]; c != nil && (c.Status == "blocked" || c.Status == "unsubscribed" || c.Status == "subscribed") {
				result.Reason = c.Status
			} else if c != nil && c.Imported != nil {
				result.Reason = "previous_import"
			} else if c != nil && c.ImportSuppressed {
				result.Reason = "unsubscribed"
			} else {
				counts["eligible"]++
				result.Status, result.Reason = "eligible", "matched_contact"
				if input.Confirm {
					a.s.Consent[v.Email] = &consent{Status: "subscribed", Source: v.Source, ConfirmedAt: v.ConfirmedAt,
						Imported: &importedConsent{consentImportRecord: v, ImportedAt: importedAt}}
					a.s.Known[v.Email] = true
					counts["imported"]++
					result.Status = "imported"
				}
			}
		}
		processed[v.Email] = true
		if result.Status == "skipped" {
			counts["skipped"]++
		}
		results = append(results, result)
	}
	if counts["imported"] > 0 {
		a.s.mustSave()
	}
	reply(w, 200, map[string]any{"records": results, "counts": counts, "confirm": input.Confirm})
}
