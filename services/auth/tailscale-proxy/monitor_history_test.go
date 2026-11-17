package main

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestMonitorHistoryBatch(t *testing.T) {
	secret := strings.Repeat("s", 32)
	const good = `{"version":1,"workspace":"alice-private","monitor_id":"batch","monitor_ids":["2","18446744073709551615"],"results":[{"monitor_id":"2","status":200,"rows":[]},{"monitor_id":"18446744073709551615","status":404,"rows":[]}]}`
	body := good
	var calls atomic.Int32
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path != "/v1/history/batch/uptime" || r.Header.Get("Authorization") != "Bearer "+secret || r.Header.Get("Cookie") != "" || r.URL.Query().Get("ids") != "2,18446744073709551615" {
			t.Error("batch credentials or scope")
		}
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, body)
	}))
	defer backend.Close()
	h := workspaceBoundary(monitorHistoryGateway(backend.URL, "alice-private", secret), workspaceTestIdentity("alice@example.com"), workspaceTestPolicy(t))
	read := func(query, workspace string, want int) {
		t.Helper()
		r := httptest.NewRequest("GET", "http://nrc/monitoring/history/batch/uptime?"+query, nil)
		r.Header.Set("X-NRC-Workspace", workspace)
		r.Header.Set("Cookie", "private")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != want {
			t.Fatalf("status %d: %s", w.Code, w.Body.String())
		}
	}
	const query = "resolution=1h&ids=2,18446744073709551615"
	read(query, "alice-private", 200)
	for _, invalid := range []string{strings.Replace(good, "alice-private", "other", 1), strings.Replace(good, `"monitor_id":"2"`, `"monitor_id":"3"`, 1), strings.Replace(good, `["2","18446744073709551615"]`, `["3","18446744073709551615"]`, 1)} {
		body = invalid
		read(query, "alice-private", 502)
	}
	before := calls.Load()
	for _, invalid := range []string{"ids=", "ids=0", "ids=02", "ids=2,2", "ids=18446744073709551616", "ids=" + strings.Repeat("2,", 16) + "3", query + "&ids=4", query + "&workspace=other", query + "&identity=x", query + "&acceptance=all"} {
		read(invalid, "alice-private", 400)
	}
	read(query, "other", 403)
	if calls.Load() != before {
		t.Fatal("rejected request reached backend")
	}
}

