package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"

	p "github.com/heavyhorst/nrc/protocol-go"
)

// Exercises the real HTTP adapter, including its private bot scope and bytes.
// The production file service's grant/storage tests live with tailscale-proxy.
func testFiles(t *testing.T) httpFiles {
	t.Helper()
	var mu sync.Mutex
	blobs := map[string][]byte{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-secret" || r.URL.Query().Get("workspace") != "tickets" {
			http.Error(w, "denied", 403)
			return
		}
		if r.Method == "POST" && r.URL.Path == "/upload" {
			file, header, err := r.FormFile("file")
			if err != nil {
				t.Error(err)
				w.WriteHeader(400)
				return
			}
			defer file.Close()
			data, _ := io.ReadAll(file)
			hash := sha256.Sum256(data)
			id := fmt.Sprintf("att_%x", hash[:16])
			mu.Lock()
			blobs[id] = data
			mu.Unlock()
			json.NewEncoder(w).Encode(map[string]any{"fileId": id, "filename": header.Filename, "size": len(data), "mimeType": http.DetectContentType(data), "uploadedAt": 12345})
			return
		}
		mu.Lock()
		data, ok := blobs[strings.TrimPrefix(r.URL.Path, "/files/")]
		mu.Unlock()
		if r.Method != "GET" || !ok {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Length", strconv.Itoa(len(data)))
		w.Write(data)
	}))
	t.Cleanup(server.Close)
	return httpFiles{server.URL, "tickets", "test-secret"}
}

func multipartRequest(t *testing.T, s *portal, path string, fields map[string]string, filenames []string, contents []byte) *httptest.ResponseRecorder {
	t.Helper()
	var body bytes.Buffer
	form := multipart.NewWriter(&body)
	for key, value := range fields {
		if err := form.WriteField(key, value); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range filenames {
		part, err := form.CreateFormFile("files", name)
		if err != nil {
			t.Fatal(err)
		}
		part.Write(contents)
	}
	form.Close()
	r := httptest.NewRequest("POST", path, &body)
	r.Header.Set("Content-Type", form.FormDataContentType())
	r.Header.Set("Origin", s.origin)
	r.SetBasicAuth("anna", "fixture-password-only")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	return w
}

func TestAttachmentsPersistAndStayTicketScoped(t *testing.T) {
	s, f := fixture(t)
	s.files = testFiles(t)
	data := []byte("binary\x00\xff\r\n<script>not active HTML</script>")
	w := multipartRequest(t, s, "/api/tickets", map[string]string{"title": "Mit Anlage", "body": "Siehe Screenshot"}, []string{"Screenshot ä.html"}, data)
	if w.Code != 201 {
		t.Fatal(w.Code, w.Body)
	}
	a := f.assets[21]
	if len(a.Attachments) != 1 || a.Attachments[0].Filename != "Screenshot ä.html" {
		t.Fatal(a)
	}
	// Fresh portal reads the persisted attachment, not a transient upload cache.
	s = &portal{source: f, files: s.files, accounts: s.accounts, origin: s.origin}
	w = own(s, "GET", "/api/tickets/21", "")
	var v view
	if err := json.Unmarshal(w.Body.Bytes(), &v); err != nil || len(v.Ticket.Attachments) != 1 {
		t.Fatal(err, w.Body)
	}
	link := v.Ticket.Attachments[0].URL
	w = own(s, "GET", link, "")
	if w.Code != 200 || !bytes.Equal(w.Body.Bytes(), data) || w.Header().Get("Content-Type") != "application/octet-stream" || !strings.HasPrefix(w.Header().Get("Content-Disposition"), "attachment;") || w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("unsafe or incorrect download", w.Code, w.Header(), w.Body)
	}
	w = multipartRequest(t, s, "/api/tickets/21/reply", map[string]string{"body": "Weitere Informationen"}, []string{"Diagnose.txt"}, []byte("reply bytes"))
	if w.Code != 201 || len(f.assets[22].Attachments) != 1 {
		t.Fatal(w.Code, w.Body)
	}
	entryAttachment := f.assets[22].Attachments[0]
	for _, id := range []uint64{2, 11} {
		asset := f.assets[id]
		asset.Attachments = []p.Attachment{entryAttachment}
		f.assets[id] = asset
	}
	hidden := f.assets[11]
	hidden.Attachments[0].Filename = "HIDDEN_INTERNAL_FILE"
	f.assets[11] = hidden
	for _, path := range []string{
		fmt.Sprintf("/tickets/2/attachments/2/%s", entryAttachment.FileId),
		fmt.Sprintf("/tickets/1/attachments/11/%s", entryAttachment.FileId),
		fmt.Sprintf("/tickets/21/attachments/11/%s", entryAttachment.FileId),
		fmt.Sprintf("/tickets/1/attachments/22/%s", entryAttachment.FileId),
		fmt.Sprintf("/tickets/21/attachments/21/%s", entryAttachment.FileId),
		"/files/" + entryAttachment.FileId,
	} {
		for _, suffix := range []string{"", "?preview=1"} {
			if w := own(s, "GET", path+suffix, ""); w.Code != 404 {
				t.Fatal("file ID bypassed ticket visibility", path+suffix, w.Code)
			}
		}
	}
	w = own(s, "GET", fmt.Sprintf("/tickets/21/attachments/22/%s", entryAttachment.FileId), "")
	if w.Code != 200 || w.Body.String() != "reply bytes" {
		t.Fatal(w.Code, w.Body)
	}
	for _, path := range []string{"/tickets/1", "/api/tickets/1"} {
		if w := own(s, "GET", path, ""); strings.Contains(w.Body.String(), "HIDDEN_INTERNAL_FILE") {
			t.Fatal("private filename leaked")
		}
	}
	// Same-case visibility is authoritative, not encoding/json's aliases.
	entry := f.assets[22]
	entry.Preview = `{"version":1,"kind":"internal_note","Kind":"public_reply"}`
	f.assets[22] = entry
	if w := own(s, "GET", fmt.Sprintf("/tickets/21/attachments/22/%s", entryAttachment.FileId), ""); w.Code != 404 {
		t.Fatal("internal attachment exposed")
	}
}

