package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/heavyhorst/nrc/cli/pkg/config"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	"github.com/spf13/cobra"
)

func executeNewsletter(t *testing.T, input string, args ...string) (string, error) {
	t.Helper()
	cmd := &cobra.Command{Use: "nrc", PersistentPreRun: rootCmd.PersistentPreRun}
	cmd.PersistentFlags().Bool("human", false, "")
	cmd.PersistentFlags().Bool("json", false, "")
	cmd.PersistentFlags().Bool("pretty", false, "")
	cmd.PersistentFlags().String("fields", "", "")
	cmd.AddCommand(newNewsletterCommand())
	cmd.SilenceErrors, cmd.SilenceUsage = true, true
	cmd.SetErr(io.Discard)
	cmd.SetIn(strings.NewReader(input))
	cmd.SetArgs(append([]string{"newsletter"}, args...))
	defer output.Configure(false, false, "")
	var err error
	data := captureStdout(t, func() { err = cmd.Execute() })
	return data, err
}

func TestNewsletterCLIImportPreviewAndConfirmation(t *testing.T) {
	_ = output.Configure(false, false, "")
	records := `[{"email":"anna@example.test","source":"Zoho export","confirmed_at":"2025-02-03T10:20:00Z","evidence":"DOI record 123","scope":"Product newsletter","external_id":"9007199254740993"}]`
	var confirmations []bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/newsletter/api/consents/import" || r.Header.Get("X-NRC-Workspace") != "cli-newsletter" || r.Header.Get("Authorization") != "" || r.Header.Get("X-NRC-Newsletter-Auth") != "" {
			t.Errorf("incorrect proxy request: %s %s %v", r.Method, r.URL.Path, r.Header)
		}
		var input struct {
			Records json.RawMessage `json:"records"`
			Confirm bool            `json:"confirm"`
		}
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			t.Error(err)
		}
		var want, got any
		_ = json.Unmarshal([]byte(records), &want)
		_ = json.Unmarshal(input.Records, &got)
		if !reflect.DeepEqual(got, want) {
			t.Errorf("proof changed: %s", input.Records)
		}
		confirmations = append(confirmations, input.Confirm)
		io.WriteString(w, `{"counts":{"total":1,"eligible":1,"imported":0,"skipped":0},"results":[{"email":"anna@example.test","status":"eligible"}]}`)
	}))
	defer server.Close()
	t.Setenv("HOME", t.TempDir())
	if err := (&config.Config{ProxyURL: server.URL, WorkspaceID: "cli-newsletter"}).Save(); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(t.TempDir(), "consents.json")
	if err := os.WriteFile(file, []byte(records), 0600); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"consent", "import", "--input", file}, {"consent", "import", "--input", file, "--confirm"}} {
		data, err := executeNewsletter(t, "", args...)
		if err != nil || !strings.Contains(data, `"eligible":1`) || !strings.Contains(data, "anna@example.test") {
			t.Fatalf("import: %s %v", data, err)
		}
	}
	if _, err := executeNewsletter(t, `{"records":`+records+`}`, "consent", "import"); err != nil {
		t.Fatal(err)
	}
	for _, input := range []string{`{"records":` + records + `,"confirm":true}`, `[]`, `null`, records + `{}`, strings.Repeat(" ", 65537)} {
		if _, err := executeNewsletter(t, input, "consent", "import"); err == nil {
			t.Fatalf("unsafe input accepted: %.100s", input)
		}
	}
	if !reflect.DeepEqual(confirmations, []bool{false, true, false}) {
		t.Fatalf("confirmation contract: %v", confirmations)
	}
}

