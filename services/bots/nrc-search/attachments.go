package main

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/xml"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/heavyhorst/nrc/protocol-go"
)

const maxAttachmentBytes = 100 * 1024 * 1024
const maxExtractedBytes = 16 * 1024 * 1024
const maxPDFPages = 20
const maxAudioSegments = 20 // Ten minutes, independently embedded in 30s windows.

var attachmentIDPattern = regexp.MustCompile(`^att_[0-9a-f]{32}$`)

type AttachmentSearch struct {
	FileID   string `json:"file_id"`
	Filename string `json:"filename"`
	Status   string `json:"status"`
	Error    string `json:"error,omitempty"`
}

type mediaEmbedder interface {
	EmbedMedia(kind, path string, offset int) ([]float32, error)
}

func attachmentKind(a protocol.Attachment) string {
	mime := strings.ToLower(strings.Split(a.MimeType, ";")[0])
	switch strings.ToLower(filepath.Ext(a.Filename)) {
	case ".pdf":
		return "pdf"
	case ".docx":
		return "docx"
	case ".xlsx":
		return "xlsx"
	}
	if mime == "application/pdf" {
		return "pdf"
	}
	if mime == "application/vnd.openxmlformats-officedocument.wordprocessingml.document" {
		return "docx"
	}
	if mime == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" {
		return "xlsx"
	}
	if strings.HasPrefix(mime, "image/") {
		return "image"
	}
	if strings.HasPrefix(mime, "audio/") {
		return "audio"
	}
	switch strings.ToLower(filepath.Ext(a.Filename)) {
	case ".png", ".jpg", ".jpeg", ".webp", ".gif":
		return "image"
	case ".wav", ".mp3", ".ogg", ".flac", ".m4a", ".aac", ".opus":
		return "audio"
	}
	return ""
}

func (c *NRCClient) downloadAttachment(a protocol.Attachment, dir string) (string, error) {
	if !attachmentIDPattern.MatchString(a.FileId) {
		return "", fmt.Errorf("invalid attachment ID")
	}
	u, err := url.Parse(strings.TrimRight(c.filesURL, "/") + "/files/" + a.FileId)
	if err != nil {
		return "", err
	}
	q := u.Query()
	q.Set("workspace", c.workspace)
	u.RawQuery = q.Encode()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+c.botSecret)
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("attachment download status %d", resp.StatusCode)
	}
	if resp.ContentLength > maxAttachmentBytes {
		return "", fmt.Errorf("attachment exceeds 100 MiB")
	}
	file, err := os.CreateTemp(dir, "blob-*")
	if err != nil {
		return "", err
	}
	defer file.Close()
	n, err := io.Copy(file, io.LimitReader(resp.Body, maxAttachmentBytes+1))
	if err != nil {
		return "", err
	}
	if n > maxAttachmentBytes {
		return "", fmt.Errorf("attachment exceeds 100 MiB")
	}
	return file.Name(), nil
}

