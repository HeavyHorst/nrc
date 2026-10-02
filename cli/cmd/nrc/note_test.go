package main

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/spf13/cobra"
)

func testNoteContentCommand() *cobra.Command {
	cmd := &cobra.Command{}
	cmd.Flags().String("content", "", "")
	cmd.Flags().String("content-file", "", "")
	return cmd
}

func TestNoteCursorRoundTrip(t *testing.T) {
	cursor := encodeNoteCursor(123456789, 42)
	if cursor == "" {
		t.Fatal("cursor should not be empty")
	}

	decoded, err := decodeNoteCursor(cursor)
	if err != nil {
		t.Fatalf("decodeNoteCursor error: %v", err)
	}
	if decoded.UpdatedAt != 123456789 || decoded.AssetID != 42 {
		t.Fatalf("decoded cursor = %+v, want updated_at=123456789 asset_id=42", decoded)
	}
}

func TestDecodeNoteCursorRejectsInvalidInput(t *testing.T) {
	cases := []string{
		"not-base64",
		encodeNoteCursor(0, 42),
		encodeNoteCursor(123456789, 0),
		"MTIz", // base64url("123"), missing asset ID separator.
	}

	for _, tc := range cases {
		if _, err := decodeNoteCursor(tc); err == nil {
			t.Fatalf("decodeNoteCursor(%q) succeeded, want error", tc)
		}
	}
}

func TestParseNoteListOptions(t *testing.T) {
	cursor := encodeNoteCursor(123456789, 42)
	opts, err := parseNoteListOptions(" Marketplace ", "", 25, 50, cursor, false)
	if err != nil {
		t.Fatalf("parseNoteListOptions error: %v", err)
	}

	if opts.Project != "Marketplace" || opts.Tag != "" {
		t.Fatalf("Project/Tag = %q/%q, want Marketplace/empty", opts.Project, opts.Tag)
	}
	if opts.Limit != 25 || opts.PageSize != 50 {
		t.Fatalf("Limit/PageSize = %d/%d, want 25/50", opts.Limit, opts.PageSize)
	}
	if !opts.HasCursor || opts.CursorUpdated != 123456789 || opts.CursorAssetID != 42 {
		t.Fatalf("cursor fields = has:%v updated:%d asset:%d", opts.HasCursor, opts.CursorUpdated, opts.CursorAssetID)
	}
}

func TestParseNoteListOptionsRejectsUnsafeCombinations(t *testing.T) {
	cases := []struct {
		name     string
		limit    int
		pageSize int
		cursor   string
		all      bool
	}{
		{name: "negative limit", limit: -1, pageSize: 50},
		{name: "zero page size", pageSize: 0},
		{name: "large page size", pageSize: maxNoteListPageSize + 1},
		{name: "all and limit", limit: 10, pageSize: 50, all: true},
		{name: "all and cursor", pageSize: 50, cursor: encodeNoteCursor(123456789, 42), all: true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := parseNoteListOptions("", "", tc.limit, tc.pageSize, tc.cursor, tc.all); err == nil {
				t.Fatal("parseNoteListOptions succeeded, want error")
			}
		})
	}
}

func TestParseNoteListOptionsRejectsProjectAndTag(t *testing.T) {
	if _, err := parseNoteListOptions("proj", "tag", 0, 50, "", false); err == nil {
		t.Fatal("parseNoteListOptions succeeded, want error")
	}
}

func TestNoteEntryIncludesUpdatedAt(t *testing.T) {
	entry := noteEntryFromAsset(protocol.Asset{
		AssetID:   42,
		UpdatedAt: 123456789,
		Preview:   `{"title":"Test"}`,
	})
	if entry.UpdatedAt != 123456789 {
		t.Fatalf("UpdatedAt = %d, want 123456789", entry.UpdatedAt)
	}
}

func TestNormalizeNoteTags(t *testing.T) {
	tags := normalizeNoteTags([]string{" alpha, beta ", "alpha", "", " ops "})
	want := []string{"alpha", "beta", "ops"}
	if len(tags) != len(want) {
		t.Fatalf("tags = %#v, want %#v", tags, want)
	}
	for i := range tags {
		if tags[i] != want[i] {
			t.Fatalf("tags = %#v, want %#v", tags, want)
		}
	}
}