func TestImagePreviewsKeepDownloadsInertAndRejectActiveContent(t *testing.T) {
	s, f := fixture(t)
	s.files = testFiles(t)
	img := image.NewRGBA(image.Rect(0, 0, 3, 2))
	img.Set(2, 1, color.RGBA{R: 255, A: 255})
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, img); err != nil {
		t.Fatal(err)
	}
	for i, tc := range []struct {
		name    string
		data    []byte
		preview bool
	}{
		{"Screenshot.png", encoded.Bytes(), true},
		{"Fake.png", []byte("<!doctype html><script>alert(1)</script>"), false},
		{"Drawing.svg", []byte(`<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>`), false},
		{"Notes.txt", []byte("plain text"), false},
	} {
		w := multipartRequest(t, s, "/api/tickets", map[string]string{"title": tc.name, "body": "Original"}, []string{tc.name}, tc.data)
		if w.Code != 201 {
			t.Fatal(w.Code, w.Body)
		}
		id := uint64(21 + i)
		asset := f.assets[id]
		// Malicious stored image MIME must never make HTML/SVG executable.
		asset.Attachments[0].MimeType = "image/png"
		f.assets[id] = asset
		w = own(s, "GET", fmt.Sprintf("/api/tickets/%d", id), "")
		var v view
		if err := json.Unmarshal(w.Body.Bytes(), &v); err != nil {
			t.Fatal(err)
		}
		attachment := v.Ticket.Attachments[0]
		if attachment.PreviewURL == "" {
			t.Fatal("missing image preview URL")
		}
		w = own(s, "GET", attachment.PreviewURL, "")
		if tc.preview {
			if w.Code != 200 || w.Header().Get("Content-Type") != "image/png" || !strings.HasPrefix(w.Header().Get("Content-Disposition"), "inline;") || !bytes.Equal(w.Body.Bytes(), tc.data) || w.Header().Get("Cache-Control") != "no-store" || w.Header().Get("X-Content-Type-Options") != "nosniff" {
				t.Fatal(w.Code, w.Header(), w.Body)
			}
			// Use actual valid raster bytes here: text would be rejected by the
			// MIME guard even if an authorization check were accidentally lost.
			for _, hiddenID := range []uint64{2, 11} {
				hidden := f.assets[hiddenID]
				hidden.Attachments = asset.Attachments
				f.assets[hiddenID] = hidden
			}
			for _, path := range []string{
				fmt.Sprintf("/tickets/2/attachments/2/%s?preview=1", asset.Attachments[0].FileId),
				fmt.Sprintf("/tickets/1/attachments/11/%s?preview=1", asset.Attachments[0].FileId),
				fmt.Sprintf("/tickets/%d/attachments/11/%s?preview=1", id, asset.Attachments[0].FileId),
			} {
				if w := own(s, "GET", path, ""); w.Code != 404 {
					t.Fatal("private image preview leaked", path, w.Code)
				}
			}
			changed := asset
			changed.Preview = `{"version":1,"title":"Reassigned","requester":"someone-else@example.test","status":"open"}`
			f.assets[id] = changed
			if w := own(s, "GET", attachment.PreviewURL, ""); w.Code != 404 {
				t.Fatal("preview ignored requester reassignment", w.Code)
			}
			f.assets[id] = asset
		} else if w.Code != 404 {
			t.Fatal("active/non-image content allowed inline", tc.name, w.Code)
		}
		w = own(s, "GET", attachment.URL, "")
		if w.Code != 200 || w.Header().Get("Content-Type") != "application/octet-stream" || !strings.HasPrefix(w.Header().Get("Content-Disposition"), "attachment;") || !bytes.Equal(w.Body.Bytes(), tc.data) {
			t.Fatal("download contract changed", tc.name, w.Code, w.Header())
		}
	}
}

