package upload

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestUploadFileTrimsTrailingProxySlash(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Fatalf("method = %s, want POST", r.Method)
		}
		if r.URL.Path != "/upload" {
			t.Fatalf("path = %q, want /upload", r.URL.Path)
		}
		if got := r.URL.Query().Get("workspace"); got != "private-alice" {
			t.Fatalf("workspace = %q, want private-alice", got)
		}
		if err := r.ParseMultipartForm(MaxFileSize); err != nil {
			t.Fatalf("ParseMultipartForm failed: %v", err)
		}
		file, handler, err := r.FormFile("file")
		if err != nil {
			t.Fatalf("FormFile failed: %v", err)
		}
		file.Close()
		if handler.Filename != "note.txt" {
			t.Fatalf("filename = %q, want note.txt", handler.Filename)
		}

		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(UploadResponse{
			FileId:     "att_test",
			Filename:   handler.Filename,
			Size:       handler.Size,
			MimeType:   "text/plain",
			UploadedAt: 123,
		}); err != nil {
			t.Fatalf("Encode failed: %v", err)
		}
	}))
	defer server.Close()

	path := filepath.Join(t.TempDir(), "note.txt")
	if err := os.WriteFile(path, []byte("hello"), 0600); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}

	attachment, err := UploadFile(path, server.URL+"/", "private-alice")
	if err != nil {
		t.Fatalf("UploadFile failed: %v", err)
	}
	if attachment.FileId != "att_test" || attachment.Filename != "note.txt" {
		t.Fatalf("attachment = %+v, want att_test/note.txt", attachment)
	}
}

func TestFileURL(t *testing.T) {
	attachment := protocol.Attachment{FileId: "att/test", Filename: "note attachment.txt"}
	got := FileURL(attachment, "https://files.example/")
	want := "https://files.example/files/att%2Ftest?filename=note+attachment.txt"
	if got != want {
		t.Fatalf("FileURL = %q, want %q", got, want)
	}
	if got := FileURL(protocol.Attachment{}, "https://files.example"); got != "" {
		t.Fatalf("FileURL with empty file ID = %q, want empty", got)
	}
}

func TestDownloadFile(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Fatalf("method = %s, want GET", r.Method)
		}
		if r.URL.Path != "/files/att_test" {
			t.Fatalf("path = %q, want /files/att_test", r.URL.Path)
		}
		if got := r.URL.Query().Get("filename"); got != "note attachment.txt" {
			t.Fatalf("filename = %q, want note attachment.txt", got)
		}
		_, _ = w.Write([]byte("downloaded contents"))
	}))
	defer server.Close()

	destination := filepath.Join(t.TempDir(), "result.txt")
	written, err := DownloadFile(protocol.Attachment{
		FileId:   "att_test",
		Filename: "note attachment.txt",
	}, server.URL+"/", destination)
	if err != nil {
		t.Fatalf("DownloadFile failed: %v", err)
	}
	if written != int64(len("downloaded contents")) {
		t.Fatalf("written = %d, want %d", written, len("downloaded contents"))
	}
	contents, err := os.ReadFile(destination)
	if err != nil {
		t.Fatalf("ReadFile failed: %v", err)
	}
	if string(contents) != "downloaded contents" {
		t.Fatalf("contents = %q, want downloaded contents", contents)
	}
}

func TestDownloadFileDoesNotReplaceDestinationOnHTTPError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "missing", http.StatusNotFound)
	}))
	defer server.Close()

	destination := filepath.Join(t.TempDir(), "existing.txt")
	if err := os.WriteFile(destination, []byte("keep me"), 0600); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}
	_, err := DownloadFile(protocol.Attachment{FileId: "att_missing"}, server.URL, destination)
	if err == nil {
		t.Fatal("DownloadFile succeeded, want error")
	}
	contents, readErr := os.ReadFile(destination)
	if readErr != nil {
		t.Fatalf("ReadFile failed: %v", readErr)
	}
	if string(contents) != "keep me" {
		t.Fatalf("contents = %q, want existing file preserved", contents)
	}
}