func TestFormatAttachmentSize(t *testing.T) {
	tests := []struct {
		name string
		size int64
		want string
	}{
		{name: "bytes", size: 42, want: "42 B"},
		{name: "kilobytes", size: 1536, want: "1.5 KB"},
		{name: "megabytes", size: 3*1024*1024 + 512*1024, want: "3.5 MB"},
		{name: "negative", size: -1, want: "0 B"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := formatAttachmentSize(tt.size); got != tt.want {
				t.Fatalf("formatAttachmentSize(%d) = %q, want %q", tt.size, got, tt.want)
			}
		})
	}
}

func TestPrintNoteAttachments(t *testing.T) {
	output := captureStdout(t, func() {
		printNoteAttachments([]protocol.Attachment{
			{FileId: "att_one", Filename: "requirements.md", Size: 1536, MimeType: "text/markdown"},
			{FileId: "att_two", Size: 12},
		}, "https://files.example/")
	})

	for _, want := range []string{
		"Attachments:",
		"[0] requirements.md  1.5 KB  text/markdown  att_one",
		"https://files.example/files/att_one?filename=requirements.md",
		"[1] att_two  12 B  application/octet-stream  att_two",
		"https://files.example/files/att_two",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("output missing %q:\n%s", want, output)
		}
	}
}

func TestNoteAttachmentIndex(t *testing.T) {
	attachments := []protocol.Attachment{
		{FileId: "att_one", Filename: "one.txt"},
		{FileId: "att_two", Filename: "two.txt"},
	}

	for _, test := range []struct {
		name     string
		selector string
		want     int
	}{
		{name: "index", selector: "1", want: 1},
		{name: "file ID", selector: "att_one", want: 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := noteAttachmentIndex(attachments, test.selector)
			if err != nil {
				t.Fatalf("noteAttachmentIndex error: %v", err)
			}
			if got != test.want {
				t.Fatalf("noteAttachmentIndex = %d, want %d", got, test.want)
			}
		})
	}

	for _, selector := range []string{"2", "-1", "att_missing"} {
		t.Run("reject "+selector, func(t *testing.T) {
			if _, err := noteAttachmentIndex(attachments, selector); err == nil {
				t.Fatalf("noteAttachmentIndex(%q) succeeded, want error", selector)
			}
		})
	}
}

func TestRemoveNoteAttachments(t *testing.T) {
	attachments := []protocol.Attachment{
		{FileId: "att_one"},
		{FileId: "att_two"},
		{FileId: "att_three"},
	}

	got, err := removeNoteAttachments(attachments, []string{"0", "att_three"})
	if err != nil {
		t.Fatalf("removeNoteAttachments error: %v", err)
	}
	if len(got) != 1 || got[0].FileId != "att_two" {
		t.Fatalf("removeNoteAttachments = %#v, want only att_two", got)
	}
	if len(attachments) != 3 {
		t.Fatalf("removeNoteAttachments mutated input: %#v", attachments)
	}
}

func TestRemoveNoteAttachmentsRejectsDuplicateSelection(t *testing.T) {
	attachments := []protocol.Attachment{{FileId: "att_one"}, {FileId: "att_two"}}
	if _, err := removeNoteAttachments(attachments, []string{"0", "att_one"}); err == nil {
		t.Fatal("removeNoteAttachments succeeded, want duplicate-selection error")
	}
}

func captureStdout(t *testing.T, fn func()) string {
	t.Helper()

	oldStdout := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("Pipe error: %v", err)
	}
	os.Stdout = w

	fn()

	if err := w.Close(); err != nil {
		t.Fatalf("Close writer error: %v", err)
	}
	os.Stdout = oldStdout

	data, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("ReadAll error: %v", err)
	}
	if err := r.Close(); err != nil {
		t.Fatalf("Close reader error: %v", err)
	}
	return string(data)
}

