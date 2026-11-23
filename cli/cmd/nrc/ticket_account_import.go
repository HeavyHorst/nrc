package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	p "github.com/heavyhorst/nrc/protocol-go"
	"golang.org/x/crypto/bcrypt"
)

func validatePortalAccountMetadata(a p.PortalAccount) error {
	valid := func(v string, limit int) bool {
		return v != "" && utf8.ValidString(v) && len(v) <= limit && strings.TrimSpace(v) == v && strings.IndexFunc(v, unicode.IsControl) < 0
	}
	if !valid(a.Login, 320) || strings.Contains(a.Login, ":") {
		return errors.New("invalid login (1–320 bytes, no colon)")
	}
	if !valid(a.Requester, 320) || strings.ToLower(a.Requester) != a.Requester {
		return errors.New("invalid requester (use a trimmed lower-case identity, 1–320 bytes)")
	}
	if !valid(a.Name, 256) {
		return errors.New("invalid display name (1–256 bytes)")
	}
	decimal := func(v string) bool {
		n, err := strconv.ParseUint(v, 10, 64)
		return v == "" || err == nil && n > 0 && strconv.FormatUint(n, 10) == v
	}
	if !decimal(a.CompanyID) || !decimal(a.ContactID) || (a.ContactID != "" && a.CompanyID == "") {
		return errors.New("company and contact IDs must be canonical positive decimals; contact requires company")
	}
	return nil
}

var portalAccountBcryptEncoding = base64.NewEncoding("./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789").WithPadding(base64.NoPadding).Strict()

func validPortalAccountHash(hash string) bool {
	if len(hash) != 60 || (hash[:4] != "$2a$" && hash[:4] != "$2b$" && hash[:4] != "$2y$") || hash[6] != '$' {
		return false
	}
	cost, err := bcrypt.Cost([]byte(hash))
	if err != nil || cost < portalAccountBcryptCost || cost > 16 {
		return false
	}
	_, saltErr := portalAccountBcryptEncoding.DecodeString(hash[7:29])
	_, hashErr := portalAccountBcryptEncoding.DecodeString(hash[29:])
	return saltErr == nil && hashErr == nil && !strings.ContainsAny(hash, "\r\n")
}

func readPortalAccountImport(path string) ([]p.PortalAccount, error) {
	// Check before opening to avoid blocking on a named pipe; check again on the
	// actual opened descriptor before reading any data.
	private := func(info os.FileInfo, err error) bool {
		return err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0077 == 0
	}
	const privateError = "import requires a private regular file (mode 0600 or 0400)"
	if !private(os.Stat(path)) {
		return nil, errors.New(privateError)
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, errors.New("could not open private account file")
	}
	defer f.Close()
	if !private(f.Stat()) {
		return nil, errors.New(privateError)
	}
	const maxFile = 1 << 20
	data, err := io.ReadAll(io.LimitReader(f, maxFile+1))
	defer clear(data)
	if err != nil || len(data) > maxFile || !utf8.Valid(data) {
		return nil, errors.New("account file must be readable UTF-8 JSON and no larger than 1 MiB")
	}
	return decodePortalAccountImport(data)
}

func decodePortalAccountImport(data []byte) ([]p.PortalAccount, error) {
	d := json.NewDecoder(bytes.NewReader(data))
	if t, err := d.Token(); err != nil || t != json.Delim('[') {
		return nil, errors.New("account file must contain a JSON array of legacy bcrypt accounts")
	}
	var accounts []p.PortalAccount
	logins, requesters, contacts := map[string]bool{}, map[string]bool{}, map[string]bool{}
	for d.More() {
		if len(accounts) == p.PortalAccountImportLimit {
			return nil, fmt.Errorf("account import accepts at most %d accounts", p.PortalAccountImportLimit)
		}
		a, err := decodePortalAccountImportRow(d)
		if err == nil {
			err = validatePortalAccountMetadata(a)
		}
		if err == nil && !validPortalAccountHash(a.PasswordHash) {
			err = errors.New("invalid bcrypt password hash (cost must be 12–16)")
		}
		if err == nil && (logins[a.Login] || requesters[a.Requester] || (a.ContactID != "" && contacts[a.ContactID])) {
			err = errors.New("duplicate login, requester, or contact")
		}
		if err != nil {
			return nil, fmt.Errorf("account %d: %w", len(accounts)+1, err)
		}
		logins[a.Login], requesters[a.Requester], contacts[a.ContactID] = true, true, true
		accounts = append(accounts, a)
	}
	if t, err := d.Token(); err != nil || t != json.Delim(']') {
		return nil, errors.New("invalid account array")
	}
	if _, err := d.Token(); err != io.EOF {
		return nil, errors.New("trailing data after account array")
	}
	if len(accounts) == 0 {
		return nil, errors.New("account import must contain at least one account")
	}
	return accounts, nil
}

// Reject unknown fields, duplicate keys, and null values without surfacing any
// decoder errors that might contain part of the sensitive input.
func decodePortalAccountImportRow(d *json.Decoder) (p.PortalAccount, error) {
	var a p.PortalAccount
	if t, err := d.Token(); err != nil || t != json.Delim('{') {
		return a, errors.New("expected an account object")
	}
	fields := map[string]*string{"login": &a.Login, "requester": &a.Requester, "name": &a.Name, "company_id": &a.CompanyID, "contact_id": &a.ContactID, "password_hash": &a.PasswordHash}
	for d.More() {
		t, err := d.Token()
		key, ok := t.(string)
		dst := fields[key]
		if err != nil || !ok || dst == nil {
			return a, errors.New("invalid, unknown, or duplicate account field")
		}
		delete(fields, key)
		var value *string
		if d.Decode(&value) != nil || value == nil {
			return a, errors.New("account fields must be strings")
		}
		*dst = *value
	}
	if t, err := d.Token(); err != nil || t != json.Delim('}') {
		return a, errors.New("invalid account object")
	}
	return a, nil
}
