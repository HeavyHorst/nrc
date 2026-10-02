package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/heavyhorst/nrc/cli/pkg/config"
	conn "github.com/heavyhorst/nrc/cli/pkg/conn"
	"github.com/heavyhorst/nrc/cli/pkg/output"
	"github.com/heavyhorst/nrc/cli/pkg/upload"
	protocol "github.com/heavyhorst/nrc/protocol-go"
	"github.com/olekukonko/tablewriter"
	"github.com/spf13/cobra"
	"golang.org/x/net/html"
)

type notePreview struct {
	Title   string   `json:"title"`
	Teaser  string   `json:"teaser"`
	Project string   `json:"project"`
	Tags    []string `json:"tags"`
	Format  string   `json:"format,omitempty"`
}

const (
	defaultNoteListPageSize = 50
	maxNoteListPageSize     = 250
	defaultRelatedNoteLimit = 20
)

type noteCursor struct {
	UpdatedAt int64
	AssetID   uint64
}

type noteEntry struct {
	ID        uint64   `json:"id"`
	Title     string   `json:"title"`
	Teaser    string   `json:"teaser"`
	Project   string   `json:"project"`
	Tags      []string `json:"tags"`
	Format    string   `json:"format"`
	Owner     string   `json:"owner"`
	UpdatedAt int64    `json:"updated_at"`
	Updated   string   `json:"updated"`
}

type relatedNoteEntry struct {
	ID       uint64 `json:"id"`
	Title    string `json:"title"`
	Relation string `json:"relation"`
}

type relatedNoteCandidate struct {
	ID       uint64
	Relation uint16
}

type noteListOptions struct {
	Project       string
	Tag           string
	Limit         int
	PageSize      int
	All           bool
	HasCursor     bool
	CursorUpdated int64
	CursorAssetID uint64
}

type noteListResult struct {
	Notes       []noteEntry `json:"notes"`
	Count       int         `json:"count"`
	TotalCount  uint32      `json:"total_count"`
	HasMore     bool        `json:"has_more"`
	NextCursor  string      `json:"next_cursor"`
	PageSize    int         `json:"page_size"`
	Project     string      `json:"project,omitempty"`
	Tag         string      `json:"tag,omitempty"`
	Limit       int         `json:"limit,omitempty"`
	All         bool        `json:"all,omitempty"`
	cursorState noteCursor
}

type noteBackup struct {
	BackupID    string   `json:"backup_id"`
	Server      string   `json:"server"`
	WorkspaceID string   `json:"workspace_id"`
	RoomID      int64    `json:"room_id"`
	NoteID      uint64   `json:"note_id"`
	AssetID     uint64   `json:"asset_id"`
	UpdatedAt   int64    `json:"updated_at"`
	CreatedAt   int64    `json:"created_at"`
	Owner       string   `json:"owner"`
	Title       string   `json:"title"`
	Project     string   `json:"project"`
	Tags        []string `json:"tags"`
	Content     string   `json:"content"`
	Format      string   `json:"format"`
}

type noteBackupEntry struct {
	BackupID    string `json:"backup_id"`
	Path        string `json:"path"`
	Server      string `json:"server"`
	WorkspaceID string `json:"workspace_id"`
	RoomID      int64  `json:"room_id"`
	NoteID      uint64 `json:"note_id"`
	UpdatedAt   int64  `json:"updated_at"`
	CreatedAt   int64  `json:"created_at"`
	Title       string `json:"title"`
	Format      string `json:"format"`
}

type noteBackupScope struct {
	Server      string
	WorkspaceID string
}

type notePatchLine struct {
	Op   byte
	Text string
}

type notePatchHunk struct {
	HasHeader bool
	OldStart  int
	OldCount  int
	NewCount  int
	Lines     []notePatchLine
}

type notePatchHunkResult struct {
	Hunk   int    `json:"hunk"`
	Status string `json:"status"`
	Line   int    `json:"line"`
	Offset int    `json:"offset,omitempty"`
}

type notePatchApplyError struct {
	Hunk           int    `json:"hunk"`
	Kind           string `json:"kind"`
	ExpectedLine   int    `json:"expected_line,omitempty"`
	CandidateLines []int  `json:"candidate_lines,omitempty"`
}

func (e *notePatchApplyError) Error() string {
	switch e.Kind {
	case "ambiguous":
		return fmt.Sprintf("hunk %d is ambiguous; context matches at lines %s", e.Hunk, formatNotePatchLineNumbers(e.CandidateLines))
	case "no_position":
		return fmt.Sprintf("hunk %d has no context and requires a numbered header", e.Hunk)
	default:
		if e.ExpectedLine > 0 {
			return fmt.Sprintf("hunk %d has no matching context (expected near line %d)", e.Hunk, e.ExpectedLine)
		}
		return fmt.Sprintf("hunk %d has no matching context", e.Hunk)
	}
}

func normalizeNoteTags(values []string) []string {
	tags := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		for _, part := range strings.Split(value, ",") {
			tag := strings.TrimSpace(part)
			if tag == "" {
				continue
			}
			if _, ok := seen[tag]; ok {
				continue
			}
			seen[tag] = struct{}{}
			tags = append(tags, tag)
		}
	}
	return tags
}

func normalizeNoteFormat(format string) (string, error) {
	format = strings.ToLower(strings.TrimSpace(format))
	if format == "" {
		return "markdown", nil
	}
	if format != "markdown" && format != "html" {
		return "", fmt.Errorf("format must be markdown or html")
	}
	return format, nil
}