func TestRelatedNoteCandidatesFromEdges(t *testing.T) {
	edges := []protocol.Edge{
		{SourceType: protocol.TargetTypeAsset, SourceID: 10, TargetType: protocol.TargetTypeAsset, TargetID: 20, Relation: protocol.RelationReferences},
		{SourceType: protocol.TargetTypeAsset, SourceID: 30, TargetType: protocol.TargetTypeAsset, TargetID: 10, Relation: protocol.RelationRelatedTo},
		{SourceType: protocol.TargetTypeAsset, SourceID: 10, TargetType: protocol.TargetTypeAsset, TargetID: 20, Relation: protocol.RelationBlocks},
		{SourceType: protocol.TargetTypeAsset, SourceID: 10, TargetType: protocol.TargetTypeTask, TargetID: 40, Relation: protocol.RelationDependsOn},
		{SourceType: protocol.TargetTypeAsset, SourceID: 10, TargetType: protocol.TargetTypeAsset, TargetID: 50, Relation: protocol.RelationSupersedes},
	}

	got := relatedNoteCandidatesFromEdges(edges, 10, 2)
	want := []relatedNoteCandidate{
		{ID: 20, Relation: protocol.RelationReferences},
		{ID: 30, Relation: protocol.RelationRelatedTo},
	}
	if len(got) != len(want) {
		t.Fatalf("candidates = %#v, want %#v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("candidates = %#v, want %#v", got, want)
		}
	}
}

func TestRelatedNoteCandidatesFromEdgesRejectsNonPositiveLimit(t *testing.T) {
	edges := []protocol.Edge{{SourceType: protocol.TargetTypeAsset, SourceID: 10, TargetType: protocol.TargetTypeAsset, TargetID: 20}}
	if got := relatedNoteCandidatesFromEdges(edges, 10, 0); got != nil {
		t.Fatalf("candidates = %#v, want nil", got)
	}
}

func TestNoteContentFromFlagsReadsContentFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "note.md")
	if err := os.WriteFile(path, []byte("# Title\n\nBody\n"), 0o600); err != nil {
		t.Fatalf("WriteFile error: %v", err)
	}

	cmd := testNoteContentCommand()
	if err := cmd.Flags().Set("content-file", path); err != nil {
		t.Fatalf("Set content-file error: %v", err)
	}

	got, err := noteContentFromFlags(cmd, "existing")
	if err != nil {
		t.Fatalf("noteContentFromFlags error: %v", err)
	}
	if got != "# Title\n\nBody\n" {
		t.Fatalf("content = %q, want file body", got)
	}
}

func TestNoteContentFromFlagsRejectsContentAndContentFile(t *testing.T) {
	cmd := testNoteContentCommand()
	if err := cmd.Flags().Set("content", "inline"); err != nil {
		t.Fatalf("Set content error: %v", err)
	}
	if err := cmd.Flags().Set("content-file", "note.md"); err != nil {
		t.Fatalf("Set content-file error: %v", err)
	}

	if _, err := noteContentFromFlags(cmd, "existing"); err == nil {
		t.Fatal("noteContentFromFlags succeeded, want error")
	}
}

func TestApplyNoteUnifiedPatchReplacesContent(t *testing.T) {
	content := "# Title\nOld sentence.\nKeep this.\n"
	patch := `--- note.md
+++ note.md
@@ -1,3 +1,3 @@
 # Title
-Old sentence.
+New sentence.
 Keep this.
`

	got, err := applyNoteUnifiedPatch(content, patch)
	if err != nil {
		t.Fatalf("applyNoteUnifiedPatch error: %v", err)
	}
	want := "# Title\nNew sentence.\nKeep this.\n"
	if got != want {
		t.Fatalf("patched content = %q, want %q", got, want)
	}
}

func TestApplyNoteUnifiedPatchSupportsHeaderlessHunk(t *testing.T) {
	content := "alpha\nbeta\n"
	patch := `@@
 alpha
+inserted
 beta
`

	got, err := applyNoteUnifiedPatch(content, patch)
	if err != nil {
		t.Fatalf("applyNoteUnifiedPatch error: %v", err)
	}
	want := "alpha\ninserted\nbeta\n"
	if got != want {
		t.Fatalf("patched content = %q, want %q", got, want)
	}
}

func TestApplyNoteUnifiedPatchRejectsNonMatchingHunk(t *testing.T) {
	content := "alpha\nbeta\n"
	patch := `@@ -1,2 +1,2 @@
 missing
-beta
+gamma
`

	if _, err := applyNoteUnifiedPatch(content, patch); err == nil {
		t.Fatal("applyNoteUnifiedPatch succeeded, want error")
	}
}