func TestNewsletterCLICampaignWorkflow(t *testing.T) {
	_ = output.Configure(false, false, "")
	id := strings.Repeat("ab", 32)
	subject := "Serviceänderung ab 1. Dezember"
	draft := `{"kind":"service","audience":"selected_customers","customer_ids":["9007199254740993","17"],"service_reason":"Necessary migration notice","title":"Migration","template_id":"12","subject":"` + subject + `","variables":{"introduction":"Details"}}`
	var method, path string
	var payload map[string]any
	status := 200
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Method != method || r.URL.Path != "/newsletter/api"+path || r.Header.Get("X-NRC-Workspace") != "cli-newsletter" {
			t.Errorf("wrong request: %s %s", r.Method, r.URL.Path)
		}
		if method != "GET" {
			var got map[string]any
			decoder := json.NewDecoder(r.Body)
			decoder.UseNumber()
			if err := decoder.Decode(&got); err != nil {
				t.Error(err)
			}
			if !reflect.DeepEqual(got, payload) {
				t.Errorf("payload: %+v; want %+v", got, payload)
			}
		}
		w.WriteHeader(status)
		if method == "GET" {
			io.WriteString(w, `{"campaigns":[{"id":"`+id+`","revision":3},{"id":"archived-record","archived":true,"status":"sent","revision":4}],"subscribers":[{"contact_id":"9007199254740993"}],"templates":[{"id":"12"}],"customers":[{"customer_id":"17"}]}`)
		} else if status == 409 {
			io.WriteString(w, `{"error":"audience changed; review recipients again"}`)
		} else {
			io.WriteString(w, `{"revision":3,"count":9007199254740993,"token":"reviewed-token"}`)
		}
	}))
	defer server.Close()
	t.Setenv("HOME", t.TempDir())
	if err := (&config.Config{ProxyURL: server.URL, WorkspaceID: "cli-newsletter"}).Save(); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"state"}, {"templates"}, {"customers"}, {"campaign", "list"}, {"subscriber", "list"}} {
		method, path = "GET", "/state"
		data, err := executeNewsletter(t, "", args...)
		if err != nil || !json.Valid([]byte(data)) || strings.TrimSpace(data) == "null" {
			t.Fatalf("read: %s %v", data, err)
		}
		if (args[0] == "customers" || args[0] == "state") && !strings.Contains(data, `"customer_id":"17"`) {
			t.Fatalf("customer ID lost: %s", data)
		}
		if args[0] == "campaign" && strings.Contains(data, "archived-record") {
			t.Fatal("default list includes archived campaigns")
		}
	}
	archivedData, archivedErr := executeNewsletter(t, "", "campaign", "list", "--include-archived", "--fields", "id,archived")
	if archivedErr != nil || !strings.Contains(archivedData, `"id":"archived-record"`) || !strings.Contains(archivedData, `"archived":true`) {
		t.Fatalf("archive list: %s %v", archivedData, archivedErr)
	}
	decoder := json.NewDecoder(strings.NewReader(draft))
	method, path, status = "POST", "/subscribers/search", 200
	payload = map[string]any{"query": "example.com", "offset": json.Number("25"), "limit": json.Number("10")}
	if _, err := executeNewsletter(t, "", "subscriber", "search", "--query", "example.com", "--offset", "25", "--limit", "10"); err != nil {
		t.Fatal(err)
	}
	payload = map[string]any{"query": "", "offset": json.Number("0"), "limit": json.Number("25"), "cursor": map[string]any{"updated_at": "100", "asset_id": "9007199254740993"}}
	if _, err := executeNewsletter(t, "", "subscriber", "search", "--cursor", `{"updated_at":"100","asset_id":"9007199254740993"}`); err != nil {
		t.Fatal(err)
	}
	if _, err := executeNewsletter(t, "", "subscriber", "search", "--offset", "25"); err == nil {
		t.Fatal("unfiltered offset accepted instead of cursor")
	}
	payload = nil
	decoder.UseNumber()
	_ = decoder.Decode(&payload)
	method, path, status = "POST", "/campaigns", 201
	data, err := executeNewsletter(t, draft, "campaign", "create")
	if err != nil || !strings.Contains(data, "9007199254740993") {
		t.Fatalf("create/number preservation: %s %v", data, err)
	}
	method, path, status = "PUT", "/campaigns/"+id, 200
	payload["revision"] = json.Number("2")
	// Go's backend struct decoder folds both aliases to Revision. Neither the
	// canonical nor Unicode-spelled value may override the explicit flag.
	aliasedDraft := strings.TrimSuffix(draft, "}") + `,"revision":99,"revi\u017fion":3}`
	if _, err := executeNewsletter(t, aliasedDraft, "campaign", "update", id, "--revision", "2"); err != nil {
		t.Fatal(err)
	}
	for _, action := range []string{"delete", "archive", "restore", "audience", "preview", "test", "send"} {
		method, path, status = "POST", "/campaigns/"+id+"/"+action, 200
		payload = map[string]any{"revision": json.Number("3")}
		args := []string{"campaign", action, id, "--revision", "3"}
		if action == "test" {
			payload["email"] = "test@example.test"
			args = append(args, "--email", "test@example.test")
		}
		if action == "send" {
			payload["confirmation"], payload["audience_token"] = subject, "reviewed-token"
			args = append(args, "--confirm-subject", subject, "--audience-token", "reviewed-token")
			status = 202
		}
		if _, err := executeNewsletter(t, "", args...); err != nil {
			t.Fatal(err)
		}
	}
	status = 409
	before := calls
	if _, err := executeNewsletter(t, "", "campaign", "send", id, "--revision", "3", "--confirm-subject", subject, "--audience-token", "reviewed-token"); err == nil || !strings.Contains(err.Error(), "audience changed") {
		t.Fatalf("conflict swallowed: %v", err)
	}
	if calls != before+1 {
		t.Fatal("mutation retried")
	}
	for _, args := range [][]string{{"campaign", "send", id, "--revision", "3"}, {"campaign", "send", id, "--confirm-subject", subject}, {"campaign", "audience", id, "--revision", "0"}, {"campaign", "preview", "../state", "--revision", "3"}} {
		if _, err := executeNewsletter(t, "", args...); err == nil {
			t.Fatalf("unsafe command accepted: %v", args)
		}
	}
	if calls != before+1 {
		t.Fatal("rejected command contacted API")
	}
	for _, action := range []string{"invite", "unsubscribe"} {
		method, path, status = "POST", "/subscribers/9007199254740993/"+action, 200
		payload = map[string]any{}
		args := []string{"subscriber", action, "9007199254740993"}
		if action == "invite" {
			payload["source"] = "Customer request #123"
			args = append(args, "--source", "Customer request #123")
		}
		if _, err := executeNewsletter(t, "", args...); err != nil {
			t.Fatal(err)
		}
	}
}