// Keep each media item/window as a separate semantic chunk, so a small relevant
// attachment is not diluted by unrelated text or other attachments on its owner.
func (c *NRCClient) embedAttachments(attachments []protocol.Attachment) ([]IndexChunk, string, []AttachmentSearch) {
	var chunks []IndexChunk
	var texts []string
	var statuses []AttachmentSearch
	for _, attachment := range attachments {
		status := AttachmentSearch{FileID: attachment.FileId, Filename: attachment.Filename, Status: "unsupported"}
		texts = append(texts, attachment.Filename)
		kind := attachmentKind(attachment)
		if kind == "" {
			statuses = append(statuses, status)
			continue
		}
		if c.filesURL == "" {
			status.Status = "disabled"
			statuses = append(statuses, status)
			continue
		}
		err := func() error {
			dir, err := os.MkdirTemp("", "nrc-attachment-")
			if err != nil {
				return err
			}
			defer os.RemoveAll(dir)
			path, err := c.downloadAttachment(attachment, dir)
			if err != nil {
				return err
			}
			var vectors [][]float32
			var text string
			if kind == "docx" || kind == "xlsx" {
				text, err = extractOffice(path, kind)
			} else if kind == "pdf" {
				var output []byte
				output, err = runExtraction("pdftotext", "-layout", path, "-")
				text = string(output)
				if err == nil && strings.TrimSpace(text) == "" {
					media, ok := c.embedder.(mediaEmbedder)
					if !ok {
						return fmt.Errorf("media encoder unavailable")
					}
					info, infoErr := runExtraction("pdfinfo", path)
					if infoErr != nil {
						return infoErr
					}
					pages := 0
					for _, line := range strings.Split(string(info), "\n") {
						if strings.HasPrefix(line, "Pages:") {
							pages, _ = strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(line, "Pages:")))
						}
					}
					if pages < 1 || pages > maxPDFPages {
						return fmt.Errorf("scanned PDF must have 1–%d pages", maxPDFPages)
					}
					for page := 1; page <= pages; page++ {
						prefix := filepath.Join(dir, "page")
						if _, err := runExtraction("pdftoppm", "-f", strconv.Itoa(page), "-l", strconv.Itoa(page), "-scale-to", "1024", "-singlefile", "-png", path, prefix); err != nil {
							return err
						}
						vec, err := media.EmbedMedia("image", prefix+".png", 0)
						if err != nil {
							return err
						}
						vectors = append(vectors, vec)
					}
				}
			} else {
				media, ok := c.embedder.(mediaEmbedder)
				if !ok {
					return fmt.Errorf("media encoder unavailable")
				}
				if kind == "image" {
					// Do not decode SVGs or external-resource document formats as images.
					head := make([]byte, 512)
					file, err := os.Open(path)
					if err != nil {
						return err
					}
					n, _ := file.Read(head)
					file.Close()
					mime := http.DetectContentType(head[:n])
					if mime != "image/png" && mime != "image/jpeg" && mime != "image/gif" && mime != "image/webp" {
						return fmt.Errorf("unsupported raster image")
					}
					vec, err := media.EmbedMedia("image", path, 0)
					if err != nil {
						return err
					}
					vectors = append(vectors, vec)
				} else {
					for segment := 0; segment <= maxAudioSegments; segment++ {
						vec, err := media.EmbedMedia("audio", path, segment*30)
						if err != nil {
							return err
						}
						if len(vec) == 0 {
							break
						}
						if segment == maxAudioSegments {
							return fmt.Errorf("audio exceeds ten-minute limit")
						}
						vectors = append(vectors, vec)
					}
				}
			}
			if err != nil {
				return err
			}
			if strings.TrimSpace(text) != "" {
				textChunks, _, err := embedDocumentChunks(c.embedder, attachment.Filename, text)
				if err != nil {
					return err
				}
				for _, chunk := range textChunks {
					vectors = append(vectors, chunk.Vector)
				}
				texts = append(texts, text)
			}
			if len(vectors) == 0 {
				return fmt.Errorf("attachment contains no indexable content")
			}
			for _, vec := range vectors {
				chunks = append(chunks, IndexChunk{Vector: vec})
			}
			return nil
		}()
		if err != nil {
			status.Status = "failed"
			status.Error = err.Error()
			slog.Warn("attachment indexing failed", "file_id", attachment.FileId, "workspace", c.workspace, "error", err)
		} else {
			status.Status = "indexed"
		}
		statuses = append(statuses, status)
	}
	return chunks, strings.Join(texts, "\n"), statuses
}

type limitedExtractionBuffer struct{ bytes.Buffer }

func (b *limitedExtractionBuffer) Write(p []byte) (int, error) {
	if b.Len()+len(p) > maxExtractedBytes {
		return 0, fmt.Errorf("extracted text exceeds 16 MiB")
	}
	return b.Buffer.Write(p)
}

func runExtraction(name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	var output limitedExtractionBuffer
	cmd.Stdout = &output
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("%s extraction failed: %w", name, err)
	}
	return output.Bytes(), nil
}

