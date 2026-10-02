package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/heavyhorst/nrc/cli/pkg/config"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestRunRetrieveUsesAIProxyContract(t *testing.T) {
	var request protocol.RetrieveRequest
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/ai/retrieve" || r.Header.Get("Content-Type") != "application/json" {
			t.Errorf("unexpected request: %s %s content-type=%q", r.Method, r.URL.Path, r.Header.Get("Content-Type"))
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
			return
		}
		_ = json.NewEncoder(w).Encode(protocol.RetrieveResponse{
			Workspace: "ws", ConvID: 0, Query: request.Query, GraphEnabled: true, GraphContributed: true,
			Results: []protocol.RetrieveResult{{Rank: 1, Type: protocol.SearchEntityAsset, ID: 42, Origins: []string{"search", "graph"}, PayloadState: protocol.RetrievePayloadStateComplete}},
		})
	}))
	defer server.Close()

	t.Setenv("HOME", t.TempDir())
	if err := (&config.Config{Server: "ws://unused", ProxyURL: server.URL, WorkspaceID: "ws", RoomID: 17}).Save(); err != nil {
		t.Fatal(err)
	}
	response, err := runRetrieve(protocol.RetrieveRequest{
		Query: "why", TopN: 8, Depth: 2, PayloadMode: protocol.RetrievePayloadTop,
		PayloadTop: 3, MaxPayloadBytes: 30_000, PathMode: protocol.RetrievePathsBest,
	}, "")
	if err != nil {
		t.Fatal(err)
	}
	if request.Workspace != "ws" || request.ConvID != 0 || request.TopN != 8 || request.Depth != 2 ||
		request.PayloadMode != protocol.RetrievePayloadTop || request.PayloadTop != 3 ||
		request.MaxPayloadBytes != 30_000 || request.PathMode != protocol.RetrievePathsBest {
		t.Fatalf("request scope/options = %#v", request)
	}
	if len(response.Results) != 1 || !response.GraphContributed || response.Results[0].PayloadState != protocol.RetrievePayloadStateComplete {
		t.Fatalf("response = %#v", response)
	}
}
