package main

import (
	"encoding/json"
	"strings"

	"github.com/heavyhorst/nrc/protocol-go"
)

const default_embedding_schema = "embeddinggemma-2-v3-customers"

const (
	embedding_gemma_query_prefix = "task: search result | query: "
	embedding_gemma_doc_prefix   = "title: "
	embedding_gemma_text_prefix  = " | text: "
)

func format_query_for_embedding(query string) string {
	return embedding_gemma_query_prefix + strings.TrimSpace(query)
}

func format_document_for_embedding(preview, content string) string {
	title := "none"
	trimmedPreview := strings.TrimSpace(preview)
	trimmedContent := strings.TrimSpace(content)
	if trimmedPreview != "" && !strings.EqualFold(trimmedPreview, trimmedContent) {
		title = trimmedPreview
	}
	return embedding_gemma_doc_prefix + title + embedding_gemma_text_prefix + trimmedContent
}

func document_content_hash(preview, content string, attachments ...protocol.Attachment) uint64 {
	text := []byte(format_document_for_embedding(preview, content))
	if len(attachments) > 0 {
		metadata, _ := json.Marshal(attachments)
		text = append(append(text, 0), metadata...)
	}
	return contentHash(text)
}
