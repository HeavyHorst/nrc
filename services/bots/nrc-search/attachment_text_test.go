package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/heavyhorst/nrc/protocol-go"
)

func textTestClient(t *testing.T, attachment protocol.Attachment, body []byte, mismatch bool, entityType string) (*NRCClient, *int) {
	t.Helper()
	downloads := new(int)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*downloads++
		if r.URL.Path != "/files/"+testAttachmentID || r.URL.Query().Get("workspace") != "demo" || r.Header.Get("Authorization") != "Bearer test-secret" {
			t.Error("untrusted download scope")
		}
		_, _ = w.Write(body)
	}))
	t.Cleanup(server.Close)
	c, err := NewNRCClient(Config{FilesURL: server.URL, NRCBotSecret: "test-secret"}, "demo", nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	c.sendMessage = func(op uint16, payload []byte) error {
		id := binary.BigEndian.Uint32(payload[len(payload)-4:])
		entity := uint64(7)
		if mismatch {
			entity = 8
		}
		if entityType == "asset" {
			if op != protocol.C_GetAsset {
				t.Fatalf("unexpected opcode %d", op)
			}
			pending, ok := c.pendingAttachmentAssets.LoadAndDelete(id)
			if !ok {
				t.Fatal("missing asset request")
			}
			pending.(chan attachmentAssetResult) <- attachmentAssetResult{asset: protocol.Asset{AssetID: entity, ConvID: 0, Attachments: []protocol.Attachment{attachment}}}
		} else {
			if op != protocol.C_GetTask {
				t.Fatalf("unexpected opcode %d", op)
			}
			c.pendingTaskFullMu.Lock()
			pending := c.pendingTaskFull[id]
			delete(c.pendingTaskFull, id)
			c.pendingTaskFullMu.Unlock()
			pending <- &protocol.TaskFull{Success: true, Task: &protocol.Task{ID: entity, ConvID: 0, Attachments: []protocol.Attachment{attachment}}}
		}
		return nil
	}
	return c, downloads
}

func textRequest(t *testing.T, client *NRCClient, extra, entityType string) (*httptest.ResponseRecorder, attachmentTextResponse) {
	t.Helper()
	h := attachmentTextHandler("test-secret", func(context.Context, string) (*NRCClient, error) { return client, nil })
	body := `{"workspace":"demo","conv_id":"0","entity_type":"` + entityType + `","entity_id":"7","file_id":"` + testAttachmentID + `"` + extra + `}`
	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/attachment/text", strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer test-secret")
	h.ServeHTTP(w, r)
	var result attachmentTextResponse
	_ = json.Unmarshal(w.Body.Bytes(), &result)
	return w, result
}

func TestAttachmentTextFreshOwnerBeforeDownload(t *testing.T) {
	for _, kind := range []string{"asset", "task"} {
		for _, mismatch := range []bool{true, false} {
			attachment := protocol.Attachment{FileId: testAttachmentID, Filename: "notes.txt", MimeType: "text/plain"}
			if !mismatch {
				attachment.FileId = "att_ffffffffffffffffffffffffffffffff"
			}
			client, downloads := textTestClient(t, attachment, []byte("secret"), mismatch, kind)
			w, _ := textRequest(t, client, "", kind)
			if w.Code != 502 && w.Code != 404 {
				t.Fatalf("owner mismatch returned %d", w.Code)
			}
			if *downloads != 0 {
				t.Fatal("download preceded owner verification")
			}
		}
	}
}

func TestAttachmentTextRequiresBotAuthentication(t *testing.T) {
	for _, secret := range []string{"test-secret", ""} {
		for _, header := range []string{"", "Bearer wrong", "Bearer test-secret"} {
			// Exercise the real public mux: even proxied requests must authenticate
			// before consulting the workspace manager or reading the request body.
			h := newHTTPHandler(Config{NRCBotSecret: secret}, time.Now(), nil, nil, nil)
			r := httptest.NewRequest("POST", "/attachment/text", strings.NewReader(`{}`))
			r.Header.Set("Authorization", header)
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			want := 401
			if secret != "" && header == "Bearer test-secret" {
				want = 400
			}
			if w.Code != want {
				t.Fatalf("configured=%v header=%q status=%d want=%d", secret != "", header, w.Code, want)
			}
		}
	}
}

