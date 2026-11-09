package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestSessionAccessRequiresOwnerAndWorkspace(t *testing.T) {
	store := newAgentSessionStore(time.Hour, 20)
	session, _ := store.getOrCreate(testAIOwner, "team", 0, 0, "", "ask")
	store.appendTurn(session.ID, AgentTurn{UserText: "private question", Answer: "private answer"})
	legacy, _ := store.getOrCreate("", "team", 0, 0, "", "ask")
	mux := http.NewServeMux()
	mux.HandleFunc("GET /ask/session/{id}", handleAskSessionGet(store))
	mux.HandleFunc("POST /ask/session/reset", handleAskSessionReset(store))
	mux.HandleFunc("POST /ask/apply", handleAskApply(nil, store))
	ask, err := handleAskFantasy(nil, nil, nil, Config{LLMProvider: "openai", LLMModel: "gpt-5.6", LLMAPIKey: "fixture"}, 4096, store)
	if err != nil {
		t.Fatal(err)
	}
	mux.HandleFunc("POST /ask", ask)
	authenticate, err := newAIAuthentication(testAIKey, "test-issuer")
	if err != nil {
		t.Fatal(err)
	}
	handler := authenticate(mux)
	for _, scenario := range []string{"other-owner", "other-workspace", "ownerless", "missing-auth"} {
		for _, path := range []string{"/ask/session/" + session.ID, "/ask/session/reset", "/ask/apply", "/ask"} {
			t.Run(scenario+path, func(t *testing.T) {
				identity := testAIIdentity("team")
				id, want := session.ID, http.StatusNotFound
				switch scenario {
				case "other-owner":
					identity.Subject = "tailscale:user:99"
				case "other-workspace":
					identity.Workspace = "other"
				case "ownerless":
					id = legacy.ID
					path = strings.ReplaceAll(path, session.ID, legacy.ID)
				case "missing-auth":
					want = http.StatusUnauthorized
				}
				method, body := "POST", `{"workspace":"`+identity.Workspace+`","agent_session_id":"`+id+`","question":"continue"}`
				if strings.HasPrefix(path, "/ask/session/") && !strings.HasSuffix(path, "/reset") {
					method, body, path = "GET", "", path+"?workspace="+identity.Workspace
				}
				r := httptest.NewRequest(method, path, strings.NewReader(body))
				r.Header.Set("X-Tailscale-User", "forged-owner")
				r.Header.Set("X-NRC-Denied-Workspaces", "[]")
				if scenario != "missing-auth" {
					r.Header.Set("X-NRC-AI-Auth", testAIToken(identity))
				}
				w := httptest.NewRecorder()
				handler.ServeHTTP(w, r)
				if w.Code != want {
					t.Fatalf("HTTP %d: %s, want %d", w.Code, w.Body, want)
				}
				if strings.Contains(w.Body.String(), "private") {
					t.Fatal("private content leaked")
				}
			})
		}
	}
	// The owning user can still read and reset the original after all denied calls.
	for _, path := range []string{"/ask/session/" + session.ID + "?workspace=team", "/ask/session/reset"} {
		method, body := "GET", ""
		if path == "/ask/session/reset" {
			method, body = "POST", `{"workspace":"team","agent_session_id":"`+session.ID+`"}`
		}
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		r.Header.Set("X-NRC-AI-Auth", testAIToken(testAIIdentity("team")))
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != http.StatusOK {
			t.Fatalf("owner denied: %d %s", w.Code, w.Body)
		}
		if method == "GET" && !strings.Contains(w.Body.String(), "private answer") {
			t.Fatal("denied callers changed history")
		}
	}
}