func htmlNoteText(content string) string {
	doc, err := html.Parse(strings.NewReader(content))
	if err != nil {
		return content
	}

	var out strings.Builder
	pendingSpace := false
	lineHasText := false
	writeText := func(text string) {
		fields := strings.Fields(text)
		if len(fields) == 0 {
			pendingSpace = pendingSpace || text != ""
			return
		}
		leadingSpace := len(strings.TrimLeftFunc(text, unicode.IsSpace)) != len(text)
		if out.Len() > 0 && (pendingSpace || leadingSpace) && out.String()[out.Len()-1] != '\n' {
			out.WriteByte(' ')
		}
		out.WriteString(strings.Join(fields, " "))
		pendingSpace = len(strings.TrimRightFunc(text, unicode.IsSpace)) != len(text)
		lineHasText = true
	}
	writeNewline := func() {
		pendingSpace = false
		if lineHasText && out.String()[out.Len()-1] != '\n' {
			out.WriteByte('\n')
		}
		lineHasText = false
	}

	var walk func(*html.Node)
	walk = func(node *html.Node) {
		if node.Type == html.ElementNode && (node.Data == "script" || node.Data == "style" || node.Data == "head") {
			return
		}
		if node.Type == html.TextNode {
			writeText(node.Data)
			return
		}

		if node.Type == html.ElementNode && node.Data == "pre" {
			writeNewline()
			var pre strings.Builder
			var collectText func(*html.Node)
			collectText = func(current *html.Node) {
				if current.Type == html.TextNode {
					pre.WriteString(current.Data)
				}
				for child := current.FirstChild; child != nil; child = child.NextSibling {
					collectText(child)
				}
			}
			collectText(node)
			value := strings.Trim(pre.String(), "\n")
			if value != "" {
				out.WriteString(value)
				lineHasText = true
			}
			writeNewline()
			return
		}

		block := node.Type == html.ElementNode && slices.Contains([]string{"address", "article", "aside", "blockquote", "dd", "div", "dl", "dt", "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "li", "main", "nav", "ol", "p", "section", "table", "tr", "ul"}, node.Data)
		if block {
			writeNewline()
		}
		if node.Type == html.ElementNode && node.Data == "li" {
			out.WriteString("- ")
		}
		if node.Type == html.ElementNode && (node.Data == "td" || node.Data == "th") && lineHasText {
			out.WriteByte('\t')
			pendingSpace = false
		}
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			walk(child)
		}
		if block || node.Type == html.ElementNode && node.Data == "br" {
			writeNewline()
		}
	}
	walk(doc)
	return strings.TrimSpace(out.String())
}

func noteTextContent(content, format string) string {
	if format == "html" {
		return htmlNoteText(content)
	}
	return content
}

func noteTeaser(content, format string) string {
	teaser := content
	if format == "html" {
		teaser = strings.Join(strings.Fields(htmlNoteText(teaser)), " ")
	}
	if len(teaser) > 200 {
		teaser = teaser[:200] + "…"
	}
	return teaser
}

func makeNotePreview(title, content, project string, tags []string, format string) string {
	format, _ = normalizeNoteFormat(format)
	data, _ := json.Marshal(notePreview{Title: title, Teaser: noteTeaser(content, format), Project: strings.TrimSpace(project), Tags: normalizeNoteTags(tags), Format: format})
	return string(data)
}

func readNoteContentFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func noteContentFromFlags(cmd *cobra.Command, current string) (string, error) {
	content, _ := cmd.Flags().GetString("content")
	contentFile, _ := cmd.Flags().GetString("content-file")
	contentChanged := cmd.Flags().Changed("content")
	contentFileChanged := cmd.Flags().Changed("content-file")

	if contentChanged && contentFileChanged {
		return "", fmt.Errorf("use either --content or --content-file, not both")
	}
	if contentFileChanged {
		if strings.TrimSpace(contentFile) == "" {
			return "", fmt.Errorf("--content-file requires a path")
		}
		return readNoteContentFile(contentFile)
	}
	if contentChanged {
		return content, nil
	}
	return current, nil
}

func splitNotePatchLines(s string) []string {
	if s == "" {
		return nil
	}
	return strings.SplitAfter(s, "\n")
}

func parseNotePatchRange(field string) (start, count int, err error) {
	value := strings.TrimPrefix(field, "-")
	value = strings.TrimPrefix(value, "+")
	if comma := strings.IndexByte(value, ','); comma >= 0 {
		start, err = strconv.Atoi(value[:comma])
		if err != nil {
			return 0, 0, err
		}
		count, err = strconv.Atoi(value[comma+1:])
		if err != nil {
			return 0, 0, err
		}
		return start, count, nil
	}

	start, err = strconv.Atoi(value)
	if err != nil {
		return 0, 0, err
	}
	return start, 1, nil
}

func parseNotePatchHeader(header string) (notePatchHunk, error) {
	if strings.TrimSpace(header) == "@@" {
		return notePatchHunk{}, nil
	}

	end := strings.Index(header[2:], "@@")
	if end < 0 {
		return notePatchHunk{}, fmt.Errorf("invalid hunk header %q", strings.TrimSpace(header))
	}
	fields := strings.Fields(strings.TrimSpace(header[2 : 2+end]))
	if len(fields) < 2 || !strings.HasPrefix(fields[0], "-") || !strings.HasPrefix(fields[1], "+") {
		return notePatchHunk{}, fmt.Errorf("invalid hunk header %q", strings.TrimSpace(header))
	}

	oldStart, oldCount, err := parseNotePatchRange(fields[0])
	if err != nil || oldStart < 0 || oldCount < 0 {
		return notePatchHunk{}, fmt.Errorf("invalid old range in hunk header %q", strings.TrimSpace(header))
	}
	_, newCount, err := parseNotePatchRange(fields[1])
	if err != nil || newCount < 0 {
		return notePatchHunk{}, fmt.Errorf("invalid new range in hunk header %q", strings.TrimSpace(header))
	}

	return notePatchHunk{HasHeader: true, OldStart: oldStart, OldCount: oldCount, NewCount: newCount}, nil
}

func stripNotePatchLineEnding(s string) string {
	if strings.HasSuffix(s, "\r\n") {
		return s[:len(s)-2]
	}
	if strings.HasSuffix(s, "\n") {
		return s[:len(s)-1]
	}
	return s
}

func parseNoteUnifiedPatch(patch string) ([]notePatchHunk, error) {
	lines := splitNotePatchLines(patch)
	hunks := make([]notePatchHunk, 0)
	var current *notePatchHunk

	for _, line := range lines {
		if strings.HasPrefix(line, "@@") {
			hunk, err := parseNotePatchHeader(line)
			if err != nil {
				return nil, err
			}
			hunks = append(hunks, hunk)
			current = &hunks[len(hunks)-1]
			continue
		}

		if current == nil {
			continue
		}
		if strings.HasPrefix(line, `\ No newline at end of file`) {
			if len(current.Lines) == 0 {
				return nil, fmt.Errorf("misplaced no-newline marker")
			}
			previous := &current.Lines[len(current.Lines)-1]
			previous.Text = stripNotePatchLineEnding(previous.Text)
			continue
		}
		if line == "" {
			continue
		}

		op := line[0]
		if op != ' ' && op != '+' && op != '-' {
			return nil, fmt.Errorf("invalid patch line %q", line)
		}
		current.Lines = append(current.Lines, notePatchLine{Op: op, Text: line[1:]})
	}

	if len(hunks) == 0 {
		return nil, fmt.Errorf("patch contains no hunks")
	}
	for i, hunk := range hunks {
		if !hunk.HasHeader {
			continue
		}
		oldCount := 0
		newCount := 0
		for _, line := range hunk.Lines {
			if line.Op != '+' {
				oldCount++
			}
			if line.Op != '-' {
				newCount++
			}
		}
		if oldCount != hunk.OldCount || newCount != hunk.NewCount {
			return nil, fmt.Errorf("hunk %d line count does not match header", i+1)
		}
	}
	return hunks, nil
}

func notePatchLinesMatch(lines, want []string, pos int, relaxedEOF bool) bool {
	if pos < 0 || pos+len(want) > len(lines) {
		return false
	}
	for i := range want {
		if lines[pos+i] == want[i] {
			continue
		}
		// Hand-written patches usually cannot express that the note's final
		// line has no newline. Treat that one terminator difference as equal.
		if relaxedEOF &&
			pos+i == len(lines)-1 &&
			!strings.HasSuffix(lines[pos+i], "\n") &&
			stripNotePatchLineEnding(want[i]) == lines[pos+i] {
			continue
		}
		{
			return false
		}
	}
	return true
}

func notePatchFindLines(lines, want []string, relaxedEOF bool) []int {
	if len(want) == 0 {
		return nil
	}
	matches := make([]int, 0, 1)
	for i := 0; i+len(want) <= len(lines); i++ {
		if notePatchLinesMatch(lines, want, i, relaxedEOF) {
			matches = append(matches, i)
		}
	}
	return matches
}

func notePatchContainsPosition(positions []int, want int) bool {
	for _, pos := range positions {
		if pos == want {
			return true
		}
	}
	return false
}

func notePatchLineNumbers(positions []int) []int {
	lines := make([]int, len(positions))
	for i, pos := range positions {
		lines[i] = pos + 1
	}
	return lines
}

func formatNotePatchLineNumbers(lines []int) string {
	const maxLines = 5
	parts := make([]string, 0, min(len(lines), maxLines))
	for i, line := range lines {
		if i == maxLines {
			parts = append(parts, fmt.Sprintf("and %d more", len(lines)-maxLines))
			break
		}
		parts = append(parts, strconv.Itoa(line))
	}
	return strings.Join(parts, ", ")
}

func applyNoteUnifiedPatchDetailed(content, patch string) (string, []notePatchHunkResult, error) {
	hunks, err := parseNoteUnifiedPatch(patch)
	if err != nil {
		return "", nil, err
	}

	lines := splitNotePatchLines(content)
	results := make([]notePatchHunkResult, 0, len(hunks))
	lineDelta := 0
	carriedOffset := 0
	for hunkIndex, hunk := range hunks {
		oldLines := make([]string, 0, len(hunk.Lines))
		newLines := make([]string, 0, len(hunk.Lines))
		for _, line := range hunk.Lines {
			if line.Op != '+' {
				oldLines = append(oldLines, line.Text)
			}
			if line.Op != '-' {
				newLines = append(newLines, line.Text)
			}
		}

		headerPos := -1
		expectedPos := -1
		if hunk.HasHeader {
			if hunk.OldCount == 0 {
				headerPos = hunk.OldStart + lineDelta
			} else {
				headerPos = hunk.OldStart - 1 + lineDelta
			}
			expectedPos = headerPos + carriedOffset
		}

		oldMatches := notePatchFindLines(lines, oldLines, true)
		newMatches := notePatchFindLines(lines, newLines, false)
		relaxedNewMatches := notePatchFindLines(lines, newLines, true)
		pos := -1
		alreadyApplied := false
		normalizePostimage := false
		postimageIsEvidence := len(newLines) > 0
		postimageWinsOverPreimage := len(newLines) > len(oldLines) || slices.Equal(newLines, oldLines)

		if expectedPos >= 0 && postimageIsEvidence && notePatchLinesMatch(lines, newLines, expectedPos, false) && !notePatchLinesMatch(lines, oldLines, expectedPos, true) {
			pos = expectedPos
			alreadyApplied = true
		} else if expectedPos >= 0 && notePatchLinesMatch(lines, oldLines, expectedPos, true) {
			pos = expectedPos
			alreadyApplied = postimageIsEvidence && postimageWinsOverPreimage && notePatchContainsPosition(newMatches, pos)
			normalizePostimage = postimageIsEvidence && !alreadyApplied && notePatchContainsPosition(relaxedNewMatches, pos) && !notePatchContainsPosition(newMatches, pos)
		} else if len(oldMatches) == 1 {
			pos = oldMatches[0]
			alreadyApplied = postimageIsEvidence && postimageWinsOverPreimage && notePatchContainsPosition(newMatches, pos)
			normalizePostimage = postimageIsEvidence && !alreadyApplied && notePatchContainsPosition(relaxedNewMatches, pos) && !notePatchContainsPosition(newMatches, pos)
		} else if len(oldMatches) == 0 && postimageIsEvidence && len(newMatches) == 1 {
			pos = newMatches[0]
			alreadyApplied = true
		} else if len(oldMatches) == 0 && postimageIsEvidence && len(newMatches) == 0 && len(relaxedNewMatches) == 1 {
			pos = relaxedNewMatches[0]
			normalizePostimage = true
		} else if len(oldMatches) > 1 {
			if postimageIsEvidence && len(newMatches) == 1 &&
				(!notePatchContainsPosition(oldMatches, newMatches[0]) || postimageWinsOverPreimage) {
				pos = newMatches[0]
				alreadyApplied = true
			} else {
				return "", nil, &notePatchApplyError{
					Hunk:           hunkIndex + 1,
					Kind:           "ambiguous",
					ExpectedLine:   expectedPos + 1,
					CandidateLines: notePatchLineNumbers(oldMatches),
				}
			}
		} else if len(newMatches) > 1 {
			return "", nil, &notePatchApplyError{
				Hunk:           hunkIndex + 1,
				Kind:           "ambiguous",
				ExpectedLine:   expectedPos + 1,
				CandidateLines: notePatchLineNumbers(newMatches),
			}
		} else {
			kind := "no_match"
			if len(oldLines) == 0 && expectedPos < 0 {
				kind = "no_position"
			}
			return "", nil, &notePatchApplyError{Hunk: hunkIndex + 1, Kind: kind, ExpectedLine: expectedPos + 1}
		}

		offset := 0
		if headerPos >= 0 {
			offset = pos - headerPos
			carriedOffset = offset
		}
		status := "applied"
		if alreadyApplied {
			status = "already_applied"
		} else {
			replacedCount := len(oldLines)
			if normalizePostimage {
				replacedCount = len(newLines)
			}
			updated := make([]string, 0, len(lines)-replacedCount+len(newLines))
			updated = append(updated, lines[:pos]...)
			updated = append(updated, newLines...)
			updated = append(updated, lines[pos+replacedCount:]...)
			lines = updated
		}
		results = append(results, notePatchHunkResult{Hunk: hunkIndex + 1, Status: status, Line: pos + 1, Offset: offset})
		lineDelta += len(newLines) - len(oldLines)
	}

	return strings.Join(lines, ""), results, nil
}

func applyNoteUnifiedPatch(content, patch string) (string, error) {
	updated, _, err := applyNoteUnifiedPatchDetailed(content, patch)
	return updated, err
}

func readNotePatchFromFlags(cmd *cobra.Command) (string, error) {
	patchFile, _ := cmd.Flags().GetString("patch-file")
	if strings.TrimSpace(patchFile) != "" {
		data, err := os.ReadFile(patchFile)
		if err != nil {
			return "", err
		}
		return string(data), nil
	}

	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func noteBackupRootDir() (string, error) {
	if stateHome := strings.TrimSpace(os.Getenv("XDG_STATE_HOME")); stateHome != "" {
		return filepath.Join(stateHome, "nrc", "note-backups"), nil
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".local", "state", "nrc", "note-backups"), nil
}

func noteBackupScopeFromConfig(cfg *config.Config) noteBackupScope {
	if cfg == nil {
		return noteBackupScope{}
	}
	return noteBackupScope{Server: cfg.Server, WorkspaceID: cfg.WorkspaceID}
}

func noteBackupScopeFromSession(s *conn.Session) noteBackupScope {
	if s == nil {
		return noteBackupScope{}
	}
	return noteBackupScopeFromConfig(s.Config)
}

func noteBackupSafeSegment(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return "default"
	}
	var b strings.Builder
	for _, r := range value {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_' || r == '.' {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	return b.String()
}

func noteBackupServerSegment(server string) string {
	sum := sha256.Sum256([]byte(server))
	return fmt.Sprintf("server-%x", sum[:8])
}

func noteBackupDir(scope noteBackupScope, roomID int64, noteID uint64) (string, error) {
	root, err := noteBackupRootDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(
		root,
		"workspace-"+noteBackupSafeSegment(scope.WorkspaceID),
		noteBackupServerSegment(scope.Server),
		fmt.Sprintf("room-%d", roomID),
		fmt.Sprintf("note-%d", noteID),
	), nil
}

func noteBackupPath(scope noteBackupScope, roomID int64, noteID uint64, backupID string) (string, error) {
	dir, err := noteBackupDir(scope, roomID, noteID)
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, backupID+".json"), nil
}

func validNoteBackupID(backupID string) bool {
	backupID = strings.TrimSpace(backupID)
	if backupID == "" || backupID != filepath.Base(backupID) || strings.Contains(backupID, "..") {
		return false
	}
	for _, r := range backupID {
		if (r >= '0' && r <= '9') || r == 'T' || r == 'Z' || r == '.' || r == '-' {
			continue
		}
		return false
	}
	return true
}

func writeNoteBackup(scope noteBackupScope, roomID int64, asset protocol.Asset) (string, error) {
	if asset.AssetType != protocol.AssetTypeNote {
		return "", fmt.Errorf("asset %d is not a note", asset.AssetID)
	}
	p := parseNotePreviewJSON(asset.Preview)
	createdAt := time.Now().UTC()
	baseBackupID := createdAt.Format("20060102T150405.000000000Z")
	dir, err := noteBackupDir(scope, roomID, asset.AssetID)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}

	for attempt := 0; attempt < 100; attempt++ {
		backupID := baseBackupID
		if attempt > 0 {
			backupID = fmt.Sprintf("%s-%02d", baseBackupID, attempt)
		}
		backup := noteBackup{
			BackupID:    backupID,
			Server:      scope.Server,
			WorkspaceID: scope.WorkspaceID,
			RoomID:      roomID,
			NoteID:      asset.AssetID,
			AssetID:     asset.AssetID,
			UpdatedAt:   asset.UpdatedAt,
			CreatedAt:   createdAt.UnixNano(),
			Owner:       asset.Owner,
			Title:       p.Title,
			Project:     p.Project,
			Tags:        normalizeNoteTags(p.Tags),
			Content:     asset.Payload,
			Format:      p.Format,
		}

		path := filepath.Join(dir, backupID+".json")
		file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if os.IsExist(err) {
			continue
		}
		if err != nil {
			return "", err
		}
		encoder := json.NewEncoder(file)
		encoder.SetIndent("", "  ")
		encodeErr := encoder.Encode(backup)
		closeErr := file.Close()
		if encodeErr != nil {
			return "", encodeErr
		}
		if closeErr != nil {
			return "", closeErr
		}
		return path, nil
	}
	return "", fmt.Errorf("could not allocate unique note backup id")
}

