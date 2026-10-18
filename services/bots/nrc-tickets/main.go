package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
)

type account struct {
	Login        string `json:"login"`
	PasswordHash string `json:"password_hash"`
	Requester    string `json:"requester"`
	Name         string `json:"name"`
	CompanyID    string `json:"company_id"`
	ContactID    string `json:"contact_id,omitempty"`
}

func decimal(s string) bool {
	if s == "" {
		return true
	}
	n, e := strconv.ParseUint(s, 10, 64)
	return e == nil && n > 0 && strconv.FormatUint(n, 10) == s
}
func loadAccounts(path string) ([]account, error) {
	f, e := os.Open(path)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	st, e := f.Stat()
	if e != nil || st.Mode().Perm()&0077 != 0 {
		return nil, errors.New("accounts file must be private (0600 or 0400)")
	}
	var a []account
	d := json.NewDecoder(io.LimitReader(f, 1<<20))
	d.DisallowUnknownFields()
	if e = d.Decode(&a); e != nil {
		return nil, e
	}
	if d.Decode(new(any)) != io.EOF {
		return nil, errors.New("trailing accounts data")
	}
	if len(a) == 0 {
		return nil, errors.New("no accounts configured")
	}
	seen := map[string]bool{}
	identities := map[string]bool{}
	contacts := map[string]bool{}
	for _, v := range a {
		cost, e := bcrypt.Cost([]byte(v.PasswordHash))
		if v.Login == "" || len(v.Login) > 320 || strings.Contains(v.Login, ":") || seen[v.Login] || identities[v.Requester] || v.Requester == "" || len(v.Requester) > 320 || strings.TrimSpace(v.Requester) != v.Requester || strings.ToLower(v.Requester) != v.Requester || v.Name == "" || len(v.Name) > 256 || !decimal(v.CompanyID) || e != nil || cost < 12 || cost > 16 {
			return nil, errors.New("invalid or duplicate account")
		}
		if !decimal(v.ContactID) || v.ContactID != "" && (v.CompanyID == "" || contacts[v.ContactID]) {
			return nil, errors.New("contact_id requires company_id and a unique canonical contact ID")
		}
		seen[v.Login] = true
		identities[v.Requester] = true
		if v.ContactID != "" {
			contacts[v.ContactID] = true
		}
	}
	return a, nil
}

// Provision a complete accounts file from a private JSON input on stdin. No
// password argument, environment variable, public registration or default login.
func provision(path string) error {
	var in []struct {
		Login, Password, Requester, Name string
		CompanyID                        string `json:"company_id"`
		ContactID                        string `json:"contact_id"`
	}
	d := json.NewDecoder(io.LimitReader(os.Stdin, 1<<20))
	d.DisallowUnknownFields()
	if e := d.Decode(&in); e != nil {
		return e
	}
	if d.Decode(new(any)) != io.EOF {
		return errors.New("trailing provisioning data")
	}
	var out []account
	for _, v := range in {
		if len(v.Password) < 14 {
			return errors.New("password must have at least 14 bytes")
		}
		h, e := bcrypt.GenerateFromPassword([]byte(v.Password), 12)
		if e != nil {
			return e
		}
		out = append(out, account{v.Login, string(h), v.Requester, v.Name, v.CompanyID, v.ContactID})
	}
	f, e := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if e != nil {
		return e
	}
	e = json.NewEncoder(f).Encode(out)
	ce := f.Close()
	if e == nil {
		e = ce
	}
	if e == nil {
		_, e = loadAccounts(path)
	}
	if e != nil {
		os.Remove(path)
	}
	return e
}
func main() {
	output := flag.String("provision", "", "create a NEW private accounts file from JSON stdin")
	flag.Parse()
	if *output != "" {
		if e := provision(*output); e != nil {
			log.Fatal("account provisioning failed (check private input and output permissions)")
		}
		return
	}
	accounts, e := loadAccounts(os.Getenv("TICKETS_ACCOUNTS_FILE"))
	if e != nil {
		log.Fatal("valid private TICKETS_ACCOUNTS_FILE required")
	}
	origin := os.Getenv("TICKETS_ORIGIN")
	u, e := url.Parse(origin)
	if e != nil || u.Scheme != "https" || u.Host == "" || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || u.User != nil {
		log.Fatal("TICKETS_ORIGIN must be an HTTPS origin without path")
	}
	server := os.Getenv("NRC_SERVER")
	ws, e := url.Parse(server)
	if e != nil || (ws.Scheme != "ws" && ws.Scheme != "wss") || ws.Host == "" || ws.User != nil || ws.RawQuery != "" || ws.Fragment != "" {
		log.Fatal("NRC_SERVER required")
	}
	workspace, secret := os.Getenv("NRC_WORKSPACE"), os.Getenv("NRC_BOT_SECRET")
	if workspace == "" || secret == "" {
		log.Fatal("NRC_WORKSPACE and NRC_BOT_SECRET required")
	}
	filesURL := os.Getenv("FILES_URL")
	files, e := url.Parse(filesURL)
	if e != nil || (files.Scheme != "http" && files.Scheme != "https") || files.Host == "" || files.User != nil || files.RawQuery != "" || files.Fragment != "" || (files.Path != "" && files.Path != "/") {
		log.Fatal("FILES_URL must be the private NRC bot file-service HTTP(S) origin")
	}
	brand, e := loadBranding()
	if e != nil {
		log.Fatal(e)
	}
	app := &portal{source: nrcSource{strings.TrimRight(server, "/"), workspace, secret}, files: httpFiles{strings.TrimRight(filesURL, "/"), workspace, secret}, brand: brand, accounts: accounts, origin: origin}
	addr := os.Getenv("TICKETS_ADDR")
	if addr == "" {
		addr = ":8096"
	}
	srv := &http.Server{Addr: addr, Handler: app, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 2 * time.Minute, WriteTimeout: 5 * time.Minute, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10}
	fmt.Println("nrc-tickets listening; HTTPS reverse proxy required")
	log.Fatal(srv.ListenAndServe())
}