func TestAttachmentOwnerRegisteredAfterReadTimeoutFailsPromptly(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		for {
			if _, _, err := conn.ReadMessage(); err != nil {
				return
			}
		}
	}))
	defer srv.Close()
	conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	c, err := NewNRCClient(Config{}, "demo", nil, nil, nil)
	if err != nil {
		conn.Close()
		t.Fatal(err)
	}
	c.conn = conn
	// The sentinel signals that the disconnect sweep has happened. Holding the
	// invalidation lock keeps the reader in cleanup while a new owner read starts.
	swept := make(chan attachmentAssetResult, 1)
	c.pendingAttachmentAssets.Store(uint32(1000), swept)
	c.taskMutationMu.Lock()
	conn.SetReadDeadline(time.Now().Add(20 * time.Millisecond))
	done := make(chan struct{})
	go func() { defer close(done); c.readPump(t.Context()) }()
	defer func() { c.taskMutationMu.Unlock(); conn.Close(); <-done }()
	select {
	case <-swept:
	case <-time.After(time.Second):
		t.Fatal("reader did not reach cleanup")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 200*time.Millisecond)
	defer cancel()
	_, err = c.attachmentOwner(ctx, "asset", 0, 7)
	if err == nil || errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("request missed cleanup and waited for its deadline: %v", err)
	}
}

func TestAttachmentAssetFailuresUseWireResponses(t *testing.T) {
	for _, mode := range []string{"not-found", "disconnect"} {
		t.Run(mode, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
				if err != nil {
					return
				}
				defer conn.Close()
				_, raw, err := conn.ReadMessage()
				if err != nil {
					return
				}
				msg, err := protocol.ReadMessage(raw)
				if err != nil || msg.Opcode != protocol.C_GetAsset {
					t.Error("missing exact asset request")
					return
				}
				if mode == "disconnect" {
					return
				}
				id := binary.BigEndian.Uint32(msg.Data[len(msg.Data)-4:])
				p := make([]byte, 23)
				binary.BigEndian.PutUint16(p, protocol.C_GetAsset)
				binary.BigEndian.PutUint16(p[2:], 15)
				copy(p[4:], "Asset not found")
				binary.BigEndian.PutUint32(p[19:], id)
				frame, _ := (&protocol.Message{Opcode: protocol.S_ErrorResponse, Data: p}).Write()
				conn.WriteMessage(websocket.BinaryMessage, frame)
				conn.ReadMessage()
			}))
			defer srv.Close()
			conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http"), nil)
			if err != nil {
				t.Fatal(err)
			}
			c, err := NewNRCClient(Config{}, "demo", nil, nil, nil)
			if err != nil {
				t.Fatal(err)
			}
			c.conn = conn
			ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
			defer cancel()
			done := make(chan struct{})
			go func() { defer close(done); c.readPump(ctx) }()
			defer func() { conn.Close(); <-done }()
			_, err = c.attachmentOwner(ctx, "asset", 0, 7)
			want := "Asset not found"
			if mode == "disconnect" {
				want = "NRC disconnected"
			}
			if err == nil || err.Error() != want {
				t.Fatalf("lost wire failure: %v", err)
			}
			if _, ok := c.pendingAttachmentAssets.Load(uint32(1)); ok {
				t.Fatal("pending read leaked")
			}
		})
	}
}

func TestAttachmentTextValidationBeforeCalls(t *testing.T) {
	for _, body := range []string{
		`{}`, `null`, `{"workspace":"../other"}`, `{"filename":"fake"}`, `{"conv_id":0}`, `{"offset":1.2}`, `{} {}`,
	} {
		h := attachmentTextHandler("test-secret", func(context.Context, string) (*NRCClient, error) {
			t.Fatal("invalid request called NRC")
			return nil, nil
		})
		w := httptest.NewRecorder()
		r := httptest.NewRequest("POST", "/attachment/text", strings.NewReader(body))
		r.Header.Set("Authorization", "Bearer test-secret")
		h.ServeHTTP(w, r)
		if w.Code != 400 {
			t.Fatalf("%s returned %d", body, w.Code)
		}
	}
	req := attachmentTextRequest{Workspace: "demo", ConvID: "0", EntityType: "asset", EntityID: "7", FileID: testAttachmentID}
	for _, mutate := range []func(*attachmentTextRequest){
		func(r *attachmentTextRequest) { r.FileID = "att_../../secret" },
		func(r *attachmentTextRequest) { r.Workspace = "demo/../other" },
		func(r *attachmentTextRequest) { r.EntityID = "0" },
		func(r *attachmentTextRequest) { r.ConvID = "-1" },
		func(r *attachmentTextRequest) { r.ConvID = "1" },
		func(r *attachmentTextRequest) { r.EntityType = "message" },
		func(r *attachmentTextRequest) { r.Offset = -1 },
	} {
		bad := req
		mutate(&bad)
		if _, _, _, err := bad.validate(); err == nil {
			t.Fatalf("accepted %#v", bad)
		}
	}
}