func readNoteBackup(path string) (noteBackup, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return noteBackup{}, err
	}
	var backup noteBackup
	if err := json.Unmarshal(data, &backup); err != nil {
		return noteBackup{}, err
	}
	return backup, nil
}

func listNoteBackups(scope noteBackupScope, roomID int64, noteID uint64) ([]noteBackupEntry, error) {
	dir, err := noteBackupDir(scope, roomID, noteID)
	if err != nil {
		return nil, err
	}
	files, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return []noteBackupEntry{}, nil
		}
		return nil, err
	}

	entries := make([]noteBackupEntry, 0, len(files))
	for _, file := range files {
		if file.IsDir() || !strings.HasSuffix(file.Name(), ".json") {
			continue
		}
		path := filepath.Join(dir, file.Name())
		backup, err := readNoteBackup(path)
		if err != nil {
			continue
		}
		entries = append(entries, noteBackupEntry{
			BackupID:    backup.BackupID,
			Path:        path,
			Server:      backup.Server,
			WorkspaceID: backup.WorkspaceID,
			RoomID:      backup.RoomID,
			NoteID:      backup.NoteID,
			UpdatedAt:   backup.UpdatedAt,
			CreatedAt:   backup.CreatedAt,
			Title:       backup.Title,
			Format:      backup.Format,
		})
	}

	sort.Slice(entries, func(i, j int) bool {
		if entries[i].CreatedAt != entries[j].CreatedAt {
			return entries[i].CreatedAt > entries[j].CreatedAt
		}
		return entries[i].BackupID > entries[j].BackupID
	})
	return entries, nil
}

func latestNoteBackup(scope noteBackupScope, roomID int64, noteID uint64) (noteBackup, string, error) {
	entries, err := listNoteBackups(scope, roomID, noteID)
	if err != nil {
		return noteBackup{}, "", err
	}
	if len(entries) == 0 {
		return noteBackup{}, "", fmt.Errorf("no backups found for note %d in room %d", noteID, roomID)
	}
	backup, err := readNoteBackup(entries[0].Path)
	return backup, entries[0].Path, err
}

func noteBackupByID(scope noteBackupScope, roomID int64, noteID uint64, backupID string) (noteBackup, string, error) {
	backupID = strings.TrimSpace(backupID)
	if !validNoteBackupID(backupID) {
		return noteBackup{}, "", fmt.Errorf("invalid backup id %q", backupID)
	}
	path, err := noteBackupPath(scope, roomID, noteID, backupID)
	if err != nil {
		return noteBackup{}, "", err
	}
	backup, err := readNoteBackup(path)
	return backup, path, err
}

func parseNotePreviewJSON(s string) notePreview {
	var p notePreview
	json.Unmarshal([]byte(s), &p)
	p.Format, _ = normalizeNoteFormat(p.Format)
	return p
}

