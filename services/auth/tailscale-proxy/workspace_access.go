package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
)

// Only explicitly configured workspaces are restricted. All other workspaces
// remain tailnet-open. This policy is immutable until the proxy is restarted.
type workspacePolicy map[string]workspaceMembers

type workspaceMembers struct {
	Owner   string   `json:"owner"`
	Members []string `json:"members"`
}

var workspaceNamePattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

func parseWorkspacePolicy(value string) (workspacePolicy, error) {
	if value == "" {
		return nil, nil
	}
	var policy workspacePolicy
	decoder := json.NewDecoder(strings.NewReader(value))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&policy); err != nil {
		return nil, fmt.Errorf("invalid NRC_WORKSPACE_ACCESS: %w", err)
	}
	if policy == nil {
		return nil, fmt.Errorf("NRC_WORKSPACE_ACCESS must be an object, not null")
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return nil, fmt.Errorf("NRC_WORKSPACE_ACCESS must contain exactly one JSON object")
	}
	if len(policy) == 0 {
		return nil, nil
	}
	validIdentity := func(identity string) bool {
		return identity != "" && identity == strings.TrimSpace(identity) &&
			!strings.ContainsAny(identity, "*\r\n\t ") &&
			(strings.Contains(identity, "@") || (strings.HasPrefix(identity, "tag:") && len(identity) > 4))
	}
	for workspace, entry := range policy {
		if !workspaceNamePattern.MatchString(workspace) || !validIdentity(entry.Owner) {
			return nil, fmt.Errorf("invalid workspace name or owner in NRC_WORKSPACE_ACCESS")
		}
		for _, member := range entry.Members {
			if !validIdentity(member) {
				return nil, fmt.Errorf("members must be full Tailscale logins or tags")
			}
		}
	}
	return policy, nil
}

func (p workspacePolicy) allows(workspace, identity string) bool {
	entry, ok := p[workspace]
	if workspace == "" || identity == "" {
		return false
	}
	if !ok {
		return true
	}
	if entry.Owner == identity {
		return true
	}
	for _, member := range entry.Members {
		if member == identity {
			return true
		}
	}
	return false
}

type workspaceAccessKey struct{}

type workspaceAccess struct {
	policy   workspacePolicy
	identity string
}

func requestWorkspaceAccess(r *http.Request) workspaceAccess {
	access, _ := r.Context().Value(workspaceAccessKey{}).(workspaceAccess)
	return access
}

