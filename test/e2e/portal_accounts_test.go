package e2e

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	p "github.com/heavyhorst/nrc/protocol-go"
)

func TestPortalAccountImportAndLiveSuspension(t *testing.T) {
	const workspace = "portal-account-acceptance"
	serviceKey := strings.Repeat("61", 32)
	adminKey := strings.Repeat("73", 32)
	server := startServerInWorkDirWithEnv(t, t.TempDir(), map[string]string{
		"NRC_THREAD_COUNT": "2", "NRC_PORTAL_ACCOUNT_SERVICE_KEY": serviceKey,
		"NRC_PORTAL_ACCOUNT_ADMIN_KEY":      adminKey,
		"NRC_PORTAL_ACCOUNT_ADMIN_SUBJECTS": `{"portal-account-acceptance":["account-admin"]}`,
	})
	t.Cleanup(func() { server.stop(t) })
	connectAdmin := func(workspace string) *websocket.Conn {
		token, err := buildProxyStyleJWT("account-admin", time.Now(), workspace)
		if err != nil {
			t.Fatal(err)
		}
		key, _ := hex.DecodeString(adminKey)
		mac := hmac.New(sha256.New, key)
		mac.Write([]byte(token))
		header := http.Header{"X-NRC-Auth": {token}, "X-NRC-Portal-Admin-Proof": {hex.EncodeToString(mac.Sum(nil))}}
		c, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), header)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		mustSetReadDeadline(t, c, 15*time.Second)
		mustExpectServerReady(t, c)
		mustSubscribeWorkspaceData(t, c)
		return c
	}
	admin := connectAdmin(workspace)
	staff := workspaceDataClient(t, workspace, "account-staff", 1)
	other := connectAdmin(workspace + "-other")
	sharedSignerOnly := workspaceDataClient(t, workspace, "account-admin", 1)
	call := func(c *websocket.Conn, q p.PortalAccountRequest, want string) *p.PortalAccountResponse {
		t.Helper()
		wire, err := p.EncodePortalAccountRequest(q, 617)
		if err != nil {
			t.Fatal(err)
		}
		if err := c.WriteMessage(websocket.BinaryMessage, wire); err != nil {
			t.Fatal(err)
		}
		mustSetReadDeadline(t, c, 15*time.Second)
		r, err := p.DecodePortalAccountResponse(mustReadUntilOpcode(t, c, p.S_PortalAccount, 64))
		if err != nil {
			t.Fatal(err)
		}
		if r.Status != want || r.CorrelationID != 617 {
			t.Fatalf("%s: got %q, want %q", q.Op, r.Status, want)
		}
		return r
	}
	call(staff, p.PortalAccountRequest{Op: "list"}, "forbidden")
	call(other, p.PortalAccountRequest{Op: "list"}, "forbidden")
	call(sharedSignerOnly, p.PortalAccountRequest{Op: "list"}, "forbidden")
	createAssetAndRead(t, admin, 0, p.AssetTypeTicket, 0, 0, `{"version":1,"title":"Older mail request","requester":"anna@example.test","requester_name":"Anna","company_id":"","contact_id":"","assignee":"","status":"open","channel":"email"}`)
	createAssetAndRead(t, admin, 0, p.AssetTypeTicket, 0, 0, `{"version":1,"title":"Unrelated mail request","requester":"bert@example.test","requester_name":"Bert","company_id":"","contact_id":"","assignee":"","status":"open","channel":"email"}`)
	form := p.ReviewForm{Version: 1, Title: "Assigned review", Build: "42", Points: []p.ReviewPoint{{ID: "1", Question: "Does it work?"}}}
	created := reviewCall(t, staff, p.ReviewRequest{Op: "create", Form: form}, "ok")
	reviewCall(t, staff, p.ReviewRequest{Op: "release", FormID: created.FormID, IfRevision: created.Revision}, "ok")
	run := reviewCall(t, staff, p.ReviewRequest{Op: "run_create", FormID: created.FormID, Label: "Existing assignment", Kind: "customer"}, "ok").Run.ID
	reviewCall(t, staff, p.ReviewRequest{Op: "participant_add", RunID: run, Source: "portal", Identity: "anna@example.test", Name: "Anna"}, "ok")
	portal, _, file := startReviewPortal(t, workspace, serviceKey)
	client := portal.Client()
	reviewHTTP(t, portal, client, "anna", "GET", "/", nil, 401)
	legacy, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	var accounts []p.PortalAccount
	if err := json.Unmarshal(legacy, &accounts); err != nil || len(accounts) != 2 {
		t.Fatal("invalid provisioning fixture")
	}
	staleBinding := append([]p.PortalAccount(nil), accounts...)
	staleBinding[1].CompanyID = "99999"
	invalid := call(admin, p.PortalAccountRequest{Op: "import", Accounts: staleBinding}, "invalid")
	if invalid.ImportRow != 2 || invalid.ImportReason != "invalid_company_contact_binding" {
		t.Fatal("stale binding did not identify the affected import row")
	}
	q := p.PortalAccountRequest{Op: "import", Accounts: accounts, DryRun: true}
	call(admin, q, "ok")
	if rows := call(admin, p.PortalAccountRequest{Op: "list"}, "ok").Accounts; len(rows) != 0 {
		t.Fatal("dry run wrote accounts")
	}
	q.DryRun = false
	call(admin, q, "ok")
	call(admin, q, "ok")
	var anna p.PortalAccount
	for _, a := range call(admin, p.PortalAccountRequest{Op: "list"}, "ok").Accounts {
		if a.PasswordHash != "" {
			t.Fatal("account listing exposed a hash")
		}
		if a.Login == "anna" {
			anna = a
		}
	}
	if anna.ID == "" {
		t.Fatal("imported account missing")
	}
	bot, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), http.Header{
		"X-NRC-User-Type": {"bot"}, "X-NRC-Bot-Secret": {metricsBotSecret}, "X-NRC-Bot-Nickname": {"nrc-tickets"},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer bot.Close()
	mustSetReadDeadline(t, bot, 15*time.Second)
	mustExpectServerReady(t, bot)
	call(bot, p.PortalAccountRequest{Op: "login", Login: "anna"}, "forbidden")
	lookup := call(bot, p.PortalAccountRequest{Op: "login", Login: "anna", ServiceKey: serviceKey}, "ok")
	if lookup.Account == nil || lookup.Account.PasswordHash != accounts[0].PasswordHash || lookup.Account.Requester != anna.Requester {
		t.Fatal("portal login lookup did not preserve account credentials")
	}
	if html := reviewHTTP(t, portal, client, "anna", "GET", "/", nil, 200); !strings.Contains(html, "Older mail request") || strings.Contains(html, "Unrelated mail request") {
		t.Fatal("incorrect visibility of preexisting email tickets")
	}
	if html := reviewHTTP(t, portal, client, "anna", "GET", "/abnahmen", nil, 200); !strings.Contains(html, "Existing assignment") {
		t.Fatal("lost existing review assignment")
	}
	proof := p.PortalWriteProof{ID: anna.ID, Revision: anna.Revision, ServiceKey: serviceKey}
	answer := p.ReviewRequest{Op: "answer", RunID: run, Source: "portal", Identity: anna.Requester, Name: anna.Name, PointID: "1", Result: "yes", PortalProof: &proof}
	reviewCall(t, bot, answer, "ok")
	ticket := p.Asset{AssetType: p.AssetTypeTicket, Payload: "local test only", Preview: `{"version":1,"title":"Account write fence control","requester":"anna@example.test","requester_name":"Anna","company_id":"","contact_id":"","assignee":"","status":"open"}`}
	writeTicket := func(proof p.PortalWriteProof, want uint16) []byte {
		t.Helper()
		body, err := p.EncodePortalTicketCreate(ticket, anna.Requester, proof, 618)
		if err != nil {
			t.Fatal(err)
		}
		if err := sendProtocolMessage(bot, p.C_CreateAsset, body); err != nil {
			t.Fatal(err)
		}
		mustSetReadDeadline(t, bot, 15*time.Second)
		return mustReadUntilOpcode(t, bot, want, 64)
	}
	writeTicket(proof, p.S_AssetCreated)
	call(admin, p.PortalAccountRequest{Op: "disable", ID: anna.ID, IfRevision: anna.Revision}, "ok")
	reviewHTTP(t, portal, client, "anna", "GET", "/", nil, 401)
	answer.Result = "no"
	reviewCall(t, bot, answer, "forbidden")
	if errReply, err := p.DecodeErrorResponse(writeTicket(proof, p.S_ErrorResponse)); err != nil || errReply.OriginOpcode != p.C_CreateAsset || errReply.CorrelationID != 618 {
		t.Fatal("stale portal ticket write was not refused by the writer")
	}
	call(admin, q, "conflict")
	got := call(admin, p.PortalAccountRequest{Op: "get", ID: anna.ID}, "ok")
	if got.Account == nil || !got.Account.Disabled {
		t.Fatal("reimport reactivated the suspended account")
	}
	call(admin, p.PortalAccountRequest{Op: "enable", ID: anna.ID, IfRevision: got.Account.Revision}, "ok")
	reviewHTTP(t, portal, client, "anna", "GET", "/", nil, 200)
	reviewCall(t, bot, answer, "forbidden") // Re-enabling does not revive an old authorization.
}
