package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/heavyhorst/nrc/cli/pkg/client"
	"github.com/heavyhorst/nrc/cli/pkg/config"
	"github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestCustomerHybridSearchAndBlankListing(t *testing.T) {
	var searchCalls, reads, lists atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/search" {
			searchCalls.Add(1)
			var req protocol.SearchRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				t.Error(err)
				return
			}
			if req.Workspace != "customer-test" || req.ConvID != 0 || req.Query != "Acme" || req.TopN != 3 || req.Filters == nil || req.Filters.Customer == nil || req.Filters.Customer.IncludeArchived || len(req.Filters.AssetTypes) != 2 || req.Filters.AssetTypes[0] != 8 || req.Filters.AssetTypes[1] != 9 {
				t.Errorf("bad company-register request: %+v", req)
			}
			w.Header().Set(protocol.SearchAPIVersionHeader, protocol.SearchAPIVersion)
			results := []protocol.SearchResult{}
			for _, id := range []uint64{81, 81, 42} {
				results = append(results, protocol.SearchResult{Entity: protocol.SearchEntityIdentity{Workspace: "customer-test", ConvID: 0, EntityType: protocol.SearchEntityAsset, EntityID: id}, Metadata: protocol.SearchMetadata{AssetType: 8}})
			}
			_ = json.NewEncoder(w).Encode(protocol.SearchResponse{Results: results, Stale: true})
			return
		}
		upgrader := websocket.Upgrader{}
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer ws.Close()
		for {
			_, data, err := ws.ReadMessage()
			if err != nil {
				return
			}
			msg, err := protocol.ReadMessage(data)
			if err != nil {
				t.Error(err)
				return
			}
			var reply protocol.Message
			switch msg.Opcode {
			case protocol.C_GetAsset:
				reads.Add(1)
				id := binary.BigEndian.Uint64(msg.Data[8:])
				preview := `{"version":1,"title":"Fresh Acme","archived":false}`
				if id == 42 {
					preview = `{"version":1,"title":"Now archived","archived":true}`
				}
				var b bytes.Buffer
				for _, value := range []any{uint16(8), id, uint16(0), uint64(0), uint16(5)} {
					_ = binary.Write(&b, binary.BigEndian, value)
				}
				b.WriteString("owner")
				for _, value := range []any{int64(100), int64(200), uint64(0), uint8(0), uint32(0), uint16(len(preview))} {
					_ = binary.Write(&b, binary.BigEndian, value)
				}
				b.WriteString(preview)
				_ = binary.Write(&b, binary.BigEndian, uint16(0)) // payload
				_ = binary.Write(&b, binary.BigEndian, uint16(0)) // attachments
				reply = protocol.Message{Opcode: protocol.S_AssetFull, Data: b.Bytes()}
			case protocol.C_SearchCustomers:
				lists.Add(1)
				if binary.BigEndian.Uint16(msg.Data[19:]) != 0 {
					t.Error("blank list sent search text")
				}
				reply = protocol.Message{Opcode: protocol.S_CustomerSearchPage, Data: make([]byte, 27)}
			default:
				t.Errorf("unexpected opcode %d", msg.Opcode)
				return
			}
			wire, _ := reply.Write()
			if err := ws.WriteMessage(websocket.BinaryMessage, wire); err != nil {
				return
			}
		}
	}))
	defer server.Close()
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{Server: "ws" + strings.TrimPrefix(server.URL, "http") + "/", ProxyURL: server.URL, WorkspaceID: "customer-test"}
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	_ = output.Configure(false, false, "")
	for _, command := range []string{"list", "search"} {
		cmd := customerSearchCommand()
		args := []string{"Acme"}
		if command == "list" {
			cmd = customerList(protocol.AssetTypeCustomerCompany)
			_ = cmd.Flags().Set("search", "  Acme  ")
			_ = cmd.Flags().Set("page-size", "3")
			args = nil
		} else {
			_ = cmd.Flags().Set("limit", "3")
		}
		got := captureStdout(t, func() { cmd.Run(cmd, args) })
		var result struct {
			Entries      []customerRecord `json:"entries"`
			Stale        bool             `json:"stale"`
			Complete     bool             `json:"complete"`
			LimitReached bool             `json:"limit_reached"`
		}
		if err := json.Unmarshal([]byte(got), &result); err != nil || len(result.Entries) != 1 || result.Entries[0].ID != 81 || result.Entries[0].Owner != "owner" || result.Entries[0].UpdatedAt != 200 || !result.Stale || result.Complete || !result.LimitReached {
			t.Fatalf("incorrect ranked output: %s (%v)", got, err)
		}
	}
	blank := customerList(protocol.AssetTypeCustomerCompany)
	_ = blank.Flags().Set("search", "   ")
	_ = blank.Flags().Set("all", "true")
	got := captureStdout(t, func() { blank.Run(blank, nil) })
	if !strings.Contains(got, `"total_count":0`) || strings.Contains(got, `"complete"`) || searchCalls.Load() != 2 || reads.Load() != 4 || lists.Load() != 1 {
		t.Fatalf("blank listing or search routing incorrect: %s calls=%d reads=%d lists=%d", got, searchCalls.Load(), reads.Load(), lists.Load())
	}
}

