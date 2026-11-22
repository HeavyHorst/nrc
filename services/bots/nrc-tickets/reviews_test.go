package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	p "github.com/heavyhorst/nrc/protocol-go"
)

const reviewFixtureToken = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

type reviewFixtureSource struct {
	*fakeSource
	lock                                              sync.Mutex
	run                                               p.ReviewRun
	form                                              p.ReviewForm
	token                                             string
	guests                                            map[string]string
	calls                                             []p.ReviewRequest
	revoked, guestClose, conflict, uncertain, stalled bool
}

func reviewFixture(t *testing.T) (*portal, *reviewFixtureSource) {
	t.Helper()
	s, f := fixture(t)
	r := &reviewFixtureSource{fakeSource: f, guests: map[string]string{}, form: p.ReviewForm{Version: 1, Title: "Release-Abnahme", Build: "2026.11", Environment: "Staging", ReleasedAt: "1790000000000000000", Points: []p.ReviewPoint{{ID: "1", Question: "Funktioniert der Export?", Instruction: "Export herunterladen", Expected: "Alle Zeilen"}, {ID: "2", Question: "Ist die Hilfe erreichbar?"}}}, run: p.ReviewRun{ID: "71", FormID: "61", Title: "Release-Abnahme", Label: "Technikteam", Kind: "customer", Revision: "100", Participants: []p.ReviewParticipant{{ID: "11", Source: "portal", Name: "Anna", CanClose: true}, {ID: "12", Source: "staff", Name: "Support"}}, Answers: []p.ReviewAnswer{{ID: "21", ParticipantID: "12", PointID: "1", Result: "no", Comment: "Teambeitrag", Name: "Support", UpdatedAt: "100"}}}}
	s.source = r
	s.guestKey = []byte(strings.Repeat("k", 32))
	return s, r
}

// This fake exercises the portal, not the Odin authorization implementation.
// It models private caller identity resolution and live invitation checks.
func (f *reviewFixtureSource) review(_ context.Context, q p.ReviewRequest) (*p.ReviewResponse, error) {
	f.lock.Lock()
	defer f.lock.Unlock()
	f.calls = append(f.calls, q)
	r := &p.ReviewResponse{Status: "ok"}
	if q.Source == "portal" && (q.Identity != "anna@example.test" || q.Name != "Anna") {
		r.Status = "forbidden"
		return r, nil
	}
	token := f.token
	if token == "" {
		token = reviewFixtureToken
	}
	if q.Source == "guest" && (f.revoked || q.Token != token || len(q.GuestID) < 32 || q.Name == "" && q.Op != "invitation_info") {
		r.Status = "forbidden"
		return r, nil
	}
	if q.Op == "invitation_info" {
		r.Form.Title = f.form.Title
		return r, nil
	}
	if q.Op == "run_list" {
		if q.Cursor == "" || f.stalled {
			r.Runs = []p.ReviewRun{{ID: "71", FormID: "61", Title: f.form.Title, Label: f.run.Label, Kind: "customer", Revision: "100", Decision: f.run.Decision}}
			r.Cursor = "71"
			r.HasMore = true
		} else {
			r.Runs = []p.ReviewRun{{ID: "72", FormID: "61", Title: "Zweite Seite", Label: "Nachtest", Revision: "100"}}
		}
		return r, nil
	}
	if q.Op != "guest_join" && q.RunID != f.run.ID {
		r.Status = "not_found"
		return r, nil
	}
	pid := "11"
	if q.Source == "guest" {
		pid = f.guests[q.GuestID]
		if q.Op == "guest_join" && pid == "" {
			pid = strconv.Itoa(30 + len(f.guests))
			f.guests[q.GuestID] = pid
			f.run.Participants = append(f.run.Participants, p.ReviewParticipant{ID: pid, Source: "guest", Name: q.Name, CanClose: f.guestClose})
		}
		if pid == "" {
			r.Status = "forbidden"
			return r, nil
		}
	}
	if q.Op == "answer" {
		if f.conflict {
			r.Status = "revision_conflict"
			return r, nil
		}
		revision, _ := strconv.Atoi(f.run.Revision)
		f.run.Revision = strconv.Itoa(revision + 1)
		answer := p.ReviewAnswer{ID: strconv.Itoa(22 + len(f.run.Answers)), ParticipantID: pid, PointID: q.PointID, Result: q.Result, Comment: q.Comment, Name: q.Name, UpdatedAt: "1790000000000000000"}
		replaced := false
		for i := range f.run.Answers {
			if f.run.Answers[i].ParticipantID == pid && f.run.Answers[i].PointID == q.PointID {
				answer.ID = f.run.Answers[i].ID
				f.run.Answers[i] = answer
				replaced = true
				break
			}
		}
		if !replaced {
			f.run.Answers = append(f.run.Answers, answer)
		}
	}
	if q.Op == "close" {
		if f.conflict || q.IfRevision != f.run.Revision {
			r.Status = "conflict"
			return r, nil
		}
		f.run.Decision = q.Decision
		f.run.Comment = q.Comment
		f.run.ClosedAt = "102"
		f.run.ClosedName = q.Name
		f.run.ClosedSource = q.Source
		f.run.Revision = "102"
	}
	if f.uncertain && (q.Op == "answer" || q.Op == "close") {
		return nil, fmt.Errorf("lost acknowledgement")
	}
	r.Run = f.run
	r.Form = f.form
	r.ParticipantID = pid
	r.FormID = f.run.FormID
	r.Revision = f.run.Revision
	b, _ := json.Marshal(r)
	var copy p.ReviewResponse
	json.Unmarshal(b, &copy)
	return &copy, nil
}