func TestAttachmentValidationAndBackendFailure(t *testing.T) {
	s, f := fixture(t)
	s.files = testFiles(t)
	for _, tc := range []struct {
		fields map[string]string
		names  []string
		want   int
	}{
		{map[string]string{"title": "Test", "body": "Text", "file_id": "att_forged"}, []string{"file.txt"}, 400},
		{map[string]string{"title": "Test", "body": "Text", "files": "att_forged"}, nil, 400},
		{map[string]string{"title": "Test", "body": "Text"}, []string{strings.Repeat("x", 256)}, 400},
		{map[string]string{"title": "Test", "body": "Text"}, strings.Fields(strings.Repeat("file.txt ", 11)), 413},
		{map[string]string{"title": "Test", "body": ""}, []string{"file.txt"}, 400},
	} {
		w := multipartRequest(t, s, "/api/tickets", tc.fields, tc.names, []byte("x"))
		if w.Code != tc.want || f.writes != 0 {
			t.Fatal(w.Code, w.Body, f.writes)
		}
	}
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Error(w, "down", 503) }))
	defer backend.Close()
	s.files = httpFiles{backend.URL, "tickets", "test-secret"}
	w := multipartRequest(t, s, "/api/tickets", map[string]string{"title": "Test", "body": "Text"}, []string{"file.txt"}, []byte("x"))
	if w.Code != 503 || f.writes != 0 {
		t.Fatal("failed upload must not create attachment-less ticket", w.Code)
	}
}

func TestOptionalFileInputAndNamedEmptyFile(t *testing.T) {
	s, f := fixture(t)
	s.files = testFiles(t)
	// An untouched browser input is filename="", not a named zero-byte file.
	w := multipartRequest(t, s, "/api/tickets", map[string]string{"title": "Text only", "body": "Original"}, []string{""}, nil)
	if w.Code != 201 || len(f.assets[21].Attachments) != 0 {
		t.Fatal("empty browser input rejected", w.Code, w.Body)
	}
	w = multipartRequest(t, s, "/api/tickets/21/reply", map[string]string{"body": "Reply without attachment"}, []string{""}, nil)
	if w.Code != 201 || len(f.assets[22].Attachments) != 0 {
		t.Fatal("empty reply input rejected", w.Code, w.Body)
	}
	w = multipartRequest(t, s, "/api/tickets/21/reply", map[string]string{"body": "Empty file is intentional"}, []string{"empty.txt"}, nil)
	if w.Code != 201 || len(f.assets[23].Attachments) != 1 || f.assets[23].Attachments[0].Size != 0 {
		t.Fatal("named empty attachment lost", w.Code, w.Body)
	}
	link := fmt.Sprintf("/tickets/21/attachments/23/%s", f.assets[23].Attachments[0].FileId)
	if w := own(s, "GET", link, ""); w.Code != 200 || w.Body.Len() != 0 {
		t.Fatal("empty attachment download failed", w.Code)
	}
}
