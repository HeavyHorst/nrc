package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
)

func TestNewSourcebotClientRequiresExplicitRepositoryScope(t *testing.T) {
	if _, err := NewSourcebotClient("http://sourcebot:3000", "", "", ""); err == nil {
		t.Fatal("expected missing repository scope to fail")
	}
	client, err := NewSourcebotClient("http://sourcebot:3000", "", "", "*")
	if err != nil {
		t.Fatalf("expected explicit wildcard to succeed: %v", err)
	}
	if !client.allowAll {
		t.Fatal("expected wildcard repository scope")
	}
}

func TestSourcebotSearchRestrictsRepositoriesAndBoundsResults(t *testing.T) {
	var received sourcebotSearchRequest
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/search" {
			http.NotFound(w, r)
			return
		}
		if got := r.Header.Get("X-Sourcebot-Api-Key"); got != "api-key" {
			t.Errorf("unexpected API key header %q", got)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer bearer-token" {
			t.Errorf("unexpected authorization header %q", got)
		}
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Fatalf("decode request: %v", err)
		}

		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{
  "stats":{"actualMatchCount":2,"totalMatchCount":9},
  "files":[
    {
      "fileName":{"text":"allowed.go"},
      "repository":"repo/allowed",
      "language":"Go",
      "externalWebUrl":"https://git.example/repo/allowed.go",
      "chunks":[
        {"content":"first","contentStart":{"lineNumber":10}},
        {"content":"second","contentStart":{"lineNumber":20}},
        {"content":"third","contentStart":{"lineNumber":30}},
        {"content":"fourth","contentStart":{"lineNumber":40}}
      ]
    },
    {
      "fileName":{"text":"secret.go"},
      "repository":"repo/denied",
      "chunks":[{"content":"must not escape","contentStart":{"lineNumber":1}}]
    }
  ],
  "isSearchExhaustive":true
}`)
	}))
	defer server.Close()

	client, err := NewSourcebotClient(server.URL, "api-key", "bearer-token", "repo/allowed,repo/other")
	if err != nil {
		t.Fatal(err)
	}
	output, err := client.Search(context.Background(), SourcebotSearchOptions{Query: "needle", Matches: 99, ContextLines: 99})
	if err != nil {
		t.Fatal(err)
	}

	if received.Matches != sourcebotMaxMatches || received.ContextLines != sourcebotMaxContextLines {
		t.Fatalf("request limits not applied: matches=%d context=%d", received.Matches, received.ContextLines)
	}
	if !strings.Contains(received.Query, `repo:^(repo/allowed|repo/other)$`) {
		t.Fatalf("query is not repository-scoped: %q", received.Query)
	}
	if output.TotalMatches != 9 || !output.Exhaustive {
		t.Fatalf("unexpected search metadata: %#v", output)
	}
	if len(output.Results) != 1 || output.Results[0].Repository != "repo/allowed" {
		t.Fatalf("expected only the allowed result, got %#v", output.Results)
	}
	if len(output.Results[0].Chunks) != sourcebotMaxChunksPerFile {
		t.Fatalf("expected bounded chunks, got %d", len(output.Results[0].Chunks))
	}
}

func TestSourcebotGetSourceBoundsLines(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/source" {
			http.NotFound(w, r)
			return
		}
		if got := r.URL.Query().Get("repo"); got != "repo/allowed" {
			t.Errorf("unexpected repo query %q", got)
		}
		if got := r.URL.Query().Get("path"); got != "main.go" {
			t.Errorf("unexpected path query %q", got)
		}
		json.NewEncoder(w).Encode(map[string]any{
			"source":         "one\ntwo\nthree\nfour\nfive",
			"language":       "Go",
			"path":           "main.go",
			"repo":           "repo/allowed",
			"externalWebUrl": "https://git.example/repo/main.go",
		})
	}))
	defer server.Close()

	client, err := NewSourcebotClient(server.URL, "", "", "repo/allowed")
	if err != nil {
		t.Fatal(err)
	}
	output, err := client.GetSource(context.Background(), "repo/allowed", "main.go", "", 2, 5)
	if err != nil {
		t.Fatal(err)
	}
	if output.StartLine != 2 || output.EndLine != 5 || output.Content != "two\nthree\nfour\nfive" {
		t.Fatalf("unexpected bounded source: %#v", output)
	}
	if !output.Truncated {
		t.Fatal("expected a partial file range to be marked truncated")
	}
}

func TestSourcebotRejectsDisallowedRepositoryBeforeRequest(t *testing.T) {
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
	}))
	defer server.Close()

	client, err := NewSourcebotClient(server.URL, "", "", "repo/allowed")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.GetSource(context.Background(), "repo/denied", "secret.go", "", 0, 0); err == nil {
		t.Fatal("expected disallowed repository error")
	}
	if requests != 0 {
		t.Fatalf("expected no HTTP request, got %d", requests)
	}
}

func TestSourcebotRejectsORQueriesWithRestrictedScope(t *testing.T) {
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
	}))
	defer server.Close()

	client, err := NewSourcebotClient(server.URL, "", "", "repo/allowed")
	if err != nil {
		t.Fatal(err)
	}
	for _, query := range []string{
		"needle OR secret",
		"needle or secret",
		"needle (Or secret)",
		`needle or"secret"`,
		"needle,or(secret)",
	} {
		if _, err := client.Search(context.Background(), SourcebotSearchOptions{Query: query}); err == nil {
			t.Fatalf("expected OR query %q to be rejected", query)
		}
	}
	if _, err := client.Search(context.Background(), SourcebotSearchOptions{Query: "foo|bar", Regex: true}); err == nil {
		t.Fatal("expected request error from test server, not local regex alternation rejection")
	}
	if requests != 1 {
		t.Fatalf("expected only regex alternation to reach server, got %d requests", requests)
	}
}

func TestSourcebotSearchRejectsNonExactResponseRepository(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{
  "stats":{"actualMatchCount":1,"totalMatchCount":1},
  "files":[{
    "fileName":{"text":"secret.go"},
    "repository":"repo/allowed ",
    "chunks":[{"content":"must not escape","contentStart":{"lineNumber":1}}]
  }],
  "isSearchExhaustive":true
}`)
	}))
	defer server.Close()

	client, err := NewSourcebotClient(server.URL, "", "", "repo/allowed")
	if err != nil {
		t.Fatal(err)
	}
	output, err := client.Search(context.Background(), SourcebotSearchOptions{Query: "needle"})
	if err != nil {
		t.Fatal(err)
	}
	if len(output.Results) != 0 {
		t.Fatalf("expected non-exact repository identity to be filtered, got %#v", output.Results)
	}
}