func reviewRequest(s *portal, method, path string, values url.Values, cookie *http.Cookie, auth bool) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(values.Encode()))
	if method == "POST" {
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		r.Header.Set("Origin", s.origin)
	}
	if cookie != nil {
		r.AddCookie(cookie)
	}
	if auth {
		r.SetBasicAuth("anna", "fixture-password-only")
	}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	return w
}

func exchangeGuest(t *testing.T, s *portal) (*http.Cookie, guestSession) {
	t.Helper()
	w := reviewRequest(s, "POST", "/abnahmen/einladung", url.Values{"token": {reviewFixtureToken}}, nil, false)
	if w.Code != 204 {
		t.Fatalf("exchange: %d %s", w.Code, w.Body.String())
	}
	c := w.Result().Cookies()[0]
	if !c.Secure || !c.HttpOnly || c.SameSite != http.SameSiteStrictMode || strings.Contains(c.Value, reviewFixtureToken) {
		t.Fatal("unprotected guest session")
	}
	r := httptest.NewRequest("GET", "/abnahmen/gast", nil)
	r.AddCookie(c)
	g, err := s.readGuest(r)
	if err != nil {
		t.Fatal(err)
	}
	return c, g
}

func joinGuest(t *testing.T, s *portal, c *http.Cookie, g guestSession, name string) (*http.Cookie, guestSession) {
	t.Helper()
	w := reviewRequest(s, "POST", "/abnahmen/gast", url.Values{"csrf": {g.CSRF}, "name": {name}}, c, false)
	if w.Code != 303 {
		t.Fatalf("join: %d %s", w.Code, w.Body.String())
	}
	c = w.Result().Cookies()[0]
	r := httptest.NewRequest("GET", "/abnahmen/gast", nil)
	r.AddCookie(c)
	g, err := s.readGuest(r)
	if err != nil {
		t.Fatal(err)
	}
	return c, g
}

func TestPortalAccountReviews(t *testing.T) {
	s, f := reviewFixture(t)
	if w := reviewRequest(s, "GET", "/abnahmen", nil, nil, false); w.Code != 401 {
		t.Fatal(w.Code)
	}
	w := reviewRequest(s, "GET", "/abnahmen", nil, nil, true)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "Zweite Seite") {
		t.Fatalf("pagination: %d %s", w.Code, w.Body.String())
	}
	w = reviewRequest(s, "GET", "/abnahmen/71", nil, nil, true)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "Teambeitrag") || !strings.Contains(w.Body.String(), "Abschlussvorschau öffnen") {
		t.Fatalf("detail: %d %s", w.Code, w.Body.String())
	}
	for _, secret := range []string{"anna@example.test", "identity", "token", "guest_id"} {
		if strings.Contains(w.Body.String(), secret) {
			t.Fatalf("private data %s leaked", secret)
		}
	}
	if w = reviewRequest(s, "GET", "/abnahmen/99", nil, nil, true); w.Code != 404 {
		t.Fatal(w.Code)
	}
	answer := url.Values{"point_id": {"1"}, "result": {"yes"}, "comment": {"<script>own</script>"}}
	if w = reviewRequest(s, "POST", "/abnahmen/71/answer", answer, nil, true); w.Code != 303 {
		t.Fatal(w.Code, w.Body.String())
	}
	w = reviewRequest(s, "GET", "/abnahmen/71", nil, nil, true)
	if !strings.Contains(w.Body.String(), "Widersprüchliche Teamantworten") || !strings.Contains(w.Body.String(), "1 / 2") || strings.Contains(w.Body.String(), "<script>own") {
		t.Fatal("progress, escaping or conflict missing")
	}
	preview := url.Values{"decision": {"conditional"}, "comment": {"Bitte nachtesten"}, "reviewed": {"yes"}}
	w = reviewRequest(s, "POST", "/abnahmen/71/preview", preview, nil, true)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `name="if_revision" value="101"`) || !strings.Contains(w.Body.String(), "Abschluss bestätigen") {
		t.Fatal(w.Code, w.Body.String())
	}
	preview.Set("if_revision", "100")
	if w = reviewRequest(s, "POST", "/abnahmen/71/close", preview, nil, true); w.Code != 409 || strings.Contains(w.Body.String(), "Abnahme verbindlich abschließen") {
		t.Fatal("stale preview was accepted")
	}
	preview.Set("if_revision", "101")
	f.conflict = true
	if w = reviewRequest(s, "POST", "/abnahmen/71/close", preview, nil, true); w.Code != 409 {
		t.Fatal("backend race not rejected")
	}
	if !strings.Contains(w.Body.String(), "Bitte nachtesten</textarea>") || strings.Contains(w.Body.String(), "Abnahme verbindlich abschließen") {
		t.Fatal("backend race lost closing draft or offered direct close")
	}
	f.conflict = false
	if w = reviewRequest(s, "POST", "/abnahmen/71/close", preview, nil, true); w.Code != 303 {
		t.Fatal(w.Code, w.Body.String())
	}
	w = reviewRequest(s, "GET", "/abnahmen/71", nil, nil, true)
	if !strings.Contains(w.Body.String(), "Mit Vorbehalt abgenommen") || !strings.Contains(w.Body.String(), "Bitte nachtesten") {
		t.Fatal("closure missing")
	}
	for _, q := range f.calls {
		if q.Source != "portal" || q.Identity != "anna@example.test" || q.Name != "Anna" || q.Token != "" {
			t.Fatalf("forged account identity %+v", q)
		}
	}
}

