package main

import (
	"strings"
	"testing"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestNoteInputFormat(t *testing.T) {
	for _, test := range []struct{ preview, want string }{
		{`{"title":"old"}`, noteFormatMarkdown},
		{`not json`, noteFormatMarkdown},
		{`{"format":"markdown"}`, noteFormatMarkdown},
		{`{"format":"html"}`, noteFormatHTML},
		{`{"format":"HTML"}`, noteFormatMarkdown},
	} {
		if got := noteInputFormat(test.preview); got != test.want {
			t.Errorf("noteInputFormat(%q) = %q, want %q", test.preview, got, test.want)
		}
	}
}

func TestHTMLNoteTextPreservesStructureAndOmitsUnsafeContent(t *testing.T) {
	html := `<h1 title="a > b">Runbook &amp; Recovery</h1><p>Restore <strong>the backup</strong>. Show &amp;lt;code&amp;gt; literally.</p><script>alert("secret")</script><style>.hidden { color: red }</style><template><template>nested secret</template>template secret</template><h2>Checks</h2><ul><li>Verify data</li><li>Notify team</li></ul>`
	got := searchableAssetContent(protocol.AssetTypeNote, `{"format":"html"}`, html)
	for _, want := range []string{"# Runbook & Recovery", "Restore the backup. Show &lt;code&gt; literally.", "## Checks", "Verify data", "Notify team"} {
		if !strings.Contains(got, want) {
			t.Errorf("extracted text %q does not contain %q", got, want)
		}
	}
	for _, unwanted := range []string{"a > b", "alert", "secret", ".hidden", "color: red", "template secret"} {
		if strings.Contains(got, unwanted) {
			t.Errorf("extracted text %q contains excluded %q", got, unwanted)
		}
	}
	chunks := chunkDocumentText(got, 8, 12, 0)
	if len(chunks) < 2 {
		t.Fatalf("structured HTML produced %d chunks, want multiple: %q", len(chunks), got)
	}
}

func TestSearchableAssetContentLeavesOriginalPayloadUntouched(t *testing.T) {
	payload := `<p>Hello</p>`
	if got := searchableAssetContent(protocol.AssetTypeDocument, `{"format":"html"}`, payload); got != payload {
		t.Fatalf("non-note payload changed to %q", got)
	}
}

func TestIndexFallbackUsesReadableHTMLNoteText(t *testing.T) {
	index := NewIndex()
	entry := &IndexEntry{
		AssetType: protocol.AssetTypeNote,
		ConvID:    7,
		Preview:   `{"title":"Runbook","format":"html"}`,
		Payload:   `<style>.secret{display:none}</style><p>Restore the backup</p>`,
	}
	if err := index.AddEntity(assetIdentity("workspace", 42, 7), entry); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(entry.PayloadLower, "restore the backup") {
		t.Fatalf("fallback payload text = %q", entry.PayloadLower)
	}
	if strings.Contains(entry.PayloadLower, "secret") || strings.Contains(entry.PayloadLower, "<p>") {
		t.Fatalf("fallback payload retained HTML-only content: %q", entry.PayloadLower)
	}
}