func noteEntryFromAsset(asset protocol.Asset) noteEntry {
	p := parseNotePreviewJSON(asset.Preview)
	return noteEntry{
		ID:        asset.AssetID,
		Title:     p.Title,
		Teaser:    p.Teaser,
		Project:   p.Project,
		Tags:      normalizeNoteTags(p.Tags),
		Format:    p.Format,
		Owner:     asset.Owner,
		UpdatedAt: asset.UpdatedAt,
		Updated:   time.Unix(0, asset.UpdatedAt).Format(time.DateTime),
	}
}

func relatedNoteCandidatesFromEdges(edges []protocol.Edge, noteID uint64, limit int) []relatedNoteCandidate {
	if limit <= 0 {
		return nil
	}

	candidates := make([]relatedNoteCandidate, 0, limit)
	seen := make(map[uint64]struct{}, limit)
	for _, edge := range edges {
		var relatedID uint64
		if edge.SourceType == protocol.TargetTypeAsset && edge.SourceID == noteID && edge.TargetType == protocol.TargetTypeAsset {
			relatedID = edge.TargetID
		} else if edge.TargetType == protocol.TargetTypeAsset && edge.TargetID == noteID && edge.SourceType == protocol.TargetTypeAsset {
			relatedID = edge.SourceID
		}

		if relatedID == 0 || relatedID == noteID {
			continue
		}
		if _, ok := seen[relatedID]; ok {
			continue
		}

		seen[relatedID] = struct{}{}
		candidates = append(candidates, relatedNoteCandidate{ID: relatedID, Relation: edge.Relation})
		if len(candidates) >= limit {
			break
		}
	}
	return candidates
}

func fetchAsset(s *conn.Session, assetID uint64) (protocol.Asset, error) {
	resp, err := s.SendAndRecv(&protocol.Message{
		Opcode: protocol.C_GetAsset,
		Data:   protocol.EncodeGetAsset(s.RoomID, assetID),
	})
	if err != nil {
		return protocol.Asset{}, err
	}
	if resp.Opcode != protocol.S_AssetFull {
		return protocol.Asset{}, fmt.Errorf("unexpected response: %d", resp.Opcode)
	}
	return protocol.DecodeAssetFull(resp.Data)
}

func fetchRelatedNotes(s *conn.Session, noteID uint64, limit int) []relatedNoteEntry {
	if limit <= 0 {
		return nil
	}

	resp, err := s.SendAndRecv(&protocol.Message{
		Opcode: protocol.C_GraphQuery,
		Data:   protocol.EncodeGraphQuery(s.RoomID, protocol.TargetTypeAsset, noteID, 1, 0, 0, 0),
	})
	if err != nil || resp.Opcode != protocol.S_GraphQueryResult {
		return nil
	}

	result, err := protocol.DecodeGraphQueryResult(resp.Data)
	if err != nil {
		return nil
	}

	candidates := relatedNoteCandidatesFromEdges(result.Edges, noteID, limit)
	related := make([]relatedNoteEntry, 0, len(candidates))
	for _, candidate := range candidates {
		asset, err := fetchAsset(s, candidate.ID)
		if err != nil || asset.AssetType != protocol.AssetTypeNote {
			continue
		}
		preview := parseNotePreviewJSON(asset.Preview)
		title := strings.TrimSpace(preview.Title)
		if title == "" {
			title = fmt.Sprintf("Note %d", asset.AssetID)
		}
		related = append(related, relatedNoteEntry{
			ID:       asset.AssetID,
			Title:    title,
			Relation: relationName(candidate.Relation),
		})
	}
	return related
}

func printRelatedNotes(related []relatedNoteEntry) {
	if len(related) == 0 {
		return
	}

	fmt.Println("\n## Verwandte Notizen")
	for _, note := range related {
		fmt.Printf("#%d: %s\n", note.ID, note.Title)
	}
}

func encodeNoteCursor(updatedAt int64, assetID uint64) string {
	if updatedAt == 0 && assetID == 0 {
		return ""
	}
	raw := fmt.Sprintf("%d:%d", updatedAt, assetID)
	return base64.RawURLEncoding.EncodeToString([]byte(raw))
}

func decodeNoteCursor(cursor string) (noteCursor, error) {
	decoded, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(cursor))
	if err != nil {
		return noteCursor{}, fmt.Errorf("invalid cursor encoding")
	}

	parts := strings.SplitN(string(decoded), ":", 2)
	if len(parts) != 2 {
		return noteCursor{}, fmt.Errorf("invalid cursor format")
	}

	updatedAt, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return noteCursor{}, fmt.Errorf("invalid cursor timestamp")
	}
	assetID, err := strconv.ParseUint(parts[1], 10, 64)
	if err != nil {
		return noteCursor{}, fmt.Errorf("invalid cursor asset id")
	}
	if updatedAt == 0 || assetID == 0 {
		return noteCursor{}, fmt.Errorf("invalid empty cursor")
	}

	return noteCursor{UpdatedAt: updatedAt, AssetID: assetID}, nil
}

func parseNoteListOptions(project, tag string, limit, pageSize int, cursor string, all bool) (noteListOptions, error) {
	project = strings.TrimSpace(project)
	tag = strings.TrimSpace(tag)
	if project != "" && tag != "" {
		return noteListOptions{}, fmt.Errorf("use either --project or --tag, not both")
	}
	if limit < 0 {
		return noteListOptions{}, fmt.Errorf("--limit must be >= 0")
	}
	if pageSize <= 0 {
		return noteListOptions{}, fmt.Errorf("--page-size must be between 1 and %d", maxNoteListPageSize)
	}
	if pageSize > maxNoteListPageSize {
		return noteListOptions{}, fmt.Errorf("--page-size must be between 1 and %d", maxNoteListPageSize)
	}
	if all && limit > 0 {
		return noteListOptions{}, fmt.Errorf("use either --all or --limit, not both")
	}
	if all && strings.TrimSpace(cursor) != "" {
		return noteListOptions{}, fmt.Errorf("use either --all or --cursor, not both")
	}

	opts := noteListOptions{
		Project:  project,
		Tag:      tag,
		Limit:    limit,
		PageSize: pageSize,
		All:      all,
	}
	if strings.TrimSpace(cursor) != "" {
		parsed, err := decodeNoteCursor(cursor)
		if err != nil {
			return noteListOptions{}, err
		}
		opts.HasCursor = true
		opts.CursorUpdated = parsed.UpdatedAt
		opts.CursorAssetID = parsed.AssetID
	}

	return opts, nil
}

func fetchNoteListPage(s *conn.Session, opts noteListOptions, pageLimit int, hasCursor bool, cursor noteCursor) (*protocol.AssetListPageResponse, error) {
	opcode := protocol.C_ListAssetsPaged
	payload := protocol.EncodeListAssetsPaged(s.RoomID, protocol.AssetTypeNote, false, uint16(pageLimit), hasCursor, cursor.UpdatedAt, cursor.AssetID)
	if opts.Project != "" {
		opcode = protocol.C_ListAssetsPagedByProject
		payload = protocol.EncodeListAssetsPagedByProject(s.RoomID, protocol.AssetTypeNote, false, uint16(pageLimit), hasCursor, cursor.UpdatedAt, cursor.AssetID, opts.Project)
	} else if opts.Tag != "" {
		opcode = protocol.C_ListAssetsPagedByTag
		payload = protocol.EncodeListAssetsPagedByTag(s.RoomID, protocol.AssetTypeNote, false, uint16(pageLimit), hasCursor, cursor.UpdatedAt, cursor.AssetID, opts.Tag)
	}

	resp, err := s.SendAndRecv(&protocol.Message{Opcode: opcode, Data: payload})
	if err != nil {
		return nil, err
	}
	if resp.Opcode != protocol.S_AssetListPage {
		return nil, fmt.Errorf("unexpected response: %d", resp.Opcode)
	}

	page, err := protocol.DecodeAssetListPage(resp.Data)
	if err != nil {
		return nil, fmt.Errorf("parsing paged notes: %w", err)
	}
	return page, nil
}

func listPagedNotes(s *conn.Session, opts noteListOptions) (*noteListResult, error) {
	result := &noteListResult{
		Notes:    make([]noteEntry, 0),
		PageSize: opts.PageSize,
		Project:  opts.Project,
		Tag:      opts.Tag,
		Limit:    opts.Limit,
		All:      opts.All,
	}

	remaining := opts.Limit
	hasCursor := opts.HasCursor
	cursor := noteCursor{UpdatedAt: opts.CursorUpdated, AssetID: opts.CursorAssetID}

	for {
		pageLimit := opts.PageSize
		if !opts.All && remaining > 0 && remaining < pageLimit {
			pageLimit = remaining
		}

		page, err := fetchNoteListPage(s, opts, pageLimit, hasCursor, cursor)
		if err != nil {
			return nil, err
		}

		for _, asset := range page.Assets {
			result.Notes = append(result.Notes, noteEntryFromAsset(asset))
		}
		result.Count = len(result.Notes)
		result.TotalCount = page.TotalCount
		result.HasMore = page.HasMore
		result.cursorState = noteCursor{UpdatedAt: page.NextCursorUpdatedAt, AssetID: page.NextCursorAssetID}
		result.NextCursor = encodeNoteCursor(page.NextCursorUpdatedAt, page.NextCursorAssetID)

		if !page.HasMore || len(page.Assets) == 0 {
			result.HasMore = false
			result.NextCursor = ""
			return result, nil
		}

		if !opts.All {
			if opts.Limit == 0 {
				return result, nil
			}
			remaining -= len(page.Assets)
			if remaining <= 0 {
				return result, nil
			}
		}

		hasCursor = true
		cursor = result.cursorState
	}
}