func TestApplyNoteUnifiedPatchHandlesNoTrailingNewline(t *testing.T) {
	content := "alpha\nbeta"
	patch := `@@ -1,2 +1,2 @@
 alpha
-beta
\ No newline at end of file
+gamma
\ No newline at end of file
`

	got, err := applyNoteUnifiedPatch(content, patch)
	if err != nil {
		t.Fatalf("applyNoteUnifiedPatch error: %v", err)
	}
	want := "alpha\ngamma"
	if got != want {
		t.Fatalf("patched content = %q, want %q", got, want)
	}
}

func TestApplyNoteUnifiedPatchInsertsAfterFinalLineWithoutMarker(t *testing.T) {
	content := "alpha\nbeta"
	patch := `@@
 beta
+gamma
`

	got, err := applyNoteUnifiedPatch(content, patch)
	if err != nil {
		t.Fatalf("applyNoteUnifiedPatch error: %v", err)
	}
	want := "alpha\nbeta\ngamma\n"
	if got != want {
		t.Fatalf("patched content = %q, want %q", got, want)
	}
}

func TestApplyNoteUnifiedPatchUsesNumberedHeaderAsPositionHint(t *testing.T) {
	content := "alpha\nbeta\ngamma\n"
	patch := `@@ -10,1 +10,1 @@
-beta
+BETA
`

	got, results, err := applyNoteUnifiedPatchDetailed(content, patch)
	if err != nil {
		t.Fatalf("applyNoteUnifiedPatchDetailed error: %v", err)
	}
	if got != "alpha\nBETA\ngamma\n" {
		t.Fatalf("patched content = %q", got)
	}
	if len(results) != 1 || results[0].Line != 2 || results[0].Offset != -8 {
		t.Fatalf("results = %#v, want line 2 offset -8", results)
	}
}

func TestApplyNoteUnifiedPatchReportsAmbiguousLines(t *testing.T) {
	content := "alpha\ntarget\n\nbeta\ntarget\n"
	patch := `@@
 target
+inserted
`

	_, err := applyNoteUnifiedPatch(content, patch)
	var patchErr *notePatchApplyError
	if !errors.As(err, &patchErr) {
		t.Fatalf("error = %v, want notePatchApplyError", err)
	}
	if patchErr.Kind != "ambiguous" || !slices.Equal(patchErr.CandidateLines, []int{2, 5}) {
		t.Fatalf("patch error = %#v, want ambiguous lines 2 and 5", patchErr)
	}
}

func TestApplyNoteUnifiedPatchReportsNoMatch(t *testing.T) {
	content := "alpha\nbeta\n"
	patch := `@@
 missing
+inserted
`

	_, err := applyNoteUnifiedPatch(content, patch)
	var patchErr *notePatchApplyError
	if !errors.As(err, &patchErr) || patchErr.Kind != "no_match" {
		t.Fatalf("error = %#v, want no_match notePatchApplyError", err)
	}
}

func TestApplyNoteUnifiedPatchIsIdempotent(t *testing.T) {
	content := "alpha\ninserted\nbeta\n"
	patch := `@@
 alpha
+inserted
 beta
`

	got, results, err := applyNoteUnifiedPatchDetailed(content, patch)
	if err != nil {
		t.Fatalf("applyNoteUnifiedPatchDetailed error: %v", err)
	}
	if got != content {
		t.Fatalf("patched content = %q, want unchanged %q", got, content)
	}
	if len(results) != 1 || results[0].Status != "already_applied" {
		t.Fatalf("results = %#v, want already_applied", results)
	}
}

func TestApplyNoteUnifiedPatchHandlesAlreadyAppliedThenPendingHunk(t *testing.T) {
	content := "a\ninserted\nb\nc\n"
	patch := `@@ -1,1 +1,2 @@
 a
+inserted
@@ -3,1 +4,1 @@
-c
+C
`

	got, results, err := applyNoteUnifiedPatchDetailed(content, patch)
	if err != nil {
		t.Fatalf("applyNoteUnifiedPatchDetailed error: %v", err)
	}
	if got != "a\ninserted\nb\nC\n" {
		t.Fatalf("patched content = %q", got)
	}
	if len(results) != 2 || results[0].Status != "already_applied" || results[1].Status != "applied" {
		t.Fatalf("results = %#v, want already_applied then applied", results)
	}
}

