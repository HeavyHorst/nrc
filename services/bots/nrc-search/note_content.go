package main

import (
	"encoding/json"
	"io"
	"strings"
	"unicode"

	protocol "github.com/heavyhorst/nrc/protocol-go"
	xhtml "golang.org/x/net/html"
)

const (
	noteFormatMarkdown = "markdown"
	noteFormatHTML     = "html"
)

// noteInputFormat reads the format metadata from a note's preview. Older and
// malformed previews remain markdown, matching the format used before this
// field was introduced.
func noteInputFormat(preview string) string {
	var metadata struct {
		Format string `json:"format"`
	}
	if json.Unmarshal([]byte(preview), &metadata) == nil && metadata.Format == noteFormatHTML {
		return noteFormatHTML
	}
	return noteFormatMarkdown
}

func searchableAssetContent(assetType uint16, preview, payload string) string {
	if assetType == protocol.AssetTypeNote && noteInputFormat(preview) == noteFormatHTML {
		return htmlNoteText(payload)
	}
	return payload
}

// htmlNoteText uses the HTML tokenizer so quoted '>' characters and malformed
// but recoverable markup cannot leak attribute text into the search document.
func htmlNoteText(source string) string {
	var out strings.Builder
	tokenizer := xhtml.NewTokenizer(strings.NewReader(source))
	suppressed := make([]string, 0, 2)
	for {
		tokenType := tokenizer.Next()
		if tokenType == xhtml.ErrorToken {
			if tokenizer.Err() != nil && tokenizer.Err() != io.EOF {
				return normalizeExtractedHTML(out.String())
			}
			break
		}
		if tokenType == xhtml.TextToken {
			if len(suppressed) == 0 {
				out.Write(tokenizer.Text())
			}
			continue
		}
		if tokenType != xhtml.StartTagToken && tokenType != xhtml.EndTagToken && tokenType != xhtml.SelfClosingTagToken {
			continue
		}

		nameBytes, _ := tokenizer.TagName()
		name := strings.ToLower(string(nameBytes))
		closing := tokenType == xhtml.EndTagToken
		if len(suppressed) > 0 {
			if !closing && (name == "script" || name == "style" || name == "noscript" || name == "template") {
				suppressed = append(suppressed, name)
			} else if closing && name == suppressed[len(suppressed)-1] {
				suppressed = suppressed[:len(suppressed)-1]
			}
			continue
		}
		if !closing && (name == "script" || name == "style" || name == "noscript" || name == "template") {
			suppressed = append(suppressed, name)
			continue
		}
		if len(name) == 2 && name[0] == 'h' && name[1] >= '1' && name[1] <= '6' {
			writeHTMLBoundary(&out)
			if !closing {
				out.WriteString(strings.Repeat("#", int(name[1]-'0')) + " ")
			}
		} else if isHTMLBlock(name) || name == "br" {
			writeHTMLBoundary(&out)
		}
	}
	return normalizeExtractedHTML(out.String())
}

func isHTMLBlock(name string) bool {
	switch name {
	case "p", "div", "section", "article", "header", "footer", "main", "aside", "blockquote", "pre", "ul", "ol", "li", "table", "tr":
		return true
	}
	return false
}

func writeHTMLBoundary(out *strings.Builder) {
	if out.Len() > 0 {
		out.WriteString("\n\n")
	}
}

func normalizeExtractedHTML(text string) string {
	lines := strings.Split(strings.ReplaceAll(text, "\u00a0", " "), "\n")
	result := make([]string, 0, len(lines))
	blank := true
	for _, line := range lines {
		line = strings.Join(strings.FieldsFunc(line, unicode.IsSpace), " ")
		if line == "" {
			if !blank {
				result = append(result, "")
				blank = true
			}
			continue
		}
		result = append(result, line)
		blank = false
	}
	return strings.TrimSpace(strings.Join(result, "\n"))
}