func listNoteProjects(s *conn.Session) ([]string, error) {
	resp, err := s.SendAndRecv(&protocol.Message{
		Opcode: protocol.C_ListNoteProjects,
		Data:   protocol.EncodeListNoteProjects(s.RoomID),
	})
	if err != nil {
		return nil, err
	}
	if resp.Opcode != protocol.S_NoteProjectList {
		return nil, fmt.Errorf("unexpected response: %d", resp.Opcode)
	}

	projectList, err := protocol.DecodeNoteProjectList(resp.Data)
	if err != nil {
		return nil, fmt.Errorf("parsing note projects: %w", err)
	}

	return projectList.Projects, nil
}

func listNoteTags(s *conn.Session) ([]string, error) {
	resp, err := s.SendAndRecv(&protocol.Message{
		Opcode: protocol.C_ListNoteTags,
		Data:   protocol.EncodeListNoteTags(s.RoomID),
	})
	if err != nil {
		return nil, err
	}
	if resp.Opcode != protocol.S_NoteTagList {
		return nil, fmt.Errorf("unexpected response: %d", resp.Opcode)
	}

	tagList, err := protocol.DecodeNoteTagList(resp.Data)
	if err != nil {
		return nil, fmt.Errorf("parsing note tags: %w", err)
	}

	return tagList.Tags, nil
}

var noteCmd = &cobra.Command{
	Use:   "note",
	Short: "Manage notes (assets)",
	Long:  "Manage notes stored as assets (AssetType=5).\n\nNotes have a title, teaser preview, and full markdown content.",
}

var noteListCmd = &cobra.Command{
	Use:   "list",
	Short: "List notes",
	Long:  "List notes. By default this returns one page. Use --cursor for the next page or --all to fetch every note.",
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		jsonOutput := useJSONOutput(cmd)
		projectFlag, _ := cmd.Flags().GetString("project")
		tagFlag, _ := cmd.Flags().GetString("tag")
		limitFlag, _ := cmd.Flags().GetInt("limit")
		pageSizeFlag, _ := cmd.Flags().GetInt("page-size")
		cursorFlag, _ := cmd.Flags().GetString("cursor")
		allFlag, _ := cmd.Flags().GetBool("all")

		noteListOpts, err := parseNoteListOptions(projectFlag, tagFlag, limitFlag, pageSizeFlag, cursorFlag, allFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		result, err := listPagedNotes(s, noteListOpts)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if jsonOutput {
			output.OutputJSON(result)
		} else {
			table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"ID", "TITLE", "PROJECT", "TAGS", "TEASER", "OWNER", "UPDATED"}))
			for _, n := range result.Notes {
				table.Append(
					fmt.Sprintf("%d", n.ID),
					truncateNote(n.Title, 30),
					truncateNote(n.Project, 20),
					truncateNote(strings.Join(n.Tags, ","), 24),
					truncateNote(n.Teaser, 40),
					n.Owner,
					n.Updated,
				)
			}
			table.Render()
			if result.HasMore {
				fmt.Fprintf(os.Stderr, "More notes available; use --cursor %s for the next page.\n", result.NextCursor)
			}
		}
	},
}

var noteProjectsCmd = &cobra.Command{
	Use:   "projects",
	Short: "List note projects",
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		jsonOutput := useJSONOutput(cmd)

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		projects, err := listNoteProjects(s)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if jsonOutput {
			output.OutputJSON(projects)
			return
		}

		table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"PROJECT"}))
		for _, project := range projects {
			table.Append(project)
		}
		table.Render()
	},
}

var noteTagsCmd = &cobra.Command{
	Use:   "tags",
	Short: "List note tags",
	Run: func(cmd *cobra.Command, args []string) {
		roomFlag, _ := cmd.Flags().GetString("room")
		jsonOutput := useJSONOutput(cmd)

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		tags, err := listNoteTags(s)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if jsonOutput {
			output.OutputJSON(tags)
			return
		}

		table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"TAG"}))
		for _, tag := range tags {
			table.Append(tag)
		}
		table.Render()
	},
}

var noteCreateCmd = &cobra.Command{
	Use:   "create <title>",
	Short: "Create new note",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		title := args[0]
		roomFlag, _ := cmd.Flags().GetString("room")
		content, err := noteContentFromFlags(cmd, "")
		if err != nil {
			conn.Fatal("Invalid content: %v", err)
		}
		project, _ := cmd.Flags().GetString("project")
		tags, _ := cmd.Flags().GetStringSlice("tag")
		formatFlag, _ := cmd.Flags().GetString("format")
		format, err := normalizeNoteFormat(formatFlag)
		if err != nil {
			conn.Fatal("Invalid format: %v", err)
		}
		attach, _ := cmd.Flags().GetString("attach")

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		preview := makeNotePreview(title, content, project, tags, format)
		attachments := uploadNoteAttachmentsFromFlag(s, attach)
		payload, err := protocol.EncodeCreateAssetWithAttachments(s.RoomID, protocol.AssetTypeNote, protocol.ParentTypeNone, 0, preview, content, attachments)
		if err != nil {
			conn.Fatal("Invalid attachments: %v", err)
		}

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_CreateAsset,
			Data:   payload,
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_AssetCreated {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		created, err := protocol.DecodeAssetCreated(resp.Data)
		if err != nil {
			conn.Fatal("Error parsing created note: %v", err)
		}

		output.PrintCreatedID("Note", created.Asset.AssetID)
	},
}

var noteGetCmd = &cobra.Command{
	Use:   "get <id>",
	Short: "Get note content",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		noteID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid note ID: %v", err)
		}

		roomFlag, _ := cmd.Flags().GetString("room")
		jsonOutput := useJSONOutput(cmd)
		textOutput, _ := cmd.Flags().GetBool("text")
		relatedEnabled, _ := cmd.Flags().GetBool("related")
		relatedLimit, _ := cmd.Flags().GetInt("related-limit")
		if textOutput {
			if err := validateNoteTextFlags(cmd); err != nil {
				conn.Fatal("Invalid output options: %v", err)
			}
			relatedEnabled = false
		}

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		asset, err := fetchAsset(s, noteID)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		p := parseNotePreviewJSON(asset.Preview)
		if textOutput {
			fmt.Print(noteTextContent(asset.Payload, p.Format))
			return
		}
		related := make([]relatedNoteEntry, 0)
		if relatedEnabled {
			related = fetchRelatedNotes(s, noteID, relatedLimit)
			if related == nil {
				related = make([]relatedNoteEntry, 0)
			}
		}

		if jsonOutput {
			output.OutputJSON(map[string]interface{}{
				"id":            asset.AssetID,
				"title":         p.Title,
				"project":       p.Project,
				"tags":          normalizeNoteTags(p.Tags),
				"format":        p.Format,
				"owner":         asset.Owner,
				"updated_at":    asset.UpdatedAt,
				"updated":       time.Unix(0, asset.UpdatedAt).Format(time.DateTime),
				"content":       asset.Payload,
				"attachments":   toOutputAttachments(asset.Attachments, s.Config.GetProxyURL()),
				"related_notes": related,
			})
		} else {
			fmt.Printf("# %s\n", p.Title)
			if p.Project != "" {
				fmt.Printf("Project: %s\n", p.Project)
			}
			if tags := normalizeNoteTags(p.Tags); len(tags) > 0 {
				fmt.Printf("Tags: %s\n", strings.Join(tags, ", "))
			}
			fmt.Printf("\n%s\n", asset.Payload)
			printNoteAttachments(asset.Attachments, s.Config.GetProxyURL())
			printRelatedNotes(related)
		}
	},
}

func validateNoteTextFlags(cmd *cobra.Command) error {
	for _, name := range []string{"human", "json", "pretty"} {
		enabled, _ := cmd.Flags().GetBool(name)
		if enabled {
			return fmt.Errorf("--text cannot be used with --%s", name)
		}
	}
	fields, _ := cmd.Flags().GetString("fields")
	for _, field := range strings.Split(fields, ",") {
		if strings.TrimSpace(field) != "" {
			return fmt.Errorf("--text cannot be used with --fields")
		}
	}
	if cmd.Flags().Changed("related") {
		related, _ := cmd.Flags().GetBool("related")
		if related {
			return fmt.Errorf("--text cannot be used with --related=true")
		}
	}
	if cmd.Flags().Changed("related-limit") {
		return fmt.Errorf("--text cannot be used with --related-limit")
	}
	return nil
}

