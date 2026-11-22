package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	p "github.com/heavyhorst/nrc/protocol-go"
)

const reviewTestPassword = "local-review-test-password"

func reviewCall(t *testing.T, c *websocket.Conn, q p.ReviewRequest, status string) *p.ReviewResponse {
	t.Helper()
	wire, err := p.EncodeReviewRequest(q, 872)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.WriteMessage(websocket.BinaryMessage, wire); err != nil {
		t.Fatal(err)
	}
	mustSetReadDeadline(t, c, 15*time.Second)
	r, err := p.DecodeReviewResponse(mustReadUntilOpcode(t, c, p.S_Review, 64))
	if err != nil || r.Status != status || r.CorrelationID != 872 {
		t.Fatalf("review %s: status=%s want=%s error=%v", q.Op, r.Status, status, err)
	}
	return r
}

// A real portal process behind TLS, using the actual NRC bot gateway and account
// provisioning. Only TLS termination is substituted; no domain response is mocked.
func reviewPortal(t *testing.T, workspace string, existingBinary ...string) (*httptest.Server, func() string) {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "nrc-tickets")
	if len(existingBinary) > 0 && existingBinary[0] != "" {
		bin = existingBinary[0]
	} else {
		build := exec.Command("go", "build", "-o", bin, ".")
		build.Dir = filepath.Join(repoRootFromThisFile(t), "services/bots/nrc-tickets")
		if out, err := build.CombinedOutput(); err != nil {
			t.Fatalf("portal build: %v\n%s", err, out)
		}
	}
	accounts := filepath.Join(dir, "accounts.json")
	provision := exec.Command(bin, "-provision", accounts)
	provision.Stdin = strings.NewReader(fmt.Sprintf(`[{"Login":"anna","Password":%q,"Requester":"anna@example.test","Name":"Anna"},{"Login":"bert","Password":%q,"Requester":"bert@example.test","Name":"Bert"}]`, reviewTestPassword, reviewTestPassword))
	if out, err := provision.CombinedOutput(); err != nil {
		t.Fatalf("portal accounts: %v\n%s", err, out)
	}
	port, err := allocateServerPort()
	if err != nil {
		t.Fatal(err)
	}
	target, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", port))
	tls := httptest.NewUnstartedServer(httputil.NewSingleHostReverseProxy(target))
	origin := "https://" + tls.Listener.Addr().String()
	logs := new(bytes.Buffer)
	cmd := exec.Command(bin)
	cmd.Env = append(os.Environ(), "TICKETS_ACCOUNTS_FILE="+accounts, "TICKETS_ORIGIN="+origin,
		"TICKETS_ADDR="+target.Host, "TICKETS_BRAND=NRC acceptance", "TICKETS_MAIL_CONFIG_FILE=",
		"TICKETS_GUEST_SESSION_KEY="+strings.Repeat("34", 32), "NRC_SERVER="+strings.TrimSuffix(wsURLForWorkspace(workspace), "/"+workspace),
		"NRC_WORKSPACE="+workspace, "NRC_BOT_SECRET="+metricsBotSecret, "FILES_URL=http://127.0.0.1:1")
	cmd.Stdout, cmd.Stderr = logs, logs
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	stopped := false
	stop := func() string {
		if !stopped {
			cmd.Process.Kill()
			cmd.Wait()
			stopped = true
		}
		return logs.String()
	}
	t.Cleanup(func() { stop() })
	deadline := time.Now().Add(10 * time.Second)
	for {
		r, err := http.Get(target.String())
		if err == nil {
			r.Body.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("portal did not start")
		}
		time.Sleep(20 * time.Millisecond)
	}
	tls.StartTLS()
	t.Cleanup(tls.Close)
	return tls, stop
}

func reviewHTTP(t *testing.T, s *httptest.Server, c *http.Client, login, method, path string, values url.Values, want int) string {
	t.Helper()
	var body io.Reader
	if values != nil {
		body = strings.NewReader(values.Encode())
	}
	r, err := http.NewRequest(method, s.URL+path, body)
	if err != nil {
		t.Fatal(err)
	}
	if login != "" {
		r.SetBasicAuth(login, reviewTestPassword)
	}
	if values != nil {
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		r.Header.Set("Origin", s.URL)
	}
	res, err := c.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	b, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	if res.StatusCode != want {
		t.Fatalf("%s %s: HTTP %d want %d: %s", method, path, res.StatusCode, want, b)
	}
	return string(b)
}