func TestApplyNoteUnifiedPatchDoesNotSkipShrinkingHunk(t *testing.T) {
	content := "keep\nremove\n"
	patch := `@@ -1,2 +1,1 @@
 keep
-remove
`

	got, results, err := applyNoteUnifiedPatchDetailed(content, patch)
	if err != nil {
		t.Fatalf("applyNoteUnifiedPatchDetailed error: %v", err)
	}
	if got != "keep\n" || len(results) != 1 || results[0].Status != "applied" {
		t.Fatalf("content/results = %q/%#v, want applied deletion", got, results)
	}
}

func TestApplyNoteUnifiedPatchDoesNotUseRelaxedEOFForPostimage(t *testing.T) {
	content := "new"
	patch := `@@ -1,1 +1,1 @@
-old
+new
`

	got, results, err := applyNoteUnifiedPatchDetailed(content, patch)
	if err != nil {
		t.Fatalf("applyNoteUnifiedPatchDetailed error: %v", err)
	}
	if got != "new\n" || len(results) != 1 || results[0].Status != "applied" {
		t.Fatalf("content/results = %q/%#v, want final newline applied", got, results)
	}
}

func TestApplyNoteUnifiedPatchNormalizesRetriedEOFInsertion(t *testing.T) {
	content := "alpha\ninserted"
	patch := `@@
 alpha
+inserted
`

	got, results, err := applyNoteUnifiedPatchDetailed(content, patch)
	if err != nil {
		t.Fatalf("applyNoteUnifiedPatchDetailed error: %v", err)
	}
	if got != "alpha\ninserted\n" || len(results) != 1 || results[0].Status != "applied" {
		t.Fatalf("content/results = %q/%#v, want normalized postimage", got, results)
	}
}

func TestApplyNoteUnifiedPatchCarriesRelocationToContextFreeHunk(t *testing.T) {
	content := "drift\na\nb\nc\n"
	patch := `@@ -1,1 +1,1 @@
-a
+A
@@ -3,0 +4,1 @@
+inserted
`

	got, results, err := applyNoteUnifiedPatchDetailed(content, patch)
	if err != nil {
		t.Fatalf("applyNoteUnifiedPatchDetailed error: %v", err)
	}
	if got != "drift\nA\nb\nc\ninserted\n" {
		t.Fatalf("patched content = %q", got)
	}
	if len(results) != 2 || results[0].Offset != 1 || results[1].Offset != 1 {
		t.Fatalf("results = %#v, want carried offset +1", results)
	}
}

func TestApplyNoteUnifiedPatchReportsAmbiguousPostimageLines(t *testing.T) {
	content := "new\nother\nnew\n"
	patch := `@@
-old
+new
`

	_, err := applyNoteUnifiedPatch(content, patch)
	var patchErr *notePatchApplyError
	if !errors.As(err, &patchErr) || patchErr.Kind != "ambiguous" || !slices.Equal(patchErr.CandidateLines, []int{1, 3}) {
		t.Fatalf("error = %#v, want ambiguous postimage lines 1 and 3", err)
	}
}

func TestApplyNoteUnifiedPatchHeaderlessDuplicateContextFails(t *testing.T) {
	content := "alpha\ntarget\n\nbeta\ntarget\n"
	patch := `@@
 target
+inserted
`

	if _, err := applyNoteUnifiedPatch(content, patch); err == nil {
		t.Fatal("applyNoteUnifiedPatch succeeded, want duplicate context error")
	}
}

func TestApplyNoteUnifiedPatchZeroContextInsertionUsesHeaderPosition(t *testing.T) {
	content := "a\nb\nc\n"
	patch := `@@ -2,0 +3,1 @@
+X
`

	got, err := applyNoteUnifiedPatch(content, patch)
	if err != nil {
		t.Fatalf("applyNoteUnifiedPatch error: %v", err)
	}
	want := "a\nb\nX\nc\n"
	if got != want {
		t.Fatalf("patched content = %q, want %q", got, want)
	}
}

func TestApplyNoteUnifiedPatchMultiHunkAdjustsHeaderPosition(t *testing.T) {
	content := "a\nb\nc\nd\n"
	patch := `@@ -1,1 +1,2 @@
 a
+inserted
@@ -4,1 +5,1 @@
-d
+D
`

	got, err := applyNoteUnifiedPatch(content, patch)
	if err != nil {
		t.Fatalf("applyNoteUnifiedPatch error: %v", err)
	}
	want := "a\ninserted\nb\nc\nD\n"
	if got != want {
		t.Fatalf("patched content = %q, want %q", got, want)
	}
}