func printNoteAttachments(attachments []protocol.Attachment, proxyURL string) {
	if len(attachments) == 0 {
		return
	}

	fmt.Printf("\nAttachments:\n")
	for i, att := range attachments {
		filename := att.Filename
		if filename == "" {
			filename = att.FileId
		}
		mimeType := att.MimeType
		if mimeType == "" {
			mimeType = "application/octet-stream"
		}
		fmt.Printf("  [%d] %s  %s  %s  %s\n", i, filename, formatAttachmentSize(att.Size), mimeType, att.FileId)
		if fileURL := upload.FileURL(att, proxyURL); fileURL != "" {
			fmt.Printf("      %s\n", fileURL)
		}
	}
}

func formatAttachmentSize(size int64) string {
	if size < 0 {
		size = 0
	}
	units := []string{"B", "KB", "MB", "GB"}
	value := float64(size)
	unit := 0
	for value >= 1024 && unit < len(units)-1 {
		value /= 1024
		unit++
	}
	if unit == 0 {
		return fmt.Sprintf("%d B", size)
	}
	return fmt.Sprintf("%.1f %s", value, units[unit])
}

var noteUpdateCmd = &cobra.Command{
	Use:   "update <id>",
	Short: "Update note",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		noteID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid note ID: %v", err)
		}

		roomFlag, _ := cmd.Flags().GetString("room")
		titleFlag, _ := cmd.Flags().GetString("title")
		projectFlag, _ := cmd.Flags().GetString("project")
		tagFlags, _ := cmd.Flags().GetStringSlice("tag")
		expectUpdatedAt, _ := cmd.Flags().GetInt64("expect-updated-at")
		attach, _ := cmd.Flags().GetString("attach")

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		// Fetch existing note
		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_GetAsset,
			Data:   protocol.EncodeGetAsset(s.RoomID, noteID),
		})
		if err != nil {
			conn.Fatal("Error fetching note: %v", err)
		}
		if resp.Opcode != protocol.S_AssetFull {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		existing, err := protocol.DecodeAssetFull(resp.Data)
		if err != nil {
			conn.Fatal("Error parsing asset: %v", err)
		}
		if existing.AssetType != protocol.AssetTypeNote {
			conn.Fatal("Asset %d is not a note", noteID)
		}
		if expectUpdatedAt != 0 && existing.UpdatedAt != expectUpdatedAt {
			conn.Fatal("Note changed before update: updated_at=%d, expected %d", existing.UpdatedAt, expectUpdatedAt)
		}
		p := parseNotePreviewJSON(existing.Preview)

		title := p.Title
		content := existing.Payload
		project := p.Project
		tags := normalizeNoteTags(p.Tags)
		format := p.Format
		if cmd.Flags().Changed("title") {
			title = titleFlag
		}
		content, err = noteContentFromFlags(cmd, content)
		if err != nil {
			conn.Fatal("Invalid content: %v", err)
		}
		if cmd.Flags().Changed("project") {
			project = projectFlag
		}
		if cmd.Flags().Changed("tag") {
			tags = normalizeNoteTags(tagFlags)
		}
		if cmd.Flags().Changed("format") {
			formatFlag, _ := cmd.Flags().GetString("format")
			format, err = normalizeNoteFormat(formatFlag)
			if err != nil {
				conn.Fatal("Invalid format: %v", err)
			}
		}
		attachments := existing.Attachments
		if attach != "" {
			newAttachments := uploadNoteAttachmentsFromFlag(s, attach)
			if len(attachments)+len(newAttachments) > upload.MaxAttachmentsCmd {
				conn.Fatal("Too many note attachments: %d existing + %d new > %d", len(attachments), len(newAttachments), upload.MaxAttachmentsCmd)
			}
			attachments = append(append([]protocol.Attachment{}, attachments...), newAttachments...)
		}

		preview := makeNotePreview(title, content, project, tags, format)
		if preview == existing.Preview && content == existing.Payload && attach == "" {
			output.Mutation("unchanged", "note", noteID, "Note unchanged", nil, nil)
			return
		}
		backupPath, err := writeNoteBackup(noteBackupScopeFromSession(s), s.RoomID, existing)
		if err != nil {
			conn.Fatal("Error writing note backup: %v", err)
		}

		payload, err := protocol.EncodeUpdateAssetWithAttachments(s.RoomID, noteID, preview, content, attachments)
		if err != nil {
			conn.Fatal("Invalid attachments: %v", err)
		}
		resp, err = s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_UpdateAsset,
			Data:   payload,
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_AssetUpdated {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		output.Mutation("updated", "note", noteID, fmt.Sprintf("Note updated (backup: %s)", backupPath), nil, map[string]any{"backup": backupPath})
	},
}

var noteAttachCmd = &cobra.Command{
	Use:   "attach <id> <file1> [file2...]",
	Short: "Attach file(s) to note",
	Args:  cobra.MinimumNArgs(2),
	Run: func(cmd *cobra.Command, args []string) {
		noteID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid note ID: %v", err)
		}

		roomFlag, _ := cmd.Flags().GetString("room")
		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		existing, err := fetchAsset(s, noteID)
		if err != nil {
			conn.Fatal("Error fetching note: %v", err)
		}
		if existing.AssetType != protocol.AssetTypeNote {
			conn.Fatal("Asset %d is not a note", noteID)
		}

		newAttachments := uploadNoteAttachments(s, args[1:])
		if len(existing.Attachments)+len(newAttachments) > upload.MaxAttachmentsCmd {
			conn.Fatal("Too many note attachments: %d existing + %d new > %d", len(existing.Attachments), len(newAttachments), upload.MaxAttachmentsCmd)
		}
		attachments := append(append([]protocol.Attachment{}, existing.Attachments...), newAttachments...)
		payload, err := protocol.EncodeUpdateAssetWithAttachments(s.RoomID, noteID, existing.Preview, existing.Payload, attachments)
		if err != nil {
			conn.Fatal("Invalid attachments: %v", err)
		}

		resp, err := s.SendAndRecv(&protocol.Message{Opcode: protocol.C_UpdateAsset, Data: payload})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		if resp.Opcode != protocol.S_AssetUpdated {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		output.Mutation("attached", "note", noteID, fmt.Sprintf("Attached %d file(s) to note #%d", len(newAttachments), noteID), nil, map[string]any{"attachment_count": len(newAttachments)})
	},
}

var noteReplaceAttachmentCmd = &cobra.Command{
	Use:   "replace-attachment <id> <index-or-file-id> <file>",
	Short: "Replace one note attachment",
	Long:  "Replace one note attachment in place. Select it by the zero-based index or exact file ID shown by 'nrc note get'.",
	Args:  cobra.ExactArgs(3),
	Run: func(cmd *cobra.Command, args []string) {
		noteID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid note ID: %v", err)
		}

		roomFlag, _ := cmd.Flags().GetString("room")
		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		existing, err := fetchAsset(s, noteID)
		if err != nil {
			conn.Fatal("Error fetching note: %v", err)
		}
		if existing.AssetType != protocol.AssetTypeNote {
			conn.Fatal("Asset %d is not a note", noteID)
		}
		index, err := noteAttachmentIndex(existing.Attachments, args[1])
		if err != nil {
			conn.Fatal("Invalid attachment selector: %v", err)
		}

		newAttachments := uploadNoteAttachments(s, args[2:])
		attachments := append([]protocol.Attachment{}, existing.Attachments...)
		oldAttachment := attachments[index]
		attachments[index] = newAttachments[0]
		if err := updateNoteAttachments(s, noteID, existing, attachments); err != nil {
			conn.Fatal("Error: %v", err)
		}

		output.Mutation("replaced_attachment", "note", noteID, fmt.Sprintf("Replaced attachment [%d] %s with %s on note #%d", index, attachmentDisplayName(oldAttachment), attachmentDisplayName(newAttachments[0]), noteID), nil, map[string]any{"index": index, "old": attachmentDisplayName(oldAttachment), "new": attachmentDisplayName(newAttachments[0])})
	},
}

var noteDownloadAttachmentCmd = &cobra.Command{
	Use:   "download-attachment <id> <index-or-file-id> [output-path]",
	Short: "Download one note attachment",
	Long:  "Download one note attachment. Select it by the zero-based index or exact file ID shown by 'nrc note get'. The attachment filename is used when output-path is omitted.",
	Args:  cobra.RangeArgs(2, 3),
	Run: func(cmd *cobra.Command, args []string) {
		noteID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid note ID: %v", err)
		}

		roomFlag, _ := cmd.Flags().GetString("room")
		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		existing, err := fetchAsset(s, noteID)
		if err != nil {
			conn.Fatal("Error fetching note: %v", err)
		}
		if existing.AssetType != protocol.AssetTypeNote {
			conn.Fatal("Asset %d is not a note", noteID)
		}
		index, err := noteAttachmentIndex(existing.Attachments, args[1])
		if err != nil {
			conn.Fatal("Invalid attachment selector: %v", err)
		}

		destination := ""
		if len(args) == 3 {
			destination = args[2]
		}
		attachment := existing.Attachments[index]
		written, err := upload.DownloadFile(attachment, s.Config.GetProxyURL(), destination)
		if err != nil {
			conn.Fatal("Error downloading attachment: %v", err)
		}
		if destination == "" {
			destination = filepath.Base(attachmentDisplayName(attachment))
		}
		output.Mutation("downloaded_attachment", "note", noteID, fmt.Sprintf("Downloaded %s to %s (%s)", attachmentDisplayName(attachment), destination, formatAttachmentSize(written)), nil, map[string]any{"path": destination, "bytes": written})
	},
}

