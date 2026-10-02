package upload

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/heavyhorst/nrc/protocol-go"
)

const (
	MaxFileSize       = 100 * 1024 * 1024 // 100 MB
	MaxAttachmentsCmd = 10
	RequestTimeout    = 30 * time.Second
)

// UploadResponse is the server response for a successful upload
type UploadResponse struct {
	FileId     string `json:"fileId"`
	Filename   string `json:"filename"`
	Size       int64  `json:"size"`
	MimeType   string `json:"mimeType"`
	UploadedAt int64  `json:"uploadedAt"`
}

// UploadFile uploads a file to the proxy service and returns attachment metadata
func UploadFile(filePath, proxyURL, workspace string) (*protocol.Attachment, error) {
	if proxyURL == "" {
		return nil, fmt.Errorf("proxy URL not configured (set PROXY_URL environment variable)")
	}
	proxyURL = strings.TrimRight(proxyURL, "/")

	// Validate file exists
	fileInfo, err := os.Stat(filePath)
	if err != nil {
		return nil, fmt.Errorf("file not found: %v", err)
	}

	// Check file size
	if fileInfo.Size() > MaxFileSize {
		sizeMB := float64(fileInfo.Size()) / 1024 / 1024
		return nil, fmt.Errorf("file exceeds 100 MB limit (%.1f MB)", sizeMB)
	}

	// Open file
	file, err := os.Open(filePath)
	if err != nil {
		return nil, fmt.Errorf("cannot open file: %v", err)
	}
	defer file.Close()

	// Create multipart request
	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)

	// Add file
	part, err := writer.CreateFormFile("file", filepath.Base(filePath))
	if err != nil {
		return nil, fmt.Errorf("cannot create form field: %v", err)
	}

	if _, err := io.Copy(part, file); err != nil {
		return nil, fmt.Errorf("cannot read file: %v", err)
	}

	// Close multipart
	if err := writer.Close(); err != nil {
		return nil, fmt.Errorf("cannot close multipart: %v", err)
	}

	// Make request
	req, err := http.NewRequest("POST", proxyURL+"/upload?workspace="+url.QueryEscape(workspace), body)
	if err != nil {
		return nil, fmt.Errorf("cannot create request: %v", err)
	}

	req.Header.Set("Content-Type", writer.FormDataContentType())

	client := &http.Client{Timeout: RequestTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("upload failed: %v", err)
	}
	defer resp.Body.Close()

	// Check status
	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("upload failed with status %d: %s", resp.StatusCode, string(respBody))
	}

	// Parse response
	var uploadResp UploadResponse
	if err := json.NewDecoder(resp.Body).Decode(&uploadResp); err != nil {
		return nil, fmt.Errorf("invalid upload response: %v", err)
	}

	// Validate response
	if uploadResp.FileId == "" || uploadResp.Filename == "" {
		return nil, fmt.Errorf("invalid upload response: missing fileId or filename")
	}

	return &protocol.Attachment{
		FileId:     uploadResp.FileId,
		Filename:   uploadResp.Filename,
		Size:       uploadResp.Size,
		MimeType:   uploadResp.MimeType,
		UploadedAt: uploadResp.UploadedAt,
	}, nil
}

// UploadFiles uploads multiple files and returns attachments
func UploadFiles(filePaths []string, proxyURL, workspace string) ([]protocol.Attachment, error) {
	if len(filePaths) == 0 {
		return []protocol.Attachment{}, nil
	}

	if len(filePaths) > MaxAttachmentsCmd {
		return nil, fmt.Errorf("too many files (max %d per command)", MaxAttachmentsCmd)
	}

	attachments := make([]protocol.Attachment, 0, len(filePaths))
	for _, filePath := range filePaths {
		att, err := UploadFile(filePath, proxyURL, workspace)
		if err != nil {
			return nil, err
		}
		attachments = append(attachments, *att)
	}

	return attachments, nil
}

// FileURL returns the public download URL for an attachment.
func FileURL(attachment protocol.Attachment, proxyURL string) string {
	if proxyURL == "" || attachment.FileId == "" {
		return ""
	}
	downloadURL := strings.TrimRight(proxyURL, "/") + "/files/" + url.PathEscape(attachment.FileId)
	query := url.Values{}
	if attachment.Filename != "" {
		query.Set("filename", attachment.Filename)
		downloadURL += "?" + query.Encode()
	}
	return downloadURL
}

// DownloadFile downloads an attachment from the proxy service to destination.
func DownloadFile(attachment protocol.Attachment, proxyURL, destination string) (int64, error) {
	if proxyURL == "" {
		return 0, fmt.Errorf("proxy URL not configured (set PROXY_URL environment variable)")
	}
	if attachment.FileId == "" {
		return 0, fmt.Errorf("attachment file ID is empty")
	}
	if destination == "" {
		destination = filepath.Base(attachment.Filename)
		if destination == "." || destination == string(filepath.Separator) || destination == "" {
			destination = attachment.FileId
		}
	}

	resp, err := (&http.Client{Timeout: RequestTimeout}).Get(FileURL(attachment, proxyURL))
	if err != nil {
		return 0, fmt.Errorf("download failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		return 0, fmt.Errorf("download failed with status %d: %s", resp.StatusCode, string(respBody))
	}

	destination = filepath.Clean(destination)
	tempFile, err := os.CreateTemp(filepath.Dir(destination), ".nrc-download-*")
	if err != nil {
		return 0, fmt.Errorf("cannot create destination file: %v", err)
	}
	tempPath := tempFile.Name()
	defer os.Remove(tempPath)

	written, copyErr := io.Copy(tempFile, resp.Body)
	closeErr := tempFile.Close()
	if copyErr != nil {
		return 0, fmt.Errorf("cannot write destination file: %v", copyErr)
	}
	if closeErr != nil {
		return 0, fmt.Errorf("cannot close destination file: %v", closeErr)
	}
	if err := os.Rename(tempPath, destination); err != nil {
		return 0, fmt.Errorf("cannot save destination file: %v", err)
	}
	return written, nil
}