func reviewHidden(t *testing.T, html, name string) string {
	t.Helper()
	m := regexp.MustCompile(`name="` + name + `" value="([^"]*)"`).FindStringSubmatch(html)
	if len(m) != 2 {
		t.Fatalf("missing hidden field %s", name)
	}
	return m[1]
}

func TestReviewTeamsPortalGuestsAndRestart(t *testing.T) {
	const workspace = "reviews-acceptance"
	dir := t.TempDir()
	server := startServerInWorkDirWithEnv(t, dir, map[string]string{"NRC_THREAD_COUNT": "2"})
	t.Cleanup(func() { server.stop(t) })
	staff := workspaceDataClient(t, workspace, "alice", 31)
	defer staff.Close()
	form := p.ReviewForm{Version: 1, Title: "PDF-Steuerprüfung", Build: "build-42", Environment: "Staging", Points: []p.ReviewPoint{
		{ID: "9", Question: "Stimmt die Mehrwertsteuer im PDF?", Expected: "19,00 €"},
		{ID: "3", Question: "Bleibt der Firmenname sichtbar?"},
	}}
	created := reviewCall(t, staff, p.ReviewRequest{Op: "create", Form: form}, "ok")
	released := reviewCall(t, staff, p.ReviewRequest{Op: "release", FormID: created.FormID, IfRevision: created.Revision}, "ok")
	createRun := func(label string) string {
		return reviewCall(t, staff, p.ReviewRequest{Op: "run_create", FormID: created.FormID, Label: label, Kind: "customer"}, "ok").Run.ID
	}
	a, b := createRun("Kunde A"), createRun("Kunde B")
	for _, item := range []struct{ run, identity, name string }{{a, "anna@example.test", "Anna"}, {b, "bert@example.test", "Bert"}} {
		reviewCall(t, staff, p.ReviewRequest{Op: "participant_add", RunID: item.run, Source: "portal", Identity: item.identity, Name: item.name, CanClose: true}, "ok")
	}
	portal, stopPortal := reviewPortal(t, workspace)
	account := portal.Client()
	account.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	listing := reviewHTTP(t, portal, account, "anna", "GET", "/abnahmen", nil, 200)
	if !strings.Contains(listing, "Kunde A") || strings.Contains(listing, "Kunde B") {
		t.Fatal("account list leaks another team")
	}
	reviewHTTP(t, portal, account, "anna", "GET", "/abnahmen/"+b, nil, 404)
	reviewHTTP(t, portal, account, "", "GET", "/", nil, 401)
	reviewHTTP(t, portal, account, "anna", "GET", "/", nil, 200)
	invite := reviewCall(t, staff, p.ReviewRequest{Op: "invite", RunID: a, ExpiresAt: strconv.FormatInt(time.Now().Add(time.Hour).UnixNano(), 10)}, "ok")
	join := func(token string) (*http.Client, string) {
		client := *portal.Client()
		c := &client
		c.Jar, _ = cookiejar.New(nil)
		c.CheckRedirect = account.CheckRedirect
		reviewHTTP(t, portal, c, "", "POST", "/abnahmen/einladung", url.Values{"token": {token}}, 204)
		page := reviewHTTP(t, portal, c, "", "GET", "/abnahmen/gast", nil, 200)
		csrf := reviewHidden(t, page, "csrf")
		reviewHTTP(t, portal, c, "", "POST", "/abnahmen/gast", url.Values{"name": {"Alex"}, "csrf": {csrf}}, 303)
		return c, csrf
	}
	g1, csrf1 := join(invite.Token)
	g2, csrf2 := join(invite.Token)
	for i, item := range []struct {
		c                     *http.Client
		csrf, result, comment string
	}{{g1, csrf1, "yes", "Desktop korrekt"}, {g2, csrf2, "no", "Mobil fehlt die Steuer"}} {
		reviewHTTP(t, portal, item.c, "", "POST", "/abnahmen/gast/answer", url.Values{"point_id": {"9"}, "result": {item.result}, "comment": {item.comment}, "csrf": {item.csrf}}, 303)
		if i == 0 {
			reviewHTTP(t, portal, item.c, "", "POST", "/abnahmen/gast/answer", url.Values{"point_id": {"9"}, "result": {"yes"}, "csrf": {"forged"}}, 403)
		}
	}
	view := reviewHTTP(t, portal, account, "anna", "GET", "/abnahmen/"+a, nil, 200)
	if !strings.Contains(view, "Widersprüchliche Teamantworten") || !strings.Contains(view, "Desktop korrekt") || !strings.Contains(view, "Mobil fehlt die Steuer") {
		t.Fatal("guest contributions overwritten or contradictions hidden")
	}
	other := reviewHTTP(t, portal, account, "bert", "GET", "/abnahmen/"+b, nil, 200)
	if strings.Contains(other, "Mobil fehlt") {
		t.Fatal("cross-team contribution leaked")
	}
	reviewHTTP(t, portal, g1, "", "POST", "/abnahmen/gast/preview", url.Values{"decision": {"accepted"}, "csrf": {csrf1}}, 403)
	preview := reviewHTTP(t, portal, account, "anna", "POST", "/abnahmen/"+a+"/preview", url.Values{"decision": {"conditional"}, "comment": {"Steuerfehler nacharbeiten"}}, 200)
	seen := reviewHidden(t, preview, "if_revision")
	reviewHTTP(t, portal, g2, "", "POST", "/abnahmen/gast/answer", url.Values{"point_id": {"3"}, "result": {"unable"}, "csrf": {csrf2}}, 303)
	reviewHTTP(t, portal, account, "anna", "POST", "/abnahmen/"+a+"/close", url.Values{"decision": {"conditional"}, "if_revision": {seen}, "comment": {"Steuerfehler nacharbeiten"}}, 409)
	preview = reviewHTTP(t, portal, account, "anna", "POST", "/abnahmen/"+a+"/preview", url.Values{"decision": {"conditional"}, "comment": {"Steuerfehler nacharbeiten"}}, 200)
	reviewHTTP(t, portal, account, "anna", "POST", "/abnahmen/"+a+"/close", url.Values{"decision": {"conditional"}, "if_revision": {reviewHidden(t, preview, "if_revision")}, "comment": {"Steuerfehler nacharbeiten"}, "reviewed": {"yes"}}, 303)
	frozen := reviewCall(t, staff, p.ReviewRequest{Op: "run_get", RunID: a}, "ok")
	if frozen.Run.ClosedSource != "portal" || len(frozen.Run.Answers) != 3 || frozen.Run.Answers[0].ParticipantID == frozen.Run.Answers[1].ParticipantID {
		t.Fatal("report provenance or same-name isolation lost")
	}
	report := reviewHTTP(t, portal, account, "anna", "GET", "/abnahmen/"+a, nil, 200)
	if strings.Contains(report, "anna@example.test") || strings.Contains(report, invite.Token) || strings.Contains(report, "RelatedTo") {
		t.Fatal("private access data leaked")
	}
	reviewHTTP(t, portal, g1, "", "POST", "/abnahmen/gast/answer", url.Values{"point_id": {"9"}, "result": {"no"}, "csrf": {csrf1}}, 400)
	reviewCall(t, staff, p.ReviewRequest{Op: "revoke", RunID: a, InviteID: invite.InviteID}, "ok")
	reviewHTTP(t, portal, g1, "", "GET", "/abnahmen/gast", nil, 404)
	// An explicitly privileged guest can close, but the report says guest.
	selfRun := createRun("Gastentscheid")
	selfInvite := reviewCall(t, staff, p.ReviewRequest{Op: "invite", RunID: selfRun, CanClose: true, ExpiresAt: strconv.FormatInt(time.Now().Add(time.Hour).UnixNano(), 10)}, "ok")
	self, csrf := join(selfInvite.Token)
	selfPreview := reviewHTTP(t, portal, self, "", "POST", "/abnahmen/gast/preview", url.Values{"decision": {"rejected"}, "comment": {"Selbstangabe"}, "csrf": {csrf}}, 200)
	reviewHTTP(t, portal, self, "", "POST", "/abnahmen/gast/close", url.Values{"decision": {"rejected"}, "comment": {"Selbstangabe"}, "csrf": {csrf}, "if_revision": {reviewHidden(t, selfPreview, "if_revision")}, "reviewed": {"yes"}}, 303)
	if reviewCall(t, staff, p.ReviewRequest{Op: "run_get", RunID: selfRun}, "ok").Run.ClosedSource != "guest" {
		t.Fatal("guest closure looks verified")
	}
	// Optional internal task edges can be removed without touching the report.
	task := createQueryTask(t, staff, 0, "Mehrwertsteuer korrigieren")
	answerID, _ := strconv.ParseUint(frozen.Run.Answers[0].ID, 10, 64)
	if err := sendProtocolMessage(staff, p.C_CreateEdge, p.EncodeCreateEdge(0, p.TargetTypeAsset, answerID, p.TargetTypeTask, task.ID, p.RelationRelatedTo)); err != nil {
		t.Fatal(err)
	}
	edge, err := p.DecodeEdgeCreated(mustReadUntilOpcode(t, staff, p.S_EdgeCreated, 24))
	if err != nil {
		t.Fatal(err)
	}
	if err := sendProtocolMessage(staff, p.C_DeleteEdge, p.EncodeDeleteEdge(0, edge.Edge.EdgeID)); err != nil {
		t.Fatal(err)
	}
	mustReadUntilOpcode(t, staff, p.S_EdgeDeleted, 24)
	copyForm := reviewCall(t, staff, p.ReviewRequest{Op: "copy", FormID: created.FormID}, "ok")
	copyForm.Form.Build = "build-43"
	updated := reviewCall(t, staff, p.ReviewRequest{Op: "update", FormID: copyForm.FormID, IfRevision: copyForm.Revision, Form: copyForm.Form}, "ok")
	reviewCall(t, staff, p.ReviewRequest{Op: "release", FormID: copyForm.FormID, IfRevision: updated.Revision}, "ok")
	retest := reviewCall(t, staff, p.ReviewRequest{Op: "run_create", FormID: copyForm.FormID, Label: "Kunde A", Kind: "customer", PreviousRun: a}, "ok")
	if retest.Run.PreviousRun != a || len(retest.Run.Answers) != 0 || released.Form.Build != "build-42" {
		t.Fatal("retest mutated original")
	}
	before, _ := json.Marshal(frozen)
	staff.Close()
	server.stopGracefully(t)
	server = startServerInWorkDirWithEnv(t, dir, map[string]string{"NRC_THREAD_COUNT": "2"})
	staff = workspaceDataClient(t, workspace, "alice", 31)
	defer staff.Close()
	after, _ := json.Marshal(reviewCall(t, staff, p.ReviewRequest{Op: "run_get", RunID: a}, "ok"))
	if !bytes.Equal(before, after) {
		t.Fatal("closed report changed after edges/retest/restart")
	}
	if afterReport := reviewHTTP(t, portal, account, "anna", "GET", "/abnahmen/"+a, nil, 200); afterReport != report {
		t.Fatal("portal report changed after restart")
	}
	portalLogs := stopPortal()
	if strings.Contains(portalLogs, invite.Token) || strings.Contains(portalLogs, selfInvite.Token) {
		t.Fatal("invitation token was logged")
	}
	t.Log("real NRC + TLS ticket portal: assigned teams, contradictory same-name guests, CSRF, stale closure, scoped guest closure, live revocation, edge removal, new-build retest and byte-identical report after restart passed")
}

