package e2e

import (
	"encoding/json"
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type e2eNotePreview struct {
	Title   string   `json:"title"`
	Teaser  string   `json:"teaser"`
	Project string   `json:"project"`
	Tags    []string `json:"tags"`
}

func mustNotePreviewJSON(t *testing.T, title string, project string, tags ...string) string {
	t.Helper()

	data, err := json.Marshal(e2eNotePreview{Title: title, Teaser: title, Project: project, Tags: tags})
	if err != nil {
		t.Fatalf("failed to marshal note preview JSON: %v", err)
	}

	return string(data)
}

func createNoteAssetAndRead(t *testing.T, conn *websocket.Conn, roomID int64, preview string) protocol.Asset {
	t.Helper()

	if err := sendProtocolMessage(conn, protocol.C_CreateAsset, protocol.EncodeCreateAsset(roomID, protocol.AssetTypeNote, protocol.ParentTypeNone, 0, preview, "")); err != nil {
		t.Fatalf("failed to send CreateAsset(note): %v", err)
	}

	payload := mustReadUntilOpcode(t, conn, protocol.S_AssetCreated, 12)
	created, err := protocol.DecodeAssetCreated(payload)
	if err != nil {
		t.Fatalf("failed to decode S_AssetCreated: %v payload=%x", err, payload)
	}

	return created.Asset
}

func createTaggedNoteAssetAndRead(t *testing.T, conn *websocket.Conn, roomID int64, title string) protocol.Asset {
	t.Helper()
	return createNoteAssetAndRead(t, conn, roomID, mustNotePreviewJSON(t, title, ""))
}

func createStructuredNoteAssetAndRead(t *testing.T, conn *websocket.Conn, roomID int64, title, project string, tags ...string) protocol.Asset {
	t.Helper()
	return createNoteAssetAndRead(t, conn, roomID, mustNotePreviewJSON(t, title, project, tags...))
}

func listNotesPage(t *testing.T, conn *websocket.Conn, roomID int64, limit uint16, hasCursor bool, cursorUpdatedAt int64, cursorAssetID uint64) *protocol.AssetListPageResponse {
	t.Helper()

	if err := sendProtocolMessage(conn, protocol.C_ListAssetsPaged, protocol.EncodeListAssetsPaged(roomID, protocol.AssetTypeNote, false, limit, hasCursor, cursorUpdatedAt, cursorAssetID)); err != nil {
		t.Fatalf("failed to send ListAssetsPaged: %v", err)
	}

	payload := mustReadUntilOpcode(t, conn, protocol.S_AssetListPage, 12)
	page, err := protocol.DecodeAssetListPage(payload)
	if err != nil {
		t.Fatalf("failed to decode S_AssetListPage: %v payload=%x", err, payload)
	}

	if page.ConvID != uint64(roomID) {
		t.Fatalf("asset list page conv_id mismatch: got %d want %d", page.ConvID, roomID)
	}
	if page.FullContent {
		t.Fatalf("expected FullContent=false for paged note list")
	}

	for i := range page.Assets {
		if page.Assets[i].AssetType != protocol.AssetTypeNote {
			t.Fatalf("paged note list returned non-note asset_type=%d id=%d", page.Assets[i].AssetType, page.Assets[i].AssetID)
		}
	}

	return page
}

func listNotesPageByProject(t *testing.T, conn *websocket.Conn, roomID int64, project string, limit uint16, hasCursor bool, cursorUpdatedAt int64, cursorAssetID uint64) *protocol.AssetListPageResponse {
	t.Helper()

	if err := sendProtocolMessage(conn, protocol.C_ListAssetsPagedByProject, protocol.EncodeListAssetsPagedByProject(roomID, protocol.AssetTypeNote, false, limit, hasCursor, cursorUpdatedAt, cursorAssetID, project)); err != nil {
		t.Fatalf("failed to send ListAssetsPagedByProject: %v", err)
	}

	payload := mustReadUntilOpcode(t, conn, protocol.S_AssetListPage, 12)
	page, err := protocol.DecodeAssetListPage(payload)
	if err != nil {
		t.Fatalf("failed to decode S_AssetListPage for project %q: %v payload=%x", project, err, payload)
	}

	if page.ConvID != uint64(roomID) {
		t.Fatalf("project asset list page conv_id mismatch: got %d want %d", page.ConvID, roomID)
	}
	if page.FullContent {
		t.Fatalf("expected FullContent=false for project paged note list")
	}

	for i := range page.Assets {
		if page.Assets[i].AssetType != protocol.AssetTypeNote {
			t.Fatalf("project paged note list returned non-note asset_type=%d id=%d", page.Assets[i].AssetType, page.Assets[i].AssetID)
		}
	}

	return page
}

func listNotesPageByTag(t *testing.T, conn *websocket.Conn, roomID int64, tag string, limit uint16, hasCursor bool, cursorUpdatedAt int64, cursorAssetID uint64) *protocol.AssetListPageResponse {
	t.Helper()

	if err := sendProtocolMessage(conn, protocol.C_ListAssetsPagedByTag, protocol.EncodeListAssetsPagedByTag(roomID, protocol.AssetTypeNote, false, limit, hasCursor, cursorUpdatedAt, cursorAssetID, tag)); err != nil {
		t.Fatalf("failed to send ListAssetsPagedByTag: %v", err)
	}

	payload := mustReadUntilOpcode(t, conn, protocol.S_AssetListPage, 12)
	page, err := protocol.DecodeAssetListPage(payload)
	if err != nil {
		t.Fatalf("failed to decode S_AssetListPage for tag %q: %v payload=%x", tag, err, payload)
	}

	if page.ConvID != uint64(roomID) {
		t.Fatalf("tag asset list page conv_id mismatch: got %d want %d", page.ConvID, roomID)
	}
	if page.FullContent {
		t.Fatalf("expected FullContent=false for tag paged note list")
	}

	for i := range page.Assets {
		if page.Assets[i].AssetType != protocol.AssetTypeNote {
			t.Fatalf("tag paged note list returned non-note asset_type=%d id=%d", page.Assets[i].AssetType, page.Assets[i].AssetID)
		}
	}

	return page
}

func listNoteProjects(t *testing.T, conn *websocket.Conn, roomID int64) *protocol.NoteProjectListResponse {
	t.Helper()

	if err := sendProtocolMessage(conn, protocol.C_ListNoteProjects, protocol.EncodeListNoteProjects(roomID)); err != nil {
		t.Fatalf("failed to send ListNoteProjects: %v", err)
	}

	payload := mustReadUntilOpcode(t, conn, protocol.S_NoteProjectList, 12)
	projects, err := protocol.DecodeNoteProjectList(payload)
	if err != nil {
		t.Fatalf("failed to decode S_NoteProjectList: %v payload=%x", err, payload)
	}
	if projects.ConvID != uint64(roomID) {
		t.Fatalf("note project list conv_id mismatch: got %d want %d", projects.ConvID, roomID)
	}

	return projects
}

func listNoteTags(t *testing.T, conn *websocket.Conn, roomID int64) *protocol.NoteTagListResponse {
	t.Helper()

	if err := sendProtocolMessage(conn, protocol.C_ListNoteTags, protocol.EncodeListNoteTags(roomID)); err != nil {
		t.Fatalf("failed to send ListNoteTags: %v", err)
	}

	payload := mustReadUntilOpcode(t, conn, protocol.S_NoteTagList, 12)
	tags, err := protocol.DecodeNoteTagList(payload)
	if err != nil {
		t.Fatalf("failed to decode S_NoteTagList: %v payload=%x", err, payload)
	}
	if tags.ConvID != uint64(roomID) {
		t.Fatalf("note tag list conv_id mismatch: got %d want %d", tags.ConvID, roomID)
	}

	return tags
}

func TestNotesPaginationByAVLIndex(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-notes-pagination-%d", time.Now().UnixNano())
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("failed to connect websocket client: %v", err)
	}
	defer conn.Close()

	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID
	note1 := createNoteAssetAndRead(t, conn, roomID, "note-1")
	note2 := createNoteAssetAndRead(t, conn, roomID, "note-2")
	note3 := createNoteAssetAndRead(t, conn, roomID, "note-3")
	note4 := createNoteAssetAndRead(t, conn, roomID, "note-4")
	note5 := createNoteAssetAndRead(t, conn, roomID, "note-5")

	if err := sendProtocolMessage(conn, protocol.C_CreateAsset, protocol.EncodeCreateAsset(roomID, protocol.AssetTypeDocument, protocol.ParentTypeNone, 0, "doc-preview", "doc-payload")); err != nil {
		t.Fatalf("failed to create non-note asset: %v", err)
	}
	_ = mustReadUntilOpcode(t, conn, protocol.S_AssetCreated, 12)

	page1 := listNotesPage(t, conn, roomID, 2, false, 0, 0)
	if len(page1.Assets) != 2 || !page1.HasMore {
		t.Fatalf("page1 mismatch: count=%d has_more=%t", len(page1.Assets), page1.HasMore)
	}
	if page1.TotalCount != 5 {
		t.Fatalf("page1 total_count mismatch: got %d want 5", page1.TotalCount)
	}
	if page1.Assets[0].AssetID != note5.AssetID || page1.Assets[1].AssetID != note4.AssetID {
		t.Fatalf("page1 IDs mismatch: got [%d,%d] want [%d,%d]", page1.Assets[0].AssetID, page1.Assets[1].AssetID, note5.AssetID, note4.AssetID)
	}

	page2 := listNotesPage(t, conn, roomID, 2, true, page1.NextCursorUpdatedAt, page1.NextCursorAssetID)
	if len(page2.Assets) != 2 || !page2.HasMore {
		t.Fatalf("page2 mismatch: count=%d has_more=%t", len(page2.Assets), page2.HasMore)
	}
	if page2.TotalCount != 5 {
		t.Fatalf("page2 total_count mismatch: got %d want 5", page2.TotalCount)
	}
	if page2.Assets[0].AssetID != note3.AssetID || page2.Assets[1].AssetID != note2.AssetID {
		t.Fatalf("page2 IDs mismatch: got [%d,%d] want [%d,%d]", page2.Assets[0].AssetID, page2.Assets[1].AssetID, note3.AssetID, note2.AssetID)
	}

	page3 := listNotesPage(t, conn, roomID, 2, true, page2.NextCursorUpdatedAt, page2.NextCursorAssetID)
	if len(page3.Assets) != 1 || page3.HasMore {
		t.Fatalf("page3 mismatch: count=%d has_more=%t", len(page3.Assets), page3.HasMore)
	}
	if page3.TotalCount != 5 {
		t.Fatalf("page3 total_count mismatch: got %d want 5", page3.TotalCount)
	}
	if page3.Assets[0].AssetID != note1.AssetID {
		t.Fatalf("page3 ID mismatch: got %d want %d", page3.Assets[0].AssetID, note1.AssetID)
	}
}

