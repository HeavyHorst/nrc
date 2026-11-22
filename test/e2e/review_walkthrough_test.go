package e2e

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	p "github.com/heavyhorst/nrc/protocol-go"
)

// TestReviewRealStackWalkthrough is deliberately opt-in: it starts a real Odin
// server and the real TLS review portal. Browser mutations use public UI only.
// NRC_REVIEW_SERVER_BIN can select an already-built binary to avoid a root build.
func TestReviewRealStackWalkthrough(t *testing.T) {
	if os.Getenv("NRC_REVIEW_WALKTHROUGH_E2E") != "1" {
		t.Skip("set NRC_REVIEW_WALKTHROUGH_E2E=1 (launches Odin, TLS portal and Chromium)")
	}
	bin := os.Getenv("NRC_REVIEW_SERVER_BIN")
	if bin == "" {
		bin = buildServerBinaryOnce(t)
	}
	proc, err := startServerProcessWithEnv(bin, t.TempDir(), map[string]string{"NRC_THREAD_COUNT": "2"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { proc.stop(t) })
	const workspace = "review-real-walkthrough"
	staff := workspaceDataClient(t, workspace, "qa-seed", 31)
	defer staff.Close()

	sections := []string{"Zugang & Navigation", "Stammdaten", "Rechnung & Steuern", "Versand & Export", "Berechtigungen", "Betrieb & Hilfe"}
	questions := [][]string{
		{"Funktioniert die Anmeldung?", "Ist die Abmeldung vollständig?", "Bleibt die Sitzung beim Seitenwechsel erhalten?", "Ist die Hauptnavigation verständlich?", "Funktioniert die Suche?", "Bleiben Filter beim Zurückgehen erhalten?", "Ist die Darstellung auf schmalem Bildschirm nutzbar?", "Sind Pflichtfelder erkennbar?"},
		{"Lässt sich ein Kunde anlegen?", "Bleibt der Firmenname sichtbar?", "Wird die Rechnungsadresse übernommen?", "Lässt sich ein Kontakt zuordnen?", "Werden Umlaute korrekt gespeichert?", "Wird eine ungültige E-Mail erkannt?", "Bleiben Änderungen nach Neuladen erhalten?", "Sind doppelte Kundennummern ausgeschlossen?"},
		{"Lässt sich eine Rechnung erstellen?", "Stimmen die Rechnungspositionen?", "Stimmt die Mehrwertsteuer im PDF?", "Wird der Bruttobetrag korrekt gerundet?", "Ist die Rechnungsnummer eindeutig?", "Stimmt das Zahlungsziel?", "Wird eine Gutschrift korrekt berechnet?", "Bleiben historische Rechnungen unverändert?"},
		{"Lässt sich die Rechnung versenden?", "Kommt die E-Mail beim Empfänger an?", "Ist der PDF-Anhang lesbar?", "Stimmt der CSV-Export?", "Bleiben Sonderzeichen im Export erhalten?", "Wird ein fehlgeschlagener Versand angezeigt?", "Ist ein erneuter Download möglich?", "Sind große Exporte vollständig?"},
		{"Sieht ein Nutzer nur seine Firma?", "Darf ein Leser keine Daten ändern?", "Kann ein Verantwortlicher freigeben?", "Ist ein gesperrtes Konto ausgeschlossen?", "Werden Rollenänderungen wirksam?", "Sind interne Notizen geschützt?", "Sind direkte Links ebenfalls geschützt?", "Ist die Änderungshistorie nachvollziehbar?"},
		{"Ist die Statusanzeige aktuell?", "Gibt es eine verständliche Fehlermeldung?", "Funktioniert ein erneuter Versuch?", "Bleiben Eingaben bei Fehlern erhalten?", "Ist die Hilfe erreichbar?", "Sind Kontaktinformationen aktuell?", "Ist die Wiederherstellung aus dem Backup geprüft?", "Ist die Betriebsübergabe dokumentiert?"},
	}
	form := p.ReviewForm{Version: 1, Title: "Kundenfreigabe · Rechnungsportal 2026.11", Build: "rc-2026.11.22", Environment: "Abnahmeumgebung · Musterfirma Nord"}
	for s, items := range questions {
		for _, question := range items {
			id := strconv.Itoa(len(form.Points) + 1)
			form.Points = append(form.Points, p.ReviewPoint{ID: id, Section: sections[s], Question: question, Instruction: "Prüfen Sie den Ablauf mit dem vereinbarten Testfall und dokumentieren Sie Abweichungen nachvollziehbar.", Expected: "Der vereinbarte Ablauf funktioniert ohne Datenverlust."})
		}
	}
	form.Points[18].Instruction = "Rechnung R-2026-104 öffnen, PDF herunterladen und Steuerzeile mit den Positionen vergleichen."
	form.Points[18].Expected = "Netto 100,00 € · 19 % MwSt. 19,00 € · Brutto 119,00 €."
	create := func(f p.ReviewForm, label string) string {
		created := reviewCall(t, staff, p.ReviewRequest{Op: "create", Form: f}, "ok")
		reviewCall(t, staff, p.ReviewRequest{Op: "release", FormID: created.FormID, IfRevision: created.Revision}, "ok")
		run := reviewCall(t, staff, p.ReviewRequest{Op: "run_create", FormID: created.FormID, Label: label, Kind: "customer"}, "ok").Run.ID
		reviewCall(t, staff, p.ReviewRequest{Op: "participant_add", RunID: run, Source: "portal", Identity: "anna@example.test", Name: "Anna · Teamverantwortliche", CanClose: true}, "ok")
		return run
	}
	run := create(form, "Musterfirma Nord · gemeinsame Kundenabnahme")
	reviewCall(t, staff, p.ReviewRequest{Op: "participant_add", RunID: run, Source: "staff", Identity: "qa-seed", Name: "QA-Team"}, "ok")
	// Existing team evidence, not guest progress: 45 passed, one not testable,
	// point 19 for the two browser users, and point 48 deliberately unanswered.
	for i := 1; i <= 47; i++ {
		if i == 19 {
			continue
		}
		result, comment := "yes", "Im vorbereitenden Teamtest geprüft."
		if i == 47 {
			result, comment = "unable", "Backupzugriff fehlt; Wiederherstellung im Nachtest prüfen."
		}
		reviewCall(t, staff, p.ReviewRequest{Op: "answer", RunID: run, PointID: strconv.Itoa(i), Result: result, Comment: comment}, "ok")
	}
	shortForm := p.ReviewForm{Version: 1, Title: "Kurzabnahme · Bestandsbogen", Build: "legacy-7", Environment: "Abnahmeumgebung", Points: []p.ReviewPoint{{ID: "1", Question: "Ist die Hilfe erreichbar?", Expected: "Die Hilfeseite öffnet sich."}, {ID: "2", Question: "Ist der Kontakt aktuell?", Expected: "Die Supportadresse ist erreichbar."}}}
	shortRun := create(shortForm, "Bestandskunde · kurzer Kontrollbogen")
	invite := reviewCall(t, staff, p.ReviewRequest{Op: "invite", RunID: run, ExpiresAt: strconv.FormatInt(time.Now().Add(8*time.Hour).UnixNano(), 10)}, "ok")
	portal, _ := reviewPortal(t, workspace)
	root := repoRootFromThisFile(t)
	fixture := map[string]string{"base": portal.URL, "token": invite.Token, "login": "anna", "password": reviewTestPassword, "runId": run, "shortRunId": shortRun, "title": form.Title, "shortTitle": shortForm.Title, "artifacts": filepath.Join(root, ".amp/in/artifacts/review-ux")}
	input, err := json.Marshal(fixture)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("node", filepath.Join(root, "services/bots/nrc-tickets/reviews.walkthrough.e2e.mjs"))
	cmd.Dir = root
	// Secrets stay off argv, URLs in test output, and disk fixtures.
	cmd.Stdin = bytes.NewReader(input)
	out, err := cmd.CombinedOutput()
	t.Logf("real-stack browser walkthrough:\n%s", out)
	if err != nil {
		t.Fatalf("browser walkthrough failed: %v", err)
	}
	persisted := reviewCall(t, staff, p.ReviewRequest{Op: "run_get", RunID: run}, "ok").Run
	if persisted.Decision != "conditional" || persisted.Comment != "Freigabe mit Vorbehalt: Steuerzeile im PDF korrigieren und im Nachtest belegen." || persisted.ClosedSource != "portal" {
		t.Fatalf("unexpected persisted closure: decision=%s source=%s", persisted.Decision, persisted.ClosedSource)
	}
	var guest, owner bool
	for _, a := range persisted.Answers {
		if a.PointID == "19" && a.Name == "Clara · Kundentest" && a.Result == "no" && a.Comment == "Nachprüfung 3: Steuerzeile fehlt weiterhin im PDF R-2026-104." {
			guest = true
		}
		if a.PointID == "19" && a.Result == "yes" && a.Comment == "In meiner Ansicht vorhanden; bitte PDF-Version gemeinsam vergleichen." {
			owner = true
		}
	}
	if !guest || !owner {
		t.Fatalf("persisted own/team evidence missing: guest=%v owner=%v", guest, owner)
	}
	t.Log("real Odin persistence confirmed: both point-19 contributions and unchanged conditional closure comment")
}