func TestCustomerSearchRejectsInvalidResponses(t *testing.T) {
	for _, test := range []struct {
		name    string
		status  int
		version string
		mutate  func(*protocol.SearchResult)
	}{
		{name: "unavailable", status: http.StatusServiceUnavailable},
		{name: "old service", status: 200},
		{name: "foreign workspace", status: 200, version: protocol.SearchAPIVersion, mutate: func(r *protocol.SearchResult) { r.Entity.Workspace = "foreign" }},
		{name: "foreign conversation", status: 200, version: protocol.SearchAPIVersion, mutate: func(r *protocol.SearchResult) { r.Entity.ConvID = 2 }},
		{name: "contact", status: 200, version: protocol.SearchAPIVersion, mutate: func(r *protocol.SearchResult) { r.Metadata.AssetType = 9 }},
		{name: "task", status: 200, version: protocol.SearchAPIVersion, mutate: func(r *protocol.SearchResult) { r.Entity.EntityType = protocol.SearchEntityTask }},
		{name: "zero id", status: 200, version: protocol.SearchAPIVersion, mutate: func(r *protocol.SearchResult) { r.Entity.EntityID = 0 }},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				result := protocol.SearchResult{Entity: protocol.SearchEntityIdentity{Workspace: "ws", ConvID: 0, EntityType: protocol.SearchEntityAsset, EntityID: 81}, Metadata: protocol.SearchMetadata{AssetType: 8}}
				if test.mutate != nil {
					test.mutate(&result)
				}
				w.Header().Set(protocol.SearchAPIVersionHeader, test.version)
				w.WriteHeader(test.status)
				_ = json.NewEncoder(w).Encode(protocol.SearchResponse{Results: []protocol.SearchResult{result}})
			}))
			defer server.Close()
			t.Setenv("HOME", t.TempDir())
			cfg := &config.Config{Server: "ws://unused/", ProxyURL: server.URL, WorkspaceID: "ws"}
			if err := cfg.Save(); err != nil {
				t.Fatal(err)
			}
			// No NRC client: invalid responses must fail before attempting exact reads.
			if err := searchCustomerCompanies(&conn.Session{Config: cfg}, "Acme", 5, false); err == nil {
				t.Fatal("invalid response accepted")
			}
		})
	}
}

func TestCustomerPreviewPreservesExtensionsAndClearsFields(t *testing.T) {
	m, err := customerMetadata(`{"version":1,"title":"Before","city":"Berlin","number":"C-12","custom":{"id":18446744073709551615},"companyId":"obsolete"}`)
	if err != nil {
		t.Fatal(err)
	}
	p, err := customerPreview(m, map[string]string{"title": " After ", "city": ""}, protocol.AssetTypeCustomerCompany, nil)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]json.RawMessage
	if err := json.Unmarshal(p, &got); err != nil {
		t.Fatal(err)
	}
	if string(got["title"]) != `"After"` || string(got["city"]) != `""` || string(got["number"]) != `"C-12"` || string(got["custom"]) != `{"id":18446744073709551615}` || got["companyId"] != nil {
		t.Fatalf("incorrect merge: %s", p)
	}
}