var noteRemoveAttachmentCmd = &cobra.Command{
	Use:   "remove-attachment <id> <index-or-file-id> [index-or-file-id...]",
	Short: "Remove one or more note attachments",
	Long:  "Remove one or more attachment references from a note. Select each by the zero-based index or exact file ID shown by 'nrc note get'.",
	Args:  cobra.MinimumNArgs(2),
	Run: func(cmd *cobra.Command, args []string) {
		noteID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid note ID: %v", err)
		}

		roomFlag, _ := cmd.Flags().GetString("room")
		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		existing, err := fetchAsset(s, noteID)
		if err != nil {
			conn.Fatal("Error fetching note: %v", err)
		}
		if existing.AssetType != protocol.AssetTypeNote {
			conn.Fatal("Asset %d is not a note", noteID)
		}
		attachments, err := removeNoteAttachments(existing.Attachments, args[1:])
		if err != nil {
			conn.Fatal("Invalid attachment selector: %v", err)
		}
		if err := updateNoteAttachments(s, noteID, existing, attachments); err != nil {
			conn.Fatal("Error: %v", err)
		}

		output.Mutation("removed_attachment", "note", noteID, fmt.Sprintf("Removed %d attachment(s) from note #%d", len(args)-1, noteID), nil, map[string]any{"attachment_count": len(args) - 1})
	},
}

func attachmentDisplayName(attachment protocol.Attachment) string {
	if attachment.Filename != "" {
		return attachment.Filename
	}
	return attachment.FileId
}

func noteAttachmentIndex(attachments []protocol.Attachment, selector string) (int, error) {
	if index, err := strconv.Atoi(selector); err == nil {
		if index < 0 || index >= len(attachments) {
			return 0, fmt.Errorf("attachment index %d is out of range (note has %d attachment(s))", index, len(attachments))
		}
		return index, nil
	}
	for index, attachment := range attachments {
		if attachment.FileId == selector {
			return index, nil
		}
	}
	return 0, fmt.Errorf("attachment %q not found; use the index or file ID shown by 'nrc note get'", selector)
}

func removeNoteAttachments(attachments []protocol.Attachment, selectors []string) ([]protocol.Attachment, error) {
	removed := make(map[int]struct{}, len(selectors))
	for _, selector := range selectors {
		index, err := noteAttachmentIndex(attachments, selector)
		if err != nil {
			return nil, err
		}
		if _, exists := removed[index]; exists {
			return nil, fmt.Errorf("attachment [%d] was selected more than once", index)
		}
		removed[index] = struct{}{}
	}

	result := make([]protocol.Attachment, 0, len(attachments)-len(removed))
	for index, attachment := range attachments {
		if _, remove := removed[index]; !remove {
			result = append(result, attachment)
		}
	}
	return result, nil
}

func updateNoteAttachments(s *conn.Session, noteID uint64, existing protocol.Asset, attachments []protocol.Attachment) error {
	payload, err := protocol.EncodeUpdateAssetWithAttachments(s.RoomID, noteID, existing.Preview, existing.Payload, attachments)
	if err != nil {
		return fmt.Errorf("invalid attachments: %w", err)
	}
	resp, err := s.SendAndRecv(&protocol.Message{Opcode: protocol.C_UpdateAsset, Data: payload})
	if err != nil {
		return err
	}
	if resp.Opcode != protocol.S_AssetUpdated {
		return fmt.Errorf("unexpected response: %d", resp.Opcode)
	}
	return nil
}

func uploadNoteAttachmentsFromFlag(s *conn.Session, attach string) []protocol.Attachment {
	if attach == "" {
		return nil
	}
	return uploadNoteAttachments(s, parseFilePaths(attach))
}

func uploadNoteAttachments(s *conn.Session, filePaths []string) []protocol.Attachment {
	if len(filePaths) == 0 {
		return nil
	}
	if output.Human() {
		fmt.Fprintf(os.Stderr, "Uploading %d note attachment(s)...\n", len(filePaths))
	}
	attachments, err := upload.UploadFiles(filePaths, s.Config.GetProxyURL(), s.Config.WorkspaceID)
	if err != nil {
		conn.Fatal("Error uploading files: %v", err)
	}
	if output.Human() {
		output.PrintSuccess("Uploaded %d file(s)", len(attachments))
	}
	return attachments
}

func printNotePatchHunkResults(results []notePatchHunkResult) {
	for _, result := range results {
		if result.Offset != 0 {
			fmt.Printf("  hunk %d: %s at line %d (offset %+d)\n", result.Hunk, result.Status, result.Line, result.Offset)
		} else {
			fmt.Printf("  hunk %d: %s at line %d\n", result.Hunk, result.Status, result.Line)
		}
	}
}

var notePatchCmd = &cobra.Command{
	Use:   "patch <id>",
	Short: "Patch note content with a unified diff",
	Long:  "Patch note content with a unified diff read from stdin or --patch-file. The CLI applies the patch locally, then sends the complete updated note through the existing asset update protocol.",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		noteID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid note ID: %v", err)
		}

		roomFlag, _ := cmd.Flags().GetString("room")
		dryRun, _ := cmd.Flags().GetBool("dry-run")
		jsonOutput := useJSONOutput(cmd)
		expectUpdatedAt, _ := cmd.Flags().GetInt64("expect-updated-at")

		patch, err := readNotePatchFromFlags(cmd)
		if err != nil {
			conn.FatalInvalid("Error reading patch: %v", err)
		}
		if strings.TrimSpace(patch) == "" {
			conn.FatalInvalid("Patch is empty")
		}

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		existing, err := fetchAsset(s, noteID)
		if err != nil {
			conn.Fatal("Error fetching note: %v", err)
		}
		if existing.AssetType != protocol.AssetTypeNote {
			conn.Fatal("Asset %d is not a note", noteID)
		}
		if expectUpdatedAt != 0 && existing.UpdatedAt != expectUpdatedAt {
			conn.Fatal("Note changed before patch: updated_at=%d, expected %d", existing.UpdatedAt, expectUpdatedAt)
		}

		content, hunkResults, err := applyNoteUnifiedPatchDetailed(existing.Payload, patch)
		if err != nil {
			if jsonOutput {
				result := map[string]interface{}{"ok": false, "error": err.Error()}
				var patchErr *notePatchApplyError
				if errors.As(err, &patchErr) {
					result["hunk"] = patchErr.Hunk
					result["kind"] = patchErr.Kind
					if patchErr.ExpectedLine > 0 {
						result["expected_line"] = patchErr.ExpectedLine
					}
					if len(patchErr.CandidateLines) > 0 {
						result["candidate_lines"] = patchErr.CandidateLines
					}
				}
				data, _ := json.Marshal(result)
				conn.FatalInvalid("%s", data)
			}
			conn.FatalInvalid("Patch failed: %v", err)
		}
		if content == existing.Payload {
			if jsonOutput {
				output.Mutation("unchanged", "note", noteID, "", nil, map[string]interface{}{"changed": false, "old_bytes": len(existing.Payload), "new_bytes": len(content), "hunk_results": hunkResults})
				return
			}
			output.PrintSuccess("Patch applies; note content unchanged")
			if dryRun {
				printNotePatchHunkResults(hunkResults)
			}
			return
		}

		p := parseNotePreviewJSON(existing.Preview)
		preview := makeNotePreview(p.Title, content, p.Project, normalizeNoteTags(p.Tags), p.Format)

		if dryRun {
			if jsonOutput {
				output.Mutation("patch_preview", "note", noteID, "", nil, map[string]interface{}{"changed": true, "old_bytes": len(existing.Payload), "new_bytes": len(content), "hunk_results": hunkResults})
				return
			}
			output.PrintSuccess("Patch applies; note content would change from %d to %d bytes", len(existing.Payload), len(content))
			printNotePatchHunkResults(hunkResults)
			return
		}
		backupPath, err := writeNoteBackup(noteBackupScopeFromSession(s), s.RoomID, existing)
		if err != nil {
			conn.Fatal("Error writing note backup: %v", err)
		}

		payload, err := protocol.EncodeUpdateAssetWithAttachments(s.RoomID, noteID, preview, content, existing.Attachments)
		if err != nil {
			conn.Fatal("Invalid attachments: %v", err)
		}
		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_UpdateAsset,
			Data:   payload,
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		if resp.Opcode != protocol.S_AssetUpdated {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		if jsonOutput {
			output.Mutation("patched", "note", noteID, "", nil, map[string]interface{}{"changed": true, "old_bytes": len(existing.Payload), "new_bytes": len(content), "hunk_results": hunkResults, "backup": backupPath})
			return
		}
		output.PrintSuccess("Note patched (backup: %s)", backupPath)
	},
}

