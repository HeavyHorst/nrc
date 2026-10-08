package main

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"unicode/utf8"

	"charm.land/fantasy"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestToolTextPagesPreserveBytesAndBoundaries(t *testing.T) {
	s := " A€🙂Z\n"
	var got string
	for offset := 0; offset < len(s); {
		part, next, more, err := toolTextPage(s, offset, 5)
		if err != nil || !utf8.ValidString(part) || next <= offset || next-offset != len(part) || more != (next < len(s)) {
			t.Fatalf("bad page %q %d %v %v", part, next, more, err)
		}
		got += part
		offset = next
	}
	if got != s {
		t.Fatalf("lost original bytes: %q", got)
	}
	for _, pair := range [][2]int{{-1, 5}, {len(s) + 1, 5}, {3, 5}, {0, -1}, {2, 1}} {
		if _, _, _, err := toolTextPage(s, pair[0], pair[1]); err == nil {
			t.Fatalf("accepted %v", pair)
		}
	}
	for _, n := range []int{1, 2, 3, 4, 5, 6, 7} {
		if got := trimForTool("€🙂abc", n); !utf8.ValidString(got) || len(got) > n {
			t.Fatalf("invalid clipping %q", got)
		}
	}
	a := adkAssetResultFromAsset(protocol.Asset{Payload: strings.Repeat("a", 9) + "€"}, true, 10)
	if !a.PayloadTruncated || a.PayloadOmitted || !utf8.ValidString(a.Payload) {
		t.Fatalf("missing clipping metadata: %+v", a)
	}
	if a := adkAssetResultFromAsset(protocol.Asset{Payload: "abc"}, false, 10); !a.PayloadOmitted || a.PayloadTruncated {
		t.Fatal(a)
	}
}

func TestAttachmentTextContractAndNativeTool(t *testing.T) {
	const id = "att_0123456789abcdef0123456789abcdef"
	for _, mode := range []string{"ok", "version", "identity", "cursor"} {
		t.Run(mode, func(t *testing.T) {
			calls := 0
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.Header.Get("Authorization") != "Bearer test-secret" {
					t.Error("missing bot authentication")
				}
				var req map[string]any
				if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
					t.Error(err)
				}
				if r.URL.Path != "/attachment/text" || req["workspace"] != "ws" || req["conv_id"] != "0" || req["entity_id"] != "9007199254740993" || req["offset"] != float64(3) || req["limit"] != float64(5) {
					t.Errorf("bad request %+v", req)
				}
				w.Header().Set("X-NRC-Attachment-Text-Version", "1")
				p := attachmentTextPage{FileID: id, Status: "partial", Text: "€", Offset: 3, NextOffset: 6, HasMore: true, TotalBytes: 12, Warning: "limited extraction"}
				if mode == "version" {
					w.Header().Set("X-NRC-Attachment-Text-Version", "0")
				}
				if mode == "identity" {
					p.FileID = "wrong"
				}
				if mode == "cursor" {
					p.NextOffset = 7
				}
				json.NewEncoder(w).Encode(p)
			}))
			defer srv.Close()
			tools := newAttachmentTools(nil, NewSearchClient(srv.URL), Config{NRCBotSecret: "test-secret"})
			ctx := context.WithValue(context.WithValue(t.Context(), workspaceContextKey{}, "ws"), convIDContextKey{}, uint64(0))
			in := `{"entity_type":"task","entity_id":"9007199254740993","file_id":"` + id + `","offset":3,"limit":5}`
			resp, err := tools[1].Run(ctx, fantasy.ToolCall{ID: "read", Input: in})
			if err != nil || resp.IsError != (mode != "ok") {
				t.Fatalf("response %+v %v", resp, err)
			}
			if mode == "ok" && (!strings.Contains(resp.Content, `"has_more":true`) || !strings.Contains(resp.Content, `"complete":false`) || !strings.Contains(resp.Content, "limited extraction")) {
				t.Fatal(resp.Content)
			}
			badScope := context.WithValue(ctx, convIDContextKey{}, uint64(9))
			resp, err = tools[1].Run(badScope, fantasy.ToolCall{Input: in})
			if err != nil || !resp.IsError || calls != 1 {
				t.Fatal("non-workspace scope reached backend")
			}
		})
	}
}

func TestPrivateMediaDownloadAndCapabilities(t *testing.T) {
	var b bytes.Buffer
	if err := png.Encode(&b, image.NewRGBA(image.Rect(0, 0, 2, 3))); err != nil {
		t.Fatal(err)
	}
	data := b.Bytes()
	redirect := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("workspace") != "ws" || r.Header.Get("Authorization") != "Bearer test-only" {
			t.Error("missing private authorization")
		}
		if redirect {
			w.Header().Set("Location", "/elsewhere")
			w.WriteHeader(302)
			return
		}
		w.Write(data)
	}))
	defer srv.Close()
	cfg := Config{LLMProvider: "openai", LLMModel: "gpt-6", FilesURL: srv.URL, NRCBotSecret: "test-only"}
	a := protocol.Attachment{FileId: "att_0123456789abcdef0123456789abcdef", MimeType: "image/png"}
	got, mime, err := downloadToolMedia(t.Context(), cfg, "ws", a)
	if err != nil || mime != "image/png" || !bytes.Equal(got, data) {
		t.Fatalf("bad media %s %v", mime, err)
	}
	data = []byte("not a PNG")
	if _, _, err := downloadToolMedia(t.Context(), cfg, "ws", a); err == nil {
		t.Fatal("accepted corrupt media")
	}
	redirect = true
	if _, _, err := downloadToolMedia(t.Context(), cfg, "ws", a); err == nil {
		t.Fatal("followed redirect")
	}
	for _, tt := range []struct {
		provider, model, mime string
		want                  bool
	}{
		{"openai", "gpt-6", "audio/wav", false}, {"openai", "gpt-4o", "audio/wav", true},
		{"anthropic", "claude", "image/png", true}, {"anthropic", "claude", "audio/mpeg", false},
		{"openrouter", "any", "image/png", false}, {"deepseek", "any", "image/png", false},
		{"openai-compat", "any", "image/png", true}, {"openai", "gpt-4o", "application/pdf", false},
	} {
		if toolMediaSupported(Config{LLMProvider: tt.provider, LLMModel: tt.model}, tt.mime) != tt.want {
			t.Fatalf("wrong capability %+v", tt)
		}
	}
}
