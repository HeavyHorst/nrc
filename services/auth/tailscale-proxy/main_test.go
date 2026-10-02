package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"

	"tailscale.com/client/tailscale/apitype"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
)

type fakeWhoIsClient struct {
	response  *apitype.WhoIsResponse
	err       error
	status    *ipnstate.Status
	statusErr error
}

func (c fakeWhoIsClient) WhoIs(context.Context, string) (*apitype.WhoIsResponse, error) {
	return c.response, c.err
}

func (c fakeWhoIsClient) Status(context.Context) (*ipnstate.Status, error) {
	return c.status, c.statusErr
}

func TestHandleGetUsers(t *testing.T) {
	oldUsers := users
	defer func() { users = oldUsers }()
	for _, tt := range []struct {
		name     string
		visitors map[string]bool
		client   fakeWhoIsClient
		want     []string
	}{
		{
			name:     "merge normalized status users and visitors",
			visitors: map[string]bool{"alice": true, "visitor": true, "tag:amp": true},
			client: fakeWhoIsClient{status: &ipnstate.Status{User: map[tailcfg.UserID]tailcfg.UserProfile{
				1: {LoginName: "alice@example.com"},
				2: {LoginName: "bob@example.com"},
				3: {LoginName: "bob@other.example"},
				4: {LoginName: "carol"},
				5: {LoginName: ""},
				6: {LoginName: "@example.com"},
			}}},
			want: []string{"alice", "bob", "carol", "tag:amp", "visitor"},
		},
		{
			name:     "status failure retains visitors",
			visitors: map[string]bool{"visitor": true},
			client:   fakeWhoIsClient{statusErr: fmt.Errorf("status unavailable")},
			want:     []string{"visitor"},
		},
		{
			name:     "empty directory is an array",
			visitors: map[string]bool{},
			want:     []string{},
		},
	} {
		t.Run(tt.name, func(t *testing.T) {
			users = tt.visitors
			rec := httptest.NewRecorder()
			handleGetUsers(rec, httptest.NewRequest(http.MethodGet, "/api/users", nil), tt.client)
			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d", rec.Code)
			}
			var got []string
			if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
				t.Fatal(err)
			}
			if got == nil || !slices.Equal(got, tt.want) {
				t.Fatalf("users = %v, want %v (non-null array)", got, tt.want)
			}
			if rec.Header().Get("Cache-Control") != "no-store" {
				t.Error("directory response must not be cached")
			}
			for _, login := range []string{"bob", "carol"} {
				if users[login] {
					t.Errorf("status user %q persisted as a visitor", login)
				}
			}
		})
	}
}

func TestInjectIdentityHeadersTaggedNode(t *testing.T) {
	oldSecret := jwtSecret
	jwtSecret = []byte("test-secret")
	defer func() { jwtSecret = oldSecret }()

	client := fakeWhoIsClient{response: &apitype.WhoIsResponse{
		Node: &tailcfg.Node{
			StableID: "n123456CNTRL",
			Name:     "ci-runner.example.ts.net.",
			Tags:     []string{"tag:ci"},
		},
		UserProfile: &tailcfg.UserProfile{},
	}}
	req := httptest.NewRequest(http.MethodGet, "https://nrc/", nil)
	req.RemoteAddr = "100.64.0.10:4321"

	login, err := injectIdentityHeaders(req, client)
	if err != nil {
		t.Fatalf("injectIdentityHeaders returned error: %v", err)
	}
	if want := "tag:ci"; login != want {
		t.Fatalf("login = %q, want %q", login, want)
	}
	if got := req.Header.Get("X-Tailscale-Login"); got != login {
		t.Errorf("X-Tailscale-Login = %q, want %q", got, login)
	}
	if got := req.Header.Get("X-Tailscale-Node"); got != "ci-runner.example.ts.net." {
		t.Errorf("X-Tailscale-Node = %q", got)
	}
	if got := req.Header.Get("X-NRC-Auth"); got == "" {
		t.Error("X-NRC-Auth was not set")
	}
}