func TestAttachmentTextUTF8Paging(t *testing.T) {
	c, _ := textTestClient(t, protocol.Attachment{FileId: testAttachmentID, MimeType: "text/plain", Filename: "note.txt"}, []byte("a€𐀀z"), false, "task")
	for _, tc := range []struct {
		extra string
		code  int
		text  string
		next  int
	}{
		{`,"limit":3`, 200, "a", 1},
		{`,"offset":1,"limit":3`, 200, "€", 4},
		{`,"offset":4,"limit":4`, 200, "𐀀", 8},
		{`,"offset":8,"limit":999999`, 200, "z", 9},
		{`,"offset":9`, 200, "", 9},
		{`,"offset":2`, 400, "", 0},
		{`,"offset":10`, 400, "", 0},
		{`,"offset":1,"limit":1`, 400, "", 0},
		{`,"limit":0`, 400, "", 0},
	} {
		w, response := textRequest(t, c, tc.extra, "task")
		if w.Code != tc.code {
			t.Fatalf("%s: %d %s", tc.extra, w.Code, w.Body.String())
		}
		if w.Code == 200 && (response.Text != tc.text || response.NextOffset != tc.next || response.TotalBytes != 9 || !response.Complete || response.HasMore != (tc.next < 9)) {
			t.Fatalf("bad page %#v", response)
		}
	}
	limit := 999999
	_, _, n, err := (attachmentTextRequest{Workspace: "demo", ConvID: "0", EntityType: "task", EntityID: "7", FileID: testAttachmentID, Limit: &limit}).validate()
	if err != nil || n != 32768 {
		t.Fatal("limit not capped")
	}
}

func TestAttachmentTextUnsupportedMedia(t *testing.T) {
	for _, mime := range []string{"image/png", "audio/wav", "application/octet-stream"} {
		c, downloads := textTestClient(t, protocol.Attachment{FileId: testAttachmentID, MimeType: mime}, nil, false, "asset")
		w, result := textRequest(t, c, "", "asset")
		if w.Code != 200 || result.Status != "unsupported" || result.Complete || result.Warning == "" || *downloads != 0 {
			t.Fatalf("unsupported media misreported: %s", w.Body.String())
		}
	}
}

func TestAttachmentTextExtractionFixtures(t *testing.T) {
	for _, tc := range []struct {
		kind     string
		data     []byte
		want     string
		complete bool
	}{
		{"docx", officeFixture(t, map[string]string{"word/document.xml": `<document><p><t>Hello €</t></p></document>`}), "Hello €", false},
		{"xlsx", officeFixture(t, map[string]string{"xl/worksheets/sheet1.xml": `<worksheet><row><c r="A1" t="inlineStr"><is><t>Hello €</t></is></c></row></worksheet>`}), "A1: Hello €", false},
		{"pdf", pdfFixture(true), "Quarterly revenue", true},
		{"pdf", pdfFixture(false), "", false},
		{"text", []byte("Hello €"), "Hello €", true},
	} {
		t.Run(tc.kind+tc.want, func(t *testing.T) {
			if tc.kind == "pdf" {
				if _, err := exec.LookPath("pdftotext"); err != nil {
					t.Skip("Poppler unavailable")
				}
			}
			path := filepath.Join(t.TempDir(), "fixture")
			if err := os.WriteFile(path, tc.data, 0600); err != nil {
				t.Fatal(err)
			}
			text, complete, _, err := extractAttachmentText(context.Background(), path, tc.kind)
			if err != nil || !strings.Contains(text, tc.want) || complete != tc.complete {
				t.Fatalf("%q complete=%v err=%v", text, complete, err)
			}
		})
	}
}

