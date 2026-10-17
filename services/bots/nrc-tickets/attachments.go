package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	p "github.com/heavyhorst/nrc/protocol-go"
)

const maxUploadBytes = 100 * 1024 * 1024

var fileIDPattern = regexp.MustCompile(`^att_[0-9a-f]{32}$`)

type fileStore interface {
	upload(context.Context, *multipart.FileHeader) (p.Attachment, error)
	open(context.Context, string) (*http.Response, error)
}

// Only the portal talks to the private bot listener. Customers never receive its
// address/secret or a generic file-ID proxy, even for blobs in this workspace.
type httpFiles struct {
	base, workspace, secret string
}

var filesClient = &http.Client{
	Timeout:       2 * time.Minute,
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

func (s httpFiles) request(ctx context.Context, method, path, contentType string, body io.Reader) (*http.Response, error) {
	r, err := http.NewRequestWithContext(ctx, method, s.base+path+"?workspace="+url.QueryEscape(s.workspace), body)
	if err != nil {
		return nil, err
	}
	r.Header.Set("Authorization", "Bearer "+s.secret)
	if contentType != "" {
		r.Header.Set("Content-Type", contentType)
	}
	return filesClient.Do(r)
}

func (s httpFiles) upload(ctx context.Context, header *multipart.FileHeader) (p.Attachment, error) {
	file, err := header.Open()
	if err != nil {
		return p.Attachment{}, err
	}
	reader, writer := io.Pipe()
	defer reader.Close()
	form := multipart.NewWriter(writer)
	go func() {
		defer file.Close()
		part, err := form.CreateFormFile("file", header.Filename)
		if err == nil {
			_, err = io.Copy(part, file)
		}
		if err == nil {
			err = form.Close()
		}
		writer.CloseWithError(err)
	}()
	resp, err := s.request(ctx, "POST", "/upload", form.FormDataContentType(), reader)
	if err != nil {
		return p.Attachment{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return p.Attachment{}, fmt.Errorf("blob upload refused")
	}
	var result struct {
		FileID, Filename, MimeType string
		Size, UploadedAt           int64
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8192)).Decode(&result); err != nil {
		return p.Attachment{}, err
	}
	a := p.Attachment{FileId: result.FileID, Filename: result.Filename, Size: result.Size, MimeType: result.MimeType, UploadedAt: result.UploadedAt}
	if !validAttachment(a) || a.Size != header.Size || a.Filename != header.Filename {
		return p.Attachment{}, fmt.Errorf("invalid upload acknowledgement")
	}
	return a, nil
}

func (s httpFiles) open(ctx context.Context, id string) (*http.Response, error) {
	return s.request(ctx, "GET", "/files/"+id, "", nil)
}

func validAttachment(a p.Attachment) bool {
	return fileIDPattern.MatchString(a.FileId) && a.Size >= 0 && a.Size <= maxUploadBytes &&
		validFilename(a.Filename) && len(a.MimeType) <= 100
}

func validFilename(name string) bool {
	return name != "" && len(name) <= 255 && utf8.ValidString(name) && !strings.ContainsAny(name, "\r\n/\\\x00")
}

type publicAttachment struct {
	Filename   string `json:"filename"`
	Size       int64  `json:"size"`
	URL        string `json:"url"`
	PreviewURL string `json:"preview_url,omitempty"`
}

func previewImageType(contentType string) bool {
	switch contentType {
	case "image/png", "image/jpeg", "image/gif", "image/webp":
		return true
	}
	return false
}

func publicAttachments(ticketID, assetID uint64, attachments []p.Attachment) []publicAttachment {
	var out []publicAttachment
	for _, a := range attachments {
		if validAttachment(a) {
			item := publicAttachment{Filename: a.Filename, Size: a.Size, URL: fmt.Sprintf("/tickets/%d/attachments/%d/%s", ticketID, assetID, a.FileId)}
			if previewImageType(a.MimeType) {
				item.PreviewURL = item.URL + "?preview=1"
			}
			out = append(out, item)
		}
	}
	return out
}

func publicReply(a p.Asset, ticketID uint64) (entryPreview, bool) {
	var v entryPreview
	ok := a.ConvID == 0 && a.AssetType == entryType && a.ParentType == 2 && a.ParentID == ticketID &&
		json.Unmarshal([]byte(a.Preview), &v) == nil && v.Version == 1 && (v.Kind == "public_reply" || v.Kind == "customer_reply")
	return v, ok
}

// The ticket has already passed requester authorization. Re-read the exact
// attached entry before opening the blob; internal/foreign entries fail closed.
func (s *portal) download(w http.ResponseWriter, r *http.Request, ticket p.Asset, parts []string) {
	if len(parts) != 4 || parts[1] != "attachments" || r.Method != "GET" || !fileIDPattern.MatchString(parts[3]) {
		http.NotFound(w, r)
		return
	}
	assetID, err := strconv.ParseUint(parts[2], 10, 64)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	a := ticket
	if assetID != ticket.AssetID {
		a, err = s.source.get(r.Context(), assetID)
		if _, ok := publicReply(a, ticket.AssetID); err != nil || !ok {
			http.NotFound(w, r)
			return
		}
	}
	for _, attachment := range a.Attachments {
		if attachment.FileId != parts[3] || !validAttachment(attachment) {
			continue
		}
		if s.files == nil {
			s.unavailable(w)
			return
		}
		resp, err := s.files.open(r.Context(), attachment.FileId)
		if err != nil {
			s.unavailable(w)
			return
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK || resp.ContentLength != attachment.Size {
			s.unavailable(w)
			return
		}
		if r.URL.Query().Get("preview") == "1" {
			// Never trust the filename, stored MIME or upstream Content-Type to
			// serve active content inline. Sniff only a bounded prefix and stream
			// raster bytes without decoding untrusted images on the server.
			var prefix [512]byte
			n, err := io.ReadFull(resp.Body, prefix[:])
			if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
				s.unavailable(w)
				return
			}
			contentType := http.DetectContentType(prefix[:n])
			if !previewImageType(contentType) {
				http.NotFound(w, r)
				return
			}
			w.Header().Set("Content-Type", contentType)
			w.Header().Set("Content-Disposition", mime.FormatMediaType("inline", map[string]string{"filename": attachment.Filename}))
			w.Header().Set("Content-Length", strconv.FormatInt(attachment.Size, 10))
			io.CopyN(w, io.MultiReader(bytes.NewReader(prefix[:n]), resp.Body), attachment.Size)
			return
		}
		// Downloads stay inert, even for HTML/SVG or a forged image MIME.
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": attachment.Filename}))
		w.Header().Set("Content-Length", strconv.FormatInt(attachment.Size, 10))
		io.CopyN(w, resp.Body, attachment.Size)
		return
	}
	http.NotFound(w, r)
}
