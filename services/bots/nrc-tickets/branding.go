package main

import (
	"bytes"
	_ "embed"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
)

//go:embed web/style.css
var portalCSS []byte

//go:embed web/attachments.js
var portalAttachmentsJS []byte

// Same operator-owned theme/logo/footer contract as nrc-publish. CSS stays a
// stylesheet response, never trusted HTML interpolated into the page.
type branding struct {
	Brand, FooterText, ImprintURL, PrivacyURL, TermsURL, ContactURL string
	ThemeCSS, Logo, LoginImage, FontRegular, FontBold               []byte
}

func loadBranding() (branding, error) {
	b := branding{Brand: os.Getenv("TICKETS_BRAND"), FooterText: os.Getenv("TICKETS_FOOTER_TEXT"),
		ImprintURL: os.Getenv("TICKETS_IMPRINT_URL"), PrivacyURL: os.Getenv("TICKETS_PRIVACY_URL"),
		TermsURL: os.Getenv("TICKETS_TERMS_URL"), ContactURL: os.Getenv("TICKETS_CONTACT_URL")}
	if b.Brand == "" {
		b.Brand = "Ihr Kundenportal"
	}
	for _, value := range []string{b.ImprintURL, b.PrivacyURL, b.TermsURL, b.ContactURL} {
		if value == "" {
			continue
		}
		u, err := url.Parse(value)
		if err != nil || strings.ContainsAny(value, "\\\r\n\t") || u.User != nil ||
			!((u.Scheme == "https" || u.Scheme == "http") && u.Host != "" || u.Scheme == "" && u.Host == "" && strings.HasPrefix(value, "/") && !strings.HasPrefix(value, "//")) {
			return b, fmt.Errorf("footer URLs must be HTTP(S) URLs or root-relative paths")
		}
	}
	for _, setting := range []struct {
		env string
		max int64
		dst *[]byte
	}{
		{"TICKETS_THEME_FILE", 256 * 1024, &b.ThemeCSS}, {"TICKETS_LOGO_FILE", 2 * 1024 * 1024, &b.Logo},
		{"TICKETS_LOGIN_IMAGE_FILE", 2 * 1024 * 1024, &b.LoginImage},
		{"TICKETS_FONT_REGULAR_FILE", 512 * 1024, &b.FontRegular}, {"TICKETS_FONT_BOLD_FILE", 512 * 1024, &b.FontBold},
	} {
		if path := os.Getenv(setting.env); path != "" {
			file, err := os.Open(path)
			if err != nil {
				return b, fmt.Errorf("read %s: %w", setting.env, err)
			}
			data, err := io.ReadAll(io.LimitReader(file, setting.max+1))
			file.Close()
			if err != nil || int64(len(data)) > setting.max {
				return b, fmt.Errorf("invalid or oversized %s", setting.env)
			}
			*setting.dst = data
		}
	}
	for name, image := range map[string][]byte{"TICKETS_LOGO_FILE": b.Logo, "TICKETS_LOGIN_IMAGE_FILE": b.LoginImage} {
		if len(image) == 0 {
			continue
		}
		switch http.DetectContentType(image) {
		case "image/png", "image/jpeg", "image/webp":
		default:
			return b, fmt.Errorf("%s must be PNG, JPEG or WebP", name)
		}
	}
	for name, font := range map[string][]byte{"TICKETS_FONT_REGULAR_FILE": b.FontRegular, "TICKETS_FONT_BOLD_FILE": b.FontBold} {
		if len(font) > 0 && !bytes.HasPrefix(font, []byte("wOF2")) {
			return b, fmt.Errorf("%s must be WOFF2", name)
		}
	}
	return b, nil
}