func TestPortalReviewForgeryAndOrigin(t *testing.T) {
	s, f := reviewFixture(t)
	for _, field := range []string{"identity", "requester", "source", "token", "guest_id", "name", "can_close", "run_id"} {
		v := url.Values{"point_id": {"1"}, "result": {"yes"}, field: {"forged"}}
		if w := reviewRequest(s, "POST", "/abnahmen/71/answer", v, nil, true); w.Code != 400 {
			t.Fatalf("accepted %s: %d", field, w.Code)
		}
	}
	r := httptest.NewRequest("POST", "/abnahmen/71/answer", strings.NewReader("point_id=1&result=yes"))
	r.SetBasicAuth("anna", "fixture-password-only")
	r.Header.Set("Origin", "https://evil.test")
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal(w.Code)
	}
	for _, q := range f.calls {
		if q.Op != "run_get" {
			t.Fatalf("forgery mutated backend: %+v", q)
		}
	}
	f.stalled = true
	if w = reviewRequest(s, "GET", "/abnahmen", nil, nil, true); w.Code != 502 {
		t.Fatal("stalled pagination not rejected")
	}
}

func TestGuestReviewSessions(t *testing.T) {
	s, f := reviewFixture(t)
	c, g := exchangeGuest(t, s)
	w := reviewRequest(s, "GET", "/abnahmen/gast", nil, c, false)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "Ihr Name") || strings.Contains(w.Body.String(), reviewFixtureToken) {
		t.Fatal(w.Code, w.Body.String())
	}
	if w = reviewRequest(s, "POST", "/abnahmen/gast", url.Values{"csrf": {"bad"}, "name": {"Same name"}}, c, false); w.Code != 403 {
		t.Fatal("csrf accepted")
	}
	c, g = joinGuest(t, s, c, g, "Same name")
	c2, g2 := exchangeGuest(t, s)
	c2, g2 = joinGuest(t, s, c2, g2, "Same name")
	if g.ID == g2.ID || g.ParticipantID == g2.ParticipantID {
		t.Fatal("same-name guests merged")
	}
	q := p.ReviewRequest{Op: "guest_join", Source: "guest", Token: g.Token, GuestID: g.ID, Name: g.Name}
	res, err := f.review(t.Context(), q)
	if err != nil || res.ParticipantID != g.ParticipantID {
		t.Fatal("same session duplicated")
	}
	w = reviewRequest(s, "GET", "/abnahmen/gast", nil, c, false)
	if w.Code != 200 || strings.Contains(w.Body.String(), "Abschlussvorschau öffnen") || strings.Contains(w.Body.String(), g.ID) || strings.Contains(w.Body.String(), g.Token) {
		t.Fatal(w.Code, w.Body.String())
	}
	answer := url.Values{"csrf": {g.CSRF}, "point_id": {"2"}, "result": {"unable"}, "comment": {"Gastbeitrag"}}
	if w = reviewRequest(s, "POST", "/abnahmen/gast/answer", answer, c, false); w.Code != 303 {
		t.Fatal(w.Code, w.Body.String())
	}
	if w = reviewRequest(s, "POST", "/abnahmen/gast/close", url.Values{"csrf": {g.CSRF}, "decision": {"accepted"}, "if_revision": {"101"}}, c, false); w.Code != 403 {
		t.Fatal("standard guest closed")
	}
	if w = reviewRequest(s, "GET", "/tickets/1", nil, c, false); w.Code != 401 {
		t.Fatal("guest bypassed ticket login")
	}
	f.revoked = true
	for _, path := range []string{"/abnahmen/gast", "/abnahmen/gast/answer"} {
		method := "GET"
		if strings.HasSuffix(path, "answer") {
			method = "POST"
		}
		if w = reviewRequest(s, method, path, answer, c, false); w.Code != 404 {
			t.Fatal("revoked guest retained access", w.Code)
		}
	}
	for _, c := range []*http.Cookie{c, c2} {
		bad := *c
		bad.Value = "x" + bad.Value
		if w = reviewRequest(s, "GET", "/abnahmen/gast", nil, &bad, false); w.Code != 403 {
			t.Fatal("tampered cookie accepted")
		}
	}
	g.Expires = time.Now().Add(-time.Hour).Unix()
	w = httptest.NewRecorder()
	s.saveGuest(w, g)
	expired := w.Result().Cookies()[0]
	if w = reviewRequest(s, "GET", "/abnahmen/gast", nil, expired, false); w.Code != 403 {
		t.Fatal("expired session accepted")
	}
	// Persisted key survives restart; rotation immediately invalidates cookies.
	fresh := &portal{source: f, origin: s.origin, guestKey: s.guestKey}
	f.revoked = false
	if w = reviewRequest(fresh, "GET", "/abnahmen/gast", nil, c, false); w.Code != 200 {
		t.Fatal("same-key restart lost session")
	}
	fresh.guestKey = []byte(strings.Repeat("z", 32))
	if w = reviewRequest(fresh, "GET", "/abnahmen/gast", nil, c, false); w.Code != 403 {
		t.Fatal("rotated key accepted old session")
	}
	s.guestKey = nil
	if w = reviewRequest(s, "GET", "/abnahmen/einladung", nil, nil, false); w.Code != 503 {
		t.Fatal("missing key did not fail closed")
	}
}

