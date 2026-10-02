package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/heavyhorst/nrc/cli/pkg/client"
	"github.com/heavyhorst/nrc/cli/pkg/conn"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

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
		for _, action := range []string{"create", "update", "delete"} {
			cmd, _, err := rootCmd.Find([]string{"customer", name, action})
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
	companyCreate, _, err := rootCmd.Find([]string{"customer", "company", "create"})
	if err != nil || companyCreate.Flag("account-type") == nil || companyCreate.Flag("phone") == nil || companyCreate.Flag("account_type") != nil {
		t.Fatalf("company create must expose --account-type and --phone")
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