func TestNoteBackupRoundTripUsesXDGStateHome(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	scope := noteBackupScope{Server: "ws://localhost:8080", WorkspaceID: "workspace/test"}
	asset := protocol.Asset{
		AssetID:   123,
		AssetType: protocol.AssetTypeNote,
		Preview:   makeNotePreview("Backup Title", "old content", "proj", []string{"alpha", "beta"}, "html"),
		Payload:   "old content",
		Owner:     "agent",
		UpdatedAt: 456,
	}

	path, err := writeNoteBackup(scope, 7, asset)
	if err != nil {
		t.Fatalf("writeNoteBackup error: %v", err)
	}
	if !strings.Contains(path, filepath.Join("nrc", "note-backups", "workspace-workspace_test")) || !strings.Contains(path, filepath.Join("room-7", "note-123")) {
		t.Fatalf("backup path = %q, want XDG state note backup path", path)
	}

	entries, err := listNoteBackups(scope, 7, 123)
	if err != nil {
		t.Fatalf("listNoteBackups error: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("backup entries = %#v, want one entry", entries)
	}
	if entries[0].Title != "Backup Title" || entries[0].UpdatedAt != 456 {
		t.Fatalf("backup entry = %#v, want title and updated_at", entries[0])
	}

	backup, _, err := latestNoteBackup(scope, 7, 123)
	if err != nil {
		t.Fatalf("latestNoteBackup error: %v", err)
	}
	if backup.Server != scope.Server || backup.WorkspaceID != scope.WorkspaceID || backup.Content != "old content" || backup.Project != "proj" || len(backup.Tags) != 2 || backup.Format != "html" {
		t.Fatalf("backup = %#v, want stored note state", backup)
	}
}

func TestNotePreviewFormatDefaultsAndHTMLTeaser(t *testing.T) {
	legacy := parseNotePreviewJSON(`{"title":"Legacy"}`)
	if legacy.Format != "markdown" {
		t.Fatalf("legacy format = %q, want markdown", legacy.Format)
	}
	p := parseNotePreviewJSON(makeNotePreview("HTML", `<p>Hello <strong>world</strong> &amp; friends</p>`, "", nil, "html"))
	if p.Format != "html" || p.Teaser != "Hello world & friends" {
		t.Fatalf("preview = %#v", p)
	}
}

func TestHTMLNoteText(t *testing.T) {
	content := `<html><head><title>ignored</title><style>.hidden {}</style></head><body><h1>Heading &amp; more</h1><p>Hello <strong>world</strong>.<br>Next line.</p><ul><li>First</li><li>Second <em>item</em></li></ul><script>alert("ignored")</script></body></html>`
	want := "Heading & more\nHello world.\nNext line.\n- First\n- Second item"
	if got := htmlNoteText(content); got != want {
		t.Fatalf("htmlNoteText() = %q, want %q", got, want)
	}
}

func TestHTMLNoteTextPreservesCommonStructures(t *testing.T) {
	content := `<ul><li><p>Item</p></li></ul><table><tr><th>Name</th><th>Value</th></tr><tr><td>A</td><td>B</td></tr></table><dl><dt>Term</dt><dd>Definition</dd></dl><pre>line 1
  indented</pre>`
	want := "- Item\nName\tValue\nA\tB\nTerm\nDefinition\nline 1\n  indented"
	if got := htmlNoteText(content); got != want {
		t.Fatalf("htmlNoteText() = %q, want %q", got, want)
	}
}

func TestNoteTextContentPreservesMarkdown(t *testing.T) {
	content := "# Heading\n\n- item\n"
	if got := noteTextContent(content, "markdown"); got != content {
		t.Fatalf("noteTextContent() = %q, want unchanged markdown", got)
	}
}

func TestValidateNoteTextFlags(t *testing.T) {
	cmd := &cobra.Command{Use: "get"}
	cmd.Flags().Bool("human", false, "")
	cmd.Flags().Bool("json", false, "")
	cmd.Flags().String("fields", "", "")
	cmd.Flags().Bool("pretty", false, "")
	cmd.Flags().Bool("related", true, "")
	cmd.Flags().Int("related-limit", defaultRelatedNoteLimit, "")

	if err := validateNoteTextFlags(cmd); err != nil {
		t.Fatalf("default flags rejected: %v", err)
	}
	if err := cmd.Flags().Set("related", "false"); err != nil {
		t.Fatal(err)
	}
	if err := validateNoteTextFlags(cmd); err != nil {
		t.Fatalf("--related=false rejected: %v", err)
	}
	if err := cmd.Flags().Set("pretty", "true"); err != nil {
		t.Fatal(err)
	}
	if err := validateNoteTextFlags(cmd); err == nil {
		t.Fatal("--pretty accepted with --text")
	}
	if err := cmd.Flags().Set("pretty", "false"); err != nil {
		t.Fatal(err)
	}
	if err := validateNoteTextFlags(cmd); err != nil {
		t.Fatalf("--pretty=false rejected: %v", err)
	}
	if err := cmd.Flags().Set("fields", " , "); err != nil {
		t.Fatal(err)
	}
	if err := validateNoteTextFlags(cmd); err != nil {
		t.Fatalf("empty --fields projection rejected: %v", err)
	}
}

func TestListNoteBackupsReturnsEmptySliceForMissingDirectory(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	entries, err := listNoteBackups(noteBackupScope{Server: "ws://localhost:8080", WorkspaceID: "workspace1"}, 7, 123)
	if err != nil {
		t.Fatalf("listNoteBackups error: %v", err)
	}
	if entries == nil || len(entries) != 0 {
		t.Fatalf("entries = %#v, want empty non-nil slice", entries)
	}
}

func TestNoteBackupByIDRejectsPathTraversal(t *testing.T) {
	if _, _, err := noteBackupByID(noteBackupScope{}, 7, 123, "../bad"); err == nil {
		t.Fatal("noteBackupByID succeeded, want invalid backup id error")
	}
}

func TestWriteNoteBackupRejectsNonNoteAsset(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	_, err := writeNoteBackup(noteBackupScope{}, 7, protocol.Asset{AssetID: 123, AssetType: protocol.AssetTypeDocument})
	if err == nil {
		t.Fatal("writeNoteBackup succeeded, want non-note error")
	}
}

func TestFormatSearchPreviewExtractsNoteJSON(t *testing.T) {
	got := formatSearchPreview(searchResult{
		AssetType: protocol.AssetTypeNote,
		Preview:   `{"title":"nrc deployment on futro","teaser":"nrc is deployed on the t...","project":"ops","tags":["nrc"]}`,
	})
	want := "nrc deployment on futro — (project: ops; tags: nrc) — nrc is deployed on the t..."
	if got != want {
		t.Fatalf("formatSearchPreview() = %q, want %q", got, want)
	}
}

func TestFormatSearchPreviewDeduplicatesNoteTags(t *testing.T) {
	got := formatSearchPreview(searchResult{
		AssetType: protocol.AssetTypeNote,
		Preview:   `{"title":"futro","teaser":"sync files","tags":["nrc", "sync", "nrc"]}`,
	})
	want := "futro — (tags: nrc, sync) — sync files"
	if got != want {
		t.Fatalf("formatSearchPreview() = %q, want %q", got, want)
	}
}

func TestSearchDisplayFieldsExtractsNoteColumns(t *testing.T) {
	got := searchDisplayFields(searchResult{
		AssetType: protocol.AssetTypeNote,
		Preview:   `{"title":"futro","teaser":"sync files","project":"nrc","tags":["deployment", "futro", "deployment"]}`,
	})
	want := searchPreviewFields{Project: "nrc", Tags: "deployment, futro", Title: "futro", Teaser: "sync files"}
	if got != want {
		t.Fatalf("searchDisplayFields() = %#v, want %#v", got, want)
	}
}

func TestFormatSearchPreviewLeavesNonNoteRaw(t *testing.T) {
	got := formatSearchPreview(searchResult{AssetType: protocol.AssetTypeDocument, Preview: ` {"title":"raw"} `})
	want := `{"title":"raw"}`
	if got != want {
		t.Fatalf("formatSearchPreview() = %q, want %q", got, want)
	}
}
