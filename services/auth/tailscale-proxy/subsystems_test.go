package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestSubsystemHealth(t *testing.T) {
	var calls atomic.Int32
	body, code := `{"status":"ok","connected_workspaces":["private"],"nrc_server":"secret-host"}`, 200
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path != "/health" || r.Method != "GET" || r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" || r.Header.Get("X-Tailscale-User") != "" {
			t.Error("health probe forwarded credentials or changed its fixed target")
		}
		w.Header().Set("Location", "/private")
		w.WriteHeader(code)
		fmt.Fprint(w, body)
	}))
	defer backend.Close()
	h := workspaceBoundary(subsystemHealth(map[string]string{"metrics": backend.URL + "/health", "publish": ""}), workspaceTestIdentity("alice@example.com"), workspaceTestPolicy(t))
	for _, tc := range []struct {
		body string
		code int
		want string
	}{
		{body, 200, "ok"},
		{"ok\n", 200, "ok"},
		{`{"status":"degraded","missing_thread_ids":[1,2]}`, 200, "degraded"},
		{`{"status":"mystery"}`, 200, "unknown"},
		{"<html>login</html>", 200, "unknown"},
		{strings.Repeat("x", 16385), 200, "unknown"},
		{"secret error", 503, "unavailable"},
		{"unauthorized", 401, "unknown"},
		{"forbidden", 403, "unknown"},
		{"not found", 404, "unknown"},
		{"redirect", 302, "unavailable"},
	} {
		body, code = tc.body, tc.code
		r := httptest.NewRequest("GET", "http://nrc/api/subsystems/metrics", nil)
		r.Header.Set("Cookie", "secret-cookie")
		r.Header.Set("Authorization", "secret-token")
		w := httptest.NewRecorder()
		before := calls.Load()
		h.ServeHTTP(w, r)
		if w.Code != 200 || w.Body.String() != fmt.Sprintf("{\"status\":%q}\n", tc.want) || w.Header().Get("Cache-Control") != "no-store" || calls.Load() != before+1 {
			t.Fatalf("status %s: HTTP %d %s", tc.want, w.Code, w.Body.String())
		}
	}
	for _, tc := range []struct {
		method, path string
		want         int
	}{
		{"GET", "/api/subsystems/publish", 200},
		{"GET", "/api/subsystems/metrics/private", 404},
		{"GET", "/api/subsystems/metrics?url=http://other", 404},
		{"POST", "/api/subsystems/metrics", 405},
		{"GET", "/api/subsystems/unknown", 404},
	} {
		w := httptest.NewRecorder()
		before := calls.Load()
		h.ServeHTTP(w, httptest.NewRequest(tc.method, "http://nrc"+tc.path, nil))
		if w.Code != tc.want || calls.Load() != before {
			t.Fatalf("%s %s: HTTP %d, unexpected upstream access", tc.method, tc.path, w.Code)
		}
		if tc.path == "/api/subsystems/publish" && w.Body.String() != "{\"status\":\"not_configured\"}\n" {
			t.Fatal(w.Body.String())
		}
	}
	denied := workspaceBoundary(subsystemHealth(map[string]string{"metrics": backend.URL}), fakeWhoIsClient{}, nil)
	w := httptest.NewRecorder()
	before := calls.Load()
	r := httptest.NewRequest("GET", "http://nrc/api/subsystems/metrics", nil)
	r.Header.Set("X-Tailscale-User", "forged@example.com")
	denied.ServeHTTP(w, r)
	if w.Code != 401 || calls.Load() != before {
		t.Fatal("unauthenticated health access permitted")
	}
}

func TestSubsystemHealthRouteWiring(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/health" {
			t.Error("wrong target")
		}
		fmt.Fprint(w, "ok\n")
	}))
	defer backend.Close()
	unavailable := httptest.NewServer(http.NotFoundHandler())
	unavailable.Close()
	for _, service := range []string{"search", "ai", "publish", "metrics"} {
		key := "NRC_" + strings.ToUpper(service) + "_HEALTH_URL"
		for _, target := range []string{"", backend.URL + "/health", unavailable.URL + "/health"} {
			t.Setenv(key, target)
			h := proxyHandler(http.NotFoundHandler(), workspaceTestIdentity("alice@example.com"), nil)
			w := httptest.NewRecorder()
			h.ServeHTTP(w, httptest.NewRequest("GET", "http://nrc/api/subsystems/"+service, nil))
			want := "ok"
			if target == "" {
				want = "not_configured"
			}
			if target == unavailable.URL+"/health" {
				want = "unavailable"
			}
			if w.Code != 200 || w.Body.String() != fmt.Sprintf("{\"status\":%q}\n", want) {
				t.Fatalf("%s: HTTP %d %s", service, w.Code, w.Body.String())
			}
		}
	}
}