// The proxy is the only public ingress. Internal bots remain trusted services,
// but cannot be used by a caller to access a workspace the caller cannot access.
func workspaceBoundary(next http.Handler, whois whoIsClient, policy workspacePolicy) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// WhoIs authenticates the machine, including a browser on that machine.
		// A hostile website must not borrow that identity. Native CLI clients
		// send no Origin; browser requests must originate at this public origin.
		if origins := r.Header.Values("Origin"); len(origins) > 0 {
			scheme := "http"
			if r.TLS != nil {
				scheme = "https"
			}
			if len(origins) != 1 || origins[0] != scheme+"://"+r.Host {
				http.Error(w, "cross-origin request denied", http.StatusForbidden)
				return
			}
		}
		_, err := injectIdentityHeaders(r, whois)
		if err != nil {
			// Static public assets retain their old behavior in open mode. No
			// caller-provided identity or service credentials survive a failure.
			if policy != nil || isWebSocketUpgrade(r) || r.URL.Path == "/upload" ||
				r.URL.Path == "/exports" || strings.HasPrefix(r.URL.Path, "/files/") {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
		}
		access := workspaceAccess{policy: policy, identity: r.Header.Get("X-Tailscale-User")}
		r = r.WithContext(context.WithValue(r.Context(), workspaceAccessKey{}, access))
		if policy != nil {
			w.Header().Set("Cache-Control", "no-store")
			// Do not let nginx/ServeMux normalization change the authorized route.
			if r.URL.RawPath != "" || strings.Contains(r.URL.Path, "//") ||
				strings.Contains(r.URL.Path, "/./") || strings.Contains(r.URL.Path, "/../") {
				http.Error(w, "invalid path", http.StatusBadRequest)
				return
			}
			workspace := ""
			needsWorkspace := false
			switch {
			// Match HTTP routes before Upgrade: callers can put that header on
			// ordinary POSTs, and the search/upload handlers would still run.
			case r.Method == http.MethodGet && r.URL.Path == "/search/health" && !isWebSocketUpgrade(r):
				// The frontend availability probe has no workspace scope.
				// Identity and same-origin checks above still apply.
			case r.URL.Path == "/upload":
				workspace = r.URL.Query().Get("workspace")
				needsWorkspace = true
			case r.URL.Path == "/search" || strings.HasPrefix(r.URL.Path, "/search/") || strings.HasPrefix(r.URL.Path, "/ai/"):
				if r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/ai/ask/session/") {
					// The AI service knows which workspace owns a session. It
					// checks this trusted header against the stored session.
					denied := []string{}
					for name := range policy {
						if !policy.allows(name, access.identity) {
							denied = append(denied, name)
						}
					}
					sort.Strings(denied)
					encoded, _ := json.Marshal(denied)
					r.Header.Set("X-NRC-Denied-Workspaces", string(encoded))
					break
				}
				if r.Method != http.MethodPost {
					http.Error(w, "forbidden", http.StatusForbidden)
					return
				}
				body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 2*1024*1024))
				if err != nil {
					http.Error(w, "invalid request body", http.StatusBadRequest)
					return
				}
				var scope struct {
					Workspace string `json:"workspace"`
				}
				if json.Unmarshal(body, &scope) != nil {
					http.Error(w, "invalid request body", http.StatusBadRequest)
					return
				}
				r.Body = io.NopCloser(bytes.NewReader(body))
				workspace, needsWorkspace = scope.Workspace, true
			case isWebSocketUpgrade(r):
				workspace = strings.TrimPrefix(r.URL.Path, "/")
				needsWorkspace = true
				if r.URL.RawQuery != "" || !workspaceNamePattern.MatchString(workspace) {
					http.Error(w, "invalid workspace path", http.StatusBadRequest)
					return
				}
			}
			if needsWorkspace && !workspaceNamePattern.MatchString(workspace) {
				http.Error(w, "invalid workspace", http.StatusBadRequest)
				return
			}
			if needsWorkspace && !policy.allows(workspace, access.identity) {
				http.Error(w, "workspace access denied", http.StatusForbidden)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

// Keep content-addressed blobs and GC unchanged. A marker grants one workspace
// access to bytes uploaded there, even if another workspace uploaded them too.
// Old blobs without markers are denied when membership enforcement is enabled.
func fileWorkspaceMarker(fileID, workspace string) string {
	hash := sha256.Sum256([]byte(workspace))
	return filepath.Join(fileStoragePath, ".workspace-access", fileID, hex.EncodeToString(hash[:]))
}

func recordFileWorkspace(fileID, workspace string) error {
	if workspace == "" {
		return nil // Legacy clients in open mode have no workspace information.
	}
	path := fileWorkspaceMarker(fileID, workspace)
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(workspace), 0600)
}

// Explicit offline migration for installations whose old blobs all belong to
// one workspace. Never run implicitly: a guessed legacy scope could leak data.
func assignLegacyFiles(workspace string) (int, error) {
	if !workspaceNamePattern.MatchString(workspace) {
		return 0, fmt.Errorf("invalid workspace")
	}
	lock, err := os.Open(fileStoragePath)
	if err != nil {
		return 0, err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return 0, fmt.Errorf("stop the proxy and attachment GC before assigning legacy files: %w", err)
	}
	entries, err := os.ReadDir(fileStoragePath)
	if err != nil {
		return 0, err
	}
	count := 0
	for _, entry := range entries {
		if !entry.Type().IsRegular() || !exportFileIDPattern.MatchString(entry.Name()) {
			continue
		}
		_, err := os.Stat(filepath.Dir(fileWorkspaceMarker(entry.Name(), workspace)))
		if err == nil {
			continue // Never reclassify already-scoped files, including private ones.
		}
		if !os.IsNotExist(err) {
			return count, err
		}
		if err := recordFileWorkspace(entry.Name(), workspace); err != nil {
			return count, err
		}
		count++
	}
	return count, nil
}

func (a workspaceAccess) allowsFile(fileID string) bool {
	if len(a.policy) == 0 {
		return true
	}
	if !exportFileIDPattern.MatchString(fileID) {
		return false
	}
	entries, err := os.ReadDir(filepath.Join(fileStoragePath, ".workspace-access", fileID))
	if err != nil {
		return false
	}
	for _, entry := range entries {
		if !entry.Type().IsRegular() {
			continue
		}
		workspace, err := os.ReadFile(filepath.Join(fileStoragePath, ".workspace-access", fileID, entry.Name()))
		if err == nil && filepath.Base(fileWorkspaceMarker(fileID, string(workspace))) == entry.Name() && a.policy.allows(string(workspace), a.identity) {
			return true
		}
	}
	return false
}
