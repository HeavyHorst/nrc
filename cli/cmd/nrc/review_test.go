package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/heavyhorst/nrc/cli/pkg/config"
	p "github.com/heavyhorst/nrc/protocol-go"
)

const reviewFixtureDraft = `{"version":1,"title":"Review","build":"v1","points":[{"id":"9007199254740993","section":"Login","question":"Works?"},{"id":"2","question":"Still open?"}]}`

func reviewCLI(t *testing.T, url string) (string, func(string, string, ...string) []byte) {
	t.Helper()
	dir := t.TempDir()
	binaryPath := filepath.Join(dir, "nrc")
	if b, err := exec.Command("go", "build", "-o", binaryPath, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, b)
	}
	t.Setenv("HOME", dir)
	cfg := config.Config{Server: strings.TrimRight(url, "/") + "/", WorkspaceID: fmt.Sprintf("cli-review-%d", time.Now().UnixNano())}
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	return dir, func(stdin, wantCode string, args ...string) []byte {
		t.Helper()
		cmd := exec.Command(binaryPath, append([]string{"review"}, args...)...)
		cmd.Stdin = strings.NewReader(stdin)
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		b, err := cmd.Output()
		if wantCode == "" {
			if err != nil || !json.Valid(b) {
				t.Fatalf("%v: %v stdout=%s stderr=%s", args, err, b, &stderr)
			}
			return b
		}
		if err == nil || len(b) != 0 || !json.Valid(stderr.Bytes()) || !strings.Contains(stderr.String(), `"code":"`+wantCode+`"`) {
			t.Fatalf("%v: want %s; got %v stdout=%s stderr=%s", args, wantCode, err, b, &stderr)
		}
		return stderr.Bytes()
	}
}

func reviewDecodeOutput[T any](t *testing.T, data []byte) T {
	t.Helper()
	var decoded T
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("invalid result %s: %v", data, err)
	}
	return decoded
}

func TestReviewCLIRejectsUnsafeInputAndDoesNotReplay(t *testing.T) {
	var requests atomic.Int32
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer ws.Close()
		_, data, err := ws.ReadMessage()
		if err != nil {
			t.Error(err)
			return
		}
		requests.Add(1)
		if len(data) < 6 || binary.BigEndian.Uint16(data) != p.C_Review {
			t.Errorf("unexpected frame: %x", data)
			return
		}
		var q p.ReviewRequest
		if err := json.Unmarshal(data[2:len(data)-4], &q); err != nil || q.Op != "answer" || q.RunID != "18446744073709551615" || q.PointID != "9007199254740993" || q.Result != "yes" || q.Source != "" || q.Identity != "" || q.Token != "" {
			t.Errorf("unexpected answer request: %+v (%v)", q, err)
		}
		// A disconnect after consuming the write could hide a committed result.
	}))
	defer server.Close()
	_, run := reviewCLI(t, "ws"+strings.TrimPrefix(server.URL, "http"))
	run("", "invalid_argument", "release", "1")
	run("", "invalid_argument", "delete-draft", "1", "--if-revision", "2", "--yes=false")
	run("", "invalid_argument", "run", "create", "1", "--if-released-at", "", "--kind", "qa", "--label", "QA")
	run("", "invalid_argument", "run", "close", "1", "--decision", "completed")
	run("", "invalid_argument", "run", "answer", "1", "2", "--result", "yes", "--source", "portal")
	run(reviewFixtureDraft+`{}`, "invalid_argument", "create", "--file", "-")
	run(strings.Replace(reviewFixtureDraft, `"9007199254740993"`, `9007199254740993`, 1), "invalid_argument", "create", "--file", "-")
	if requests.Load() != 0 {
		t.Fatal("invalid inputs sent a request")
	}
	err := run("", "review_outcome_unconfirmed", "run", "answer", "18446744073709551615", "9007199254740993", "--result", "yes")
	if requests.Load() != 1 || !bytes.Contains(err, []byte(`"retryable":false`)) {
		t.Fatalf("requests=%d error=%s", requests.Load(), err)
	}
}

