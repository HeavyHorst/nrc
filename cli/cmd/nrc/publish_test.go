package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/heavyhorst/nrc/cli/pkg/config"
)

func TestPublishHTTPContract(t *testing.T) {
	id := "9007199254740993"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/publish/api/drafts" || r.Header.Get("Authorization") != "" || r.Header.Get("X-NRC-Publish-Auth") != "" {
			t.Errorf("wrong request: %s %s", r.Method, r.URL.Path)
		}
		var input map[string]string
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			t.Error(err)
		}
		if input["note_id"] != id || input["title"] != "Public title" {
			t.Errorf("wrong payload: %+v", input)
		}
		w.WriteHeader(201)
		w.Write([]byte(`{"draft":{"id":"0123456789abcdef0123456789abcdef","note_id":"9007199254740993"},"review_url":"https://review.example/drafts/0123456789abcdef0123456789abcdef"}`))
	}))
	defer server.Close()
	t.Setenv("NRC_PUBLISH_URL", "")
	t.Setenv("HOME", t.TempDir())
	if err := (&config.Config{ProxyURL: server.URL}).Save(); err != nil {
		t.Fatal(err)
	}
	result, err := runPublish(context.Background(), "POST", "/api/drafts", map[string]string{"note_id": id, "title": "Public title"})
	if err != nil {
		t.Fatal(err)
	}
	if result["review_url"] != "https://review.example/drafts/0123456789abcdef0123456789abcdef" || result["draft"].(map[string]any)["note_id"] != id {
		t.Fatalf("bad response: %+v", result)
	}
}

func TestPublishDoesNotFollowRedirects(t *testing.T) {
	hit := false
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hit = true }))
	defer target.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, target.URL, 307) }))
	defer server.Close()
	t.Setenv("NRC_PUBLISH_URL", server.URL)
	if _, err := runPublish(context.Background(), "GET", "/api/publications", nil); err == nil || !strings.Contains(err.Error(), "307") {
		t.Fatalf("redirect accepted: %v", err)
	}
	if hit {
		t.Fatal("credential-bearing request followed redirect")
	}
}

func TestPublishCommandBoundary(t *testing.T) {
	for _, name := range []string{"list", "draft", "inspect"} {
		cmd, _, err := publishCmd.Find([]string{name})
		if err != nil || cmd.Name() != name {
			t.Fatalf("missing command %s", name)
		}
		if name == "draft" && cmd.Annotations["mutation"] != "true" {
			t.Fatal("draft lacks mutation annotation")
		}
	}
	for _, cmd := range publishCmd.Commands() {
		if cmd.Name() == "approve" || cmd.Name() == "withdraw" {
			t.Fatal("agent CLI has reviewer mutation")
		}
	}
	t.Setenv("NRC_PUBLISH_URL", "https://reviewer:password@example.test")
	if _, err := runPublish(context.Background(), "GET", "/api/publications", nil); err == nil || strings.Contains(err.Error(), "password") {
		t.Fatal("URL credentials accepted or echoed")
	}
}
