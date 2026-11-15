package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type decisionTransport func(*http.Request) (*http.Response, error)

func (f decisionTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestTicketClassifierSurvivesInteractiveReadinessTimeout(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(t.Context())
		defer cancel()
		clientCtx, stop := context.WithCancel(ctx)
		client := NewNRCClient(Config{TicketWorkspaces: "ws", TicketAPIKey: "test-only"}, "ws")
		client.cancel = stop
		wm := &WorkspaceManager{ctx: ctx, clients: map[string]*NRCClient{"ws": client}}
		if _, err := wm.GetOrCreateClient("ws"); err == nil {
			t.Fatal("unavailable server must time out the interactive request")
		}
		if clientCtx.Err() != nil {
			t.Fatal("interactive timeout stopped the background classifier")
		}
		// Recovery arrives on the existing client's reconnect loop, without a
		// second interactive request creating a replacement connection.
		client.closeReady()
		got, err := wm.GetOrCreateClient("ws")
		if err != nil || got != client {
			t.Fatalf("permanent client did not survive recovery: %v", err)
		}
	})
}

func TestAutomaticTicketCategory(t *testing.T) {
	for _, mode := range []string{"absent", "empty", "manual", "unclear", "failure", "refusal", "invalid", "conflict"} {
		t.Run(mode, func(t *testing.T) {
			c, requests := connectedListingTestClient(t)
			calls := 0
			c.ticketClassifier = &ticketClassifier{key: "test-only", http: &http.Client{Transport: decisionTransport(func(r *http.Request) (*http.Response, error) {
				calls++
				if r.URL.String() != "https://api.openai.com/v1/decisions" || r.Header.Get("Authorization") != "Bearer test-only" {
					t.Error("wrong authenticated endpoint")
				}
				var request struct{ Model, Input string }
				if json.NewDecoder(r.Body).Decode(&request) != nil || request.Model != "gpt-6-luna" || request.Input != "Betreff: Export\n\nStürzt immer ab." {
					t.Errorf("wrong input: %+v", request)
				}
				status, body := 200, `{"answers":[{"type":"choice","name":"ticketart","choice":"bug"}]}`
				switch mode {
				case "failure":
					status, body = 429, "private provider body"
				case "refusal":
					body = `{"answers":[{"type":"refusal","name":"ticketart"}]}`
				case "invalid":
					body = `{"answers":[{"type":"choice","name":"ticketart","choice":"other"}]}`
				}
				return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
			})}}
			metadata := map[string]any{"version": 1, "title": "Export", "status": "open", "extra": json.Number("9007199254740993")}
			switch mode {
			case "empty":
				metadata["category"] = ""
			case "manual":
				metadata["category"] = "support"
			case "unclear":
				metadata["category"] = "unclear"
			}
			preview, _ := json.Marshal(metadata)
			asset := protocol.Asset{AssetID: 7, AssetType: protocol.AssetTypeTicket, UpdatedAt: 456, Preview: string(preview), Payload: "Stürzt immer ab."}
			ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
			defer cancel()
			done := make(chan error, 1)
			go func() { done <- c.classifyTicket(ctx, 7) }()
			if m := nextTicketRequest(t, requests); m.Opcode != protocol.C_GetAsset {
				t.Fatal("missing authoritative read")
			}
			deliverTicketAsset(c, asset)
			writes := mode == "absent" || mode == "empty" || mode == "conflict"
			if writes {
				m := nextTicketRequest(t, requests)
				if m.Opcode != protocol.C_ApplyTransaction {
					t.Fatal("unconditional category write")
				}
				id := binary.BigEndian.Uint32(m.Data[4:])
				metadata["category"] = "bug"
				wantPreview, _ := json.Marshal(metadata)
				body, err := protocol.EncodeTransactionAssetPatch(protocol.TransactionAssetPatch{Asset: protocol.Existing(protocol.TransactionEntityAsset, 7), IfUpdatedAt: 456, Present: protocol.TransactionAssetPatchPreview, Preview: wantPreview})
				want, err2 := protocol.EncodeApplyTransaction(id, []protocol.TransactionOperation{{Type: protocol.TransactionOpAssetPatch, Body: body}})
				if err != nil || err2 != nil || !bytes.Equal(want, m.Data) {
					t.Fatal("must preserve metadata, body and attachments and guard the exact classified version")
				}
				result := &protocol.TransactionResult{Status: protocol.TransactionStatusCommitted}
				if mode == "conflict" {
					result.Status = 1
				}
				c.settleDataRead(id, protocol.C_ApplyTransaction, result, nil)
			}
			err := <-done
			wantError := mode == "failure" || mode == "refusal" || mode == "invalid" || mode == "conflict"
			if (err != nil) != wantError {
				t.Fatalf("unexpected result: %v", err)
			}
			if err != nil && strings.Contains(err.Error(), "private provider body") {
				t.Fatal("provider contents leaked")
			}
			wantCalls := 1
			if mode == "manual" || mode == "unclear" {
				wantCalls = 0
			}
			if calls != wantCalls {
				t.Fatalf("API calls: %d, want %d", calls, wantCalls)
			}
			select {
			case m := <-requests:
				t.Fatalf("unexpected write/retry: %d", m.Opcode)
			default:
			}
		})
	}
}

func TestTicketClassificationCredentials(t *testing.T) {
	t.Setenv("NRC_TICKET_CLASSIFICATION_WORKSPACES", "alpha, beta")
	t.Setenv("NRC_TICKET_OPENAI_API_KEY", "")
	t.Setenv("LLM_API_KEY", "test-provider-key")
	t.Setenv("LLM_BASE_URL", "")
	t.Setenv("NRC_KNOWLEDGE_GAP_SLICES", "")
	for _, provider := range []string{"openai", "anthropic"} {
		t.Setenv("LLM_PROVIDER", provider)
		cfg := loadConfig()
		if ticketClassificationEnabled(cfg, "beta") != (provider == "openai") {
			t.Fatal("wrong provider fallback")
		}
		if ticketClassificationEnabled(cfg, "other") {
			t.Fatal("workspace not opted in")
		}
	}
	t.Setenv("LLM_PROVIDER", "openai")
	t.Setenv("LLM_BASE_URL", "https://other-provider.test")
	if loadConfig().TicketAPIKey != "" {
		t.Fatal("forwarded custom provider credential")
	}
	t.Setenv("NRC_TICKET_OPENAI_API_KEY", "test-openai-key")
	if loadConfig().TicketAPIKey != "test-openai-key" {
		t.Fatal("explicit credential ignored")
	}
}