// Use only the disposable server from test/customer-workspace-dev.mjs.
func TestReviewCLIRealServer(t *testing.T) {
	url := os.Getenv("NRC_CUSTOMER_CLI_TEST_URL")
	if url == "" {
		t.Skip("requires disposable fixture")
	}
	dir, run := reviewCLI(t, url)
	path := filepath.Join(dir, "draft.json")
	if err := os.WriteFile(path, []byte(reviewFixtureDraft), 0600); err != nil {
		t.Fatal(err)
	}
	form := func(args ...string) reviewFormReceipt {
		return reviewDecodeOutput[reviewFormReceipt](t, run("", "", args...))
	}
	runRecord := func(args ...string) p.ReviewRun {
		return reviewDecodeOutput[reviewRunReceipt](t, run("", "", append([]string{"run"}, args...)...)).Run
	}
	draft := form("create", "--file", path)
	const pointID = "9007199254740993"
	if draft.Form.Points[0].ID != pointID || draft.Form.Points[0].Section != "Login" {
		t.Fatalf("draft: %+v", draft)
	}
	updated := reviewDecodeOutput[reviewFormReceipt](t, run(reviewFixtureDraft, "", "update", draft.FormID, "--if-revision", draft.Revision, "--file", "-"))
	run("", "conflict", "release", draft.FormID, "--if-revision", draft.Revision)
	first := form("release", draft.FormID, "--if-revision", updated.Revision)
	withdrawn := form("withdraw-release", first.FormID, "--if-revision", first.Revision)
	released := form("release", first.FormID, "--if-revision", withdrawn.Revision)
	run("", "conflict", "run", "create", first.FormID, "--if-released-at", first.Form.ReleasedAt, "--kind", "qa", "--label", "Team")
	if empty := run("", "", "run", "list", "--fields", "id"); !bytes.Contains(empty, []byte(`"entries":[]`)) {
		t.Fatalf("unexpected empty run list: %s", empty)
	}
	created := runRecord("create", released.FormID, "--if-released-at", released.Form.ReleasedAt, "--kind", "qa", "--label", "Team")
	run("", "has_runs", "withdraw-release", released.FormID, "--if-revision", released.Revision)
	archived := form("archive", released.FormID, "--if-revision", released.Revision)
	run("", "archived", "run", "create", archived.FormID, "--if-released-at", released.Form.ReleasedAt, "--kind", "qa", "--label", "Team")
	form("restore", archived.FormID, "--if-revision", archived.Revision)
	run("", "", "list", "--limit", "1", "--fields", "form_id,revision,archived")
	run("", "", "run", "list", "--form", released.FormID, "--fields", "id,revision")
	run("", "", "run", "portal-accounts", created.ID, "--fields", "requester")
	runRecord("assign", "portal", created.ID, "--requester", "demo@example.test", "--name", "Demo")
	assigned := runRecord("assign", "staff", created.ID, "--name", "Ada", "--can-close")
	answered := runRecord("answer", created.ID, pointID, "--result", "unable", "--comment", "Unavailable")
	if len(answered.Answers) != 1 || answered.Answers[0].PointID != pointID {
		t.Fatalf("answer: %+v", answered.Answers)
	}
	invite := reviewDecodeOutput[map[string]string](t, run("", "", "run", "invite", created.ID, "--expires-at", fmt.Sprint(time.Now().Add(time.Hour).UnixNano())))
	if len(invite["token"]) != 64 || invite["invite_id"] == "" {
		t.Fatal("missing invitation ID or token")
	}
	preview := reviewDecodeOutput[reviewClosePreview](t, run("", "", "run", "close-preview", created.ID))
	if !preview.CanClose || preview.Answered != 1 || preview.Open != 1 || preview.NotAllYes != 1 || preview.Revision == assigned.Revision {
		t.Fatalf("preview: %+v", preview)
	}
	run("", "conflict", "run", "close", created.ID, "--if-revision", assigned.Revision, "--decision", "completed")
	closed := runRecord("close", created.ID, "--if-revision", preview.Revision, "--decision", "completed")
	if closed.ClosedSource != "staff" || closed.Decision != "completed" {
		t.Fatalf("closure: %+v", closed)
	}
	run("", "", "run", "revoke", created.ID, invite["invite_id"])
	copy := form("copy", released.FormID)
	retestForm := reviewDecodeOutput[reviewFormReceipt](t, run(strings.Replace(reviewFixtureDraft, `"v1"`, `"v2"`, 1), "", "update", copy.FormID, "--if-revision", copy.Revision, "--file", "-"))
	retestForm = form("release", copy.FormID, "--if-revision", retestForm.Revision)
	retest := runRecord("retest", created.ID, copy.FormID, "--if-released-at", retestForm.Form.ReleasedAt)
	if retest.PreviousRun != created.ID || retest.Label != created.Label || len(retest.Answers) != 0 || len(retest.Participants) != 0 {
		t.Fatalf("retest: %+v", retest)
	}
	if got := runRecord("get", created.ID); got.Decision != "completed" || len(got.Answers) != 1 {
		t.Fatalf("retest changed original run: %+v", got)
	}
	page := func(args ...string) reviewFormPage {
		return reviewDecodeOutput[reviewFormPage](t, run("", "", append([]string{"list", "--limit", "1", "--fields", "form_id"}, args...)...))
	}
	firstPage := page()
	if !firstPage.HasMore || len(firstPage.Entries) != 1 || firstPage.Entries[0].FormID != copy.FormID {
		t.Fatalf("first page: %+v", firstPage)
	}
	if lastPage := page("--cursor", firstPage.NextCursor); lastPage.HasMore || len(lastPage.Entries) != 1 || lastPage.Entries[0].FormID != released.FormID {
		t.Fatalf("second page: %+v", lastPage)
	}
	deletable := form("copy", released.FormID)
	run("", "", "delete-draft", deletable.FormID, "--if-revision", deletable.Revision, "--yes")
	run("", "not_found", "get", deletable.FormID)
}