func TestNotesPaginationCursorRemapsAfterCursorAssetUpdate(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-notes-pagination-cursor-update-%d", time.Now().UnixNano())
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("failed to connect websocket client: %v", err)
	}
	defer conn.Close()

	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID
	note1 := createNoteAssetAndRead(t, conn, roomID, "cursor-note-1")
	note2 := createNoteAssetAndRead(t, conn, roomID, "cursor-note-2")
	note3 := createNoteAssetAndRead(t, conn, roomID, "cursor-note-3")
	note4 := createNoteAssetAndRead(t, conn, roomID, "cursor-note-4")

	page1 := listNotesPage(t, conn, roomID, 2, false, 0, 0)
	if len(page1.Assets) != 2 || !page1.HasMore {
		t.Fatalf("page1 mismatch: count=%d has_more=%t", len(page1.Assets), page1.HasMore)
	}
	if page1.TotalCount != 4 {
		t.Fatalf("page1 total_count mismatch: got %d want 4", page1.TotalCount)
	}
	if page1.Assets[0].AssetID != note4.AssetID || page1.Assets[1].AssetID != note3.AssetID {
		t.Fatalf("page1 IDs mismatch: got [%d,%d] want [%d,%d]", page1.Assets[0].AssetID, page1.Assets[1].AssetID, note4.AssetID, note3.AssetID)
	}

	if err := sendProtocolMessage(conn, protocol.C_UpdateAsset, protocol.EncodeUpdateAsset(roomID, note3.AssetID, "cursor-note-3-updated", "")); err != nil {
		t.Fatalf("failed to update cursor note: %v", err)
	}
	updatePayload := mustReadUntilOpcode(t, conn, protocol.S_AssetUpdated, 12)
	updated, err := protocol.DecodeAssetFull(updatePayload)
	if err != nil {
		t.Fatalf("failed to decode S_AssetUpdated after cursor update: %v payload=%x", err, updatePayload)
	}
	if updated.AssetID != note3.AssetID {
		t.Fatalf("updated asset id mismatch: got %d want %d", updated.AssetID, note3.AssetID)
	}

	page2 := listNotesPage(t, conn, roomID, 2, true, page1.NextCursorUpdatedAt, page1.NextCursorAssetID)
	if len(page2.Assets) != 2 || page2.HasMore {
		t.Fatalf("page2 mismatch: count=%d has_more=%t", len(page2.Assets), page2.HasMore)
	}
	if page2.TotalCount != 4 {
		t.Fatalf("page2 total_count mismatch: got %d want 4", page2.TotalCount)
	}
	if page2.Assets[0].AssetID != note2.AssetID || page2.Assets[1].AssetID != note1.AssetID {
		t.Fatalf("page2 IDs mismatch after cursor note update: got [%d,%d] want [%d,%d]", page2.Assets[0].AssetID, page2.Assets[1].AssetID, note2.AssetID, note1.AssetID)
	}
}

