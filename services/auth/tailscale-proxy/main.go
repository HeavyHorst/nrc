// tailscale-proxy - Reverse proxy that injects Tailscale user identity
package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"mime"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	xhtml "golang.org/x/net/html"
	tsclient "tailscale.com/client/tailscale"
	"tailscale.com/client/tailscale/apitype"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
)

// User cache to track connected users
var (
	usersMu sync.RWMutex
	users   = make(map[string]bool) // map of login names
)

var (
	jwtSecret   []byte
	jwtIssuer   = "nrc-tailscale-proxy"
	jwtAudience = "nrc"
	jwtTTL      = 5 * time.Minute
)

type customerUsers map[string]struct{}

func parseCustomerUsers(value string) customerUsers {
	users := make(customerUsers)
	for _, entry := range strings.Split(value, ",") {
		login := strings.TrimSpace(entry)
		if login != "" && login != "*" {
			users[login] = struct{}{}
		}
	}
	return users
}

type proxyJWTHeader struct {
	Alg string `json:"alg"`
	Typ string `json:"typ"`
}

type proxyJWTClaims struct {
	Sub       string `json:"sub"`
	Username  string `json:"username"`
	Workspace string `json:"workspace,omitempty"`
	Iss       string `json:"iss"`
	Aud       string `json:"aud"`
	Exp       int64  `json:"exp"`
	Nbf       int64  `json:"nbf"`
}

func buildNRCAuthToken(username, subject, workspace string, now time.Time) (string, error) {
	return buildProxyAuthToken(username, subject, workspace, jwtAudience, now)
}

func buildProxyAuthToken(username, subject, workspace, audience string, now time.Time) (string, error) {
	headerJSON, err := json.Marshal(proxyJWTHeader{Alg: "HS256", Typ: "JWT"})
	if err != nil {
		return "", fmt.Errorf("marshal jwt header: %w", err)
	}

	claims := proxyJWTClaims{
		Sub:       subject,
		Username:  username,
		Workspace: workspace,
		Iss:       jwtIssuer,
		Aud:       audience,
		Nbf:       now.Unix() - 2,
		Exp:       now.Add(jwtTTL).Unix(),
	}

	claimsJSON, err := json.Marshal(claims)
	if err != nil {
		return "", fmt.Errorf("marshal jwt claims: %w", err)
	}

	headerSegment := base64.RawURLEncoding.EncodeToString(headerJSON)
	payloadSegment := base64.RawURLEncoding.EncodeToString(claimsJSON)
	signingInput := headerSegment + "." + payloadSegment

	mac := hmac.New(sha256.New, jwtSecret)
	if _, err := mac.Write([]byte(signingInput)); err != nil {
		return "", fmt.Errorf("sign jwt: %w", err)
	}

	signatureSegment := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return signingInput + "." + signatureSegment, nil
}

// File storage configuration
var (
	fileStoragePath = "/data/files"            // Base directory for file storage
	maxFileSize     = int64(100 * 1024 * 1024) // 100 MB
	maxFilesPerTask = 10
	fileStorageLock *os.File
)

func acquireFileStorageProcessLock() error {
	lock, err := os.Open(fileStoragePath)
	if err != nil {
		return fmt.Errorf("open attachment storage lock: %w", err)
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_SH|syscall.LOCK_NB); err != nil {
		lock.Close()
		return fmt.Errorf("lock attachment storage: %w", err)
	}
	fileStorageLock = lock
	return nil
}

const (
	maxExportRequestSize = int64(1024 * 1024)
	maxExportImageBytes  = int64(50 * 1024 * 1024)
	exportTimeout        = 30 * time.Second
	exporterUID          = uint32(10001)
	exporterGID          = uint32(10001)
)

var (
	exportSlots          = make(chan struct{}, 2)
	exportFileIDPattern  = regexp.MustCompile(`^att_[0-9a-f]{32}$`)
	markdownAttRef       = regexp.MustCompile(`(!?\[[^\]]*\]\()att:(\d+)(\))`)
	htmlAttRef           = regexp.MustCompile(`(?i)(src|href)(\s*=\s*)(["'])att:(\d+)(["'])`)
	convertExportRequest = runPandocExport
)

// FileMetadata represents attachment metadata
type FileMetadata struct {
	FileID     string `json:"fileId"`
	Filename   string `json:"filename"`
	Size       int64  `json:"size"`
	MimeType   string `json:"mimeType"`
	UploadedAt int64  `json:"uploadedAt"`
}