func TestSourcebotDoesNotForwardCredentialsThroughRedirects(t *testing.T) {
	redirectedHeaders := make(chan http.Header, 1)
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		redirectedHeaders <- r.Header.Clone()
		w.WriteHeader(http.StatusOK)
	}))
	defer target.Close()

	redirector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+"/api/search", http.StatusTemporaryRedirect)
	}))
	defer redirector.Close()

	client, err := NewSourcebotClient(redirector.URL, "api-key", "bearer-token", "*")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Search(context.Background(), SourcebotSearchOptions{Query: "needle"}); err == nil {
		t.Fatal("expected redirect response to fail")
	}
	select {
	case headers := <-redirectedHeaders:
		t.Fatalf("redirect target was contacted with headers %#v", headers)
	default:
	}
}

func TestSourcebotSourceLinesRemovesOnlyTerminalSentinel(t *testing.T) {
	tests := []struct {
		source string
		want   []string
	}{
		{source: "", want: nil},
		{source: "one\ntwo", want: []string{"one", "two"}},
		{source: "one\ntwo\n", want: []string{"one", "two"}},
		{source: "one\n\n", want: []string{"one", ""}},
	}
	for _, test := range tests {
		got := sourcebotSourceLines(test.source)
		if fmt.Sprint(got) != fmt.Sprint(test.want) {
			t.Fatalf("sourcebotSourceLines(%q) = %#v, want %#v", test.source, got, test.want)
		}
	}
}

func TestNewSourcebotToolsIsOptional(t *testing.T) {
	tools, err := newSourcebotTools(nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(tools) != 0 {
		t.Fatalf("expected no tools when Sourcebot is disabled, got %d", len(tools))
	}
}

func TestSourcebotToolSchemasRequireOnlyEssentialInputs(t *testing.T) {
	client, err := NewSourcebotClient("http://sourcebot:3000", "", "", "*")
	if err != nil {
		t.Fatal(err)
	}
	tools, err := newSourcebotTools(client)
	if err != nil {
		t.Fatal(err)
	}
	if len(tools) != 2 {
		t.Fatalf("expected two Sourcebot tools, got %d", len(tools))
	}

	wantRequired := map[string][]string{
		"search_code": {"query"},
		"get_source":  {"path", "repository"},
	}
	for _, sourcebotTool := range tools {
		runnable, ok := sourcebotTool.(adkRunnableTool)
		if !ok {
			t.Fatalf("tool %s is not runnable", sourcebotTool.Name())
		}
		info := fantasyToolInfo(runnable)
		got := append([]string(nil), info.Required...)
		slices.Sort(got)
		if !slices.Equal(got, wantRequired[sourcebotTool.Name()]) {
			t.Fatalf("tool %s required fields = %#v, want %#v", sourcebotTool.Name(), got, wantRequired[sourcebotTool.Name()])
		}
		if len(info.Parameters) == 0 {
			t.Fatalf("tool %s has no parameters", sourcebotTool.Name())
		}
	}
}