func TestTaggedNodeLoginSelectsTagDeterministically(t *testing.T) {
	node := &tailcfg.Node{
		StableID: "n123456CNTRL",
		Tags:     []string{"tag:worker", "tag:amp"},
	}

	login, err := taggedNodeLogin(node)
	if err != nil {
		t.Fatalf("taggedNodeLogin returned error: %v", err)
	}
	if want := "tag:amp"; login != want {
		t.Fatalf("login = %q, want %q", login, want)
	}
}

func TestInjectIdentityHeadersUserNode(t *testing.T) {
	oldSecret := jwtSecret
	jwtSecret = []byte("test-secret")
	defer func() { jwtSecret = oldSecret }()

	client := fakeWhoIsClient{response: &apitype.WhoIsResponse{
		Node:        &tailcfg.Node{Name: "alice-laptop.example.ts.net."},
		UserProfile: &tailcfg.UserProfile{LoginName: "alice@example.com"},
	}}
	req := httptest.NewRequest(http.MethodGet, "https://nrc/", nil)
	req.RemoteAddr = "100.64.0.11:4321"

	login, err := injectIdentityHeaders(req, client)
	if err != nil {
		t.Fatalf("injectIdentityHeaders returned error: %v", err)
	}
	if login != "alice" {
		t.Fatalf("login = %q, want alice", login)
	}
	if got := req.Header.Get("X-Tailscale-User"); got != "alice@example.com" {
		t.Errorf("X-Tailscale-User = %q", got)
	}
}

func TestHandleFeatures(t *testing.T) {
	userResponse := func(login string) *apitype.WhoIsResponse {
		return &apitype.WhoIsResponse{
			Node:        &tailcfg.Node{Name: "user-device.example.ts.net."},
			UserProfile: &tailcfg.UserProfile{LoginName: login},
		}
	}

	tests := []struct {
		name       string
		config     string
		method     string
		response   *apitype.WhoIsResponse
		whoisError error
		forgedUser string
		wantStatus int
		wantBody   string
	}{
		{
			name:   "authorized exact full login with config whitespace",
			config: " bob@example.com, alice@example.com ", method: http.MethodGet,
			response: userResponse("alice@example.com"), wantStatus: http.StatusOK,
			wantBody: `{"customers":true}` + "\n",
		},
		{
			name:   "unauthorized user returns disabled feature",
			config: "alice@example.com", method: http.MethodGet,
			response: userResponse("mallory@example.com"), wantStatus: http.StatusOK,
			wantBody: `{"customers":false}` + "\n",
		},
		{
			name:   "same nickname on another domain is not the same login",
			config: "alice@example.com", method: http.MethodGet,
			response: userResponse("alice@other.example"), wantStatus: http.StatusOK,
			wantBody: `{"customers":false}` + "\n",
		},
		{
			name: "missing identity denied", method: http.MethodGet,
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:   "missing config defaults deny",
			method: http.MethodGet, response: userResponse("alice@example.com"),
			wantStatus: http.StatusOK, wantBody: `{"customers":false}` + "\n",
		},
		{
			name:   "empty entries and wildcard do not authorize",
			config: " , *,  ", method: http.MethodGet, response: userResponse("alice@example.com"),
			wantStatus: http.StatusOK, wantBody: `{"customers":false}` + "\n",
		},
		{
			name:   "forged identity header ignored",
			config: "alice@example.com", method: http.MethodGet,
			response: userResponse("mallory@example.com"), forgedUser: "alice@example.com",
			wantStatus: http.StatusOK, wantBody: `{"customers":false}` + "\n",
		},
		{
			name:   "tagged node denied",
			config: "owner@example.com", method: http.MethodGet,
			response: &apitype.WhoIsResponse{
				Node:        &tailcfg.Node{Name: "worker.example.ts.net.", Tags: []string{"tag:worker"}},
				UserProfile: &tailcfg.UserProfile{LoginName: "owner@example.com"},
			},
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:   "whois failure denied",
			config: "alice@example.com", method: http.MethodGet, whoisError: fmt.Errorf("unavailable"),
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:   "unsupported method",
			config: "alice@example.com", method: http.MethodPost, response: userResponse("alice@example.com"),
			wantStatus: http.StatusMethodNotAllowed,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			handler := handleFeatures(parseCustomerUsers(test.config), fakeWhoIsClient{
				response: test.response,
				err:      test.whoisError,
			})
			req := httptest.NewRequest(test.method, "https://nrc/api/features", nil)
			req.RemoteAddr = "100.64.0.20:1234"
			if test.forgedUser != "" {
				req.Header.Set("X-Tailscale-User", test.forgedUser)
				req.Header.Set("X-Tailscale-Login", "alice")
			}
			rec := httptest.NewRecorder()

			handler.ServeHTTP(rec, req)

			if rec.Code != test.wantStatus {
				t.Fatalf("status = %d, want %d; body = %q", rec.Code, test.wantStatus, rec.Body.String())
			}
			if got := rec.Header().Get("Cache-Control"); got != "no-store" {
				t.Errorf("Cache-Control = %q, want no-store", got)
			}
			if test.wantBody != "" && rec.Body.String() != test.wantBody {
				t.Errorf("body = %q, want %q", rec.Body.String(), test.wantBody)
			}
			if strings.Contains(rec.Body.String(), "example.com") {
				t.Errorf("response disclosed identity: %q", rec.Body.String())
			}
		})
	}
}