// UploadResponse is the response from the upload endpoint
type UploadResponse struct {
	FileID     string `json:"fileId"`
	URL        string `json:"url"`
	Filename   string `json:"filename"`
	Size       int64  `json:"size"`
	MimeType   string `json:"mimeType"`
	UploadedAt int64  `json:"uploadedAt"`
}

type ExportAttachment struct {
	FileID   string `json:"fileId"`
	Filename string `json:"filename"`
	MimeType string `json:"mimeType"`
}

type ExportRequest struct {
	Format      string             `json:"format"`
	Title       string             `json:"title"`
	Author      string             `json:"author"`
	Date        string             `json:"date"`
	Markdown    string             `json:"markdown"`
	Content     string             `json:"content"`
	InputFormat string             `json:"inputFormat"`
	Attachments []ExportAttachment `json:"attachments"`
}

func main() {
	if len(os.Args) > 1 {
		if len(os.Args) != 3 || os.Args[1] != "--assign-legacy-files" {
			log.Fatal("usage: tailscale-proxy [--assign-legacy-files WORKSPACE]")
		}
		count, err := assignLegacyFiles(os.Args[2])
		if err != nil {
			log.Fatal(err)
		}
		log.Printf("assigned %d previously unscoped files", count)
		return
	}
	policy, err := parseWorkspacePolicy(os.Getenv("NRC_WORKSPACE_ACCESS"))
	if err != nil {
		log.Fatal(err)
	}
	jwtSecretValue := os.Getenv("NRC_JWT_SECRET")
	if policy != nil && (jwtSecretValue == "" || jwtSecretValue == "dev-insecure-nrc-jwt-secret") {
		log.Fatal("NRC_WORKSPACE_ACCESS requires a non-default NRC_JWT_SECRET")
	}
	if jwtSecretValue == "" {
		jwtSecretValue = "dev-insecure-nrc-jwt-secret"
		log.Printf("WARNING: NRC_JWT_SECRET not set, using insecure default")
	}
	jwtSecret = []byte(jwtSecretValue)

	if issuer := os.Getenv("NRC_JWT_ISSUER"); issuer != "" {
		jwtIssuer = issuer
	}
	if audience := os.Getenv("NRC_JWT_AUDIENCE"); audience != "" {
		jwtAudience = audience
	}

	// Initialize file storage directory
	if err := os.MkdirAll(fileStoragePath, 0755); err != nil {
		log.Fatalf("failed to create file storage directory: %v", err)
	}
	if err := acquireFileStorageProcessLock(); err != nil {
		log.Fatalf("failed to lock file storage (attachment GC may be running): %v", err)
	}
	defer fileStorageLock.Close()

	if addr := os.Getenv("NRC_SEARCH_FILES_ADDR"); addr != "" {
		secret := os.Getenv("NRC_BOT_SECRET")
		if secret == "" {
			log.Fatal("NRC_SEARCH_FILES_ADDR requires NRC_BOT_SECRET")
		}
		listener, err := net.Listen("tcp", addr)
		if err != nil {
			log.Fatalf("private search file listener: %v", err)
		}
		server := &http.Server{Handler: searchFilesHandler(secret), ReadHeaderTimeout: 5 * time.Second, WriteTimeout: 60 * time.Second}
		defer server.Close()
		go func() {
			if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
				log.Fatalf("private search file server: %v", err)
			}
		}()
	}

	// Initialize Tailscale tsnet server
	ts := &tsnet.Server{
		Hostname: "nrc",
		Dir:      "/var/lib/tailscale",
		Port:     41642,
	}

	if err := ts.Start(); err != nil {
		log.Fatalf("failed to start tsnet server: %v", err)
	}

	localClient, err := ts.LocalClient()
	if err != nil {
		log.Fatalf("failed to get local client: %v", err)
	}

	// Create reverse proxy to nginx backend
	nginxURL, err := url.Parse("http://nginx:80")
	if err != nil {
		log.Fatalf("invalid backend URL: %v", err)
	}

	proxy := httputil.NewSingleHostReverseProxy(nginxURL)

	// Enable WebSocket support by flushing responses immediately
	proxy.FlushInterval = -1 // Flush immediately for streaming/WebSocket

	// Handle both HTTPS and HTTP
	handleHTTPS(ts, proxy, localClient, policy)
}

