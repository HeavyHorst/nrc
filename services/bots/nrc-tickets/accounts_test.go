package main

import (
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/gorilla/websocket"
	p "github.com/heavyhorst/nrc/protocol-go"
	"golang.org/x/crypto/bcrypt"
)

func TestConfiguredAccountsMode(t *testing.T) {
	path := filepath.Join(t.TempDir(), "accounts.json")
	t.Setenv("TICKETS_ACCOUNTS_FILE", path)
	t.Setenv("NRC_PORTAL_ACCOUNT_SERVICE_KEY", strings.Repeat("ab", 32))
	t.Setenv("TICKETS_ACCOUNTS_MODE", "db")
	source := nrcSource{server: "wss://nrc.internal.example", secret: "bot-secret"}
	if store, err := configuredAccounts(source); err != nil {
		t.Fatal("DB mode must not require an accounts file", err)
	} else if _, ok := store.(dbAccounts); !ok {
		t.Fatal("DB mode did not select the database")
	}
	// A valid legacy file must not rescue malformed DB configuration.
	if err := os.WriteFile(path, []byte(`[{"login":"anna","requester":"anna@example.test","name":"Anna","password_hash":"$2a$12$wxfLT9kvYWz8FuK16p8dreIzfGwQNzXCvnPkbwmVKx8C2kmMPyDBi"}]`), 0600); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"", "ff", strings.Repeat("xx", 32)} {
		t.Setenv("NRC_PORTAL_ACCOUNT_SERVICE_KEY", key)
		if _, err := configuredAccounts(source); err == nil {
			t.Fatal("DB mode accepted a malformed key")
		}
	}
	t.Setenv("NRC_PORTAL_ACCOUNT_SERVICE_KEY", strings.Repeat("ab", 32))
	if _, err := configuredAccounts(nrcSource{server: source.server, secret: os.Getenv("NRC_PORTAL_ACCOUNT_SERVICE_KEY")}); err == nil {
		t.Fatal("DB mode accepted reuse of the bot key")
	}
	for _, endpoint := range []string{"ws://websocket-server:8080", "ws://localhost:8080", "wss://user@nrc.internal.example"} {
		if _, err := configuredAccounts(nrcSource{server: endpoint, secret: source.secret}); err == nil {
			t.Fatalf("DB mode accepted unsafe endpoint %q", endpoint)
		}
	}
	if _, err := configuredAccounts(nrcSource{server: "ws://127.0.0.1:8080", secret: source.secret}); err != nil {
		t.Fatal("DB mode should permit direct loopback fixtures", err)
	}
	for _, mode := range []string{"", "file"} {
		t.Setenv("TICKETS_ACCOUNTS_MODE", mode)
		if store, err := configuredAccounts(source); err != nil {
			t.Fatal("legacy file mode", err)
		} else if _, ok := store.(fileAccounts); !ok {
			t.Fatal("did not select legacy file mode")
		}
	}
	t.Setenv("TICKETS_ACCOUNTS_MODE", "other")
	if _, err := configuredAccounts(source); err == nil {
		t.Fatal("accepted unknown account mode")
	}
}

// Use the real WebSocket request path and independently marshal replies, so
// these tests check auth headers, wire scope, correlation and status handling.
func accountPeer(t *testing.T, respond func(p.PortalAccountRequest) (p.PortalAccountResponse, uint32)) dbAccounts {
	t.Helper()
	key := strings.Repeat("12", 32)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/tickets" || r.Header.Get("X-NRC-User-Type") != "bot" || r.Header.Get("X-NRC-Bot-Nickname") != "nrc-tickets" || r.Header.Get("X-NRC-Bot-Secret") != "bot-secret" {
			t.Error("missing bot auth/scope")
			return
		}
		conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.Close()
		send := func(op uint16, data []byte) error {
			b, err := (&p.Message{Opcode: op, Data: data}).Write()
			if err != nil {
				return err
			}
			return conn.WriteMessage(websocket.BinaryMessage, b)
		}
		if err := send(p.S_ServerReady, nil); err != nil {
			t.Error(err)
			return
		}
		_, wire, err := conn.ReadMessage()
		if err != nil {
			t.Error(err)
			return
		}
		var q p.PortalAccountRequest
		m, err := p.ReadMessage(wire)
		if err != nil || m.Opcode != p.C_PortalAccount || len(m.Data) < 4 || binary.BigEndian.Uint32(m.Data[len(m.Data)-4:]) != 1 || json.Unmarshal(m.Data[:len(m.Data)-4], &q) != nil {
			t.Error("invalid portal account request")
			return
		}
		if q.ServiceKey != key || (q.Op != "change_password" && q.PasswordHash != "") || len(q.Accounts) != 0 {
			t.Error("unexpected portal account credentials or payload")
			return
		}
		res, correlation := respond(q)
		data, _ := json.Marshal(res)
		if err := send(p.S_PortalAccount, append(binary.BigEndian.AppendUint32(nil, correlation), data...)); err != nil {
			t.Error(err)
		}
	}))
	t.Cleanup(server.Close)
	return dbAccounts{nrcSource{strings.Replace(server.URL, "http:", "ws:", 1), "tickets", "bot-secret"}, key}
}