// TestHandleUpload tests the file upload endpoint
func TestHandleUpload(t *testing.T) {
	// Setup temp storage directory
	tmpDir := t.TempDir()
	oldStoragePath := fileStoragePath
	fileStoragePath = tmpDir
	defer func() { fileStoragePath = oldStoragePath }()

	tests := []struct {
		name           string
		setupRequest   func() *http.Request
		expectedStatus int
		checkResponse  func(t *testing.T, rec *httptest.ResponseRecorder)
	}{
		{
			name: "successful upload",
			setupRequest: func() *http.Request {
				body := &bytes.Buffer{}
				writer := multipart.NewWriter(body)

				// Create form file field
				fileWriter, err := writer.CreateFormFile("file", "test.txt")
				if err != nil {
					t.Fatal(err)
				}
				fileWriter.Write([]byte("test file content"))
				writer.Close()

				req := httptest.NewRequest("POST", "/upload", body)
				req.Header.Set("Content-Type", writer.FormDataContentType())
				req.Header.Set("X-Tailscale-Login", "alice")
				return req
			},
			expectedStatus: http.StatusOK,
			checkResponse: func(t *testing.T, rec *httptest.ResponseRecorder) {
				if rec.Header().Get("Content-Type") != "application/json" {
					t.Errorf("expected application/json, got %s", rec.Header().Get("Content-Type"))
				}
			},
		},
		{
			name: "missing auth header",
			setupRequest: func() *http.Request {
				body := &bytes.Buffer{}
				writer := multipart.NewWriter(body)
				fileWriter, _ := writer.CreateFormFile("file", "test.txt")
				fileWriter.Write([]byte("test content"))
				writer.Close()

				req := httptest.NewRequest("POST", "/upload", body)
				req.Header.Set("Content-Type", writer.FormDataContentType())
				return req
			},
			expectedStatus: http.StatusUnauthorized,
		},
		{
			name: "missing file field",
			setupRequest: func() *http.Request {
				body := &bytes.Buffer{}
				writer := multipart.NewWriter(body)
				writer.WriteField("other", "value")
				writer.Close()

				req := httptest.NewRequest("POST", "/upload", body)
				req.Header.Set("Content-Type", writer.FormDataContentType())
				req.Header.Set("X-Tailscale-Login", "alice")
				return req
			},
			expectedStatus: http.StatusBadRequest,
		},
		{
			name: "wrong HTTP method",
			setupRequest: func() *http.Request {
				return httptest.NewRequest("GET", "/upload", nil)
			},
			expectedStatus: http.StatusMethodNotAllowed,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := tt.setupRequest()
			rec := httptest.NewRecorder()

			handleUpload(rec, req)

			if rec.Code != tt.expectedStatus {
				t.Errorf("expected status %d, got %d", tt.expectedStatus, rec.Code)
			}

			if tt.checkResponse != nil {
				tt.checkResponse(t, rec)
			}
		})
	}
}