func TestMonitorHistoryBoundary(t *testing.T) {
	secret := strings.Repeat("s", 32)
	var calls atomic.Int32
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path != "/v1/history/123/samples" || r.URL.RawQuery != "resolution=5m" || r.Header.Get("Authorization") != "Bearer "+secret || r.Header.Get("Cookie") != "" || r.Header.Get("X-NRC-Auth") != "" {
			t.Error("wrong scope or credentials forwarded")
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Set-Cookie", "private")
		io.WriteString(w, `{"version":1,"workspace":"alice-private","monitor_id":"123","rows":[{"value":17}]}`)
	}))
	defer backend.Close()
	t.Setenv("NRC_MONITOR_HISTORY_BACKEND", backend.URL)
	t.Setenv("NRC_MONITOR_HISTORY_WORKSPACE", "alice-private")
	t.Setenv("NRC_HISTORY_SECRET", secret)
	for _, tc := range []struct {
		identity, workspace, method, suffix, origin string
		want                                        int
	}{
		{"alice@example.com", "alice-private", "GET", "123/samples?resolution=5m", "", 200},
		{"bob@example.com", "alice-private", "GET", "123/samples", "", 403},
		{"alice@example.com", "other", "GET", "123/samples", "", 403},
		{"alice@example.com", "", "GET", "123/samples", "", 403},
		{"alice@example.com", "alice-private", "POST", "123/samples", "", 405},
		{"alice@example.com", "alice-private", "GET", "123/samples?workspace=other", "", 400},
		{"alice@example.com", "alice-private", "GET", "123/samples?resolution=5m&resolution=1h", "", 400},
		{"alice@example.com", "alice-private", "GET", "123/config", "", 404},
		{"alice@example.com", "alice-private", "GET", "123/samples", "https://evil.example", 403},
	} {
		h := proxyHandler(http.NotFoundHandler(), workspaceTestIdentity(tc.identity), workspaceTestPolicy(t))
		r := httptest.NewRequest(tc.method, "http://nrc/monitoring/history/"+tc.suffix, nil)
		r.Header.Set("X-NRC-Workspace", tc.workspace)
		r.Header.Set("Authorization", "Bearer forged")
		r.Header.Set("Cookie", "private")
		r.Header.Set("X-NRC-Auth", "forged")
		if tc.origin != "" {
			r.Header.Set("Origin", tc.origin)
		}
		before := calls.Load()
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.want || (tc.want != 200 && calls.Load() != before) || w.Header().Get("Set-Cookie") != "" {
			t.Fatalf("%+v: status=%d calls=%d body=%s", tc, w.Code, calls.Load()-before, w.Body.String())
		}
		if tc.want == 200 && (w.Body.String() != `{"version":1,"workspace":"alice-private","monitor_id":"123","rows":[{"value":17}]}` || w.Header().Get("Cache-Control") != "no-store") {
			t.Fatal(w)
		}
	}
	// Open workspace policy does not allow unauthenticated history access.
	h := proxyHandler(http.NotFoundHandler(), fakeWhoIsClient{}, nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "http://nrc/monitoring/history/123/samples", nil))
	if w.Code != 401 {
		t.Fatal(w.Code)
	}
}

func TestMonitorHistoryUpstreamFailures(t *testing.T) {
	for _, code := range []int{302, 401, 400, 404, 422, 503, 200} {
		t.Run(http.StatusText(code), func(t *testing.T) {
			backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Location", "http://secret.invalid/")
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(code)
				if code == 200 {
					io.WriteString(w, strings.Repeat("x", (4<<20)+1))
				} else {
					io.WriteString(w, "private backend details")
				}
			}))
			defer backend.Close()
			h := workspaceBoundary(monitorHistoryGateway(backend.URL, "alice-private", strings.Repeat("s", 32)), workspaceTestIdentity("alice@example.com"), workspaceTestPolicy(t))
			r := httptest.NewRequest("GET", "http://nrc/monitoring/history/123/runs", nil)
			r.Header.Set("X-NRC-Workspace", "alice-private")
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			want := code
			if code == 302 || code == 401 || code == 200 {
				want = 502
			}
			if w.Code != want || strings.Contains(w.Body.String(), "private") || w.Header().Get("Location") != "" {
				t.Fatalf("%d %s", w.Code, w.Body.String())
			}
		})
	}
}

func TestMonitorHistoryRejectsWrongScope(t *testing.T) {
	for _, body := range []string{
		`{"version":1,"workspace":"other","monitor_id":"123","rows":[]}`,
		`{"version":1,"workspace":"alice-private","monitor_id":"124","rows":[]}`,
		`{"version":2,"workspace":"alice-private","monitor_id":"123","rows":[]}`,
		`not json`,
	} {
		backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, body)
		}))
		h := workspaceBoundary(monitorHistoryGateway(backend.URL, "alice-private", strings.Repeat("s", 32)), workspaceTestIdentity("alice@example.com"), workspaceTestPolicy(t))
		r := httptest.NewRequest("GET", "http://nrc/monitoring/history/123/runs", nil)
		r.Header.Set("X-NRC-Workspace", "alice-private")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		backend.Close()
		if w.Code != 502 || strings.Contains(w.Body.String(), body) {
			t.Fatalf("%d %s", w.Code, w.Body.String())
		}
	}
}