var noteBackupsCmd = &cobra.Command{
	Use:   "backups <id>",
	Short: "List local note backups",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		noteID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid note ID: %v", err)
		}

		jsonOutput := useJSONOutput(cmd)

		cfg, err := config.Load()
		if err != nil {
			output.Error("command_failed", fmt.Sprintf("Error loading config: %v", err), false)
		}
		roomID := int64(protocol.WorkspaceDataConvID)

		entries, err := listNoteBackups(noteBackupScopeFromConfig(cfg), roomID, noteID)
		if err != nil {
			conn.Fatal("Error listing backups: %v", err)
		}

		if jsonOutput {
			output.OutputJSON(entries)
			return
		}
		if len(entries) == 0 {
			output.PrintSuccess("No backups found")
			return
		}

		table := tablewriter.NewTable(os.Stdout, tablewriter.WithHeader([]string{"BACKUP ID", "TITLE", "UPDATED_AT", "CREATED", "PATH"}))
		for _, entry := range entries {
			table.Append(
				entry.BackupID,
				truncateNote(entry.Title, 30),
				fmt.Sprintf("%d", entry.UpdatedAt),
				time.Unix(0, entry.CreatedAt).Format(time.DateTime),
				entry.Path,
			)
		}
		table.Render()
	},
}

var noteRevertCmd = &cobra.Command{
	Use:   "revert <id>",
	Short: "Restore a note from a local backup",
	Long:  "Restore a note from a local backup created before note update or note patch. Revert writes a backup of the current note before restoring, so the revert can be undone.",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		noteID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid note ID: %v", err)
		}

		roomFlag, _ := cmd.Flags().GetString("room")
		backupID, _ := cmd.Flags().GetString("backup-id")
		dryRun, _ := cmd.Flags().GetBool("dry-run")
		force, _ := cmd.Flags().GetBool("force")

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()
		scope := noteBackupScopeFromSession(s)

		var backup noteBackup
		var backupPath string
		if strings.TrimSpace(backupID) == "" {
			backup, backupPath, err = latestNoteBackup(scope, s.RoomID, noteID)
		} else {
			backup, backupPath, err = noteBackupByID(scope, s.RoomID, noteID, backupID)
		}
		if err != nil {
			conn.Fatal("Error loading backup: %v", err)
		}
		if backup.Server != scope.Server || backup.WorkspaceID != scope.WorkspaceID || backup.RoomID != s.RoomID || backup.NoteID != noteID {
			conn.Fatal("Backup %s is for server/workspace/room/note %s/%s/%d/%d, not %s/%s/%d/%d", backup.BackupID, backup.Server, backup.WorkspaceID, backup.RoomID, backup.NoteID, scope.Server, scope.WorkspaceID, s.RoomID, noteID)
		}

		current, err := fetchAsset(s, noteID)
		if err != nil {
			conn.Fatal("Error fetching note: %v", err)
		}
		if current.AssetType != protocol.AssetTypeNote {
			conn.Fatal("Asset %d is not a note", noteID)
		}

		preview := makeNotePreview(backup.Title, backup.Content, backup.Project, backup.Tags, backup.Format)
		if dryRun {
			output.Mutation("restore_preview", "note", noteID, fmt.Sprintf("Would restore backup %s from %s (%d -> %d bytes)", backup.BackupID, backupPath, len(current.Payload), len(backup.Content)), nil, map[string]any{"backup_id": backup.BackupID, "backup_path": backupPath})
			return
		}
		if !force {
			conn.Fatal("Refusing to restore without --force; run with --dry-run to inspect or --force to restore backup %s", backup.BackupID)
		}
		if preview == current.Preview && backup.Content == current.Payload {
			output.Mutation("unchanged", "note", noteID, fmt.Sprintf("Note already matches backup %s", backup.BackupID), nil, map[string]any{"backup_id": backup.BackupID})
			return
		}

		currentBackupPath, err := writeNoteBackup(scope, s.RoomID, current)
		if err != nil {
			conn.Fatal("Error writing current note backup: %v", err)
		}

		payload, err := protocol.EncodeUpdateAssetWithAttachments(s.RoomID, noteID, preview, backup.Content, current.Attachments)
		if err != nil {
			conn.Fatal("Invalid attachments: %v", err)
		}
		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_UpdateAsset,
			Data:   payload,
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		if resp.Opcode != protocol.S_AssetUpdated {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		output.Mutation("restored", "note", noteID, fmt.Sprintf("Note restored from backup %s (current backup: %s)", backup.BackupID, currentBackupPath), nil, map[string]any{"backup_id": backup.BackupID, "current_backup": currentBackupPath})
	},
}

var noteDeleteCmd = &cobra.Command{
	Use:   "delete <id>",
	Short: "Delete note",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		noteID, err := strconv.ParseUint(args[0], 10, 64)
		if err != nil {
			conn.Fatal("Invalid note ID: %v", err)
		}

		roomFlag, _ := cmd.Flags().GetString("room")

		s, err := conn.Dial(roomFlag)
		if err != nil {
			conn.Fatal("Error: %v", err)
		}
		defer s.Close()

		resp, err := s.SendAndRecv(&protocol.Message{
			Opcode: protocol.C_DeleteAsset,
			Data:   protocol.EncodeDeleteAsset(s.RoomID, noteID),
		})
		if err != nil {
			conn.Fatal("Error: %v", err)
		}

		if resp.Opcode != protocol.S_AssetDeleted {
			output.PrintError("Unexpected response: %d", resp.Opcode)
		}

		output.Mutation("deleted", "note", noteID, "Note deleted", nil, nil)
	},
}

func truncateNote(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen-3] + "..."
}

func init() {
	noteListCmd.Flags().String("project", "", "Filter notes by project")
	noteListCmd.Flags().String("tag", "", "Filter notes by tag")
	noteListCmd.Flags().Int("limit", 0, "Maximum notes to return from the paged listing")
	noteListCmd.Flags().Int("page-size", defaultNoteListPageSize, "Notes per page (1-250)")
	noteListCmd.Flags().String("cursor", "", "Opaque cursor from the previous JSON page")
	noteListCmd.Flags().Bool("all", false, "Fetch all notes by following every page")

	noteCreateCmd.Flags().String("content", "", "Note content (markdown)")
	noteCreateCmd.Flags().String("content-file", "", "Read note content from file")
	noteCreateCmd.Flags().String("project", "", "Note project")
	noteCreateCmd.Flags().StringSlice("tag", nil, "Note tag (repeat or use comma-separated values)")
	noteCreateCmd.Flags().String("attach", "", "Comma-separated file paths to attach")
	noteCreateCmd.Flags().String("format", "markdown", "Content format: markdown or html")

	noteGetCmd.Flags().Bool("related", true, "Append related notes from the graph (use --related=false to disable)")
	noteGetCmd.Flags().Int("related-limit", defaultRelatedNoteLimit, "Maximum related notes to append")
	noteGetCmd.Flags().Bool("text", false, "Output only note content, converting HTML to plain text")

	noteUpdateCmd.Flags().String("title", "", "New title; omit to keep existing")
	noteUpdateCmd.Flags().String("content", "", "New content; omit to keep existing")
	noteUpdateCmd.Flags().String("content-file", "", "Read new content from file; omit to keep existing")
	noteUpdateCmd.Flags().String("project", "", "New project; pass empty value to clear, omit to keep existing")
	noteUpdateCmd.Flags().StringSlice("tag", nil, "Replacement tag set (repeat or use comma-separated values); pass empty value to clear, omit to keep existing")
	noteUpdateCmd.Flags().String("attach", "", "Comma-separated file paths to append as attachments")
	noteUpdateCmd.Flags().Int64("expect-updated-at", 0, "Refuse to update unless the note has this updated_at timestamp")
	noteUpdateCmd.Flags().String("format", "", "New content format: markdown or html; omit to keep existing")

	notePatchCmd.Flags().String("patch-file", "", "Read unified diff from file instead of stdin")
	notePatchCmd.Flags().Bool("dry-run", false, "Check whether the patch applies without updating the note")
	notePatchCmd.Flags().Int64("expect-updated-at", 0, "Refuse to patch unless the note has this updated_at timestamp")

	noteRevertCmd.Flags().String("backup-id", "", "Backup ID to restore (default: latest backup)")
	noteRevertCmd.Flags().Bool("dry-run", false, "Show the backup that would be restored without updating the note")
	noteRevertCmd.Flags().Bool("force", false, "Restore the selected backup")

	noteCmd.AddCommand(noteListCmd, noteProjectsCmd, noteTagsCmd, noteCreateCmd, noteGetCmd, noteUpdateCmd, noteAttachCmd, noteReplaceAttachmentCmd, noteDownloadAttachmentCmd, noteRemoveAttachmentCmd, notePatchCmd, noteBackupsCmd, noteRevertCmd, noteDeleteCmd)
	rootCmd.AddCommand(noteCmd)
}