func passwordAccountPeer(t *testing.T) dbAccounts {
	t.Helper()
	hash, err := bcrypt.GenerateFromPassword([]byte("fixture-password-only"), 12)
	if err != nil {
		t.Fatal(err)
	}
	a := p.PortalAccount{ID: "9", Revision: "1", Login: "anna", Requester: "anna@example.test", Name: "Anna", PasswordHash: string(hash)}
	var mu sync.Mutex
	return accountPeer(t, func(q p.PortalAccountRequest) (p.PortalAccountResponse, uint32) {
		mu.Lock()
		defer mu.Unlock()
		if q.Op == "login" && q.Login == a.Login {
			snapshot := a
			return p.PortalAccountResponse{Status: "ok", Account: &snapshot}, 1
		}
		if q.Op == "change_password" && q.ID == a.ID && q.Requester == a.Requester && q.IfRevision == a.Revision && q.Login == "" {
			if cost, err := bcrypt.Cost([]byte(q.PasswordHash)); err != nil || cost != 12 {
				t.Error("expected a bcrypt hash, not the plaintext password")
				return p.PortalAccountResponse{Status: "invalid"}, 1
			}
			a.Revision, a.PasswordHash = "2", q.PasswordHash
			return p.PortalAccountResponse{Status: "ok"}, 1
		}
		t.Error("unexpected account operation or identity")
		return p.PortalAccountResponse{Status: "invalid"}, 1
	})
}

func TestDBPortalAccountsAuthorizeEachRequest(t *testing.T) {
	s, _ := sharingFixture(t)
	hash, err := bcrypt.GenerateFromPassword([]byte("fixture-password-only"), 12)
	if err != nil {
		t.Fatal(err)
	}
	var state atomic.Int32
	s.accounts = accountPeer(t, func(q p.PortalAccountRequest) (p.PortalAccountResponse, uint32) {
		switch q.Op {
		case "login":
			if q.Requester != "" {
				t.Error("login query included a requester")
			}
			if q.Login != "anna" || state.Load() == 1 {
				return p.PortalAccountResponse{Status: "not_found"}, 1
			}
			a := &p.PortalAccount{ID: "9", Revision: "1", Login: "anna", Requester: "anna@example.test", Name: "Anna", CompanyID: "123", ContactID: "51", PasswordHash: string(hash)}
			if state.Load() == 2 {
				return p.PortalAccountResponse{Status: "ok", Account: a}, 9
			}
			return p.PortalAccountResponse{Status: "ok", Account: a}, 1
		case "mapping":
			if q.Login != "" || q.Requester != "bea@example.test" {
				t.Error("unexpected legacy ticket mapping query")
			}
			if state.Load() == 3 {
				return p.PortalAccountResponse{Status: "forbidden"}, 1
			}
			a := &p.PortalAccount{Requester: "bea@example.test", CompanyID: "123", ContactID: "52", Disabled: true}
			return p.PortalAccountResponse{Status: "ok", Account: a}, 1
		default:
			t.Error("unexpected lookup operation")
			return p.PortalAccountResponse{Status: "error"}, 1
		}
	})
	if w := own(s, "GET", "/api/tickets/2", ""); w.Code != 200 || !strings.Contains(w.Body.String(), `"shared":true`) || strings.Contains(w.Body.String(), string(hash)) {
		t.Fatal("a disabled peer's legacy ticket should remain visible to the team", w.Code)
	}
	for _, test := range []struct {
		state int32
		code  int
	}{{1, 401}, {2, 503}, {3, 503}, {0, 200}} {
		state.Store(test.state)
		if w := own(s, "GET", "/api/tickets/2", ""); w.Code != test.code {
			t.Errorf("state %d: HTTP %d, want %d", test.state, w.Code, test.code)
		}
	}
}