func TestGuestInvitationSwitchesPreserveOwnAnswersAndScope(t *testing.T) {
	s, a := reviewFixture(t)
	_, b := reviewFixture(t)
	b.token, b.run.ID, b.guestClose = strings.Repeat("b", 64), "73", true
	s.source = reviewBrowserSource{reviewFixtureSource: a, long: b}
	server := httptest.NewTLSServer(s)
	defer server.Close()
	s.origin = server.URL
	client := server.Client()
	client.Jar, _ = cookiejar.New(nil)
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	request := func(path string, values url.Values, want int) string {
		t.Helper()
		method := "GET"
		if values != nil {
			method = "POST"
		}
		r, _ := http.NewRequest(method, server.URL+path, strings.NewReader(values.Encode()))
		r.Header.Set("Origin", server.URL)
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		res, err := client.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		body, _ := io.ReadAll(res.Body)
		if res.StatusCode != want {
			t.Fatalf("%s: status %d, want %d: %s", path, res.StatusCode, want, body)
		}
		if want == 404 && len(res.Cookies()) != 0 {
			t.Fatal("invalid invitation changed cookies")
		}
		return string(body)
	}
	active := func() guestSession {
		t.Helper()
		r := httptest.NewRequest("GET", server.URL+"/abnahmen/gast", nil)
		for _, c := range client.Jar.Cookies(r.URL) {
			r.AddCookie(c)
		}
		g, err := s.readGuest(r)
		if err != nil {
			t.Fatal(err)
		}
		return g
	}
	join := func(token, name, comment string) guestSession {
		request("/abnahmen/einladung", url.Values{"token": {token}}, 204)
		g := active()
		request("/abnahmen/gast", url.Values{"csrf": {g.CSRF}, "name": {name}}, 303)
		g = active()
		request("/abnahmen/gast/answer", url.Values{"csrf": {g.CSRF}, "point_id": {"2"}, "result": {"no"}, "comment": {comment}}, 303)
		return g
	}
	ga := join(reviewFixtureToken, "Guest A", "Original A")
	// Existing pre-upgrade browsers may have only the active cookie.
	u, _ := url.Parse(server.URL)
	client.Jar.SetCookies(u, []*http.Cookie{{Name: guestInvitationCookie(ga.Token), Path: "/", Secure: true, MaxAge: -1}})
	request("/abnahmen/einladung", url.Values{"token": {strings.Repeat("c", 64)}}, 404)
	if active() != ga {
		t.Fatal("invalid exchange replaced the active identity")
	}
	gb := join(b.token, "Guest B", "Original B")
	if ga.ID == gb.ID || ga.CSRF == gb.CSRF {
		t.Fatal("identities or CSRF shared across invitations")
	}
	for _, g := range []guestSession{ga, gb, ga} {
		request("/abnahmen/einladung", url.Values{"token": {g.Token}}, 204)
		if active() != g {
			t.Fatal("switch changed identity, participant, rights context, or absolute expiry")
		}
		body := request("/abnahmen/gast", nil, 200)
		if !strings.Contains(body, "Original "+strings.TrimPrefix(g.Name, "Guest ")) || strings.Contains(body, "Ihr Name") {
			t.Fatal("own saved answer not restored")
		}
		if strings.Contains(body, "Abschlussvorschau öffnen") != (g.Token == gb.Token) {
			t.Fatal("closing rights transferred across runs")
		}
		request("/abnahmen/gast/answer", url.Values{"csrf": {g.CSRF}, "point_id": {"2"}, "result": {"yes"}, "comment": {"Original " + strings.TrimPrefix(g.Name, "Guest ")}}, 303)
	}
	request("/abnahmen/gast/answer", url.Values{"csrf": {gb.CSRF}, "point_id": {"2"}, "result": {"no"}}, 403)
	b.revoked = true
	request("/abnahmen/einladung", url.Values{"token": {b.token}}, 404)
	if active() != ga {
		t.Fatal("revoked restored invitation displaced active session")
	}
	if len(a.guests) != 1 || len(b.guests) != 1 || len(a.run.Answers) != 2 || len(b.run.Answers) != 2 {
		t.Fatal("switches duplicated participants or answers")
	}
	// A remembered cookie cannot outlive its original session, even if a
	// client keeps sending its ciphertext after the browser expiry.
	expired := gb
	expired.Expires = time.Now().Add(-time.Minute).Unix()
	w := httptest.NewRecorder()
	if err := s.saveGuestCookie(w, expired, guestInvitationCookie(gb.Token)); err != nil {
		t.Fatal(err)
	}
	c := w.Result().Cookies()[0]
	c.Expires, c.MaxAge = time.Now().Add(time.Hour), 3600
	client.Jar.SetCookies(u, []*http.Cookie{c})
	b.revoked = false
	request("/abnahmen/einladung", url.Values{"token": {gb.Token}}, 204)
	if g := active(); g.ID == gb.ID || g.Name != "" || g.ParticipantID != "" {
		t.Fatal("expired remembered identity restored")
	}
}

