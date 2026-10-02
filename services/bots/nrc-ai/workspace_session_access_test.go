package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestSessionAccessUsesStoredWorkspace(t *testing.T) {
	t.Setenv("NRC_WORKSPACE_ACCESS", `{"alice-private":{"owner":"alice@example.com"}}`)
	store := newAgentSessionStore(time.Hour, 20)
	private, _ := store.getOrCreate("alice-private", 0, 0, "", "ask")
	public, _ := store.getOrCreate("workspace1", 0, 0, "", "ask")
	mux := http.NewServeMux()
	mux.HandleFunc("GET /ask/session/{id}", handleAskSessionGet(store))
	for _, tc := range []struct {
		session, header string
		status          int
	}{
		{private.ID, `["alice-private"]`, 403},
		{private.ID, `[]`, 200},
		{public.ID, `["alice-private"]`, 200},
		{private.ID, "", 403},
		{private.ID, "null", 403},
		{private.ID, "malformed", 403},
	} {
		r := httptest.NewRequest("GET", "/ask/session/"+tc.session+"?workspace=workspace1", nil)
		r.Header.Set("X-NRC-Denied-Workspaces", tc.header)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, r)
		if w.Code != tc.status {
			t.Errorf("session %s header %q: %d want %d", tc.session, tc.header, w.Code, tc.status)
		}
		if w.Code == 403 && strings.Contains(w.Body.String(), private.ID) {
			t.Fatal("denied response leaked session contents")
		}
	}
	// Reset/apply cannot use an authorized workspace with somebody else's session.
	for path, handler := range map[string]http.HandlerFunc{
		"/ask/session/reset": handleAskSessionReset(store),
		"/ask/apply":         handleAskApply(nil, store),
	} {
		r := httptest.NewRequest("POST", path, strings.NewReader(`{"workspace":"workspace1","agent_session_id":"`+private.ID+`"}`))
		w := httptest.NewRecorder()
		handler(w, r)
		if w.Code != 400 {
			t.Fatalf("session workspace mismatch %s: %d", path, w.Code)
		}
		if _, ok := store.get(private.ID); !ok {
			t.Fatal("foreign session was reset")
		}
	}
}

func TestSessionAccessRemainsOpenWithoutConfiguration(t *testing.T) {
	for _, config := range []string{"", "{}", " \n { \t } "} {
		t.Setenv("NRC_WORKSPACE_ACCESS", config)
		store := newAgentSessionStore(time.Hour, 20)
		session, _ := store.getOrCreate("workspace1", 0, 0, "", "ask")
		r := httptest.NewRequest("GET", "/ask/session/"+session.ID, nil)
		r.SetPathValue("id", session.ID)
		w := httptest.NewRecorder()
		handleAskSessionGet(store)(w, r)
		if w.Code != 200 {
			t.Fatalf("open mode %q: %d %s", config, w.Code, w.Body)
		}
	}
}
