package main

import (
	"bytes"
	"fmt"
	"html/template"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
	"github.com/yuin/goldmark/parser"
	"golang.org/x/net/html"
)

type section struct{ ID, Title string }

var noteReferencePattern = regexp.MustCompile(`\[note:([0-9]+)\]`)

type articleReference struct{ Slug, Title, URL string }

func nodeText(n *html.Node) string {
	var b strings.Builder
	var walk func(*html.Node)
	walk = func(n *html.Node) {
		if n.Type == html.TextNode {
			b.WriteString(n.Data)
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(n)
	return b.String()
}

// Goldmark deliberately leaves raw HTML disabled. Inspect generated HTML to
// rewrite ONLY explicitly attached files; never fetch URLs from note content.
func renderMarkdown(r revision) (template.HTML, []section, []protocol.Attachment, error) {
	return renderMarkdownWithReferences(r, nil)
}

func renderMarkdownWithReferences(r revision, resolve func(string) (articleReference, error)) (template.HTML, []section, []protocol.Attachment, error) {
	md := goldmark.New(goldmark.WithExtensions(extension.Table, extension.Strikethrough), goldmark.WithParserOptions(parser.WithAutoHeadingID()))
	var output bytes.Buffer
	if err := md.Convert([]byte(r.Markdown), &output); err != nil {
		return "", nil, nil, err
	}
	doc, err := html.Parse(strings.NewReader(output.String()))
	if err != nil {
		return "", nil, nil, err
	}
	var sections []section
	used := map[string]bool{}
	var body *html.Node
	var walk func(*html.Node) error
	walk = func(n *html.Node) error {
		if n.Type == html.TextNode {
			// Pre-existing snapshots remain readable without changing approved text.
			if resolve == nil && r.NoteReferences == nil {
				return nil
			}
			for p := n.Parent; p != nil; p = p.Parent {
				if p.Data == "code" || p.Data == "pre" || p.Data == "a" {
					return nil
				}
			}
			matches := noteReferencePattern.FindAllStringSubmatchIndex(n.Data, -1)
			if len(matches) > 0 {
				end := 0
				for _, match := range matches {
					id := n.Data[match[2]:match[3]]
					value, err := strconv.ParseUint(id, 10, 64)
					if err != nil || value == 0 {
						return fmt.Errorf("Ungültige Notizreferenz: [note:%s]", id)
					}
					id = strconv.FormatUint(value, 10)
					ref, ok := r.NoteReferences[id]
					if resolve != nil {
						ref, err = resolve(id)
						if err != nil {
							return err
						}
						ok = true
					}
					if !ok {
						return fmt.Errorf("Notiz [note:%s] hat keinen veröffentlichten Artikel.", id)
					}
					n.Parent.InsertBefore(&html.Node{Type: html.TextNode, Data: n.Data[end:match[0]]}, n)
					if ref.Slug == "" {
						missing := &html.Node{Type: html.ElementNode, Data: "strong"}
						missing.AppendChild(&html.Node{Type: html.TextNode, Data: "[note:" + id + "] (Linkziel fehlt)"})
						n.Parent.InsertBefore(missing, n)
					} else {
						href := ref.URL
						if href == "" {
							href = "/articles/" + ref.Slug
						}
						link := &html.Node{Type: html.ElementNode, Data: "a", Attr: []html.Attribute{{Key: "href", Val: href}}}
						link.AppendChild(&html.Node{Type: html.TextNode, Data: ref.Title})
						n.Parent.InsertBefore(link, n)
					}
					end = match[1]
				}
				n.Data = n.Data[end:]
			}
		}
		if n.Type == html.ElementNode {
			if n.Data == "body" {
				body = n
			}
			if n.Data == "h2" || n.Data == "h3" {
				id := fmt.Sprintf("section-%d", len(sections)+1)
				for _, a := range n.Attr {
					if a.Key == "id" {
						id = a.Val
						break
					}
				}
				n.Attr = []html.Attribute{{Key: "id", Val: id}}
				sections = append(sections, section{id, nodeText(n)})
			}
			if n.Data == "a" || n.Data == "img" {
				for i, a := range n.Attr {
					if a.Key != "href" && a.Key != "src" {
						continue
					}
					u, err := url.Parse(a.Val)
					if err != nil {
						return fmt.Errorf("Ungültiger Link: %s", a.Val)
					}
					if u.Scheme == "att" {
						index, err := strconv.Atoi(u.Opaque)
						if err != nil || index < 0 || index >= len(r.Attachments) || a.Val != "att:"+strconv.Itoa(index) {
							return fmt.Errorf("Ungültige Anhangsreferenz: %s", a.Val)
						}
						n.Attr[i].Val = "/media/" + r.ID + "/" + r.Attachments[index].FileId
						used[r.Attachments[index].FileId] = true
					} else if u.Scheme == "" && u.Host == "" && strings.HasPrefix(u.Path, "/files/") {
						id := strings.TrimPrefix(u.Path, "/files/")
						found := false
						for _, f := range r.Attachments {
							if f.FileId == id {
								found = true
								break
							}
						}
						if !found {
							return fmt.Errorf("Dateilink %s ist kein Anhang dieser Notiz.", id)
						}
						n.Attr[i].Val = "/media/" + r.ID + "/" + id
						used[id] = true
					} else if n.Data == "img" {
						return fmt.Errorf("Bild %s muss als NRC-Anhang eingebunden sein (keine externen Bildquellen).", a.Val)
					} else if u.Scheme == "" && u.Host == "" && strings.HasPrefix(a.Val, "#") {
						// Section links stay on the current article.
					} else if u.Scheme == "" && u.Host == "" && strings.HasPrefix(u.Path, "/articles/by-note/") {
						id := strings.TrimPrefix(u.Path, "/articles/by-note/")
						value, err := strconv.ParseUint(id, 10, 64)
						if err != nil || value == 0 || strconv.FormatUint(value, 10) != id {
							return fmt.Errorf("Ungültige NRC-Notiz-ID im Artikellink %q.", a.Val)
						}
					} else if u.Scheme == "" && u.Host == "" && strings.HasPrefix(u.Path, "/articles/") {
						slug := strings.TrimPrefix(u.Path, "/articles/")
						if !slugPattern.MatchString(slug) || len(slug) > 100 {
							return fmt.Errorf("Ungültiger Artikellink %q. Erwartet wird /articles/<gültiger-slug>.", a.Val)
						}
					} else if (u.Scheme == "https" || u.Scheme == "http") && u.Host != "" {
						// Explicit external links are visible to the human reviewer.
					} else if u.Scheme == "mailto" {
					} else {
						return fmt.Errorf("Interner oder unsicherer Link %q. Bitte durch einen öffentlichen Link ersetzen.", a.Val)
					}
				}
			}
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			if err := walk(c); err != nil {
				return err
			}
		}
		if n.Type == html.ElementNode && (n.Data == "h2" || n.Data == "h3") {
			sections[len(sections)-1].Title = nodeText(n)
		}
		return nil
	}
	if err := walk(doc); err != nil {
		return "", nil, nil, err
	}
	output.Reset()
	for c := body.FirstChild; c != nil; c = c.NextSibling {
		if err := html.Render(&output, c); err != nil {
			return "", nil, nil, err
		}
	}
	var additional []protocol.Attachment
	for _, attachment := range r.Attachments {
		if !used[attachment.FileId] {
			additional = append(additional, attachment)
		}
	}
	return template.HTML(output.String()), sections, additional, nil
}