func handleGetUsers(w http.ResponseWriter, r *http.Request, localClient tailscaleClient) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	usersMu.RLock()
	knownUsers := make(map[string]bool, len(users))
	for login := range users {
		knownUsers[login] = true
	}
	usersMu.RUnlock()

	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	status, err := localClient.Status(ctx)
	if err != nil {
		log.Printf("user directory status lookup failed: %v", err)
	} else if status != nil {
		for _, profile := range status.User {
			login, _, _ := strings.Cut(profile.LoginName, "@")
			if login != "" {
				knownUsers[login] = true
			}
		}
	}
	userList := make([]string, 0, len(knownUsers))
	for login := range knownUsers {
		userList = append(userList, login)
	}
	slices.Sort(userList)

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	json.NewEncoder(w).Encode(userList)
}

// generateFileID creates a unique file ID from file hash
func generateFileID(data []byte) string {
	hash := sha256.Sum256(data)
	// Use first 20 bytes of SHA256 as file ID (40 hex chars, but truncate to 26 for ULID-like format)
	return "att_" + hex.EncodeToString(hash[:16])
}

// handleUpload handles file upload from clients
func handleUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Verify Tailscale auth
	login := r.Header.Get("X-Tailscale-Login")
	if login == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	workspace := r.URL.Query().Get("workspace")
	// Parse multipart form
	if err := r.ParseMultipartForm(maxFileSize); err != nil {
		http.Error(w, fmt.Sprintf("failed to parse form: %v", err), http.StatusBadRequest)
		return
	}

	// Get file from form
	file, handler, err := r.FormFile("file")
	if err != nil {
		http.Error(w, fmt.Sprintf("failed to get file: %v", err), http.StatusBadRequest)
		return
	}
	defer file.Close()

	// Check file size
	if handler.Size > maxFileSize {
		http.Error(w, fmt.Sprintf("file too large: %d > %d", handler.Size, maxFileSize), http.StatusRequestEntityTooLarge)
		return
	}

	// Read file data
	fileData := make([]byte, handler.Size)
	n, err := io.ReadFull(file, fileData)
	if err != nil && err != io.EOF {
		http.Error(w, fmt.Sprintf("failed to read file: %v", err), http.StatusInternalServerError)
		return
	}
	if int64(n) != handler.Size {
		http.Error(w, "incomplete file upload", http.StatusBadRequest)
		return
	}

	// Generate file ID
	fileID := generateFileID(fileData)

	// Detect MIME type
	mimeType := handler.Header.Get("Content-Type")
	if mimeType == "" {
		mimeType = mime.TypeByExtension(filepath.Ext(handler.Filename))
		if mimeType == "" {
			mimeType = "application/octet-stream"
		}
	}

	// Sanitize filename
	filename := filepath.Base(handler.Filename)
	if filename == "" || filename == "." {
		filename = fileID
	}

	// Ensure storage directory exists
	if err := os.MkdirAll(fileStoragePath, 0755); err != nil {
		http.Error(w, fmt.Sprintf("failed to create directory: %v", err), http.StatusInternalServerError)
		return
	}

	// Store file in shared storage (content-addressed)
	filePath := filepath.Join(fileStoragePath, fileID)
	if err := os.WriteFile(filePath, fileData, 0644); err != nil {
		http.Error(w, fmt.Sprintf("failed to store file: %v", err), http.StatusInternalServerError)
		return
	}
	if err := recordFileWorkspace(fileID, workspace); err != nil {
		http.Error(w, "failed to store file workspace", http.StatusInternalServerError)
		return
	}

	// Log upload
	log.Printf("file uploaded: user=%s fileId=%s filename=%s size=%d mimeType=%s", login, fileID, filename, handler.Size, mimeType)

	// Return response
	now := time.Now().UnixNano()
	resp := UploadResponse{
		FileID:     fileID,
		URL:        fmt.Sprintf("/files/%s", fileID),
		Filename:   filename,
		Size:       handler.Size,
		MimeType:   mimeType,
		UploadedAt: now,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

// handleDownload handles file download requests
func handleDownload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Verify Tailscale auth
	login := r.Header.Get("X-Tailscale-Login")
	if login == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	// Extract file ID from path
	fileID := strings.TrimPrefix(r.URL.Path, "/files/")
	if fileID == "" || fileID == r.URL.Path {
		http.Error(w, "invalid file ID", http.StatusBadRequest)
		return
	}

	if !strings.HasPrefix(fileID, "att_") || strings.ContainsAny(fileID, `/\`) || !requestWorkspaceAccess(r).allowsFile(fileID) {
		http.Error(w, "file access denied", http.StatusForbidden)
		return
	}
	// Blobs are shared; workspace grants are checked independently of their ID.
	filePath := filepath.Join(fileStoragePath, fileID)

	// Prevent directory traversal
	if !strings.HasPrefix(filePath, fileStoragePath) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}

	// Check if file exists
	info, err := os.Stat(filePath)
	if err != nil {
		if os.IsNotExist(err) {
			http.Error(w, "file not found", http.StatusNotFound)
			return
		}
		http.Error(w, fmt.Sprintf("failed to stat file: %v", err), http.StatusInternalServerError)
		return
	}

	// Set response headers
	downloadFilename := downloadFilenameFromRequest(r, fileID)
	contentType := downloadContentType(downloadFilename)
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	// Uploaded documents must never gain the application's origin or execute scripts,
	// even when an untrusted filename or chat MIME label requests a preview.
	w.Header().Set("Content-Security-Policy", "sandbox")

	// Check for inline query parameter
	previewable := strings.HasPrefix(contentType, "image/") || strings.HasPrefix(contentType, "audio/") || strings.HasPrefix(contentType, "video/") || contentType == "application/pdf"
	if r.URL.Query().Get("inline") == "true" && previewable {
		w.Header().Set("Content-Disposition", contentDisposition("inline", downloadFilename))
	} else {
		w.Header().Set("Content-Disposition", contentDisposition("attachment", downloadFilename))
	}

	file, err := os.Open(filePath)
	if err != nil {
		http.Error(w, "failed to open file", http.StatusInternalServerError)
		return
	}
	defer file.Close()
	// Support byte ranges for native media seeking and PDF readers, plus HEAD.
	http.ServeContent(w, r, downloadFilename, info.ModTime(), file)

	log.Printf("file downloaded: user=%s fileId=%s size=%d", login, fileID, info.Size())
}

func handleExport(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if r.Header.Get("X-Tailscale-Login") == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		http.Error(w, "content type must be application/json", http.StatusUnsupportedMediaType)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxExportRequestSize)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	var request ExportRequest
	if err := decoder.Decode(&request); err != nil {
		http.Error(w, "invalid export request", http.StatusBadRequest)
		return
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		http.Error(w, "invalid export request", http.StatusBadRequest)
		return
	}
	if request.Format != "pdf" && request.Format != "docx" {
		http.Error(w, "unsupported export format", http.StatusBadRequest)
		return
	}
	if request.InputFormat == "" {
		request.InputFormat = "markdown"
	}
	if request.InputFormat != "markdown" && request.InputFormat != "html" {
		http.Error(w, "unsupported input format", http.StatusBadRequest)
		return
	}
	request.Title = strings.TrimSpace(request.Title)
	if request.Title == "" {
		request.Title = "NRC Note"
	}
	if len(request.exportContent()) > 65536 {
		http.Error(w, "note is too large", http.StatusRequestEntityTooLarge)
		return
	}
	if len(request.Attachments) > maxFilesPerTask {
		http.Error(w, "too many attachments", http.StatusBadRequest)
		return
	}
	imageIndices := referencedExportImageIndices(request.exportContent(), request.InputFormat)
	totalImageBytes := int64(0)
	for index, attachment := range request.Attachments {
		if !exportFileIDPattern.MatchString(attachment.FileID) {
			http.Error(w, "invalid attachment ID", http.StatusBadRequest)
			return
		}
		if !requestWorkspaceAccess(r).allowsFile(attachment.FileID) {
			http.Error(w, "file access denied", http.StatusForbidden)
			return
		}
		path := filepath.Join(fileStoragePath, attachment.FileID)
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() {
			http.Error(w, "attachment not found", http.StatusBadRequest)
			return
		}
		if imageIndices[index] {
			if !isSupportedExportImage(path) {
				http.Error(w, "unsupported image attachment", http.StatusBadRequest)
				return
			}
			totalImageBytes += info.Size()
			if totalImageBytes > maxExportImageBytes {
				http.Error(w, "export images are too large", http.StatusRequestEntityTooLarge)
				return
			}
		}
	}

	workDir, err := os.MkdirTemp("", "nrc-export-*")
	if err != nil {
		http.Error(w, "failed to prepare export", http.StatusInternalServerError)
		return
	}
	defer os.RemoveAll(workDir)
	if os.Geteuid() == 0 {
		if err := os.Chown(workDir, int(exporterUID), int(exporterGID)); err != nil {
			http.Error(w, "failed to prepare export", http.StatusInternalServerError)
			return
		}
	}

	outputPath := filepath.Join(workDir, "output."+request.Format)
	ctx, cancel := context.WithTimeout(r.Context(), exportTimeout)
	defer cancel()
	select {
	case exportSlots <- struct{}{}:
	default:
		http.Error(w, "document exporter busy", http.StatusTooManyRequests)
		return
	}
	if err := convertExportRequest(ctx, request, workDir, outputPath); err != nil {
		<-exportSlots
		log.Printf("document export failed: user=%s format=%s error=%v", r.Header.Get("X-Tailscale-Login"), request.Format, err)
		if ctx.Err() != nil {
			http.Error(w, "document export timed out", http.StatusGatewayTimeout)
		} else {
			http.Error(w, "document export failed", http.StatusInternalServerError)
		}
		return
	}
	<-exportSlots

	output, err := os.Open(outputPath)
	if err != nil {
		http.Error(w, "document export failed", http.StatusInternalServerError)
		return
	}
	defer output.Close()
	info, err := output.Stat()
	if err != nil {
		http.Error(w, "document export failed", http.StatusInternalServerError)
		return
	}

	filename := exportFilename(request.Title, request.Format)
	if request.Format == "pdf" {
		w.Header().Set("Content-Type", "application/pdf")
		w.Header().Set("Content-Disposition", contentDisposition("inline", filename))
	} else {
		w.Header().Set("Content-Type", "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
		w.Header().Set("Content-Disposition", contentDisposition("attachment", filename))
	}
	w.Header().Set("Content-Length", strconv.FormatInt(info.Size(), 10))
	if _, err := io.Copy(w, output); err != nil {
		log.Printf("document export response failed: user=%s format=%s error=%v", r.Header.Get("X-Tailscale-Login"), request.Format, err)
	}
}

func exportFilename(title, format string) string {
	title = strings.Map(func(ch rune) rune {
		if ch < 0x20 || strings.ContainsRune(`/\\:*?"<>|`, ch) {
			return '-'
		}
		return ch
	}, strings.TrimSpace(title))
	title = strings.Trim(title, " .-")
	if title == "" {
		title = "nrc-note"
	}
	runes := []rune(title)
	if len(runes) > 120 {
		title = string(runes[:120])
	}
	return title + "." + format
}

