package main

import (
	"context"
	"encoding/hex"
	"errors"
	"net/netip"
	"net/url"
	"os"
	"strings"
	"unicode"
	"unicode/utf8"

	p "github.com/heavyhorst/nrc/protocol-go"
	"golang.org/x/crypto/bcrypt"
)

// A missing account is distinct from an unavailable backend. Only a confirmed
// miss can be treated as an unregistered email sender.
type accountStore interface {
	login(context.Context, string) (account, bool, error)
	mapping(context.Context, string) (account, bool, error)
}

type fileAccounts []account

func (a fileAccounts) login(_ context.Context, login string) (account, bool, error) {
	for _, v := range a {
		if v.Login == login {
			return v, true, nil
		}
	}
	return account{}, false, nil
}

func (a fileAccounts) mapping(_ context.Context, requester string) (account, bool, error) {
	for _, v := range a {
		if v.Requester == requester {
			v.PasswordHash = ""
			return v, true, nil
		}
	}
	return account{}, false, nil
}

type dbAccounts struct {
	source nrcSource
	key    string
}

func configuredAccounts(source nrcSource) (accountStore, error) {
	switch os.Getenv("TICKETS_ACCOUNTS_MODE") {
	case "", "file":
		a, err := loadAccounts(os.Getenv("TICKETS_ACCOUNTS_FILE"))
		if err != nil {
			return nil, errors.New("valid private TICKETS_ACCOUNTS_FILE required")
		}
		return fileAccounts(a), nil
	case "db":
		if !secureAccountEndpoint(source.server) {
			return nil, errors.New("DB account mode requires verified wss:// to NRC or direct literal loopback ws:// for local development")
		}
		key := os.Getenv("NRC_PORTAL_ACCOUNT_SERVICE_KEY")
		if value, err := hex.DecodeString(key); err != nil || len(value) != 32 {
			return nil, errors.New("NRC_PORTAL_ACCOUNT_SERVICE_KEY must be a private random 32-byte key encoded as 64 hex characters")
		}
		if key == source.secret {
			return nil, errors.New("NRC_PORTAL_ACCOUNT_SERVICE_KEY must differ from NRC_BOT_SECRET")
		}
		return dbAccounts{source, key}, nil
	default:
		return nil, errors.New("TICKETS_ACCOUNTS_MODE must be file or db")
	}
}

func secureAccountEndpoint(endpoint string) bool {
	u, err := url.Parse(endpoint)
	if err != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return false
	}
	if u.Scheme == "wss" {
		return true
	}
	ip, err := netip.ParseAddr(u.Hostname())
	return u.Scheme == "ws" && err == nil && ip.Zone() == "" && ip.IsLoopback()
}

func (s dbAccounts) login(ctx context.Context, login string) (account, bool, error) {
	if !validAccountLogin(login) || !dbAccountText(login, 320) {
		return account{}, false, nil
	}
	return s.lookup(ctx, p.PortalAccountRequest{Op: "login", Login: login, ServiceKey: s.key})
}

func (s dbAccounts) mapping(ctx context.Context, requester string) (account, bool, error) {
	if !dbAccountRequester(requester) {
		return account{}, false, nil
	}
	return s.lookup(ctx, p.PortalAccountRequest{Op: "mapping", Requester: requester, ServiceKey: s.key})
}

var errAccountLookup = errors.New("portal account lookup unavailable")

func (s dbAccounts) lookup(ctx context.Context, q p.PortalAccountRequest) (account, bool, error) {
	const correlation = 1
	wire, err := p.EncodePortalAccountRequest(q, correlation)
	if err != nil {
		return account{}, false, errAccountLookup
	}
	body, err := s.source.request(ctx, p.C_PortalAccount, wire[2:], p.S_PortalAccount)
	if err != nil {
		return account{}, false, errAccountLookup
	}
	r, err := p.DecodePortalAccountResponse(body)
	if err != nil || r == nil || r.CorrelationID != correlation || r.Cursor != "" || len(r.Accounts) != 0 {
		return account{}, false, errAccountLookup
	}
	if r.Status == "not_found" && r.Account == nil {
		return account{}, false, nil
	}
	a := r.Account
	if r.Status != "ok" || a == nil || !dbAccountRequester(a.Requester) || !decimal(a.CompanyID) || !decimal(a.ContactID) || (a.ContactID != "" && a.CompanyID == "") {
		return account{}, false, errAccountLookup
	}
	switch q.Op {
	case "login":
		cost, err := bcrypt.Cost([]byte(a.PasswordHash))
		if a.Login != q.Login || a.Disabled || !dbAccountText(a.Name, 256) || len(a.PasswordHash) != 60 || err != nil || cost < 12 || cost > 16 ||
			a.ID == "" || !decimal(a.ID) || a.Revision == "" || !decimal(a.Revision) {
			return account{}, false, errAccountLookup
		}
	case "mapping":
		if a.Requester != q.Requester || a.PasswordHash != "" {
			return account{}, false, errAccountLookup
		}
	}
	return account{Login: a.Login, Requester: a.Requester, Name: a.Name, CompanyID: a.CompanyID, ContactID: a.ContactID, PasswordHash: a.PasswordHash, Disabled: a.Disabled, PortalID: a.ID, PortalRevision: a.Revision}, true, nil
}

func validAccountLogin(login string) bool {
	return login != "" && len(login) <= 320 && !strings.Contains(login, ":")
}

// Invalid lookup keys cannot match the DB constraints. Treat them as misses,
// not service failures (e.g. historical requester text that cannot be bound).
func dbAccountText(value string, limit int) bool {
	return value != "" && len(value) <= limit && strings.TrimSpace(value) == value &&
		utf8.ValidString(value) && strings.IndexFunc(value, unicode.IsControl) == -1
}

func dbAccountRequester(value string) bool {
	return dbAccountText(value, 320) && strings.ToLower(value) == value
}
