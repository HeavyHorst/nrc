package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/heavyhorst/nrc/protocol-go"
)

type attachmentTextRequest struct {
	Workspace  string `json:"workspace"`
	ConvID     string `json:"conv_id"`
	EntityType string `json:"entity_type"`
	EntityID   string `json:"entity_id"`
	FileID     string `json:"file_id"`
	Offset     int    `json:"offset"`
	Limit      *int   `json:"limit"`
}

type attachmentTextResponse struct {
	FileID     string `json:"file_id"`
	Filename   string `json:"filename"`
	MimeType   string `json:"mime_type"`
	Status     string `json:"status"`
	Text       string `json:"text"`
	Offset     int    `json:"offset"`
	NextOffset int    `json:"next_offset"`
	HasMore    bool   `json:"has_more"`
	Complete   bool   `json:"complete"`
	TotalBytes int    `json:"total_bytes"`
	Warning    string `json:"warning,omitempty"`
}

var attachmentWorkspacePattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)
var attachmentDecimalPattern = regexp.MustCompile(`^(0|[1-9][0-9]*)$`)

type attachmentAssetResult struct {
	asset protocol.Asset
	err   error
}

func (c *NRCClient) settleAttachmentAsset(id uint32, result attachmentAssetResult) {
	if pending, ok := c.pendingAttachmentAssets.LoadAndDelete(id); ok {
		pending.(chan attachmentAssetResult) <- result
	}
}

func (c *NRCClient) failAttachmentAssets() {
	c.pendingAttachmentAssets.Range(func(key, _ any) bool {
		c.settleAttachmentAsset(key.(uint32), attachmentAssetResult{err: fmt.Errorf("NRC disconnected")})
		return true
	})
}

func (r attachmentTextRequest) validate() (uint64, uint64, int, error) {
	if !attachmentWorkspacePattern.MatchString(r.Workspace) || !attachmentIDPattern.MatchString(r.FileID) || (r.EntityType != "asset" && r.EntityType != "task") {
		return 0, 0, 0, fmt.Errorf("invalid workspace, file_id or entity_type")
	}
	conv, err := strconv.ParseUint(r.ConvID, 10, 63)
	if err != nil || conv != protocol.WorkspaceDataConvID || !attachmentDecimalPattern.MatchString(r.ConvID) {
		return 0, 0, 0, fmt.Errorf("conv_id must be workspace data scope 0")
	}
	entity, err := strconv.ParseUint(r.EntityID, 10, 64)
	if err != nil || entity == 0 || !attachmentDecimalPattern.MatchString(r.EntityID) {
		return 0, 0, 0, fmt.Errorf("entity_id must be a nonzero decimal string")
	}
	limit := 16384
	if r.Limit != nil {
		limit = *r.Limit
	}
	if r.Offset < 0 || r.Offset > maxExtractedBytes || limit < 1 {
		return 0, 0, 0, fmt.Errorf("invalid offset or limit")
	}
	if limit > 32768 {
		limit = 32768
	}
	return conv, entity, limit, nil
}