func TestNewsletterCLIRefusesRedirectsAndURLCredentials(t *testing.T) {
	hits := 0
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits++ }))
	defer target.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, target.URL, 307) }))
	defer server.Close()
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ProxyURL: server.URL, WorkspaceID: "cli-newsletter"}
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	if err := runNewsletter(context.Background(), "POST", "/consents/import", map[string]any{}, &result); err == nil || !strings.Contains(err.Error(), "307") {
		t.Fatalf("redirect accepted: %v", err)
	}
	if hits != 0 {
		t.Fatal("redirect forwarded consent data")
	}
	cfg.ProxyURL = "https://user:private-password@example.test"
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	if err := runNewsletter(context.Background(), "GET", "/state", nil, &result); err == nil || strings.Contains(err.Error(), "private-password") {
		t.Fatalf("URL credentials accepted or exposed: %v", err)
	}
}

func TestNewsletterCLIFieldProjection(t *testing.T) {
	state := `{"campaigns":[],"subscribers":[],"templates":[],"customers":[]}`
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, state) }))
	defer server.Close()
	t.Setenv("HOME", t.TempDir())
	if err := (&config.Config{ProxyURL: server.URL, WorkspaceID: "cli-newsletter"}).Save(); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"campaign", "list", "--fields", "id,revision"}, {"subscriber", "list", "--fields", "email,source,confirmed_at,import_proof"}, {"templates", "--fields", "id,variables"}, {"customers", "--fields", "customer_id,contacts"}} {
		data, err := executeNewsletter(t, "", args...)
		if err != nil || strings.TrimSpace(data) != "[]" {
			t.Fatalf("empty projected list %v: %s %v", args, data, err)
		}
	}
	for _, subscribers := range []string{
		`[{"email":"new@example.test"},{"email":"old@example.test","source":"Zoho","confirmed_at":"2025-01-01T00:00:00Z","import_proof":{"external_id":"9007199254740993"}}]`,
		`[{"email":"old@example.test","source":"Zoho","confirmed_at":"2025-01-01T00:00:00Z","import_proof":{"external_id":"9007199254740993"}},{"email":"new@example.test"}]`,
	} {
		state = `{"subscribers":` + subscribers + `}`
		data, err := executeNewsletter(t, "", "subscriber", "list", "--fields", "email,source,confirmed_at,import_proof")
		var got, want any
		if json.Unmarshal([]byte(data), &got) != nil || json.Unmarshal([]byte(subscribers), &want) != nil || err != nil || !reflect.DeepEqual(got, want) {
			t.Fatalf("optional fields/order: %s %v", data, err)
		}
	}
}