func TestGuestCloseAttributionAndUncertainWrite(t *testing.T) {
	s, f := reviewFixture(t)
	f.guestClose = true
	c, g := exchangeGuest(t, s)
	c, g = joinGuest(t, s, c, g, "Gastname")
	v := url.Values{"csrf": {g.CSRF}, "decision": {"accepted"}, "comment": {"Freigegeben"}, "reviewed": {"yes"}}
	w := reviewRequest(s, "POST", "/abnahmen/gast/preview", v, c, false)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "selbst angegebenen Gastnamen") {
		t.Fatal("missing guest close disclosure")
	}
	v.Set("if_revision", "100")
	f.uncertain = true
	w = reviewRequest(s, "POST", "/abnahmen/gast/close", v, c, false)
	if w.Code != 502 {
		t.Fatal("uncertain write reported success")
	}
	n := 0
	for _, q := range f.calls {
		if q.Op == "close" {
			n++
			if q.Name != "Gastname" || q.Token != g.Token || q.GuestID != g.ID || q.Identity != "" {
				t.Fatal("guest attribution wrong")
			}
		}
	}
	if n != 1 {
		t.Fatal("uncertain write retried")
	}
	f.uncertain = false
	f.run.ClosedAt = "1790000000000000000"
	w = reviewRequest(s, "GET", "/abnahmen/gast", nil, c, false)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "Gastname (Selbstangabe)") || !strings.Contains(w.Body.String(), "Abgeschlossen am 21.09.2026 14:13:20 UTC") {
		t.Fatal("closed report must disclose guest identity and readable closure time", w.Body.String())
	}
}

