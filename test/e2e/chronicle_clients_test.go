package e2e

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

// Optional browser tooling is not a prerequisite for standalone Go tests.
// The full local acceptance invokes the fake-process test with this enabled.
func chronicleCheckRealClients(t *testing.T, workspace, summary string) {
	t.Helper()
	if os.Getenv("NRC_CHRONICLE_CLIENT_ACCEPTANCE") != "1" {
		return
	}
	root := repoRootFromThisFile(t)
	target, err := url.Parse(strings.Replace(wsURLForWorkspace(workspace), "ws://", "http://", 1))
	if err != nil {
		t.Fatal(err)
	}
	target.Path = ""
	proxy := httputil.NewSingleHostReverseProxy(target)
	static := http.FileServer(http.Dir(filepath.Join(root, "client")))
	token := chronicleJWTHeader(t, "worker", workspace, "user", "")["X-NRC-Auth"][0]
	// Only authentication is supplied by the disposable proxy. HTTP assets,
	// browser/CLI frames, server handlers, SQLite and the fake worker are real.
	frontend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
			if r.URL.Path != "/"+workspace {
				http.Error(w, "wrong workspace", http.StatusForbidden)
				return
			}
			r.Header.Set("X-NRC-Auth", token)
			proxy.ServeHTTP(w, r)
			return
		}
		static.ServeHTTP(w, r)
	}))
	defer frontend.Close()
	dir := t.TempDir()
	cli := filepath.Join(dir, "nrc")
	build := exec.Command("go", "build", "-o", cli, "./cmd/nrc")
	build.Dir = filepath.Join(root, "cli")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build CLI: %v\n%s", err, out)
	}
	cfgDir := filepath.Join(dir, ".config", "nrc")
	if err := os.MkdirAll(cfgDir, 0700); err != nil {
		t.Fatal(err)
	}
	cfg := "server: " + strings.Replace(frontend.URL, "http://", "ws://", 1) + "/\nworkspace_id: " + workspace + "\n"
	if err := os.WriteFile(filepath.Join(cfgDir, "config.yaml"), []byte(cfg), 0600); err != nil {
		t.Fatal(err)
	}
	for _, op := range []string{"history", "gaps", "status"} {
		cmd := exec.Command(cli, "chronicle", op)
		cmd.Env = append(os.Environ(), "HOME="+dir)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("real CLI %s: %v\n%s", op, err, out)
		}
		if !json.Valid(out) {
			t.Fatalf("CLI JSON invalid: %s", out)
		}
		if op == "history" {
			var result struct {
				Entries []protocol.ChronicleEntry `json:"entries"`
			}
			if json.Unmarshal(out, &result) != nil || len(result.Entries) != 1 || result.Entries[0].Summary != summary {
				t.Fatalf("CLI changed or omitted persisted result: %s", out)
			}
		}
		if op == "gaps" && !strings.Contains(string(out), "token_limit") {
			t.Fatalf("CLI omitted real gap: %s", out)
		}
		t.Logf("real CLI %s: %s", op, strings.TrimSpace(string(out)))
	}
	cmd := exec.Command("node", filepath.Join(root, "test/e2e/fixtures/chronicle_browser.mjs"))
	cmd.Env = append(os.Environ(), "NRC_ACCEPTANCE_URL="+frontend.URL, "NRC_ACCEPTANCE_WORKSPACE="+workspace, "NRC_ACCEPTANCE_SUMMARY="+summary)
	cmd.Dir = root
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("real browser: %v\n%s", err, out)
	} else {
		t.Log(strings.TrimSpace(string(out)))
	}
}
