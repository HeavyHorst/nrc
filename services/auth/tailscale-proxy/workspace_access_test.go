package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"

	"tailscale.com/client/tailscale/apitype"
	"tailscale.com/tailcfg"
)

const testWorkspacePolicy = `{"alice-private":{"owner":"alice@example.com","members":["tag:amp"]},"bob-private":{"owner":"bob@example.com"},"team":{"owner":"alice@example.com","members":["bob@example.com"]}}`

func workspaceTestPolicy(t *testing.T) workspacePolicy {
	t.Helper()
	p, err := parseWorkspacePolicy(testWorkspacePolicy)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func workspaceTestIdentity(identity string) fakeWhoIsClient {
	response := &apitype.WhoIsResponse{Node: &tailcfg.Node{}, UserProfile: &tailcfg.UserProfile{LoginName: identity}}
	if strings.HasPrefix(identity, "tag:") {
		response.Node.Tags = []string{identity}
	}
	return fakeWhoIsClient{response: response}
}

func TestWorkspacePolicyOptIn(t *testing.T) {
	for _, value := range []string{"", "{}", testWorkspacePolicy} {
		p, err := parseWorkspacePolicy(value)
		if err != nil {
			t.Fatal(err)
		}
		if !p.allows("workspace1", "stranger@example.com") || !p.allows("new-workspace", "tag:cli") {
			t.Fatal("unconfigured workspaces must stay tailnet-open")
		}
	}
	p := workspaceTestPolicy(t)
	for _, tc := range []struct {
		workspace, identity string
		allowed             bool
	}{
		{"alice-private", "alice@example.com", true},
		{"alice-private", "alice@other.example", false},
		{"alice-private", "bob@example.com", false},
		{"alice-private", "tag:amp", true},
		{"bob-private", "tag:amp", false},
		{"team", "bob@example.com", true},
		{"team", "mallory@example.com", false},
	} {
		if got := p.allows(tc.workspace, tc.identity); got != tc.allowed {
			t.Errorf("%+v: got %v", tc, got)
		}
	}
	for _, value := range []string{"null", " ", "[]", "{} {}", `{"private":{}}`, `{"private":{"owner":"alice"}}`, `{"private":{"owner":"alice@example.com","members":["*"]}}`, `{"private":{"owner":"alice@example.com","member":[]}}`, `{"private/other":{"owner":"alice@example.com"}}`} {
		if _, err := parseWorkspacePolicy(value); err == nil {
			t.Errorf("accepted malformed policy %q", value)
		}
	}
}

func TestWorkspaceBrowserOriginsThroughReverseProxy(t *testing.T) {
	var forwarded atomic.Int32
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		forwarded.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer backend.Close()
	backendURL, _ := url.Parse(backend.URL)
	proxy := httptest.NewTLSServer(proxyHandler(httputil.NewSingleHostReverseProxy(backendURL), workspaceTestIdentity("alice@example.com"), workspaceTestPolicy(t)))
	defer proxy.Close()
	for _, endpoint := range []string{"/alice-private", "/ai/retrieve", "/search", "/search/health", "/ai/ask/apply"} {
		for _, origin := range []string{"", proxy.URL, "https://evil.example", "null", strings.Replace(proxy.URL, "https:", "http:", 1)} {
			method := http.MethodPost
			if endpoint == "/alice-private" || endpoint == "/search/health" {
				method = http.MethodGet
			}
			r, err := http.NewRequest(method, proxy.URL+endpoint, strings.NewReader(`{"workspace":"alice-private"}`))
			if err != nil {
				t.Fatal(err)
			}
			if origin != "" {
				r.Header.Set("Origin", origin)
			}
			r.Header.Set("Content-Type", "text/plain") // No CORS preflight required.
			r.Header.Set("X-Forwarded-Host", "evil.example")
			r.Header.Set("X-Forwarded-Proto", "https")
			if endpoint == "/alice-private" {
				r.Header.Set("Upgrade", "websocket")
			}
			before := forwarded.Load()
			response, err := proxy.Client().Do(r)
			if err != nil {
				t.Fatal(err)
			}
			response.Body.Close()
			if origin == "" || origin == proxy.URL {
				if response.StatusCode != 204 || forwarded.Load() != before+1 {
					t.Fatalf("authorized origin %q to %s: %d", origin, endpoint, response.StatusCode)
				}
			} else if response.StatusCode != 403 || forwarded.Load() != before {
				t.Fatalf("foreign origin %q reached %s: status %d", origin, endpoint, response.StatusCode)
			}
		}
	}
}

func TestOpenPolicyPreservesLegacyUploads(t *testing.T) {
	oldPath := fileStoragePath
	fileStoragePath = t.TempDir()
	t.Cleanup(func() { fileStoragePath = oldPath })
	for _, config := range []string{"", "{}", " \n { \t } "} {
		policy, err := parseWorkspacePolicy(config)
		if err != nil || policy != nil {
			t.Fatalf("empty policy not normalized: %q %v", config, err)
		}
		for _, workspace := range []string{"", "team:2026", strings.Repeat("long-workspace", 30)} {
			var body bytes.Buffer
			form := multipart.NewWriter(&body)
			part, _ := form.CreateFormFile("file", "legacy.txt")
			_, _ = io.WriteString(part, "legacy content")
			_ = form.Close()
			r := httptest.NewRequest("POST", "/upload?workspace="+url.QueryEscape(workspace), &body)
			r.Header.Set("Content-Type", form.FormDataContentType())
			w := httptest.NewRecorder()
			proxyHandler(http.NotFoundHandler(), workspaceTestIdentity("alice@example.com"), policy).ServeHTTP(w, r)
			if w.Code != 200 {
				t.Fatalf("open upload %q %q: %d %s", config, workspace, w.Code, w.Body)
			}
			if workspace != "" {
				marker, err := os.ReadFile(fileWorkspaceMarker(generateFileID([]byte("legacy content")), workspace))
				if err != nil || string(marker) != workspace {
					t.Fatalf("workspace marker: %q %v", marker, err)
				}
			}
		}
	}
	r := httptest.NewRequest("POST", "/upload?workspace=team:2026", nil)
	w := httptest.NewRecorder()
	proxyHandler(http.NotFoundHandler(), workspaceTestIdentity("alice@example.com"), workspaceTestPolicy(t)).ServeHTTP(w, r)
	if w.Code != 400 {
		t.Fatalf("protected upload name validation: %d", w.Code)
	}
}

func TestWorkspaceBoundary(t *testing.T) {
	policy := workspaceTestPolicy(t)
	for _, tc := range []struct {
		name, identity, method, path, body string
		ws                                 bool
		status                             int
	}{
		{"owner", "alice@example.com", "GET", "/alice-private", "", true, 204},
		{"other user", "bob@example.com", "GET", "/alice-private", "", true, 403},
		{"same nickname", "alice@other.example", "GET", "/alice-private", "", true, 403},
		{"tag allowed", "tag:amp", "GET", "/alice-private", "", true, 204},
		{"tag denied", "tag:amp", "GET", "/bob-private", "", true, 403},
		{"existing open", "bob@example.com", "GET", "/workspace1", "", true, 204},
		{"new open", "bob@example.com", "GET", "/brand-new", "", true, 204},
		{"encoded workspace", "bob@example.com", "GET", "/alice%2dprivate", "", true, 400},
		{"query alias", "bob@example.com", "GET", "/alice-private?x=1", "", true, 400},
		{"search health", "bob@example.com", "GET", "/search/health", "", false, 204},
		{"search GET denied", "bob@example.com", "GET", "/search", "", false, 403},
		{"search health subpath denied", "bob@example.com", "GET", "/search/health/private", "", false, 403},
		{"search health upgrade denied", "bob@example.com", "GET", "/search/health", "", true, 403},
		{"search health POST scoped", "bob@example.com", "POST", "/search/health", `{"workspace":"alice-private"}`, false, 403},
		{"search leak", "bob@example.com", "POST", "/search", `{"workspace":"alice-private"}`, false, 403},
		{"search upgrade spoof", "bob@example.com", "POST", "/search", `{"workspace":"alice-private"}`, true, 403},
		{"search member", "bob@example.com", "POST", "/search", `{"workspace":"team"}`, false, 204},
		{"search open", "bob@example.com", "POST", "/search", `{"workspace":"workspace1"}`, false, 204},
		{"Sullivan read", "bob@example.com", "POST", "/ai/retrieve", `{"workspace":"alice-private"}`, false, 403},
		{"Sullivan ask", "bob@example.com", "POST", "/ai/ask", `{"workspace":"alice-private"}`, false, 403},
		{"Sullivan mutation", "bob@example.com", "POST", "/ai/ask/apply", `{"workspace":"alice-private"}`, false, 403},
		{"Sullivan reset", "bob@example.com", "POST", "/ai/ask/session/reset", `{"workspace":"alice-private"}`, false, 403},
		{"missing reset scope", "bob@example.com", "POST", "/ai/ask/session/reset", `{"session_id":"known"}`, false, 400},
		{"body duplicates", "bob@example.com", "POST", "/ai/ask", `{"workspace":"workspace1","Workspace":"alice-private"}`, false, 403},
		{"fragment alias", "bob@example.com", "POST", "/ai/ask", `{"workspace":"alice-private#open"}`, false, 400},
		{"whitespace alias", "bob@example.com", "POST", "/ai/ask", `{"workspace":"alice-private "}`, false, 400},
		{"trailing JSON", "bob@example.com", "POST", "/search", `{"workspace":"workspace1"} {"workspace":"alice-private"}`, false, 400},
		{"path normalization", "bob@example.com", "POST", "/something/../ai/ask", `{"workspace":"alice-private"}`, false, 400},
		{"upload denied", "bob@example.com", "POST", "/upload?workspace=alice-private", "", false, 403},
		{"upload upgrade spoof", "bob@example.com", "POST", "/upload?workspace=alice-private", "", true, 403},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			handler := workspaceBoundary(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				for _, name := range []string{"X-NRC-User-Type", "X-NRC-Bot-Secret", "X-NRC-Bot-Nickname"} {
					if r.Header.Get(name) != "" {
						t.Errorf("forged service header survived: %s", name)
					}
				}
				body, _ := io.ReadAll(r.Body)
				if string(body) != tc.body {
					t.Errorf("forwarded body changed: %s", body)
				}
				if tc.ws {
					payload, err := base64.RawURLEncoding.DecodeString(strings.Split(r.Header.Get("X-NRC-Auth"), ".")[1])
					if err != nil {
						t.Fatal(err)
					}
					var claims proxyJWTClaims
					if err := json.Unmarshal(payload, &claims); err != nil {
						t.Fatal(err)
					}
					if claims.Sub != tc.identity || claims.Workspace != strings.TrimPrefix(tc.path, "/") {
						t.Errorf("incorrect claims: %+v", claims)
					}
				}
				w.WriteHeader(204)
			}), workspaceTestIdentity(tc.identity), policy)
			r := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
			r.Header.Set("X-Tailscale-User", "alice@example.com")
			r.Header.Set("X-NRC-User-Type", "admin")
			r.Header.Set("X-NRC-Bot-Secret", "forged")
			r.Header.Set("X-NRC-Bot-Nickname", "sullivan-ai")
			if tc.ws {
				r.Header.Set("Upgrade", "websocket")
			}
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, r)
			if w.Code != tc.status {
				t.Fatalf("status %d, want %d: %s", w.Code, tc.status, w.Body)
			}
			if tc.status != 204 && calls != 0 {
				t.Fatal("denied request reached backend")
			}
		})
	}
}