func TestNoteProjectsAndProjectPagination(t *testing.T) {
	server := startServer(t)
	defer server.stop(t)

	workspace := fmt.Sprintf("e2e-note-projects-%d", time.Now().UnixNano())
	conn, _, err := websocket.DefaultDialer.Dial(wsURLForWorkspace(workspace), mustAuthHeader(t, ""))
	if err != nil {
		t.Fatalf("failed to connect websocket client: %v", err)
	}
	defer conn.Close()

	mustSetReadDeadline(t, conn, 5*time.Second)
	mustExpectServerReady(t, conn)

	const roomID int64 = protocol.WorkspaceDataConvID
	alphaOld := createStructuredNoteAssetAndRead(t, conn, roomID, "alpha-old", "alpha", "ops")
	_ = createStructuredNoteAssetAndRead(t, conn, roomID, "beta-only", "beta", "infra")
	alphaNew := createStructuredNoteAssetAndRead(t, conn, roomID, "alpha-new", "alpha", "ops", "infra")
	_ = createStructuredNoteAssetAndRead(t, conn, roomID, "untagged note", "")

	projects := listNoteProjects(t, conn, roomID)
	if !reflect.DeepEqual(projects.Projects, []string{"alpha", "beta"}) {
		t.Fatalf("projects = %v, want %v", projects.Projects, []string{"alpha", "beta"})
	}
	tags := listNoteTags(t, conn, roomID)
	if !reflect.DeepEqual(tags.Tags, []string{"infra", "ops"}) {
		t.Fatalf("tags = %v, want %v", tags.Tags, []string{"infra", "ops"})
	}

	page1 := listNotesPageByProject(t, conn, roomID, "alpha", 1, false, 0, 0)
	if len(page1.Assets) != 1 || !page1.HasMore {
		t.Fatalf("alpha page1 mismatch: count=%d has_more=%t", len(page1.Assets), page1.HasMore)
	}
	if page1.TotalCount != 2 {
		t.Fatalf("alpha page1 total_count mismatch: got %d want 2", page1.TotalCount)
	}
	if page1.Assets[0].AssetID != alphaNew.AssetID {
		t.Fatalf("alpha page1 ID mismatch: got %d want %d", page1.Assets[0].AssetID, alphaNew.AssetID)
	}

	page2 := listNotesPageByProject(t, conn, roomID, "alpha", 1, true, page1.NextCursorUpdatedAt, page1.NextCursorAssetID)
	if len(page2.Assets) != 1 || page2.HasMore {
		t.Fatalf("alpha page2 mismatch: count=%d has_more=%t", len(page2.Assets), page2.HasMore)
	}
	if page2.TotalCount != 2 {
		t.Fatalf("alpha page2 total_count mismatch: got %d want 2", page2.TotalCount)
	}
	if page2.Assets[0].AssetID != alphaOld.AssetID {
		t.Fatalf("alpha page2 ID mismatch: got %d want %d", page2.Assets[0].AssetID, alphaOld.AssetID)
	}

	emptyPage := listNotesPageByProject(t, conn, roomID, "missing", 5, false, 0, 0)
	if len(emptyPage.Assets) != 0 || emptyPage.HasMore || emptyPage.TotalCount != 0 {
		t.Fatalf("missing project page mismatch: count=%d has_more=%t total=%d", len(emptyPage.Assets), emptyPage.HasMore, emptyPage.TotalCount)
	}

	opsPage1 := listNotesPageByTag(t, conn, roomID, "ops", 1, false, 0, 0)
	if len(opsPage1.Assets) != 1 || !opsPage1.HasMore {
		t.Fatalf("ops page1 mismatch: count=%d has_more=%t", len(opsPage1.Assets), opsPage1.HasMore)
	}
	if opsPage1.TotalCount != 2 {
		t.Fatalf("ops page1 total_count mismatch: got %d want 2", opsPage1.TotalCount)
	}
	if opsPage1.Assets[0].AssetID != alphaNew.AssetID {
		t.Fatalf("ops page1 ID mismatch: got %d want %d", opsPage1.Assets[0].AssetID, alphaNew.AssetID)
	}

	opsPage2 := listNotesPageByTag(t, conn, roomID, "ops", 1, true, opsPage1.NextCursorUpdatedAt, opsPage1.NextCursorAssetID)
	if len(opsPage2.Assets) != 1 || opsPage2.HasMore {
		t.Fatalf("ops page2 mismatch: count=%d has_more=%t", len(opsPage2.Assets), opsPage2.HasMore)
	}
	if opsPage2.Assets[0].AssetID != alphaOld.AssetID {
		t.Fatalf("ops page2 ID mismatch: got %d want %d", opsPage2.Assets[0].AssetID, alphaOld.AssetID)
	}
}