func TestDBMailMappingRetryAndDisabledAccess(t *testing.T) {
	c, source, _ := mailFixture(t)
	_, shared := sharingFixture(t)
	source.fakeSource = shared
	for id, a := range shared.assets {
		if a.AssetType == entryType {
			delete(shared.assets, id)
		}
	}
	contact := shared.assets[52]
	contact.Preview = `{"version":1,"title":"Bea","email":"bea@example.test"}`
	shared.assets[52] = contact
	var stage atomic.Int32
	c.portal.accounts = accountPeer(t, func(q p.PortalAccountRequest) (p.PortalAccountResponse, uint32) {
		if q.Op != "mapping" || q.Login != "" {
			t.Error("mail sent a non-mapping query")
		}
		if stage.Load() == 3 {
			t.Error("own reply queried account mapping")
			return p.PortalAccountResponse{Status: "unavailable"}, 1
		}
		if (stage.Load() == 0 && q.Requester == "anna@example.test") || (stage.Load() == 1 && q.Requester == "bea@example.test") {
			return p.PortalAccountResponse{Status: "unavailable"}, 1
		}
		a := &p.PortalAccount{Requester: q.Requester, CompanyID: "123"}
		switch q.Requester {
		case "anna@example.test":
			a.ContactID = "51"
		case "bea@example.test":
			a.ContactID, a.Disabled = "52", true
		default:
			t.Error("unexpected requester")
		}
		return p.PortalAccountResponse{Status: "ok", Account: a}, 1
	})
	queue := func(id, from string, ticket uint64) {
		t.Helper()
		to := "support@our.test"
		if ticket != 0 {
			var err error
			to, err = c.replyAddress(ticket)
			if err != nil {
				t.Fatal(err)
			}
		}
		raw := "From: " + from + "\r\nTo: " + to + "\r\nMessage-ID: <" + id + "@example.test>\r\nSubject: " + id + "\r\n\r\n" + id
		if w := mailHTTP(c, "/inbound", raw); w.Code != 202 {
			t.Fatal(w.Code)
		}
	}
	queue("peer-reply", "anna@example.test", 2)
	// First fail the sender lookup, then fail the old ticket's mapping.
	for attempt := int32(0); attempt < 2; attempt++ {
		stage.Store(attempt)
		mailTick(t, c)
		jobs, err := c.jobs()
		if err != nil || len(jobs) != 1 || jobs[0].State != "queued" || source.writes != 0 {
			t.Fatal("a failed account lookup must leave mail queued without writing", jobs, err)
		}
	}
	stage.Store(2)
	mailTick(t, c)
	stage.Store(3)
	queue("own-reply-during-outage", "bea@example.test", 2)
	mailTick(t, c)
	if source.writes != 2 {
		t.Fatal("own reply was not saved during the account outage")
	}
	stage.Store(2)
	queue("disabled-team-reply", "bea@example.test", 1)
	queue("disabled-own-reply", "bea@example.test", 2)
	queue("disabled-new-ticket", "bea@example.test", 0)
	mailTick(t, c)
	seen := map[string]p.Asset{}
	for _, a := range shared.assets {
		seen[a.Payload] = a
	}
	if seen["peer-reply"].ParentID != 2 || seen["disabled-own-reply"].ParentID != 2 || seen["disabled-team-reply"].AssetID != 0 {
		t.Fatal("mail reply access did not respect disabled account and token scope")
	}
	if seen["own-reply-during-outage"].ParentID != 2 {
		t.Fatal("own reply was not linked to its ticket during the account outage")
	}
	var preview ticketPreview
	a := seen["disabled-new-ticket"]
	if a.AssetType != ticketType || json.Unmarshal([]byte(a.Preview), &preview) != nil || preview.CompanyID != "123" || preview.ContactID != "52" {
		t.Fatal("disabled account binding was lost on a new ticket", a.Preview)
	}
}