func TestWorkspaceBoundarySessionAndIdentityFailure(t *testing.T) {
	policy := workspaceTestPolicy(t)
	for _, identity := range []string{"bob@example.com", "alice@example.com"} {
		h := workspaceBoundary(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			want := `["alice-private"]`
			if identity == "alice@example.com" {
				want = `["bob-private"]`
			}
			if got := r.Header.Get("X-NRC-Denied-Workspaces"); got != want {
				t.Errorf("denied = %s, want %s", got, want)
			}
		}), workspaceTestIdentity(identity), policy)
		r := httptest.NewRequest("GET", "/ai/ask/session/known?workspace=workspace1", nil)
		r.Header.Set("X-NRC-Denied-Workspaces", "[]")
		h.ServeHTTP(httptest.NewRecorder(), r)
	}
	h := workspaceBoundary(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Fatal("identity failure reached backend") }), fakeWhoIsClient{}, policy)
	r := httptest.NewRequest("POST", "/search", strings.NewReader(`{"workspace":"workspace1"}`))
	r.Header.Set("X-Tailscale-User", "alice@example.com")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 401 {
		t.Fatalf("missing identity status = %d", w.Code)
	}
}

func TestWorkspaceFilesAndLegacyMigration(t *testing.T) {
	oldPath := fileStoragePath
	fileStoragePath = t.TempDir()
	t.Cleanup(func() { fileStoragePath = oldPath })
	policy := workspaceTestPolicy(t)
	backend := http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Fatal("file request reached backend") })
	handler := func(identity string, p workspacePolicy) http.Handler {
		return proxyHandler(backend, workspaceTestIdentity(identity), p)
	}
	upload := func(workspace, content string) string {
		t.Helper()
		var body bytes.Buffer
		form := multipart.NewWriter(&body)
		part, _ := form.CreateFormFile("file", "private.txt")
		_, _ = io.WriteString(part, content)
		_ = form.Close()
		r := httptest.NewRequest("POST", "/upload?workspace="+workspace, &body)
		r.Header.Set("Content-Type", form.FormDataContentType())
		w := httptest.NewRecorder()
		handler("alice@example.com", policy).ServeHTTP(w, r)
		if w.Code != 200 {
			t.Fatalf("upload: %d %s", w.Code, w.Body)
		}
		return generateFileID([]byte(content))
	}
	privateID := upload("alice-private", "alice's private file")
	publicID := upload("workspace1", "public file")
	legacyID := generateFileID([]byte("legacy"))
	if err := os.WriteFile(filepath.Join(fileStoragePath, legacyID), []byte("legacy"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		identity, fileID string
		status           int
	}{
		{"alice@example.com", privateID, 200},
		{"bob@example.com", privateID, 403},
		{"alice@other.example", privateID, 403},
		{"bob@example.com", publicID, 200},
		{"alice@example.com", legacyID, 403},
	} {
		for _, method := range []string{"GET", "HEAD"} {
			r := httptest.NewRequest(method, "/files/"+tc.fileID+"?workspace=workspace1&inline=true", nil)
			w := httptest.NewRecorder()
			handler(tc.identity, policy).ServeHTTP(w, r)
			if w.Code != tc.status {
				t.Fatalf("%s %s %s: %d want %d", method, tc.identity, tc.fileID, w.Code, tc.status)
			}
		}
	}
	r := httptest.NewRequest("POST", "/exports", strings.NewReader(fmt.Sprintf(`{"format":"pdf","attachments":[{"fileId":%q}]}`, privateID)))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	handler("bob@example.com", policy).ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatalf("export bypass: %d %s", w.Code, w.Body)
	}
	// Open mode preserves legacy downloads; turning on protection fails closed.
	w = httptest.NewRecorder()
	handler("bob@example.com", nil).ServeHTTP(w, httptest.NewRequest("GET", "/files/"+legacyID, nil))
	if w.Code != 200 {
		t.Fatalf("open legacy download: %d", w.Code)
	}
	count, err := assignLegacyFiles("workspace1")
	if err != nil || count != 1 {
		t.Fatalf("legacy migration: %d %v", count, err)
	}
	if !(workspaceAccess{policy, "bob@example.com"}).allowsFile(legacyID) || (workspaceAccess{policy, "bob@example.com"}).allowsFile(privateID) {
		t.Fatal("migration changed private grants or failed to open legacy files")
	}
	count, err = assignLegacyFiles("workspace1")
	if err != nil || count != 0 {
		t.Fatalf("migration not idempotent: %d %v", count, err)
	}
	// Removing a member takes effect even though the file marker still exists.
	delete(policy, "team")
	policy["alice-private"] = workspaceMembers{Owner: "charlie@example.com"}
	if (workspaceAccess{policy, "alice@example.com"}).allowsFile(privateID) {
		t.Fatal("old owner still has file access")
	}
	// A truncated marker must not turn a private workspace into an unknown,
	// therefore open, workspace. Marker filenames bind their complete contents.
	if err := os.WriteFile(fileWorkspaceMarker(privateID, "alice-private"), []byte("alice"), 0600); err != nil {
		t.Fatal(err)
	}
	if (workspaceAccess{policy, "bob@example.com"}).allowsFile(privateID) {
		t.Fatal("corrupt grant exposed a private file")
	}
}

func TestSharedFileGrantsAndMigrationLock(t *testing.T) {
	oldPath := fileStoragePath
	fileStoragePath = t.TempDir()
	t.Cleanup(func() { fileStoragePath = oldPath })
	policy := workspaceTestPolicy(t)
	fileID := generateFileID([]byte("same uploaded bytes"))
	if err := recordFileWorkspace(fileID, "alice-private"); err != nil {
		t.Fatal(err)
	}
	if (workspaceAccess{policy, "bob@example.com"}).allowsFile(fileID) {
		t.Fatal("first grant exposed another workspace")
	}
	if err := recordFileWorkspace(fileID, "bob-private"); err != nil {
		t.Fatal(err)
	}
	for _, identity := range []string{"alice@example.com", "bob@example.com"} {
		if !(workspaceAccess{policy, identity}).allowsFile(fileID) {
			t.Fatalf("missing independent grant: %s", identity)
		}
	}
	if (workspaceAccess{policy, "mallory@example.com"}).allowsFile(fileID) {
		t.Fatal("shared blob became public")
	}
	lock, err := os.Open(fileStoragePath)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_SH|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	if _, err := assignLegacyFiles("workspace1"); err == nil {
		t.Fatal("migration must refuse while proxy holds storage lock")
	}
}
