package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

// The preview uses the real handlers/templates/store but only synthetic content.
// It is opt-in, lives in the test binary, and never seeds a deployment database.
func TestBrowserPreview(t *testing.T) {
	if os.Getenv("PUBLISH_BROWSER_PREVIEW") != "1" {
		t.Skip("opt-in browser fixture")
	}
	a := testApp(t)
	a.cfg.JWTSecret = os.Getenv("PUBLISH_PREVIEW_JWT_SECRET")
	a.cfg.JWTIssuer = "nrc-tailscale-proxy"
	a.cfg.Workspace = "test-workspace"
	a.cfg.ReviewURL = "http://" + env("PUBLISH_PREVIEW_ADMIN_ADDR", "127.0.0.1:8094")
	src := a.source.(*fixtureSource)
	body := "## Voraussetzungen\n\nSie benötigen ein Benutzerkonto und die Berechtigung, Integrationen zu verwalten.\n\n## Schlüssel erstellen\n\n1. Öffnen Sie die Einstellungen Ihrer Anwendung.\n2. Wählen Sie **Integrationen → API-Schlüssel**.\n3. Geben Sie einen aussagekräftigen Namen ein und erstellen Sie den Schlüssel.\n4. Kopieren Sie den Schlüssel und bewahren Sie ihn sicher auf.\n\n> **Wichtig:** Teilen Sie Ihren Schlüssel nicht mit anderen. Das folgende Beispiel ist illustrative Dokumentation, keine NRC-API.\n\n## Erster Request\n\nSenden Sie den Schlüssel im Authorization-Header Ihrer Anfrage:\n\n```bash\ncurl -H \"Authorization: Bearer YOUR_API_KEY\" \\\n  https://api.example.com/v1/items\n```\n\n## Nächste Schritte\n\nLesen Sie die [API-Referenz](/articles/api-referenz) für weitere Beispiele."
	fixtures := []revision{
		{SourceID: 1, Slug: "konto-einrichten", Title: "Ihr Konto einrichten", Category: "Erste Schritte", Kind: "Anleitung", Summary: "In wenigen Schritten bereit für die tägliche Arbeit.", Markdown: "## Willkommen\n\nRichten Sie Ihr Konto ein und ergänzen Sie Ihre Profildaten.\n\n## Loslegen\n\nÖffnen Sie Ihre Anwendung und folgen Sie den Einrichtungsschritten."},
		{SourceID: 2, Slug: "benutzer-rechte", Title: "Benutzer und Rechte verstehen", Category: "Erste Schritte", Kind: "Anleitung", Summary: "Zugriffe im Team sinnvoll organisieren.", Markdown: "## Berechtigungen\n\nWählen Sie die passenden Rechte für Ihre Teammitglieder."},
		{SourceID: 3, Slug: "dateien-verwalten", Title: "Dateien verwalten und teilen", Category: "Anleitungen", Kind: "Anleitung", Summary: "Dokumente hinzufügen und Informationen gemeinsam nutzen.", Markdown: "## Dateien hinzufügen\n\nLaden Sie Ihre Dokumente in der Anwendung hoch.\n\n## Teilen\n\nPrüfen Sie vor dem Teilen die Zugriffsrechte."},
		{SourceID: 4, Slug: "api-schluessel", Title: "API-Schlüssel erstellen", Category: "API & Integrationen", Kind: "Anleitung", Summary: "Verbinden Sie Ihre Anwendung sicher mit anderen Systemen.", Markdown: body},
		{SourceID: 5, Slug: "api-referenz", Title: "API-Referenz", Category: "API & Integrationen", Kind: "Referenz", Summary: "Endpunkte, Parameter und Antworten im Überblick.", Markdown: "## Überblick\n\nDies ist eine Beispieldokumentation.\n\n## Anfragen\n\nVerwenden Sie einen gültigen API-Schlüssel."},
		{SourceID: 6, Slug: "webhooks", Title: "Mit Webhooks auf Ereignisse reagieren", Category: "API & Integrationen", Kind: "Anleitung", Summary: "Automatisierungen mit Ereignissen verbinden.", Markdown: "## Ereignisse\n\nDies ist ein illustrativer Artikel zu Integrationen."},
		{SourceID: 7, Slug: "verbindungsprobleme", Title: "Verbindungsprobleme beheben", Category: "Fehlerbehebung", Kind: "Fehlerbehebung", Summary: "Schritt für Schritt wieder verbunden.", Markdown: "## Verbindung prüfen\n\nPrüfen Sie zunächst Ihre Internetverbindung.\n\n## Erneut verbinden\n\nLaden Sie die Anwendung neu."},
	}
	// NRC's REF-generated links exercise real snapshot media serving in the browser.
	a.cfg.FilesDir = t.TempDir()
	var picture bytes.Buffer
	img := image.NewRGBA(image.Rect(0, 0, 320, 100))
	draw.Draw(img, img.Bounds(), image.NewUniform(color.RGBA{245, 237, 220, 255}), image.Point{}, draw.Src)
	draw.Draw(img, image.Rect(20, 25, 130, 75), image.NewUniform(color.RGBA{230, 90, 35, 255}), image.Point{}, draw.Src)
	draw.Draw(img, image.Rect(190, 25, 300, 75), image.NewUniform(color.RGBA{45, 55, 65, 255}), image.Point{}, draw.Src)
	if err := png.Encode(&picture, img); err != nil {
		t.Fatal(err)
	}
	fixtures[2].Markdown += "\n\n![Beispielabbildung](att:1)\n\n[Beispieldatei herunterladen](att:0)"
	fixtures[2].Attachments = []protocol.Attachment{{FileId: "att_manual", Filename: "beispiel.txt"}, {FileId: "att_diagram", Filename: "beispiel.png"}}
	for i, attachment := range fixtures[2].Attachments {
		data := []byte("Synthetische Beispieldatei\n")
		if i == 1 {
			data = picture.Bytes()
		}
		if err := os.WriteFile(filepath.Join(a.cfg.FilesDir, attachment.FileId), data, 0600); err != nil {
			t.Fatal(err)
		}
		grantDir := filepath.Join(a.cfg.FilesDir, ".workspace-access", attachment.FileId)
		if err := os.MkdirAll(grantDir, 0700); err != nil {
			t.Fatal(err)
		}
		hash := sha256.Sum256([]byte(a.cfg.Workspace))
		if err := os.WriteFile(filepath.Join(grantDir, hex.EncodeToString(hash[:])), []byte(a.cfg.Workspace), 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, r := range fixtures {
		meta, _ := json.Marshal(map[string]string{"title": r.Title, "format": "markdown"})
		note := src.assets[41]
		note.AssetID = r.SourceID
		note.Preview = string(meta)
		note.Payload = r.Markdown
		note.Attachments = r.Attachments
		src.assets[r.SourceID] = note
		r.SourceUpdated = 100
		r.CreatedBy = "reviewer"
		draft, err := a.store.create(r, a.cfg.FilesDir)
		if err != nil {
			t.Fatal(err)
		}
		if err := a.store.approve(draft.ID, "reviewer"); err != nil {
			t.Fatal(err)
		}
	}
	// One pending update makes the actual review interface inspectable.
	r := fixtures[3]
	r.Markdown = body + "\n\n## Schlüssel widerrufen\n\nNicht mehr benötigte Schlüssel können Sie in den Integrationseinstellungen widerrufen."
	r.CreatedBy = "reviewer"
	r.SourceUpdated = 100
	if _, err := a.store.create(r, ""); err != nil {
		t.Fatal(err)
	}
	public := &http.Server{Addr: env("PUBLISH_PREVIEW_ADDR", "127.0.0.1:8093"), Handler: a.public()}
	admin := &http.Server{Addr: env("PUBLISH_PREVIEW_ADMIN_ADDR", "127.0.0.1:8094"), Handler: a.admin()}
	t.Cleanup(func() { public.Close(); admin.Close() })
	go admin.ListenAndServe()
	t.Log("Synthetic public preview", public.Addr, "and authenticated admin preview", admin.Addr)
	if err := public.ListenAndServe(); err != http.ErrServerClosed {
		t.Fatal(err)
	}
}