func TestReviewProtocolAcknowledgement(t *testing.T) {
	for _, correlation := range []uint32{1, 9} {
		t.Run(strconv.Itoa(int(correlation)), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("X-NRC-Bot-Nickname") != "nrc-tickets" || r.Header.Get("X-NRC-User-Type") != "bot" {
					t.Error("gateway auth missing")
				}
				c, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
				if err != nil {
					return
				}
				defer c.Close()
				b, _ := (&p.Message{Opcode: p.S_ServerReady}).Write()
				c.WriteMessage(websocket.BinaryMessage, b)
				_, wire, err := c.ReadMessage()
				if err != nil {
					return
				}
				m, err := p.ReadMessage(wire)
				if err != nil || m.Opcode != p.C_Review || binary.BigEndian.Uint32(m.Data[len(m.Data)-4:]) != 1 {
					t.Error("wrong review framing")
					return
				}
				var q p.ReviewRequest
				if json.Unmarshal(m.Data[:len(m.Data)-4], &q) != nil || q.Op != "run_list" || q.Identity != "anna@example.test" {
					t.Error("wrong request")
				}
				body := append(binary.BigEndian.AppendUint32(nil, correlation), []byte(`{"status":"ok","runs":[]}`)...)
				b, _ = (&p.Message{Opcode: p.S_Review, Data: body}).Write()
				c.WriteMessage(websocket.BinaryMessage, b)
			}))
			defer server.Close()
			s := nrcSource{server: strings.Replace(server.URL, "http:", "ws:", 1), workspace: "tickets", secret: "fixture-only"}
			_, err := s.review(t.Context(), p.ReviewRequest{Op: "run_list", Source: "portal", Identity: "anna@example.test", Name: "Anna"})
			if (err == nil) != (correlation == 1) {
				t.Fatal("wrong correlation accepted", err)
			}
		})
	}
}

func TestReviewBrowserFixture(t *testing.T) {
	addr := os.Getenv("TICKETS_REVIEW_TEST_ADDR")
	if addr == "" {
		t.Skip("opt-in review browser fixture")
	}
	s, short := reviewFixture(t)
	_, long := reviewFixture(t)
	invoiceReviewFixture(long)
	long.run.ID = "73"
	_, closed := reviewFixture(t)
	invoiceReviewFixture(closed)
	closed.run.ID, closed.run.Decision, closed.run.ClosedName, closed.run.ClosedSource, closed.run.ClosedAt = "74", "conditional", "Anna Weber", "portal", "1790000000000000000"
	closed.run.Comment = "Die Steuerzeile im mobilen PDF muss korrigiert werden."
	s.source = reviewBrowserSource{reviewFixtureSource: short, long: long, closed: closed}
	s.origin = "http://" + addr
	if origin := os.Getenv("TICKETS_REVIEW_TEST_ORIGIN"); origin != "" {
		s.origin = origin
	}
	t.Fatal(http.ListenAndServe(addr, s))
}

type reviewBrowserSource struct {
	*reviewFixtureSource
	long, closed *reviewFixtureSource
}

func (f reviewBrowserSource) review(ctx context.Context, q p.ReviewRequest) (*p.ReviewResponse, error) {
	if f.long != nil && f.long.token != "" && q.Source == "guest" && q.Token == f.long.token {
		return f.long.review(ctx, q)
	}
	switch q.RunID {
	case "73":
		return f.long.review(ctx, q)
	case "74":
		return f.closed.review(ctx, q)
	}
	return f.reviewFixtureSource.review(ctx, q)
}

func invoiceReviewFixture(f *reviewFixtureSource) {
	f.form.Title = "Rechnungen prüfen"
	f.form.Build, f.form.Environment, f.run.Label = "Release 42", "Testumgebung", "Kunde A"
	f.form.Points = nil
	f.run.Answers = nil
	sections := []string{"Zugang", "Rechnungsdaten", "Beträge & Steuern", "PDF-Export", "Versand", "Archiv"}
	questions := []string{"Ist der Zugang zum Rechnungsportal möglich?", "Stimmen die Rechnungsdaten?", "Ist der Nettobetrag korrekt?", "Ist das PDF vollständig lesbar?", "Kommt die Rechnung beim Empfänger an?", "Ist die archivierte Rechnung abrufbar?"}
	for i := 1; i <= 48; i++ {
		id := strconv.Itoa(i)
		question := fmt.Sprintf("%s — Fall %d", questions[(i-1)/8], (i-1)%8+1)
		if i == 19 {
			question = "Stimmt die Mehrwertsteuer im PDF?"
		}
		if i == 32 {
			question = "Ist das PDF auf dem Smartphone lesbar?"
		}
		if i == 41 {
			question = "Ist der Archivzugriff möglich?"
		}
		f.form.Points = append(f.form.Points, p.ReviewPoint{ID: id, Section: sections[(i-1)/8], Question: question, Instruction: "Vergleichen Sie die Rechnung im Portal mit dem heruntergeladenen PDF.", Expected: "Alle Angaben stimmen überein."})
		result := "yes"
		if i == 19 || i == 32 {
			result = "no"
		}
		if i == 41 {
			result = "unable"
		}
		f.run.Answers = append(f.run.Answers, p.ReviewAnswer{ID: strconv.Itoa(100 + i), ParticipantID: "12", PointID: id, Result: result, Name: "Support", Comment: "Im Testsystem geprüft.", UpdatedAt: "1790000000000000000"})
		if i <= 18 {
			f.run.Answers = append(f.run.Answers, p.ReviewAnswer{ID: strconv.Itoa(200 + i), ParticipantID: "11", PointID: id, Result: "yes", Name: "Anna", UpdatedAt: "1790000000000000000"})
		}
	}
}