func extractOffice(path, kind string) (string, error) {
	archive, err := zip.OpenReader(path)
	if err != nil {
		return "", err
	}
	defer archive.Close()
	budget := int64(maxExtractedBytes)
	read := func(file *zip.File) ([]byte, error) {
		if file.UncompressedSize64 > uint64(budget) {
			return nil, fmt.Errorf("office content exceeds 16 MiB")
		}
		r, err := file.Open()
		if err != nil {
			return nil, err
		}
		defer r.Close()
		data, err := io.ReadAll(io.LimitReader(r, budget+1))
		budget -= int64(len(data))
		if budget < 0 {
			return nil, fmt.Errorf("office content exceeds 16 MiB")
		}
		return data, err
	}
	var names []*zip.File
	var shared []string
	type richText struct {
		Text string `xml:"t"`
		Runs []struct {
			Text string `xml:"t"`
		} `xml:"r"`
	}
	plain := func(value richText) string {
		text := value.Text
		for _, run := range value.Runs {
			text += run.Text
		}
		return text
	}
	for _, file := range archive.File {
		if kind == "docx" && file.Name == "word/document.xml" {
			names = append(names, file)
		}
		if kind == "xlsx" && strings.HasPrefix(file.Name, "xl/worksheets/") && strings.HasSuffix(file.Name, ".xml") {
			names = append(names, file)
		}
		if kind == "xlsx" && file.Name == "xl/sharedStrings.xml" {
			data, err := read(file)
			if err != nil {
				return "", err
			}
			var table struct {
				Strings []richText `xml:"si"`
			}
			if err := xml.Unmarshal(data, &table); err != nil {
				return "", err
			}
			for _, value := range table.Strings {
				shared = append(shared, plain(value))
			}
		}
	}
	if len(names) == 0 {
		return "", fmt.Errorf("not a %s document", kind)
	}
	sort.Slice(names, func(i, j int) bool { return names[i].Name < names[j].Name })
	var result strings.Builder
	for _, file := range names {
		data, err := read(file)
		if err != nil {
			return "", err
		}
		decoder := xml.NewDecoder(bytes.NewReader(data))
		if kind == "xlsx" {
			fmt.Fprintln(&result, filepath.Base(file.Name))
		}
		for {
			token, err := decoder.Token()
			if err == io.EOF {
				break
			}
			if err != nil {
				return "", err
			}
			switch element := token.(type) {
			case xml.StartElement:
				if kind == "docx" && element.Name.Local == "t" {
					var text string
					if err := decoder.DecodeElement(&text, &element); err != nil {
						return "", err
					}
					result.WriteString(text)
				}
				if kind == "docx" && (element.Name.Local == "br" || element.Name.Local == "tab") {
					result.WriteByte('\n')
				}
				if kind == "xlsx" && element.Name.Local == "c" {
					var cell struct {
						Ref    string   `xml:"r,attr"`
						Type   string   `xml:"t,attr"`
						Value  string   `xml:"v"`
						Inline richText `xml:"is"`
					}
					if err := decoder.DecodeElement(&cell, &element); err != nil {
						return "", err
					}
					value := cell.Value
					if cell.Type == "s" {
						i, err := strconv.Atoi(value)
						if err != nil || i < 0 || i >= len(shared) {
							return "", fmt.Errorf("invalid shared string index")
						}
						value = shared[i]
					}
					if cell.Type == "inlineStr" {
						value = plain(cell.Inline)
					}
					// Shared strings can amplify a small worksheet into huge text.
					if result.Len()+len(cell.Ref)+len(value)+3 > maxExtractedBytes {
						return "", fmt.Errorf("extracted office text exceeds 16 MiB")
					}
					fmt.Fprintf(&result, "%s: %s\n", cell.Ref, value)
				}
			case xml.EndElement:
				if kind == "docx" && element.Name.Local == "p" {
					result.WriteByte('\n')
				}
			}
		}
	}
	return result.String(), nil
}