// TestHandleDownload tests the file download endpoint
func TestHandleDownload(t *testing.T) {
	// Setup temp storage directory
	tmpDir := t.TempDir()
	oldStoragePath := fileStoragePath
	fileStoragePath = tmpDir
	defer func() { fileStoragePath = oldStoragePath }()

	// Create test file in shared content-addressed storage.
	testFileID := "att_testfile123456789012345"
	testContent := []byte("test file content")
	testFilePath := filepath.Join(tmpDir, testFileID)
	os.WriteFile(testFilePath, testContent, 0644)

	tests := []struct {
		name           string
		fileID         string
		authHeader     string
		expectedStatus int
		checkResponse  func(t *testing.T, body []byte)
	}{
		{
			name:           "successful download",
			fileID:         testFileID,
			authHeader:     "alice",
			expectedStatus: http.StatusOK,
			checkResponse: func(t *testing.T, body []byte) {
				if !bytes.Equal(body, testContent) {
					t.Errorf("expected content %s, got %s", testContent, body)
				}
			},
		},
		{
			name:           "missing auth header",
			fileID:         testFileID,
			authHeader:     "",
			expectedStatus: http.StatusUnauthorized,
		},
		{
			name:           "file not found",
			fileID:         "att_nonexistent1234567890",
			authHeader:     "alice",
			expectedStatus: http.StatusNotFound,
		},
		{
			name:           "directory traversal attempt",
			fileID:         "../../../etc/passwd",
			authHeader:     "alice",
			expectedStatus: http.StatusForbidden,
		},
		{
			name:           "missing file ID",
			fileID:         "",
			authHeader:     "alice",
			expectedStatus: http.StatusBadRequest,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest("GET", fmt.Sprintf("/files/%s", tt.fileID), nil)
			if tt.authHeader != "" {
				req.Header.Set("X-Tailscale-Login", tt.authHeader)
			}
			rec := httptest.NewRecorder()

			handleDownload(rec, req)

			if rec.Code != tt.expectedStatus {
				t.Errorf("expected status %d, got %d", tt.expectedStatus, rec.Code)
			}

			if tt.checkResponse != nil && rec.Code == http.StatusOK {
				body, _ := io.ReadAll(rec.Body)
				tt.checkResponse(t, body)
			}
		})
	}
}

func TestHandleDownloadUsesRequestedFilename(t *testing.T) {
	tmpDir := t.TempDir()
	oldStoragePath := fileStoragePath
	fileStoragePath = tmpDir
	defer func() { fileStoragePath = oldStoragePath }()

	fileID := "att_testfile123456789012345"
	if err := os.WriteFile(filepath.Join(tmpDir, fileID), []byte("content"), 0644); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest("GET", fmt.Sprintf("/files/%s?filename=Kundenfassung%%20Anforderungen.docx", fileID), nil)
	req.Header.Set("X-Tailscale-Login", "alice")
	rec := httptest.NewRecorder()

	handleDownload(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}
	disposition := rec.Header().Get("Content-Disposition")
	if disposition != `attachment; filename="Kundenfassung Anforderungen.docx"` {
		t.Fatalf("Content-Disposition = %q", disposition)
	}
}