// Fresh exact reads only: the embedding inventory and the proxy's workspace-wide
// file grant are not evidence that this particular entity owns this attachment.
func (c *NRCClient) attachmentOwner(ctx context.Context, kind string, conv, entity uint64) ([]protocol.Attachment, error) {
	if kind == "task" {
		task, err := c.requestTaskFull(ctx, taskIdentity(c.workspace, entity, conv))
		if err != nil {
			return nil, err
		}
		if task.ID != entity || task.ConvID < 0 || uint64(task.ConvID) != conv {
			return nil, fmt.Errorf("owner identity mismatch")
		}
		return task.Attachments, nil
	}
	id := c.correlationID()
	ch := make(chan attachmentAssetResult, 1)
	c.pendingAttachmentAssets.Store(id, ch)
	defer c.pendingAttachmentAssets.Delete(id)
	if err := c.sendProtocolMessage(protocol.C_GetAsset, protocol.EncodeGetAssetWithCorrelation(int64(conv), entity, id)); err != nil {
		return nil, err
	}
	select {
	case result := <-ch:
		if result.err != nil {
			return nil, result.err
		}
		asset := result.asset
		if asset.AssetID != entity || asset.ConvID != conv {
			return nil, fmt.Errorf("owner identity mismatch")
		}
		return asset.Attachments, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func attachmentTextHandler(secret string, clientFor func(context.Context, string) (*NRCClient, error)) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if secret == "" || subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+secret)) != 1 {
			http.Error(w, "bot authentication required", http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-NRC-Attachment-Text-Version", "1")
		fail := func(code int, message string) {
			w.WriteHeader(code)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
		}
		var req attachmentTextRequest
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&req); err != nil {
			fail(400, "invalid request body")
			return
		}
		var extra any
		if err := decoder.Decode(&extra); err != io.EOF {
			fail(400, "invalid request body")
			return
		}
		conv, entity, limit, err := req.validate()
		if err != nil {
			fail(400, err.Error())
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
		defer cancel()
		client, err := clientFor(ctx, req.Workspace)
		if err != nil || client == nil || client.workspace != req.Workspace {
			fail(503, "workspace unavailable")
			return
		}
		attachments, err := client.attachmentOwner(ctx, req.EntityType, conv, entity)
		if err != nil {
			fail(502, "fresh owner lookup failed")
			return
		}
		var attachment *protocol.Attachment
		for i := range attachments {
			if attachments[i].FileId == req.FileID {
				attachment = &attachments[i]
				break
			}
		}
		if attachment == nil {
			fail(404, "attachment not found on requested entity")
			return
		}
		response := attachmentTextResponse{FileID: req.FileID, Filename: attachment.Filename, MimeType: attachment.MimeType, Offset: req.Offset, NextOffset: req.Offset, Status: "unsupported"}
		kind := attachmentKind(*attachment)
		mime := strings.ToLower(strings.TrimSpace(strings.Split(attachment.MimeType, ";")[0]))
		if strings.HasPrefix(mime, "image/") || strings.HasPrefix(mime, "audio/") {
			kind = "unsupported"
		}
		if kind == "" {
			if strings.HasPrefix(mime, "text/") || mime == "application/json" || mime == "application/xml" {
				kind = "text"
			}
			switch strings.ToLower(filepath.Ext(attachment.Filename)) {
			case ".txt", ".md", ".csv", ".tsv", ".log", ".json", ".xml":
				kind = "text"
			}
		}
		if kind != "text" && kind != "pdf" && kind != "docx" && kind != "xlsx" {
			response.Warning = "Text extraction unsupported; no OCR or transcription is performed"
			_ = json.NewEncoder(w).Encode(response)
			return
		}
		if client.filesURL == "" {
			fail(503, "FILES_URL is required")
			return
		}
		dir, err := os.MkdirTemp("", "nrc-attachment-text-")
		if err != nil {
			fail(500, "temporary storage unavailable")
			return
		}
		defer os.RemoveAll(dir)
		path, err := client.downloadAttachmentContext(ctx, *attachment, dir)
		if err != nil {
			fail(502, "attachment download failed")
			return
		}
		text, complete, warning, err := extractAttachmentText(ctx, path, kind)
		if err != nil {
			response.Status = "failed"
			response.Warning = "Text extraction failed (invalid, encrypted, over extraction bounds, or extractor unavailable)"
			_ = json.NewEncoder(w).Encode(response)
			return
		}
		if req.Offset > len(text) || (req.Offset < len(text) && !utf8.RuneStart(text[req.Offset])) {
			fail(400, "offset is outside extracted text or splits a UTF-8 rune")
			return
		}
		end := req.Offset + limit
		if end > len(text) {
			end = len(text)
		}
		for end < len(text) && end > req.Offset && !utf8.RuneStart(text[end]) {
			end--
		}
		if end == req.Offset && end < len(text) {
			fail(400, "limit is too small for next UTF-8 rune")
			return
		}
		response.Status = "ok"
		if !complete {
			response.Status = "partial"
		}
		response.Text = text[req.Offset:end]
		response.NextOffset, response.TotalBytes = end, len(text)
		response.HasMore, response.Complete, response.Warning = end < len(text), complete, warning
		_ = json.NewEncoder(w).Encode(response)
	})
}

func extractAttachmentText(ctx context.Context, path, kind string) (string, bool, string, error) {
	if err := ctx.Err(); err != nil {
		return "", false, "", err
	}
	var text string
	var err error
	complete, warning := true, ""
	switch kind {
	case "pdf":
		info, e := runExtractionContext(ctx, "pdfinfo", path)
		if e != nil {
			return "", false, "", e
		}
		pages := 0
		for _, line := range strings.Split(string(info), "\n") {
			if strings.HasPrefix(line, "Encrypted:") && strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(line, "Encrypted:")), "yes") {
				return "", false, "", fmt.Errorf("encrypted PDF")
			}
			if strings.HasPrefix(line, "Pages:") {
				pages, _ = strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(line, "Pages:")))
			}
		}
		if pages < 1 {
			return "", false, "", fmt.Errorf("unknown PDF page count")
		}
		output, e := runExtractionContext(ctx, "pdftotext", "-f", "1", "-l", strconv.Itoa(maxPDFPages), "-layout", path, "-")
		text, err = string(output), e
		complete = pages <= maxPDFPages && strings.TrimSpace(text) != ""
		warning = "PDF text layer only; scanned content is not extracted (no OCR)"
		if pages > maxPDFPages {
			warning += "; extraction limited to the first 20 pages"
		}
	case "docx", "xlsx":
		text, err = extractOfficeContext(ctx, path, kind)
		warning = "Office extraction includes document body or worksheet cell values only; headers, comments, drawings and other parts are not extracted"
		complete = false
	case "text":
		file, e := os.Open(path)
		if e != nil {
			return "", false, "", e
		}
		defer file.Close()
		data, e := io.ReadAll(io.LimitReader(file, maxExtractedBytes+1))
		text, err = string(data), e
	default:
		return "", false, "", fmt.Errorf("unsupported text extraction")
	}
	if err != nil {
		return "", false, "", err
	}
	if err := ctx.Err(); err != nil {
		return "", false, "", err
	}
	if len(text) > maxExtractedBytes || !utf8.ValidString(text) {
		return "", false, "", fmt.Errorf("extracted text exceeds bounds or is not UTF-8")
	}
	return text, complete, warning, nil
}
