package main

import (
	"bytes"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestPrivateUploadRoundTrip(t *testing.T) {
	old := fileStoragePath
	fileStoragePath = t.TempDir()
	defer func() { fileStoragePath = old }()
	t.Setenv("TMPDIR", t.TempDir())
	data := bytes.Repeat([]byte{0, 255, 42}, 400000) // spill multipart data to disk
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	part, err := mw.CreateFormFile("file", "ticket.bin")
	if err != nil {
		t.Fatal(err)
	}
	part.Write(data)
	mw.Close()
	r := httptest.NewRequest("POST", "/upload?workspace=tickets", &body)
	r.Header.Set("Authorization", "Bearer test-secret")
	r.Header.Set("Content-Type", mw.FormDataContentType())
	w := httptest.NewRecorder()
	h := searchFilesHandler("test-secret")
	h.ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatalf("upload: %d %s", w.Code, w.Body)
	}
	var upload UploadResponse
	if err := json.Unmarshal(w.Body.Bytes(), &upload); err != nil {
		t.Fatal(err)
	}
	if upload.Size != int64(len(data)) || upload.Filename != "ticket.bin" || upload.FileID != generateFileID(data) || upload.URL != "/files/"+upload.FileID {
		t.Fatalf("response: %+v", upload)
	}
	for _, tc := range []struct {
		method, workspace string
		status            int
	}{
		{"GET", "tickets", 200}, {"HEAD", "tickets", 200}, {"GET", "other", 403},
	} {
		r = httptest.NewRequest(tc.method, upload.URL+"?workspace="+tc.workspace, nil)
		r.Header.Set("Authorization", "Bearer test-secret")
		w = httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.status {
			t.Fatalf("download: %d", w.Code)
		}
		if tc.status == 200 && tc.method == "GET" && !bytes.Equal(w.Body.Bytes(), data) {
			t.Fatal("wrong bytes")
		}
		if tc.method == "HEAD" && w.Body.Len() != 0 {
			t.Fatal("HEAD body")
		}
	}
	entries, err := os.ReadDir(os.Getenv("TMPDIR"))
	if err != nil || len(entries) != 0 {
		t.Fatalf("multipart leftovers: %v %v", entries, err)
	}
}

func TestPrivateUploadRejectsBeforeReading(t *testing.T) {
	old := fileStoragePath
	fileStoragePath = t.TempDir()
	defer func() { fileStoragePath = old }()
	for _, tc := range []struct {
		query, auth string
		status      int
	}{
		{"workspace=alice", "", 401}, {"workspace=alice", "Bearer wrong", 401},
		{"", "Bearer secret", 400}, {"workspace=../alice", "Bearer secret", 400},
		{"workspace=alice&workspace=bob", "Bearer secret", 400}, {"workspace=%zz", "Bearer secret", 400},
	} {
		r := httptest.NewRequest("POST", "/upload?"+tc.query, nil)
		r.Body = unreadUploadBody{t}
		r.Header.Set("Authorization", tc.auth)
		r.Header.Set("X-Tailscale-Login", "spoofed@example.com")
		w := httptest.NewRecorder()
		searchFilesHandler("secret").ServeHTTP(w, r)
		if w.Code != tc.status {
			t.Fatalf("%s: %d", tc.query, w.Code)
		}
	}
	entries, _ := os.ReadDir(fileStoragePath)
	if len(entries) != 0 {
		t.Fatal("rejected upload wrote files")
	}
}

type unreadUploadBody struct{ t *testing.T }

func (b unreadUploadBody) Read([]byte) (int, error) {
	b.t.Fatal("rejected request read body")
	return 0, io.EOF
}
func (unreadUploadBody) Close() error { return nil }

func TestPrivateUploadPayloadCap(t *testing.T) {
	old := fileStoragePath
	fileStoragePath = t.TempDir()
	defer func() { fileStoragePath = old }()
	t.Setenv("TMPDIR", t.TempDir())
	// Stream a multipart part without allocating a 100 MB request in the test.
	prefix := "--cap\r\nContent-Disposition: form-data; name=\"file\"; filename=\"large.bin\"\r\n\r\n"
	r := httptest.NewRequest("POST", "/upload?workspace=alice", io.MultiReader(bytes.NewBufferString(prefix), io.LimitReader(zeroUploadReader{}, maxFileSize+128*1024)))
	r.Header.Set("Authorization", "Bearer secret")
	r.Header.Set("Content-Type", "multipart/form-data; boundary=cap")
	w := httptest.NewRecorder()
	searchFilesHandler("secret").ServeHTTP(w, r)
	if w.Code != 413 {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}
	for _, dir := range []string{fileStoragePath, os.Getenv("TMPDIR")} {
		entries, err := os.ReadDir(dir)
		if err != nil || len(entries) != 0 {
			t.Fatalf("leftovers: %v %v", entries, err)
		}
	}
}

type zeroUploadReader struct{}

func (zeroUploadReader) Read(p []byte) (int, error) { clear(p); return len(p), nil }

func TestSearchFilesRequiresBotAndExactWorkspaceGrant(t *testing.T) {
	old := fileStoragePath
	fileStoragePath = t.TempDir()
	defer func() { fileStoragePath = old }()
	id := "att_0123456789abcdef0123456789abcdef"
	if err := os.WriteFile(filepath.Join(fileStoragePath, id), []byte("private media"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := recordFileWorkspace(id, "alice"); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, path, secret, method string
		status                     int
	}{
		{"allowed", "/files/" + id + "?workspace=alice", "test-secret", "GET", 200},
		{"other workspace", "/files/" + id + "?workspace=bob", "test-secret", "GET", 403},
		{"no auth", "/files/" + id + "?workspace=alice", "", "GET", 401},
		{"wrong auth", "/files/" + id + "?workspace=alice", "wrong", "GET", 401},
		{"missing scope", "/files/" + id, "test-secret", "GET", 400},
		{"traversal", "/files/../secret?workspace=alice", "test-secret", "GET", 400},
		{"short path", "/?workspace=alice", "test-secret", "GET", 400},
		{"wrong method", "/files/" + id + "?workspace=alice", "test-secret", "POST", 405},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(tc.method, tc.path, nil)
			r.Header.Set("Authorization", "Bearer "+tc.secret)
			w := httptest.NewRecorder()
			searchFilesHandler("test-secret").ServeHTTP(w, r)
			if w.Code != tc.status {
				t.Fatalf("status=%d want=%d body=%s", w.Code, tc.status, w.Body)
			}
			if tc.status == http.StatusOK && w.Body.String() != "private media" {
				t.Fatal("wrong bytes")
			}
		})
	}
	if err := os.Remove(fileWorkspaceMarker(id, "alice")); err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("GET", "/files/"+id+"?workspace=alice", nil)
	r.Header.Set("Authorization", "Bearer test-secret")
	w := httptest.NewRecorder()
	searchFilesHandler("test-secret").ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("unscoped legacy blob must fail closed")
	}
}