func TestReviewSectionedLongFormPortal(t *testing.T) {
	const workspace = "reviews-sections"
	server := startServerInWorkDirWithEnv(t, t.TempDir(), map[string]string{"NRC_THREAD_COUNT": "1"})
	t.Cleanup(func() { server.stop(t) })
	staff := workspaceDataClient(t, workspace, "alice", 31)
	defer staff.Close()
	sections := []string{"Zugang", "Rechnungsdaten", "Beträge & Steuern", "PDF-Export", "Versand", "Archiv"}
	form := p.ReviewForm{Version: 1, Title: "Rechnungen prüfen", Build: "Release 42", Environment: "Testumgebung"}
	for i := range 48 {
		form.Points = append(form.Points, p.ReviewPoint{ID: strconv.Itoa(1000 + i*7), Section: sections[i/8], Question: fmt.Sprintf("%s: Prüffall %d", sections[i/8], i%8+1), Expected: "Entspricht der freigegebenen Rechnung"})
	}
	created := reviewCall(t, staff, p.ReviewRequest{Op: "create", Form: form}, "ok")
	released := reviewCall(t, staff, p.ReviewRequest{Op: "release", FormID: created.FormID, IfRevision: created.Revision}, "ok")
	if len(released.Form.Points) != 48 || released.Form.Points[18].Section != "Beträge & Steuern" {
		t.Fatal("author-defined section lost during create/release")
	}
	run := reviewCall(t, staff, p.ReviewRequest{Op: "run_create", FormID: created.FormID, Label: "Kunde A", Kind: "customer"}, "ok").Run.ID
	reviewCall(t, staff, p.ReviewRequest{Op: "participant_add", RunID: run, Source: "portal", Identity: "anna@example.test", Name: "Anna", CanClose: true}, "ok")
	portal, stopPortal := reviewPortal(t, workspace)
	t.Cleanup(func() { stopPortal() })
	account := portal.Client()
	account.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	path := "/abnahmen/" + run
	page := reviewHTTP(t, portal, account, "anna", "GET", path, nil, 200)
	for _, section := range []string{"Zugang", "Rechnungsdaten", "PDF-Export", "Versand", "Archiv"} {
		if !strings.Contains(page, section) {
			t.Fatalf("section navigation omits %q", section)
		}
	}
	pointID := form.Points[18].ID
	reviewHTTP(t, portal, account, "anna", "POST", path+"/answer", url.Values{"point_id": {pointID}, "result": {"no"}, "comment": {"Mobil fehlt die Steuerzeile"}}, 303)
	current := reviewCall(t, staff, p.ReviewRequest{Op: "run_get", RunID: run}, "ok")
	if len(current.Run.Answers) != 1 || current.Run.Answers[0].PointID != pointID || current.Run.Answers[0].Comment != "Mobil fehlt die Steuerzeile" || current.Form.Points[18].Section != "Beträge & Steuern" {
		t.Fatal("long form saved answer by position instead of stable point ID, or dropped section")
	}
	preview := reviewHTTP(t, portal, account, "anna", "POST", path+"/preview", url.Values{"decision": {"conditional"}, "comment": {"Steuerzeile nacharbeiten"}}, 200)
	reviewHTTP(t, portal, account, "anna", "POST", path+"/close", url.Values{"decision": {"conditional"}, "comment": {"Steuerzeile nacharbeiten"}, "if_revision": {reviewHidden(t, preview, "if_revision")}, "reviewed": {"yes"}}, 303)
	report := reviewHTTP(t, portal, account, "anna", "GET", path, nil, 200)
	if !strings.Contains(report, "Mobil fehlt die Steuerzeile") || strings.Contains(report, "<form") || !strings.Contains(report, "Steuerzeile nacharbeiten") {
		t.Fatal("closed long-form report lost finding, proviso or read-only state")
	}
	t.Log("real 48-point form: six persisted author sections, stable non-positional point IDs, portal answer, close preview and read-only report passed")
}

