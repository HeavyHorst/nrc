package e2e

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	p "github.com/heavyhorst/nrc/protocol-go"
)

// Opt-in because this test launches Chromium as well as the real Odin server.
// NRC_REVIEW_BEFORE points at an unchanged client tree to verify the negative control.
func TestReviewClientPublicUI(t *testing.T) {
	if os.Getenv("NRC_REVIEW_CLIENT_E2E") != "1" {
		t.Skip("set NRC_REVIEW_CLIENT_E2E=1")
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
	root := repoRootFromThisFile(t)
	for _, phase := range []string{"before", "after"} {
		source := filepath.Join(root, "client")
		if phase == "before" {
			source = os.Getenv("NRC_REVIEW_BEFORE")
			if source == "" {
				continue
			}
		}
		workspace := "review-public-ui-" + phase
		staff := workspaceDataClient(t, workspace, "alice", 31)
		form := p.ReviewForm{Version: 1, Title: "Release acceptance", Build: "build-42", Environment: "Staging", Points: []p.ReviewPoint{{ID: "1", Question: "ASCII evidence"}, {ID: "2", Question: "Unicode evidence"}, {ID: "3", Question: "Short evidence"}}}
		created := reviewCall(t, staff, p.ReviewRequest{Op: "create", Form: form}, "ok")
		reviewCall(t, staff, p.ReviewRequest{Op: "release", FormID: created.FormID, IfRevision: created.Revision}, "ok")
		run := reviewCall(t, staff, p.ReviewRequest{Op: "run_create", FormID: created.FormID, Label: "Customer Alpha", Kind: "customer"}, "ok").Run
		member := reviewCall(t, staff, p.ReviewRequest{Op: "participant_add", RunID: run.ID, Source: "staff", Identity: "alice", Name: "Same Name", CanClose: true}, "ok").ParticipantID
		comments := []string{strings.Repeat("A", 4096), strings.Repeat("é🙂", 682) + "tail", "Complete short original: € tax line missing."}
		for i, comment := range comments {
			reviewCall(t, staff, p.ReviewRequest{Op: "answer", RunID: run.ID, PointID: strconv.Itoa(i + 1), Result: "no", Comment: comment}, "ok")
		}
		other := workspaceDataClient(t, workspace, "bob", 32)
		reviewCall(t, staff, p.ReviewRequest{Op: "participant_add", RunID: run.ID, Source: "staff", Identity: "bob", Name: "Same Name"}, "ok")
		reviewCall(t, other, p.ReviewRequest{Op: "answer", RunID: run.ID, PointID: "1", Result: "yes", Comment: "WRONG SAME-NAME CONTRIBUTION"}, "ok")
		run = reviewCall(t, staff, p.ReviewRequest{Op: "run_get", RunID: run.ID}, "ok").Run
		asset := func(kind uint16, preview, body string) uint64 {
			if err := sendProtocolMessage(staff, p.C_CreateAsset, p.EncodeCreateAsset(0, kind, 0, 0, preview, body)); err != nil {
				t.Fatal(err)
			}
			a, err := p.DecodeAssetCreated(mustReadUntilOpcode(t, staff, p.S_AssetCreated, 128))
			if err != nil {
				t.Fatal(err)
			}
			return a.Asset.AssetID
		}
		ticket := asset(p.AssetTypeTicket, `{"version":1,"title":"Review navigation ticket","status":"open","priority":"normal","assignee":"","company_id":"","contact_id":"","requester":"test@example.test","requester_name":"Test"}`, "Original ticket")
		note := asset(p.AssetTypeNote, `{"title":"Note navigation control"}`, "Original note control body")
		if err := sendProtocolMessage(staff, p.C_CreateTask, p.EncodeTaskCreate(0, "Review navigation task", "Navigation control", 128)); err != nil {
			t.Fatal(err)
		}
		task, err := p.DecodeTaskCreated(mustReadUntilOpcode(t, staff, p.S_TaskCreated, 128))
		if err != nil {
			t.Fatal(err)
		}
		answers := []p.ReviewAnswer{}
		for _, a := range run.Answers {
			if a.ParticipantID == member {
				answers = append(answers, a)
			}
		}
		if len(answers) != 3 {
			t.Fatalf("seeded answers: %v member=%s", run.Answers, member)
		}
		answerID := func(point string) uint64 {
			for _, a := range answers {
				if a.PointID == point {
					id, _ := strconv.ParseUint(a.ID, 10, 64)
					return id
				}
			}
			t.Fatal("missing point")
			return 0
		}
		formID, _ := strconv.ParseUint(created.FormID, 10, 64)
		for _, edge := range [][]uint64{{1, ticket, 1, formID}, {2, task.Task.ID, 1, answerID("1")}, {2, task.Task.ID, 1, note}} {
			if err := sendProtocolMessage(staff, p.C_CreateEdge, p.EncodeCreateEdge(0, uint16(edge[0]), edge[1], uint16(edge[2]), edge[3], p.RelationRelatedTo)); err != nil {
				t.Fatal(err)
			}
			mustReadUntilOpcode(t, staff, p.S_EdgeCreated, 128)
		}
		fixture := map[string]any{"formId": created.FormID, "runId": run.ID, "participantId": member, "answers": answers, "ticketId": fmt.Sprint(ticket), "taskId": fmt.Sprint(task.Task.ID), "noteId": fmt.Sprint(note), "workspace": workspace}
		expires := strconv.FormatInt(time.Now().Add(time.Hour).UnixNano(), 10)
		revoked := reviewCall(t, staff, p.ReviewRequest{Op: "invite", RunID: run.ID, ExpiresAt: expires, CanClose: true}, "ok")
		reviewCall(t, staff, p.ReviewRequest{Op: "revoke", RunID: run.ID, InviteID: revoked.InviteID}, "ok")
		shortExpiry := time.Now().Add(2 * time.Second)
		short := reviewCall(t, staff, p.ReviewRequest{Op: "invite", RunID: run.ID, ExpiresAt: strconv.FormatInt(shortExpiry.UnixNano(), 10)}, "ok")
		otherActive := reviewCall(t, staff, p.ReviewRequest{Op: "invite", RunID: run.ID, ExpiresAt: expires, CanClose: true}, "ok")
		active := reviewCall(t, staff, p.ReviewRequest{Op: "invite", RunID: run.ID, ExpiresAt: expires}, "ok")
		fixture["guestLink"] = "https://review.example.test/abnahmen/einladung#" + active.Token
		fixture["activeInvite"] = active.InviteID
		fixture["revokedInvite"] = revoked.InviteID
		fixture["expiredInvite"] = short.InviteID
		fixture["otherActiveInvite"] = otherActive.InviteID
		time.Sleep(time.Until(shortExpiry))
		target, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", serverPort))
		proxy := httputil.NewSingleHostReverseProxy(target)
		direct := proxy.Director
		proxy.Director = func(r *http.Request) {
			direct(r)
			token, _ := buildProxyStyleJWT("alice", time.Now(), workspace)
			r.Header.Set("X-NRC-Auth", token)
		}
		files := http.FileServer(http.Dir(source))
		var transportDown atomic.Bool
		var socketMu sync.Mutex
		var sockets []net.Conn
		web := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Fault injection closes actual upgraded transports; no domain response is mocked.
			if r.Method == http.MethodPost && r.URL.Path == "/disconnect-transport" {
				transportDown.Store(true)
				socketMu.Lock()
				for _, socket := range sockets {
					socket.Close()
				}
				sockets = nil
				socketMu.Unlock()
				w.WriteHeader(http.StatusNoContent)
				return
			}
			if r.Method == http.MethodPost && r.URL.Path == "/restore-transport" {
				transportDown.Store(false)
				w.WriteHeader(http.StatusNoContent)
				return
			}
			if strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
				if transportDown.Load() {
					http.Error(w, "synthetic transport outage", http.StatusServiceUnavailable)
					return
				}
				proxy.ServeHTTP(w, r)
				return
			}
			if r.URL.Path == "/fixture.json" {
				w.Header().Set("Content-Type", "application/json")
				json.NewEncoder(w).Encode(fixture)
				return
			}
			if r.URL.Path == "/api/features" {
				w.Header().Set("Content-Type", "application/json")
				fmt.Fprint(w, `{"review_portal_origin":"https://review.example.test"}`)
				return
			}
			files.ServeHTTP(w, r)
		}))
		web.Config.ConnState = func(conn net.Conn, state http.ConnState) {
			if state == http.StateHijacked {
				socketMu.Lock()
				sockets = append(sockets, conn)
				socketMu.Unlock()
			}
		}
		web.Start()
		script := "reviews-fixes.e2e.mjs"
		if os.Getenv("NRC_REVIEW_IDENTITY") == "1" {
			script = "reviews-identity.e2e.mjs"
		}
		cmd := exec.Command("node", filepath.Join(root, "client", script))
		cmd.Dir = root
		cmd.Env = append(os.Environ(), "NRC_REVIEW_URL="+web.URL, "NRC_REVIEW_PHASE="+phase)
		out, err := cmd.CombinedOutput()
		web.Close()
		t.Logf("%s browser:\n%s", phase, out)
		if err != nil {
			t.Fatalf("%s browser: %v", phase, err)
		}
		// Re-read persisted originals independently of the browser's cache.
		persisted := reviewCall(t, staff, p.ReviewRequest{Op: "run_get", RunID: run.ID}, "ok").Run
		for _, want := range answers {
			found := false
			for _, got := range persisted.Answers {
				if got.ID == want.ID {
					found = true
					if got.Comment != want.Comment {
						t.Fatal("original answer modified")
					}
				}
			}
			if !found {
				t.Fatal("original answer deleted")
			}
		}
		if os.Getenv("NRC_REVIEW_IDENTITY") == "1" {
			staff.Close()
			other.Close()
			continue
		}
		if err := sendProtocolMessage(staff, p.C_GetTasks, p.EncodeGetTasks(0)); err != nil {
			t.Fatal(err)
		}
		tasks, err := p.DecodeTaskListResponse(mustReadUntilOpcode(t, staff, p.S_TaskListResponse, 128))
		if err != nil || !tasks.Success {
			t.Fatalf("persisted tasks: %v", err)
		}
		count := 0
		for _, task := range tasks.Tasks {
			if !strings.HasPrefix(task.Title, "Finding point ") {
				continue
			}
			count++
			point := strings.TrimPrefix(task.Title, "Finding point ")
			id := answerID(point)
			if len(task.Description) > 4096 || !strings.Contains(task.Description, fmt.Sprintf("Answer asset #%d", id)) {
				t.Fatal("invalid persisted finding description")
			}
			if point == "3" && !strings.Contains(task.Description, comments[2]) {
				t.Fatal("short original truncated")
			}
			if point != "3" && !strings.Contains(task.Description, "Full original preserved") {
				t.Fatal("excerpt source marker missing")
			}
			if err := sendProtocolMessage(staff, p.C_ListEdges, p.EncodeListEdges(0, 2, task.ID)); err != nil {
				t.Fatal(err)
			}
			edges, err := p.DecodeEdgeListResponse(mustReadUntilOpcode(t, staff, p.S_EdgeList, 128))
			if err != nil {
				t.Fatal(err)
			}
			found := false
			for _, edge := range edges.Edges {
				if edge.SourceType == 1 && edge.SourceID == id && edge.TargetType == 2 && edge.TargetID == task.ID && edge.Relation == p.RelationRelatedTo {
					found = true
				}
			}
			if !found {
				t.Fatal("exact answer RelatedTo edge missing from server")
			}
			t.Logf("%s persisted task #%d point=%s description_bytes=%d exact_answer=%d RelatedTo confirmed", phase, task.ID, point, len(task.Description), id)
		}
		want := 3
		if phase == "before" {
			want = 1
		}
		if count != want {
			t.Fatalf("finding count=%d want=%d", count, want)
		}
		t.Logf("%s: all 3 original answers unchanged; persisted finding count=%d", phase, count)
		staff.Close()
		other.Close()
	}
}