func TestDownloadPreviewIsolationAndRanges(t *testing.T) {
	old := fileStoragePath
	fileStoragePath = t.TempDir()
	defer func() { fileStoragePath = old }()
	if err := os.WriteFile(filepath.Join(fileStoragePath, "att_fixture"), []byte("0123456789"), 0644); err != nil {
		t.Fatal(err)
	}
	for _, filename := range []string{"payload.html", "payload.svg", "document.pdf", "clip.mp4", "sound.wav"} {
		t.Run(filename, func(t *testing.T) {
			req := httptest.NewRequest("GET", "/files/att_fixture?inline=true&filename="+filename, nil)
			req.Header.Set("X-Tailscale-Login", "alice")
			req.Header.Set("Range", "bytes=2-5")
			rec := httptest.NewRecorder()
			handleDownload(rec, req)
			if rec.Code != http.StatusPartialContent || rec.Body.String() != "2345" || rec.Header().Get("Content-Range") != "bytes 2-5/10" {
				t.Fatalf("range response: %d %q %v", rec.Code, rec.Body.String(), rec.Header())
			}
			if rec.Header().Get("Content-Security-Policy") != "sandbox" || rec.Header().Get("X-Content-Type-Options") != "nosniff" {
				t.Fatal("uploaded content lacks origin/script isolation")
			}
			want := "inline;"
			if filename == "payload.html" {
				want = "attachment;"
			}
			if !strings.HasPrefix(rec.Header().Get("Content-Disposition"), want) {
				t.Fatalf("wrong disposition: %s", rec.Header().Get("Content-Disposition"))
			}
		})
	}
}

func TestDownloadContentType(t *testing.T) {
	tests := []struct {
		filename string
		want     string
	}{
		{filename: "diagram.SVG", want: "image/svg+xml"},
		{filename: "screenshot.png", want: "image/png"},
		{filename: "photo.jpg", want: "image/jpeg"},
		{filename: "document.pdf", want: "application/pdf"},
		{filename: "archive.unknown", want: "application/octet-stream"},
		{filename: "no-extension", want: "application/octet-stream"},
	}

	for _, test := range tests {
		t.Run(test.filename, func(t *testing.T) {
			if got := downloadContentType(test.filename); got != test.want {
				t.Fatalf("downloadContentType(%q) = %q, want %q", test.filename, got, test.want)
			}
		})
	}
}