func TestMonitorHistoryAdmissionAndCancellation(t *testing.T) {
	entered := make(chan struct{}, 2)
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		entered <- struct{}{}
		<-r.Context().Done()
	}))
	defer backend.Close()
	h := workspaceBoundary(monitorHistoryGateway(backend.URL, "alice-private", strings.Repeat("s", 32)), workspaceTestIdentity("alice@example.com"), workspaceTestPolicy(t))
	request := func(ctx context.Context) int {
		r := httptest.NewRequest("GET", "http://nrc/monitoring/history/123/runs", nil).WithContext(ctx)
		r.Header.Set("X-NRC-Workspace", "alice-private")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w.Code
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	done := make(chan int, 2)
	for range 2 {
		go func() { done <- request(ctx) }()
	}
	for range 2 {
		select {
		case <-entered:
		case <-ctx.Done():
			t.Fatal("two reads did not reach upstream")
		}
	}
	if code := request(ctx); code != 503 {
		t.Fatalf("third read returned %d", code)
	}
	cancel()
	for range 2 {
		if code := <-done; code != 502 {
			t.Fatalf("canceled read returned %d", code)
		}
	}
	// Cancellation must free admission slots; a canceled request reaches the
	// transport and fails as unavailable rather than remaining busy.
	if code := request(ctx); code != 502 {
		t.Fatalf("slot leaked after cancellation: %d", code)
	}
}

func TestMonitorHistorySlowReadersReleaseSlots(t *testing.T) {
	large := `{"version":1,"workspace":"alice-private","monitor_id":"123","rows":["` + strings.Repeat("x", 2<<20) + `"]}`
	entered := make(chan struct{}, 2)
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.HasSuffix(r.URL.Path, "/samples") {
			entered <- struct{}{}
			io.WriteString(w, large)
		} else {
			io.WriteString(w, `{"version":1,"workspace":"alice-private","monitor_id":"123","rows":[]}`)
		}
	}))
	defer backend.Close()
	h := workspaceBoundary(monitorHistoryGateway(backend.URL, "alice-private", strings.Repeat("s", 32)), workspaceTestIdentity("alice@example.com"), workspaceTestPolicy(t))
	done := make(chan struct{}, 2)
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.ServeHTTP(w, r)
		if strings.HasSuffix(r.URL.Path, "/samples") {
			done <- struct{}{}
		}
	}))
	server.Config.ConnState = func(c net.Conn, state http.ConnState) {
		if state == http.StateNew {
			if err := c.(*net.TCPConn).SetWriteBuffer(1024); err != nil {
				t.Error(err)
			}
		}
	}
	server.Start()
	defer server.Close()
	for range 2 {
		c, err := net.Dial("tcp", server.Listener.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		if err := c.(*net.TCPConn).SetReadBuffer(1024); err != nil {
			t.Fatal(err)
		}
		if _, err := io.WriteString(c, "GET /monitoring/history/123/samples HTTP/1.1\r\nHost: nrc\r\nX-NRC-Workspace: alice-private\r\n\r\n"); err != nil {
			t.Fatal(err)
		}
	}
	for range 2 {
		select {
		case <-entered:
		case <-time.After(3 * time.Second):
			t.Fatal("read did not reach backend")
		}
	}
	control := func(want int) {
		r, _ := http.NewRequest("GET", server.URL+"/monitoring/history/123/runs", nil)
		r.Header.Set("X-NRC-Workspace", "alice-private")
		client := &http.Client{Timeout: 2 * time.Second}
		resp, err := client.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, err := io.ReadAll(resp.Body)
		if err != nil || resp.StatusCode != want {
			t.Fatalf("status=%d err=%v body=%s", resp.StatusCode, err, body)
		}
	}
	control(503)
	deadline := time.NewTimer(7 * time.Second)
	defer deadline.Stop()
	for range 2 {
		select {
		case <-done:
		case <-deadline.C:
			t.Fatal("non-reading clients retained history slots beyond budget")
		}
	}
	control(200)
}
