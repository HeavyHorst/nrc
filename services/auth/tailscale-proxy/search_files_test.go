package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

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