func TestHandleDownloadUsesSVGContentTypeInline(t *testing.T) {
	tmpDir := t.TempDir()
	oldStoragePath := fileStoragePath
	fileStoragePath = tmpDir
	defer func() { fileStoragePath = oldStoragePath }()

	fileID := "att_testfile123456789012345"
	content := []byte(`<svg xmlns="http://www.w3.org/2000/svg"><circle r="1"/></svg>`)
	if err := os.WriteFile(filepath.Join(tmpDir, fileID), content, 0644); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest("GET", fmt.Sprintf("/files/%s?inline=true&filename=diagram.SVG", fileID), nil)
	req.Header.Set("X-Tailscale-Login", "alice")
	rec := httptest.NewRecorder()

	handleDownload(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if got := rec.Header().Get("Content-Type"); got != "image/svg+xml" {
		t.Fatalf("Content-Type = %q, want %q", got, "image/svg+xml")
	}
	if got := rec.Header().Get("Content-Disposition"); got != "inline; filename=diagram.SVG" {
		t.Fatalf("Content-Disposition = %q, want %q", got, "inline; filename=diagram.SVG")
	}
	if !bytes.Equal(rec.Body.Bytes(), content) {
		t.Fatalf("body = %q, want %q", rec.Body.Bytes(), content)
	}
}

func TestHandleDownloadSanitizesRequestedFilename(t *testing.T) {
	tmpDir := t.TempDir()
	oldStoragePath := fileStoragePath
	fileStoragePath = tmpDir
	defer func() { fileStoragePath = oldStoragePath }()

	fileID := "att_testfile123456789012345"
	if err := os.WriteFile(filepath.Join(tmpDir, fileID), []byte("content"), 0644); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest("GET", fmt.Sprintf("/files/%s?filename=../../secret.txt", fileID), nil)
	req.Header.Set("X-Tailscale-Login", "alice")
	rec := httptest.NewRecorder()

	handleDownload(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}
	disposition := rec.Header().Get("Content-Disposition")
	if disposition != `attachment; filename=secret.txt` {
		t.Fatalf("Content-Disposition = %q", disposition)
	}
}

// TestHandleDownloadHead tests HEAD request support
func TestHandleDownloadHead(t *testing.T) {
	tmpDir := t.TempDir()
	oldStoragePath := fileStoragePath
	fileStoragePath = tmpDir
	defer func() { fileStoragePath = oldStoragePath }()

	// Create test file in shared content-addressed storage.
	testFileID := "att_testfile123456789012345"
	testContent := []byte("test file content")
	testFilePath := filepath.Join(tmpDir, testFileID)
	os.WriteFile(testFilePath, testContent, 0644)

	req := httptest.NewRequest("HEAD", fmt.Sprintf("/files/%s", testFileID), nil)
	req.Header.Set("X-Tailscale-Login", "alice")
	rec := httptest.NewRecorder()

	handleDownload(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d", rec.Code)
	}

	if rec.Body.Len() > 0 {
		t.Errorf("HEAD request should not return body, got %d bytes", rec.Body.Len())
	}

	if rec.Header().Get("Content-Length") == "" {
		t.Error("HEAD response should include Content-Length header")
	}
}

// TestGenerateFileID tests file ID generation
func TestGenerateFileID(t *testing.T) {
	data1 := []byte("test content")
	data2 := []byte("test content")
	data3 := []byte("different content")

	id1 := generateFileID(data1)
	id2 := generateFileID(data2)
	id3 := generateFileID(data3)

	// Same content should produce same ID
	if id1 != id2 {
		t.Errorf("same content should produce same ID: %s != %s", id1, id2)
	}

	// Different content should produce different ID
	if id1 == id3 {
		t.Errorf("different content should produce different IDs")
	}

	// Check format
	if !bytes.HasPrefix([]byte(id1), []byte("att_")) {
		t.Errorf("file ID should start with 'att_', got %s", id1)
	}

	// Check length (att_ + 32 hex chars = 36)
	if len(id1) != 36 {
		t.Errorf("expected file ID length 36, got %d", len(id1))
	}
}

// TestSharedContentAddressedStorage tests that authenticated users share
// content-addressed attachment storage.
func TestSharedContentAddressedStorage(t *testing.T) {
	tmpDir := t.TempDir()
	oldStoragePath := fileStoragePath
	fileStoragePath = tmpDir
	defer func() { fileStoragePath = oldStoragePath }()

	fileID := "att_testfile123456789012345"
	content := []byte("shared file")
	os.WriteFile(filepath.Join(tmpDir, fileID), content, 0644)

	// Alice can download the shared file.
	req := httptest.NewRequest("GET", fmt.Sprintf("/files/%s", fileID), nil)
	req.Header.Set("X-Tailscale-Login", "alice")
	rec := httptest.NewRecorder()

	handleDownload(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("alice should be able to download her file, got status %d", rec.Code)
	}

	body, _ := io.ReadAll(rec.Body)
	if !bytes.Equal(body, content) {
		t.Errorf("alice got wrong file content: %s", body)
	}

	// Bob gets the same content-addressed file; storage is shared across
	// authenticated users rather than isolated by user directory.
	req = httptest.NewRequest("GET", fmt.Sprintf("/files/%s", fileID), nil)
	req.Header.Set("X-Tailscale-Login", "bob")
	rec = httptest.NewRecorder()

	handleDownload(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("bob should be able to download his file, got status %d", rec.Code)
	}

	body, _ = io.ReadAll(rec.Body)
	if !bytes.Equal(body, content) {
		t.Errorf("bob got wrong file content: %s", body)
	}
}

func TestFileStorageProcessLockRefusesExclusiveGC(t *testing.T) {
	tmpDir := t.TempDir()
	oldStoragePath := fileStoragePath
	fileStoragePath = tmpDir
	defer func() { fileStoragePath = oldStoragePath }()

	gcDirectory, err := os.Open(tmpDir)
	if err != nil {
		t.Fatal(err)
	}
	defer gcDirectory.Close()
	if err := syscall.Flock(int(gcDirectory.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	defer syscall.Flock(int(gcDirectory.Fd()), syscall.LOCK_UN)

	if err := acquireFileStorageProcessLock(); err == nil {
		fileStorageLock.Close()
		t.Fatal("proxy acquired shared storage lock while GC held the exclusive lock")
	}
}

// TestInlineDisposition tests inline query parameter
func TestInlineDisposition(t *testing.T) {
	tmpDir := t.TempDir()
	oldStoragePath := fileStoragePath
	fileStoragePath = tmpDir
	defer func() { fileStoragePath = oldStoragePath }()

	// Create test file in shared content-addressed storage.
	fileID := "att_testfile123456789012345"
	os.WriteFile(filepath.Join(tmpDir, fileID), []byte("content"), 0644)

	// Test inline=true
	req := httptest.NewRequest("GET", fmt.Sprintf("/files/%s?inline=true", fileID), nil)
	req.Header.Set("X-Tailscale-Login", "alice")
	rec := httptest.NewRecorder()

	handleDownload(rec, req)

	if disposition := rec.Header().Get("Content-Disposition"); disposition != "attachment; filename=att_testfile123456789012345" {
		t.Errorf("expected download for an unknown content type, got %s", disposition)
	}

	// Test inline=false
	req = httptest.NewRequest("GET", fmt.Sprintf("/files/%s?inline=false", fileID), nil)
	req.Header.Set("X-Tailscale-Login", "alice")
	rec = httptest.NewRecorder()

	handleDownload(rec, req)

	if disposition := rec.Header().Get("Content-Disposition"); !bytes.HasPrefix([]byte(disposition), []byte("attachment")) {
		t.Errorf("expected attachment disposition, got %s", disposition)
	}
}

func TestRewriteAttachmentReferences(t *testing.T) {
	markdown := "![diagram](att:0) [source](att:1) <img src=\"att:0\"> <IMG SRC = 'att:0'> plain att:0"
	got := rewriteAttachmentReferences(markdown, []string{"attachment-0.png", "attachment-1.md"}, "markdown")
	want := "![diagram](attachment-0.png) [source](attachment-1.md) <img src=\"attachment-0.png\"> <IMG SRC = 'attachment-0.png'> plain att:0"
	if got != want {
		t.Fatalf("rewriteAttachmentReferences() = %q, want %q", got, want)
	}
	indices := referencedExportImageIndices(markdown, "markdown")
	if !indices[0] || indices[1] {
		t.Fatalf("referenced image indices = %#v", indices)
	}
	htmlIndices := referencedExportImageIndices(`<p><IMG alt="diagram" SRC = att:1></p>`, "html")
	if !htmlIndices[1] {
		t.Fatalf("HTML referenced image indices = %#v", htmlIndices)
	}
	htmlOutput := rewriteAttachmentReferences(`<IMG SRC = att:1><a href=att:0>source</a>`, []string{"source.md", "diagram.png"}, "html")
	if !strings.Contains(htmlOutput, `src="diagram.png"`) || !strings.Contains(htmlOutput, `href="source.md"`) {
		t.Fatalf("HTML attachment rewrite failed: %q", htmlOutput)
	}
}

func TestPandocExportArgsSelectInputFormat(t *testing.T) {
	for _, test := range []struct{ format, want string }{
		{"markdown", "--from=gfm"},
		{"html", "--from=html"},
	} {
		args := pandocExportArgs(ExportRequest{Format: "docx", InputFormat: test.format}, "/work", "/work/input", "/work/output", "/work/filter")
		if !slices.Contains(args, test.want) {
			t.Fatalf("args for %s = %#v, missing %q", test.format, args, test.want)
		}
	}
}

func TestExportLuaFilterAllowsOnlyLocalImages(t *testing.T) {
	filter := exportLuaFilter([]string{"attachment-0.png"})
	if !strings.Contains(filter, `["attachment-0.png"] = true`) {
		t.Fatalf("filter does not allow expected local image: %s", filter)
	}
	if !strings.Contains(filter, "return pandoc.Link") {
		t.Fatalf("filter does not replace external images with links: %s", filter)
	}
}

func TestHandleExport(t *testing.T) {
	oldConverter := convertExportRequest
	convertExportRequest = func(_ context.Context, _ ExportRequest, _, outputPath string) error {
		return os.WriteFile(outputPath, []byte("converted"), 0600)
	}
	defer func() { convertExportRequest = oldConverter }()

	for _, test := range []struct {
		format      string
		contentType string
		disposition string
	}{
		{
			format:      "pdf",
			contentType: "application/pdf",
			disposition: `inline; filename="Test Note.pdf"`,
		},
		{
			format:      "docx",
			contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
			disposition: `attachment; filename="Test Note.docx"`,
		},
	} {
		t.Run(test.format, func(t *testing.T) {
			body, err := json.Marshal(ExportRequest{Format: test.format, Title: "Test Note", Markdown: "Hello"})
			if err != nil {
				t.Fatal(err)
			}
			req := httptest.NewRequest(http.MethodPost, "/exports", bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("X-Tailscale-Login", "alice")
			rec := httptest.NewRecorder()

			handleExport(rec, req)

			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d, body = %q", rec.Code, rec.Body.String())
			}
			if got := rec.Header().Get("Content-Type"); got != test.contentType {
				t.Fatalf("Content-Type = %q, want %q", got, test.contentType)
			}
			if got := rec.Header().Get("Content-Disposition"); got != test.disposition {
				t.Fatalf("Content-Disposition = %q, want %q", got, test.disposition)
			}
			if got := rec.Body.String(); got != "converted" {
				t.Fatalf("body = %q", got)
			}
		})
	}
}

func TestHandleExportRejectsInvalidRequestEnvelope(t *testing.T) {
	tests := []struct {
		name        string
		contentType string
		body        string
		status      int
	}{
		{name: "missing content type", body: `{"format":"pdf"}`, status: http.StatusUnsupportedMediaType},
		{name: "text content type", contentType: "text/plain", body: `{"format":"pdf"}`, status: http.StatusUnsupportedMediaType},
		{name: "trailing JSON", contentType: "application/json", body: `{"format":"pdf"}{}`, status: http.StatusBadRequest},
		{name: "unsupported format", contentType: "application/json", body: `{"format":"odt"}`, status: http.StatusBadRequest},
		{name: "unsupported input format", contentType: "application/json", body: `{"format":"pdf","content":"x","inputFormat":"rst"}`, status: http.StatusBadRequest},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/exports", strings.NewReader(test.body))
			req.Header.Set("X-Tailscale-Login", "alice")
			if test.contentType != "" {
				req.Header.Set("Content-Type", test.contentType)
			}
			rec := httptest.NewRecorder()
			handleExport(rec, req)
			if rec.Code != test.status {
				t.Fatalf("status = %d, want %d", rec.Code, test.status)
			}
		})
	}
}

func TestHandleExportRejectsAttachmentSymlink(t *testing.T) {
	tmpDir := t.TempDir()
	oldStoragePath := fileStoragePath
	fileStoragePath = tmpDir
	defer func() { fileStoragePath = oldStoragePath }()

	fileID := "att_0123456789abcdef0123456789abcdef"
	target := filepath.Join(tmpDir, "target")
	if err := os.WriteFile(target, []byte("secret"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(tmpDir, fileID)); err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(ExportRequest{
		Format: "docx",
		Title:  "Test",
		Attachments: []ExportAttachment{{
			FileID:   fileID,
			Filename: "image.png",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/exports", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Tailscale-Login", "alice")
	rec := httptest.NewRecorder()
	handleExport(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadRequest)
	}
}