func (request ExportRequest) exportContent() string {
	if request.Content != "" {
		return request.Content
	}
	return request.Markdown
}

func runPandocExport(ctx context.Context, request ExportRequest, workDir, outputPath string) error {
	content := request.exportContent()
	allowedImages := make([]string, 0, len(request.Attachments))
	attachmentPaths := make([]string, len(request.Attachments))
	imageIndices := referencedExportImageIndices(content, request.InputFormat)
	for i, attachment := range request.Attachments {
		extension := strings.ToLower(filepath.Ext(filepath.Base(attachment.Filename)))
		if len(extension) > 16 || !regexp.MustCompile(`^\.[a-z0-9]+$`).MatchString(extension) {
			extension = ""
		}
		if imageIndices[i] {
			extension = exportImageExtension(filepath.Join(fileStoragePath, attachment.FileID))
		}
		name := fmt.Sprintf("attachment-%d%s", i, extension)
		attachmentPaths[i] = name
		if !imageIndices[i] {
			continue
		}
		source, err := os.Open(filepath.Join(fileStoragePath, attachment.FileID))
		if err != nil {
			return fmt.Errorf("open attachment %d: %w", i, err)
		}
		destination, err := os.OpenFile(filepath.Join(workDir, name), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			source.Close()
			return fmt.Errorf("create attachment %d: %w", i, err)
		}
		_, copyErr := io.Copy(destination, source)
		closeErr := destination.Close()
		source.Close()
		if copyErr != nil {
			return fmt.Errorf("copy attachment %d: %w", i, copyErr)
		}
		if closeErr != nil {
			return fmt.Errorf("close attachment %d: %w", i, closeErr)
		}
		if err := chownExportFile(filepath.Join(workDir, name)); err != nil {
			return fmt.Errorf("set attachment %d ownership: %w", i, err)
		}
		allowedImages = append(allowedImages, name)
	}

	content = rewriteAttachmentReferences(content, attachmentPaths, request.InputFormat)
	inputPath := filepath.Join(workDir, "input."+request.InputFormat)
	if err := os.WriteFile(inputPath, []byte(content), 0600); err != nil {
		return fmt.Errorf("write input: %w", err)
	}
	if err := chownExportFile(inputPath); err != nil {
		return fmt.Errorf("set input ownership: %w", err)
	}
	filterPath := filepath.Join(workDir, "export-filter.lua")
	if err := os.WriteFile(filterPath, []byte(exportLuaFilter(allowedImages)), 0600); err != nil {
		return fmt.Errorf("write pandoc filter: %w", err)
	}
	if err := chownExportFile(filterPath); err != nil {
		return fmt.Errorf("set pandoc filter ownership: %w", err)
	}

	args := pandocExportArgs(request, workDir, inputPath, outputPath, filterPath)

	cmd := exec.CommandContext(ctx, "pandoc", args...)
	cmd.Dir = workDir
	cmd.Env = []string{
		"HOME=" + workDir,
		"LANG=C.UTF-8",
		"PATH=/usr/local/bin:/usr/bin:/bin",
		"XDG_CACHE_HOME=" + filepath.Join(workDir, ".cache"),
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if os.Geteuid() == 0 {
		cmd.SysProcAttr.Credential = &syscall.Credential{
			Uid:         exporterUID,
			Gid:         exporterGID,
			NoSetGroups: true,
		}
	}
	cmd.Cancel = func() error {
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	cmd.WaitDelay = 2 * time.Second
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		message := strings.TrimSpace(stderr.String())
		if len(message) > 2048 {
			message = message[:2048]
		}
		return fmt.Errorf("pandoc: %w: %s", err, message)
	}
	return nil
}

func pandocExportArgs(request ExportRequest, workDir, inputPath, outputPath, filterPath string) []string {
	from := "gfm"
	if request.InputFormat == "html" {
		from = "html"
	}
	args := []string{
		"--from=" + from,
		"--standalone",
		"--lua-filter=" + filterPath,
		"--resource-path=" + workDir,
		"--metadata", "title=" + request.Title,
		"--metadata", "lang=de-DE",
	}
	if request.Author != "" {
		args = append(args, "--metadata", "author="+request.Author)
	}
	if request.Date != "" {
		args = append(args, "--metadata", "date="+request.Date)
	}
	if request.Format == "pdf" {
		args = append(args, "--to=typst", "--pdf-engine=typst")
	}
	return append(args, inputPath, "--output="+outputPath)
}

func referencedExportImageIndices(content, inputFormat string) map[int]bool {
	indices := make(map[int]bool)
	if inputFormat == "html" {
		document, err := xhtml.Parse(strings.NewReader(content))
		if err != nil {
			return indices
		}
		walkHTMLNodes(document, func(node *xhtml.Node) {
			if node.Type != xhtml.ElementNode || !strings.EqualFold(node.Data, "img") {
				return
			}
			for _, attribute := range node.Attr {
				if strings.EqualFold(attribute.Key, "src") {
					if index, ok := exportAttachmentIndex(attribute.Val); ok {
						indices[index] = true
					}
				}
			}
		})
		return indices
	}
	for _, match := range markdownAttRef.FindAllStringSubmatch(content, -1) {
		if !strings.HasPrefix(match[1], "![") {
			continue
		}
		if index, err := strconv.Atoi(match[2]); err == nil {
			indices[index] = true
		}
	}
	return indices
}

func isSupportedExportImage(path string) bool {
	return exportImageExtension(path) != ""
}

func exportImageExtension(path string) string {
	file, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer file.Close()
	buffer := make([]byte, 512)
	n, err := file.Read(buffer)
	if err != nil && err != io.EOF {
		return ""
	}
	switch http.DetectContentType(buffer[:n]) {
	case "image/jpeg":
		return ".jpg"
	case "image/png":
		return ".png"
	case "image/gif":
		return ".gif"
	case "image/webp":
		return ".webp"
	default:
		return ""
	}
}

func chownExportFile(path string) error {
	if os.Geteuid() != 0 {
		return nil
	}
	return os.Chown(path, int(exporterUID), int(exporterGID))
}

func rewriteAttachmentReferences(content string, attachmentPaths []string, inputFormat string) string {
	if inputFormat == "html" {
		document, err := xhtml.Parse(strings.NewReader(content))
		if err != nil {
			return content
		}
		walkHTMLNodes(document, func(node *xhtml.Node) {
			if node.Type != xhtml.ElementNode {
				return
			}
			for i := range node.Attr {
				attribute := &node.Attr[i]
				if !strings.EqualFold(attribute.Key, "src") && !strings.EqualFold(attribute.Key, "href") {
					continue
				}
				index, ok := exportAttachmentIndex(attribute.Val)
				if ok && index < len(attachmentPaths) {
					attribute.Val = attachmentPaths[index]
				}
			}
		})
		var rendered bytes.Buffer
		if err := xhtml.Render(&rendered, document); err != nil {
			return content
		}
		return rendered.String()
	}

	markdown := content
	markdown = markdownAttRef.ReplaceAllStringFunc(markdown, func(match string) string {
		parts := markdownAttRef.FindStringSubmatch(match)
		index, err := strconv.Atoi(parts[2])
		if err != nil || index < 0 || index >= len(attachmentPaths) {
			return match
		}
		return parts[1] + attachmentPaths[index] + parts[3]
	})
	return htmlAttRef.ReplaceAllStringFunc(markdown, func(match string) string {
		parts := htmlAttRef.FindStringSubmatch(match)
		index, err := strconv.Atoi(parts[4])
		if err != nil || index < 0 || index >= len(attachmentPaths) {
			return match
		}
		return parts[1] + parts[2] + parts[3] + attachmentPaths[index] + parts[5]
	})
}

func exportAttachmentIndex(value string) (int, bool) {
	value = strings.TrimSpace(value)
	if len(value) < 5 || !strings.EqualFold(value[:4], "att:") {
		return 0, false
	}
	index, err := strconv.Atoi(value[4:])
	return index, err == nil && index >= 0
}

func walkHTMLNodes(node *xhtml.Node, visit func(*xhtml.Node)) {
	if node == nil {
		return
	}
	visit(node)
	for child := node.FirstChild; child != nil; child = child.NextSibling {
		walkHTMLNodes(child, visit)
	}
}

func exportLuaFilter(allowedImages []string) string {
	var filter strings.Builder
	filter.WriteString("local allowed_images = {\n")
	for _, image := range allowedImages {
		fmt.Fprintf(&filter, "  [%q] = true,\n", image)
	}
	filter.WriteString(`}

function Image(image)
  if allowed_images[image.src] then
    return image
  end
  return pandoc.Link(image.caption, image.src, image.title)
end

function RawBlock(_)
  return {}
end

function RawInline(_)
  return {}
end
`)
	return filter.String()
}

func downloadFilenameFromRequest(r *http.Request, fallback string) string {
	filename := r.URL.Query().Get("filename")
	if filename == "" {
		return fallback
	}

	filename = filepath.Base(filename)
	filename = strings.Map(func(ch rune) rune {
		if ch < 0x20 || ch == 0x7f {
			return -1
		}
		return ch
	}, filename)
	if filename == "" || filename == "." || filename == string(filepath.Separator) {
		return fallback
	}
	return filename
}

func downloadContentType(filename string) string {
	if contentType := mime.TypeByExtension(filepath.Ext(filename)); contentType != "" {
		return contentType
	}
	return "application/octet-stream"
}

func contentDisposition(disposition, filename string) string {
	formatted := mime.FormatMediaType(disposition, map[string]string{"filename": filename})
	if formatted == "" {
		return fmt.Sprintf("%s; filename=%q", disposition, filename)
	}
	return formatted
}

// extractRemoteIP extracts the IP address from request RemoteAddr
func extractRemoteIP(r *http.Request) string {
	remoteIP := strings.TrimSpace(r.RemoteAddr)
	if remoteIP == "" {
		return ""
	}

	host, _, err := net.SplitHostPort(remoteIP)
	if err == nil {
		return host
	}

	return remoteIP
}

func isWebSocketUpgrade(r *http.Request) bool {
	return strings.EqualFold(r.Header.Get("Upgrade"), "websocket")
}

type whoIsClient interface {
	WhoIs(context.Context, string) (*apitype.WhoIsResponse, error)
}

type tailscaleClient interface {
	whoIsClient
	Status(context.Context) (*ipnstate.Status, error)
}

func taggedNodeLogin(node *tailcfg.Node) (string, error) {
	if node == nil || !node.IsTagged() {
		return "", fmt.Errorf("node is not tagged")
	}

	login := ""
	for _, tag := range node.Tags {
		if !strings.HasPrefix(tag, "tag:") || len(tag) == len("tag:") || len(tag) > 32 {
			continue
		}
		if login == "" || tag < login {
			login = tag
		}
	}
	if login == "" {
		return "", fmt.Errorf("tagged node missing valid tag")
	}

	return login, nil
}

func injectIdentityHeaders(r *http.Request, localClient whoIsClient) (string, error) {
	// These headers are assertions by this boundary, never by its callers.
	for _, header := range []string{"X-Tailscale-Login", "X-Tailscale-User", "X-Tailscale-Node", "X-NRC-Auth", "X-NRC-Publish-Auth", "X-NRC-User-Type", "X-NRC-Bot-Secret", "X-NRC-Bot-Nickname", "X-NRC-Denied-Workspaces"} {
		r.Header.Del(header)
	}
	remoteIP := extractRemoteIP(r)
	if remoteIP == "" {
		return "", fmt.Errorf("missing remote ip")
	}

	whois, err := localClient.WhoIs(r.Context(), net.JoinHostPort(remoteIP, "1"))
	if err != nil || whois == nil {
		return "", fmt.Errorf("whois error: %w", err)
	}

	fullLogin := ""
	login := ""
	if whois.Node != nil && whois.Node.IsTagged() {
		login, err = taggedNodeLogin(whois.Node)
		if err != nil {
			return "", err
		}
		fullLogin = login
	} else {
		if whois.UserProfile == nil || whois.UserProfile.LoginName == "" {
			return "", fmt.Errorf("whois missing login")
		}

		fullLogin = whois.UserProfile.LoginName
		login = fullLogin
		if idx := strings.Index(login, "@"); idx != -1 {
			login = login[:idx]
		}
		if login == "" {
			return "", fmt.Errorf("empty login")
		}
	}

	workspace := ""
	if isWebSocketUpgrade(r) {
		workspace = strings.TrimPrefix(r.URL.RequestURI(), "/")
	}
	token, tokenErr := buildNRCAuthToken(login, fullLogin, workspace, time.Now())
	if tokenErr != nil {
		return "", fmt.Errorf("failed to build X-NRC-Auth token: %w", tokenErr)
	}

	r.Header.Set("X-Tailscale-Login", login)
	r.Header.Set("X-Tailscale-User", fullLogin)
	if whois.Node != nil {
		r.Header.Set("X-Tailscale-Node", whois.Node.Name)
	} else {
		r.Header.Del("X-Tailscale-Node")
	}
	r.Header.Set("X-NRC-Auth", token)

	usersMu.Lock()
	users[login] = true
	usersMu.Unlock()

	return login, nil
}

func handleFeatures(allowed customerUsers, localClient whoIsClient) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		remoteIP := extractRemoteIP(r)
		if remoteIP == "" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		whois, err := localClient.WhoIs(r.Context(), net.JoinHostPort(remoteIP, "1"))
		if err != nil || whois == nil || whois.Node == nil || whois.Node.IsTagged() ||
			whois.UserProfile == nil || whois.UserProfile.LoginName == "" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		_, customers := allowed[whois.UserProfile.LoginName]
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(struct {
			Customers bool `json:"customers"`
		}{Customers: customers})
	}
}

