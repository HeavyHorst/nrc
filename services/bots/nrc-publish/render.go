package main

import (
	"bytes"
	"fmt"
	"html/template"
	"net/url"
	"strconv"
	"strings"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
	"github.com/yuin/goldmark/parser"
	"golang.org/x/net/html"
)

type section struct{ ID, Title string }

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
func renderMarkdown(r revision) (template.HTML, []section, error) {
	md := goldmark.New(goldmark.WithExtensions(extension.Table, extension.Strikethrough), goldmark.WithParserOptions(parser.WithAutoHeadingID()))
	var output bytes.Buffer
	if err := md.Convert([]byte(r.Markdown), &output); err != nil {
		return "", nil, err
	}
	doc, err := html.Parse(strings.NewReader(output.String()))
	if err != nil {
		return "", nil, err
	}
	var sections []section
	var body *html.Node
	var walk func(*html.Node) error
	walk = func(n *html.Node) error {
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
					} else if n.Data == "img" {
						return fmt.Errorf("Bild %s muss als NRC-Anhang eingebunden sein (keine externen Bildquellen).", a.Val)
					} else if u.Scheme == "" && u.Host == "" && strings.HasPrefix(a.Val, "#") {
						// Section links stay on the current article.
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
		return nil
	}
	if err := walk(doc); err != nil {
		return "", nil, err
	}
	output.Reset()
	for c := body.FirstChild; c != nil; c = c.NextSibling {
		if err := html.Render(&output, c); err != nil {
			return "", nil, err
		}
	}
	return template.HTML(output.String()), sections, nil
}