func TestCustomerActivityExcerptAndValidation(t *testing.T) {
	body := strings.Repeat("ä", 159) + "界end"
	m := map[string]json.RawMessage{"title": json.RawMessage(`"Call"`), "kind": json.RawMessage(`"Call"`)}
	p, err := customerPreview(m, nil, protocol.AssetTypeCustomerActivity, &body)
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Excerpt string `json:"excerpt"`
	}
	if err := json.Unmarshal(p, &got); err != nil {
		t.Fatal(err)
	}
	if got.Excerpt != strings.Repeat("ä", 159)+"界" {
		t.Fatalf("incorrect excerpt: %q", got.Excerpt)
	}
	if _, err := customerPreview(m, map[string]string{"kind": "bogus"}, protocol.AssetTypeCustomerActivity, &body); err == nil {
		t.Fatal("invalid kind accepted")
	}
	empty := " "
	if _, err := customerPreview(m, map[string]string{"kind": "Email"}, protocol.AssetTypeCustomerActivity, &empty); err == nil {
		t.Fatal("blank activity accepted")
	}
	if _, err := customerPreview(m, map[string]string{"title": " "}, protocol.AssetTypeCustomerContact, nil); err == nil {
		t.Fatal("blank title accepted")
	}
	if _, err := customerPreview(m, map[string]string{"title": strings.Repeat("界", protocol.MaxPreviewLength/3+1)}, protocol.AssetTypeCustomerCompany, nil); err == nil {
		t.Fatal("oversize preview accepted")
	}
}

func TestCustomerAssetTypesAndMutationContract(t *testing.T) {
	for name, code := range map[string]uint16{"company": 8, "contact": 9, "activity": 10} {
		got, err := parseAssetTypeName(name)
		if err != nil || got != code || assetTypeName(code) != name {
			t.Fatalf("type mapping %s: %d %v", name, got, err)
		}
		command := name
		if name == "company" {
			command = "customer"
		}
		for _, action := range []string{"create", "update", "delete"} {
			cmd, _, err := rootCmd.Find([]string{command, action})
			if err != nil || cmd.Name() != action || cmd.Annotations["mutation"] != "true" {
				t.Fatalf("missing mutation annotation: %s %s", name, action)
			}
		}
	}
	for _, raw := range []string{"0", "-1", "18446744073709551616", "abc"} {
		if _, err := customerID(raw); err == nil {
			t.Fatalf("invalid ID accepted: %s", raw)
		}
	}
	for _, preview := range []string{"null", "[]", `{"version":2,"title":"x"}`, `{"version":1}`, `{"version":1,"title":null}`} {
		if _, err := customerMetadata(preview); err == nil {
			t.Fatalf("invalid metadata accepted: %s", preview)
		}
	}
	companyCreate, _, err := rootCmd.Find([]string{"customer", "create"})
	if err != nil || companyCreate.Flag("account-type") == nil || companyCreate.Flag("phone") == nil || companyCreate.Flag("account_type") != nil {
		t.Fatalf("company create must expose --account-type and --phone")
	}
}

func TestCustomerCommandsAreFlatWithoutAliases(t *testing.T) {
	for _, name := range []string{"customer", "contact", "activity"} {
		group, remaining, err := rootCmd.Find([]string{name})
		if err != nil || len(remaining) != 0 || group.Parent() != rootCmd || len(group.Aliases) != 0 {
			t.Fatalf("invalid top-level group %s: %v", name, err)
		}
		for _, action := range []string{"list", "get", "create", "update", "delete"} {
			cmd, remaining, err := rootCmd.Find([]string{name, action})
			if err != nil || len(remaining) != 0 || cmd.Name() != action || cmd.Parent() != group {
				t.Fatalf("missing flat command %s %s: %v", name, action, err)
			}
		}
	}
	for _, name := range []string{"company", "contact", "activity"} {
		cmd, remaining, err := rootCmd.Find([]string{"customer", name, "get", "81"})
		if err == nil && (cmd.Name() != "customer" || cmd.Args == nil || cmd.Args(cmd, remaining) == nil) {
			t.Fatalf("nested command customer %s still accepted", name)
		}
	}
}

func TestCustomerTransactionLostAcknowledgement(t *testing.T) {
	var received atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upgrader := websocket.Upgrader{}
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		_, data, err := ws.ReadMessage()
		if err != nil {
			return
		}
		msg, err := protocol.ReadMessage(data)
		if err == nil && msg.Opcode == protocol.C_ApplyTransaction {
			received.Add(1)
		}
		// Model a committed request whose acknowledgement is lost.
	}))
	defer server.Close()
	c := client.New("ws"+strings.TrimPrefix(server.URL, "http")+"/", "test")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.Connect(ctx); err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_, err := customerTransaction(&conn.Session{Client: c, RoomID: 2}, []protocol.TransactionOperation{{Type: protocol.TransactionOpAssetCreate, Body: []byte{1}}})
	if err == nil || !strings.Contains(err.Error(), "outcome unconfirmed") || conn.Classify(err).Retryable {
		t.Fatalf("unsafe lost-ACK classification: %v", err)
	}
	if received.Load() != 1 {
		t.Fatalf("requests: %d", received.Load())
	}
}