// Optional baseline binary reproduces the identical browser transitions before
// the fix, without checking out or overwriting the current uncommitted MVP.
func TestReviewGuestInvitationBrowser(t *testing.T) {
	if os.Getenv("NRC_REVIEW_GUEST_E2E") != "1" {
		t.Skip("set NRC_REVIEW_GUEST_E2E=1 to launch Odin, TLS portal and Chromium")
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
	for _, phase := range []string{"before", "after"} {
		baseline := os.Getenv("NRC_REVIEW_GUEST_BEFORE_BIN")
		if phase == "before" && baseline == "" {
			continue
		}
		t.Run(phase, func(t *testing.T) {
			workspace := "review-guest-switch-" + phase
			staff := workspaceDataClient(t, workspace, "qa-switch", 31)
			defer staff.Close()
			form := p.ReviewForm{Version: 1, Title: "Gastwechsel · Rechnungsprüfung", Build: "rc-42", Environment: "Testumgebung", Points: []p.ReviewPoint{{ID: "1", Question: "Stimmt die Steuerzeile im PDF?", Expected: "Netto und Steuer sind getrennt ausgewiesen."}}}
			created := reviewCall(t, staff, p.ReviewRequest{Op: "create", Form: form}, "ok")
			reviewCall(t, staff, p.ReviewRequest{Op: "release", FormID: created.FormID, IfRevision: created.Revision}, "ok")
			a := reviewCall(t, staff, p.ReviewRequest{Op: "run_create", FormID: created.FormID, Label: "Team A · nur Beiträge", Kind: "customer"}, "ok").Run.ID
			b := reviewCall(t, staff, p.ReviewRequest{Op: "run_create", FormID: created.FormID, Label: "Team B · mit Abschlussrecht", Kind: "customer"}, "ok").Run.ID
			invite := func(run string, close bool, expiry time.Time) *p.ReviewResponse {
				return reviewCall(t, staff, p.ReviewRequest{Op: "invite", RunID: run, CanClose: close, ExpiresAt: strconv.FormatInt(expiry.UnixNano(), 10)}, "ok")
			}
			ia, ib := invite(a, false, time.Now().Add(time.Hour)), invite(b, true, time.Now().Add(time.Hour))
			// Only this disposable test-control endpoint uses staff authority;
			// every guest transition and answer is submitted by the browser UI.
			control := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != "POST" {
					w.WriteHeader(405)
					return
				}
				if r.URL.Path == "/revoke" {
					reviewCall(t, staff, p.ReviewRequest{Op: "revoke", RunID: b, InviteID: ib.InviteID}, "ok")
					w.WriteHeader(204)
					return
				}
				if r.URL.Path == "/expiring" {
					expiry := time.Now().Add(3 * time.Second)
					res := invite(b, false, expiry)
					json.NewEncoder(w).Encode(map[string]any{"token": res.Token, "expires": expiry.UnixMilli()})
					return
				}
				http.NotFound(w, r)
			}))
			defer control.Close()
			if phase == "after" {
				baseline = ""
			}
			portal, stop := reviewPortal(t, workspace, baseline)
			defer stop()
			root := repoRootFromThisFile(t)
			data, _ := json.Marshal(map[string]string{"phase": phase, "base": portal.URL, "tokenA": ia.Token, "tokenB": ib.Token, "control": control.URL, "artifacts": filepath.Join(root, ".amp/in/artifacts/review-p2-latest")})
			cmd := exec.Command("node", filepath.Join(root, "services/bots/nrc-tickets/reviews.sessions.e2e.mjs"))
			cmd.Dir, cmd.Stdin = root, bytes.NewReader(data)
			out, err := cmd.CombinedOutput()
			t.Logf("%s browser guest switches:\n%s", phase, out)
			if err != nil {
				t.Fatalf("browser failed: %v", err)
			}
			if phase == "after" {
				for _, item := range []struct{ run, comment string }{{a, "A · nach Rückkehr bearbeitet"}, {b, "B · nach Rückkehr bearbeitet"}} {
					r := reviewCall(t, staff, p.ReviewRequest{Op: "run_get", RunID: item.run}, "ok").Run
					if len(r.Answers) != 1 || len(r.Participants) != 1 || r.Answers[0].Comment != item.comment || r.Answers[0].ParticipantID != r.Participants[0].ID || r.Participants[0].CanClose != (item.run == b) {
						t.Fatalf("guest switch duplicated or crossed participant/answer/rights in run %s", item.run)
					}
				}
				t.Log("independent Odin read: exactly one participant and answer per run, edited originals and isolated close rights")
			}
		})
	}
}
