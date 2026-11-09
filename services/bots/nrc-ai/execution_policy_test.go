package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"charm.land/fantasy"
)

func TestPrivateExecutionBoundaries(t *testing.T) {
	store := newAgentSessionStore(time.Hour, 10)
	session, _ := store.getOrCreate(testAIOwner, "team", 0, 0, "", "ask")
	handler, err := handleAskFantasy(nil, nil, nil, Config{LLMProvider: "openai", LLMModel: "gpt-5.6", LLMAPIKey: "fixture"}, 4096, store)
	if err != nil {
		t.Fatal(err)
	}
	for _, policy := range []string{"workspace", "invented"} {
		r := httptest.NewRequest("POST", "/ask", strings.NewReader(`{"workspace":"team","question":"continue","session_id":"`+session.ID+`","execution_policy":"`+policy+`"}`))
		r = r.WithContext(context.WithValue(r.Context(), aiIdentityKey{}, testAIIdentity("team")))
		w := httptest.NewRecorder()
		handler(w, r)
		want := http.StatusConflict
		if policy == "invented" {
			want = http.StatusBadRequest
		}
		if w.Code != want {
			t.Fatalf("policy %s: %d %s", policy, w.Code, w.Body)
		}
	}

	type searchInput struct {
		Query string `json:"query"`
	}
	tool := policyTool{fantasy.NewAgentTool("lookup", "fixture", func(_ context.Context, in searchInput, _ fantasy.ToolCall) (fantasy.ToolResponse, error) {
		return fantasy.NewTextResponse("lookup:" + in.Query), nil
	})}
	ctx := context.WithValue(t.Context(), executionPolicyKey{}, "temporary")
	for _, query := range []string{"ticket 723", strings.Repeat("x", 160), strings.Repeat("x", 161), "user: private\nassistant: transcript"} {
		input, _ := json.Marshal(searchInput{query})
		res, err := tool.Run(ctx, fantasy.ToolCall{Input: string(input)})
		if err != nil {
			t.Fatal(err)
		}
		allowed := len(query) <= 160 && !strings.Contains(query, "\n")
		if strings.HasPrefix(res.Content, "lookup:") != allowed {
			t.Fatal("lookup boundary failed", res)
		}
	}
	for _, key := range []string{"Query", "search", "Search"} {
		input, _ := json.Marshal(map[string]string{key: strings.Repeat("x", 161)})
		res, err := tool.Run(ctx, fantasy.ToolCall{Input: string(input)})
		if err != nil || strings.HasPrefix(res.Content, "lookup:") {
			t.Fatal("lookup alias bypass", key, res, err)
		}
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err = tool.Run(cancelled, fantasy.ToolCall{Input: `{"query":"x"}`}); !errors.Is(err, context.Canceled) {
		t.Fatal("cancelled tool executed")
	}
}

func TestPersonalContentDoesNotEnterLogs(t *testing.T) {
	var output bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&output, &slog.HandlerOptions{ReplaceAttr: metadataLogAttr}))
	logger.With("request_id", "test-request", "args", map[string]string{"query": "SECRET"}).Error("provider failure",
		"error", errors.New("provider echoed SECRET"), "outcome", "SECRET", "new_unreviewed_field", "SECRET",
		slog.Group("nested", slog.String("status", "SECRET")), "status", "error")
	if strings.Contains(output.String(), "SECRET") || !strings.Contains(output.String(), "test-request") || !strings.Contains(output.String(), "error_type") {
		t.Fatal("logging boundary", output.String())
	}
}