func proxyHandler(proxy http.Handler, localClient tailscaleClient, policy workspacePolicy) http.Handler {
	// Create a handler that routes between API and proxy
	mux := http.NewServeMux()
	mux.HandleFunc("/api/users", func(w http.ResponseWriter, r *http.Request) {
		handleGetUsers(w, r, localClient)
	})
	mux.HandleFunc("/api/features", handleFeatures(parseCustomerUsers(os.Getenv("NRC_CUSTOMERS_USERS")), localClient))
	mux.HandleFunc("/upload", handleUpload)
	mux.HandleFunc("/files/", handleDownload)
	mux.HandleFunc("/exports", handleExport)
	mux.Handle("/publish/api/", publishGateway(os.Getenv("NRC_PUBLISH_BACKEND"), os.Getenv("NRC_PUBLISH_WORKSPACE")))
	mux.Handle("/", proxy)
	return workspaceBoundary(mux, localClient, policy)
}

func handleHTTPS(ts *tsnet.Server, proxy *httputil.ReverseProxy, localClient *tsclient.LocalClient, policy workspacePolicy) {
	// Listen on HTTPS with Tailscale TLS
	lnHTTPS, err := ts.ListenTLS("tcp", ":443")
	if err != nil {
		log.Fatalf("failed to listen on :443: %v", err)
	}

	// Also listen on HTTP for redirects
	go func() {
		lnHTTP, err := ts.Listen("tcp", ":80")
		if err != nil {
			log.Fatalf("failed to listen on :80: %v", err)
		}

		log.Fatal(http.Serve(lnHTTP, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Redirect HTTP to HTTPS
			url := "https://" + r.Host + r.RequestURI
			http.Redirect(w, r, url, http.StatusMovedPermanently)
		})))
	}()

	log.Printf("tailscale-proxy listening on %v", lnHTTPS.Addr())
	log.Fatal(http.Serve(lnHTTPS, proxyHandler(proxy, localClient, policy)))
}