func TestReviewLongNavigationAndReport(t *testing.T) {
	s, f := reviewFixture(t)
	invoiceReviewFixture(f)
	w := reviewRequest(s, "GET", "/abnahmen/71", nil, nil, true)
	body := w.Body.String()
	if w.Code != 200 || strings.Count(body, `name="point_id"`) != 1 || !strings.Contains(body, `value="19"`) || !strings.Contains(body, "18 / 48") || !strings.Contains(body, "Beträge &amp; Steuern") {
		t.Fatal("long form navigation", body)
	}
	v := url.Values{"point_id": {"19"}, "result": {""}, "comment": {"Entwurf"}}
	w = reviewRequest(s, "POST", "/abnahmen/71/answer", v, nil, true)
	if w.Code != 400 || !strings.Contains(w.Body.String(), "Entwurf") || !strings.Contains(w.Body.String(), `value="19"`) {
		t.Fatal("validation lost point or draft")
	}
	v.Set("result", "yes")
	f.uncertain = true
	w = reviewRequest(s, "POST", "/abnahmen/71/answer", v, nil, true)
	if w.Code != 502 || w.Header().Get("Location") != "" || !strings.Contains(w.Body.String(), `value="19"`) {
		t.Fatal("uncertain save advanced")
	}
	f.uncertain = false
	w = reviewRequest(s, "POST", "/abnahmen/71/answer", v, nil, true)
	if w.Code != 303 || w.Header().Get("Location") != "/abnahmen/71?point=20#point-20" {
		t.Fatal("confirmed save did not advance", w.Header())
	}
	w = reviewRequest(s, "POST", "/abnahmen/71/preview", url.Values{"decision": {"conditional"}}, nil, true)
	if strings.Count(w.Body.String(), `class="review-point"`) != 48 || strings.Contains(w.Body.String(), "Speichern und weiter") {
		t.Fatal("preview hides team points")
	}
	f.run.Decision = "conditional"
	w = reviewRequest(s, "GET", "/abnahmen/71", nil, nil, true)
	body = w.Body.String()
	if strings.Contains(body, "<form") || !strings.Contains(body, "45 bestanden") || !strings.Contains(body, "2 mit Abweichung") || !strings.Contains(body, "1 nicht prüfbar") || strings.Index(body, "Klärungsbedarf") > strings.Index(body, "Alle 48") {
		t.Fatal("report counts/order/write safety", body)
	}
	for i := range f.form.Points {
		f.form.Points[i].Section = ""
	}
	f.run.Decision = ""
	w = reviewRequest(s, "GET", "/abnahmen/71?point=25", nil, nil, true)
	if !strings.Contains(w.Body.String(), "Prüfpunkte 25–32") || f.form.Points[24].Section != "" {
		t.Fatal("legacy batching changes form")
	}
	f.form.Points = f.form.Points[:8]
	w = reviewRequest(s, "GET", "/abnahmen/71", nil, nil, true)
	if strings.Contains(w.Body.String(), `aria-label="Abschnitte"`) || strings.Count(w.Body.String(), `name="point_id"`) != 8 {
		t.Fatal("short legacy gained navigation")
	}
}