func TestAttachmentTextExtractionFailuresAndCancellation(t *testing.T) {
	for _, kind := range []string{"pdf", "docx", "xlsx", "text"} {
		path := filepath.Join(t.TempDir(), "invalid")
		_ = os.WriteFile(path, []byte{255, 254, 0}, 0600)
		if _, _, _, err := extractAttachmentText(context.Background(), path, kind); err == nil {
			t.Fatalf("accepted corrupt %s", kind)
		}
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		if _, _, _, err := extractAttachmentText(ctx, path, kind); err == nil {
			t.Fatal("ignored cancellation")
		}
	}
	c, _ := textTestClient(t, protocol.Attachment{FileId: testAttachmentID, Filename: "bad.docx"}, []byte("not a zip"), false, "asset")
	w, result := textRequest(t, c, "", "asset")
	if w.Code != 200 || result.Status != "failed" || result.Complete || result.Warning == "" {
		t.Fatalf("failure misreported: %s", w.Body.String())
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := runExtractionContext(ctx, "sh", "-c", "sleep 30"); err == nil {
		t.Fatal("subprocess ignored cancellation")
	}
}

func TestAttachmentTextScopeAndLookupFailure(t *testing.T) {
	c, downloads := textTestClient(t, protocol.Attachment{FileId: testAttachmentID, MimeType: "text/plain"}, []byte("secret"), false, "asset")
	c.workspace = "other"
	w, _ := textRequest(t, c, "", "asset")
	if w.Code != 503 || *downloads != 0 {
		t.Fatal("cross-workspace client accepted")
	}
	c.workspace = "demo"
	c.sendMessage = func(_ uint16, payload []byte) error {
		id := binary.BigEndian.Uint32(payload[len(payload)-4:])
		pending, _ := c.pendingAttachmentAssets.LoadAndDelete(id)
		pending.(chan attachmentAssetResult) <- attachmentAssetResult{asset: protocol.Asset{AssetID: 7, ConvID: 99, Attachments: []protocol.Attachment{{FileId: testAttachmentID}}}}
		return nil
	}
	w, _ = textRequest(t, c, "", "asset")
	if w.Code != 502 || *downloads != 0 {
		t.Fatal("cross-conversation owner accepted")
	}
	c.sendMessage = func(uint16, []byte) error { return context.Canceled }
	w, _ = textRequest(t, c, "", "asset")
	if w.Code != 502 || *downloads != 0 {
		t.Fatal("failed lookup permitted download")
	}
}

func TestAttachmentTextCapsAndPDFWarnings(t *testing.T) {
	path := filepath.Join(t.TempDir(), "large.txt")
	if err := os.WriteFile(path, []byte(strings.Repeat("x", maxExtractedBytes+1)), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := extractAttachmentText(context.Background(), path, "text"); err == nil {
		t.Fatal("text extraction unbounded")
	}
	dir := t.TempDir()
	t.Setenv("PATH", dir)
	write := func(name, script string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+script), 0700); err != nil {
			t.Fatal(err)
		}
	}
	write("pdfinfo", "printf 'Pages: 21\\nEncrypted: no\\n'\n")
	write("pdftotext", "[ \"$1\" = '-f' ] && [ \"$2\" = '1' ] && [ \"$3\" = '-l' ] && [ \"$4\" = '20' ] || exit 1\nprintf 'bounded text'\n")
	text, complete, warning, err := extractAttachmentText(context.Background(), path, "pdf")
	if err != nil || text != "bounded text" || complete || !strings.Contains(warning, "first 20 pages") {
		t.Fatalf("PDF cap not reported: %q %v %q %v", text, complete, warning, err)
	}
	write("pdfinfo", "printf 'Pages: 1\\nEncrypted: yes (print:yes)\\n'\n")
	if _, _, _, err := extractAttachmentText(context.Background(), path, "pdf"); err == nil {
		t.Fatal("encrypted PDF accepted")
	}
}

func TestAttachmentTextRunningSubprocessCancellation(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	start := time.Now()
	if _, err := runExtractionContext(ctx, "sleep", "30"); err == nil || time.Since(start) > time.Second {
		t.Fatalf("running subprocess was not promptly cancelled: %v", err)
	}
}
