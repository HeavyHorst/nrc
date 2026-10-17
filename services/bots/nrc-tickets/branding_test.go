package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBrandingConfigurationAndHTTP(t *testing.T) {
	s, _ := fixture(t)
	if w := own(s, "GET", "/", ""); strings.Contains(w.Body.String(), "<footer>") || strings.Contains(w.Body.String(), "/branding/logo") {
		t.Fatal("default branding should have no footer or logo")
	}
	t.Setenv("TICKETS_BRAND", "Example & Co")
	t.Setenv("TICKETS_FOOTER_TEXT", "© Example <Team>")
	t.Setenv("TICKETS_IMPRINT_URL", "https://example.org/impressum")
	t.Setenv("TICKETS_PRIVACY_URL", "/datenschutz")
	t.Setenv("TICKETS_TERMS_URL", "https://example.org/terms")
	t.Setenv("TICKETS_CONTACT_URL", "https://example.org/contact")
	dir := t.TempDir()
	css := []byte(":root { --accent: #773366; --header-background: #281828; }")
	logo := []byte("\x89PNG\r\n\x1a\nlogo-fixture")
	for _, file := range []struct {
		env, name string
		data      []byte
	}{
		{"TICKETS_THEME_FILE", "theme.css", css}, {"TICKETS_LOGO_FILE", "logo.png", logo},
	} {
		path := filepath.Join(dir, file.name)
		if err := os.WriteFile(path, file.data, 0600); err != nil {
			t.Fatal(err)
		}
		t.Setenv(file.env, path)
	}
	brand, err := loadBranding()
	if err != nil {
		t.Fatal(err)
	}
	s.brand = brand
	for _, path := range []string{"/", "/new", "/tickets/1"} {
		w := own(s, "GET", path, "")
		if w.Code != 200 {
			t.Fatal(w.Code, w.Body)
		}
		for _, want := range []string{"Example &amp; Co", "© Example &lt;Team&gt;", `href="https://example.org/impressum"`, `href="/datenschutz"`, `href="https://example.org/terms"`, `href="https://example.org/contact"`, `src="/branding/logo"`, `href="/style.css"`} {
			if !strings.Contains(w.Body.String(), want) {
				t.Fatal(path, "missing branding", want)
			}
		}
		if policy := w.Header().Get("Content-Security-Policy"); strings.Contains(policy, "unsafe-inline") || !strings.Contains(policy, "img-src 'self'") {
			t.Fatal("branding weakened CSP", policy)
		}
	}
	w := own(s, "GET", "/style.css", "")
	if w.Code != 200 || !bytes.HasSuffix(w.Body.Bytes(), css) || w.Header().Get("Content-Type") != "text/css; charset=utf-8" {
		t.Fatal("theme not applied after defaults")
	}
	w = own(s, "GET", "/branding/logo", "")
	if w.Code != 200 || !bytes.Equal(w.Body.Bytes(), logo) || w.Header().Get("Content-Type") != "image/png" {
		t.Fatal("logo response mismatch")
	}
	if w := own(s, "GET", "/api/tickets/1", ""); strings.Contains(w.Body.String(), "ThemeCSS") || strings.Contains(w.Body.String(), "Example") {
		t.Fatal("branding config leaked into ticket API")
	}
}

func TestBrandingRejectsUnsafeConfig(t *testing.T) {
	for _, invalid := range []string{"javascript:alert(1)", "//evil.example/", "https://user:pass@example.org/", "/\\evil.example", "https://example.org/\n"} {
		t.Setenv("TICKETS_PRIVACY_URL", invalid)
		if _, err := loadBranding(); err == nil {
			t.Fatal("unsafe footer URL accepted", invalid)
		}
	}
	t.Setenv("TICKETS_PRIVACY_URL", "")
	path := filepath.Join(t.TempDir(), "logo.svg")
	if err := os.WriteFile(path, []byte(`<svg xmlns="http://www.w3.org/2000/svg"><script/></svg>`), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TICKETS_LOGO_FILE", path)
	if _, err := loadBranding(); err == nil {
		t.Fatal("active logo type accepted")
	}
}