func TestReviewPreviewRetainsDraftAcrossRepeatedChanges(t *testing.T) {
	s, f := reviewFixture(t)
	draft := "Vorbehalt: €-Zeile prüfen.\nOriginal <Kommentar> bleibt."
	draft += strings.Repeat("ä", (4096-len(draft))/2) + strings.Repeat("!", (4096-len(draft))%2)
	values := url.Values{"decision": {"conditional"}, "comment": {draft}, "reviewed": {"yes"}}
	hidden := func(body, name string) string {
		t.Helper()
		match := regexp.MustCompile(`name="` + name + `" value="([^"]*)"`).FindStringSubmatch(body)
		if len(match) != 2 {
			t.Fatalf("missing %s", name)
		}
		return html.UnescapeString(match[1])
	}
	w := reviewRequest(s, "POST", "/abnahmen/71/preview", values, nil, true)
	body := w.Body.String()
	if w.Code != 200 || strings.Index(body, "Mit Vorbehalt abgenommen") > strings.Index(body, "Vor dem Abschluss prüfen") || !strings.Contains(body, html.EscapeString(draft)) || !strings.Contains(body, `href="#point-1"`) || !strings.Contains(body, `<details class="review-all">`) || strings.Contains(body, `>conditional<`) {
		t.Fatal("preview priority, labels or point links wrong", body)
	}
	values.Set("if_revision", hidden(body, "if_revision"))
	values.Set("snapshot", hidden(body, "snapshot"))
	for round := 1; round <= 2; round++ {
		// The second change arrives while reviewing the first conflict. A comment
		// change counts even if the result and timestamp remain the same.
		f.run.Revision = strconv.Itoa(100 + round)
		f.run.Answers[0].Comment = fmt.Sprintf("Neue Teamantwort %d", round)
		action := "/close"
		if round == 2 {
			action = "/preview"
		}
		w = reviewRequest(s, "POST", "/abnahmen/71"+action, values, nil, true)
		body = w.Body.String()
		if w.Code != 409 || !strings.Contains(body, "Abschlussentwurf erhalten") || !strings.Contains(body, html.EscapeString(draft)) || !strings.Contains(body, `value="conditional" selected`) || strings.Contains(body, "Abnahme verbindlich abschließen") || strings.Count(body, "Seit Ihrer Durchsicht geändert") != 1 || !strings.Contains(body, "Seit Durchsicht geändert") || !strings.Contains(body, f.run.Answers[0].Comment) {
			t.Fatal("lost draft or specific repeated change", w.Code, body)
		}
		values.Set("if_revision", hidden(body, "if_revision"))
		values.Set("snapshot", hidden(body, "snapshot"))
	}
	w = reviewRequest(s, "POST", "/abnahmen/71/preview", values, nil, true)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "Abnahme verbindlich abschließen") {
		t.Fatal("fresh preview unavailable")
	}
	values.Del("reviewed")
	if w = reviewRequest(s, "POST", "/abnahmen/71/close", values, nil, true); w.Code != 400 || f.run.Decision != "" {
		t.Fatal("closed without explicit renewed confirmation")
	}
	values.Set("reviewed", "yes")
	if w = reviewRequest(s, "POST", "/abnahmen/71/close", values, nil, true); w.Code != 303 || f.run.Comment != draft {
		t.Fatal("fresh close changed original draft", w.Code)
	}
	w = reviewRequest(s, "GET", "/abnahmen", nil, nil, true)
	if !strings.Contains(w.Body.String(), "Mit Vorbehalt abgenommen") || strings.Contains(w.Body.String(), ">conditional<") {
		t.Fatal("raw list decision")
	}
}

func TestReviewGuestTitleOnlyForValidInvitation(t *testing.T) {
	s, f := reviewFixture(t)
	c, _ := exchangeGuest(t, s)
	w := reviewRequest(s, "GET", "/abnahmen/gast", nil, c, false)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "<h1>Release-Abnahme</h1>") || !strings.Contains(w.Body.String(), "höchstens acht Stunden") || strings.Contains(w.Body.String(), "Teambeitrag") || len(f.run.Participants) != 2 {
		t.Fatal("title, explanation, privacy or non-mutating entry wrong", w.Body.String())
	}
	f.revoked = true
	w = reviewRequest(s, "GET", "/abnahmen/gast", nil, c, false)
	if w.Code != 404 || strings.Contains(w.Body.String(), f.form.Title) || strings.Contains(w.Body.String(), "Ihr Name") {
		t.Fatal("revoked invitation leaked title/name form")
	}
}

func TestReviewAnswerErrorsPreserveHTMLDraft(t *testing.T) {
	for _, name := range []string{"invalid result", "comment bytes", "conflict", "unconfirmed"} {
		t.Run(name, func(t *testing.T) {
			s, f := reviewFixture(t)
			invoiceReviewFixture(f)
			v := url.Values{"point_id": {"19"}, "result": {"yes"}, "comment": {"Entwurf <PDF>"}}
			status := 400
			switch name {
			case "invalid result":
				v.Set("result", "")
			case "comment bytes":
				v.Set("comment", strings.Repeat("ä", 2049))
			case "conflict":
				f.conflict = true
				status = 409
			case "unconfirmed":
				f.uncertain = true
				status = 502
			}
			w := reviewRequest(s, "POST", "/abnahmen/71/answer", v, nil, true)
			if w.Code != status || w.Result().Header.Get("Content-Type") != "text/html; charset=utf-8" || w.Header().Get("Location") != "" {
				t.Fatal(w.Code, w.Result().Header)
			}
			body := w.Body.String()
			own := regexp.MustCompile(`<p class="review-own">(.*?)</p>`).FindString(body)
			if !strings.Contains(own, "Noch unbeantwortet") || strings.Contains(own, "Entwurf") {
				t.Fatal("unsaved draft shown as saved answer", own)
			}
			if strings.Count(body, `name="point_id"`) != 1 || !strings.Contains(body, `value="19"`) || !strings.Contains(body, `role="alert"`) {
				t.Fatal("lost navigation", body)
			}
			if name == "comment bytes" {
				if !strings.Contains(body, v.Get("comment")) {
					t.Fatal("lost long draft")
				}
			} else if !strings.Contains(body, "Entwurf &lt;PDF&gt;") {
				t.Fatal("lost or unescaped draft")
			}
		})
	}
}
