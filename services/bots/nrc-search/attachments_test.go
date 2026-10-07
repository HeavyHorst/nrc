package main

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/heavyhorst/nrc/protocol-go"
)

const testAttachmentID = "att_0123456789abcdef0123456789abcdef"

func officeFixture(t *testing.T, entries map[string]string) []byte {
	t.Helper()
	var output bytes.Buffer
	archive := zip.NewWriter(&output)
	for name, text := range entries {
		file, err := archive.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := file.Write([]byte(text)); err != nil {
			t.Fatal(err)
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	return output.Bytes()
}

func pdfFixture(text bool) []byte {
	content := "1 0 0 rg 20 20 100 100 re f"
	if text {
		content = "BT /F1 10 Tf 30 150 Td (Quarterly revenue 42 EUR) Tj ET"
	}
	objects := []string{"<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>", fmt.Sprintf("<< /Length %d >>\nstream\n%s\nendstream", len(content), content)}
	var output bytes.Buffer
	output.WriteString("%PDF-1.4\n")
	offsets := []int{0}
	for i, object := range objects {
		offsets = append(offsets, output.Len())
		fmt.Fprintf(&output, "%d 0 obj\n%s\nendobj\n", i+1, object)
	}
	xref := output.Len()
	fmt.Fprintf(&output, "xref\n0 %d\n0000000000 65535 f \n", len(offsets))
	for _, offset := range offsets[1:] {
		fmt.Fprintf(&output, "%010d 00000 n \n", offset)
	}
	fmt.Fprintf(&output, "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", len(offsets), xref)
	return output.Bytes()
}

func TestOfficeTextExtractionAndLimits(t *testing.T) {
	for _, tc := range []struct {
		kind  string
		files map[string]string
		want  string
	}{
		{"docx", map[string]string{"word/document.xml": `<document><body><p><r><t>Budget &amp; </t></r><r><t>forecast</t></r></p><p><r><t>Second paragraph</t></r></p></body></document>`}, "Budget & forecast\nSecond paragraph\n"},
		{"xlsx", map[string]string{"xl/sharedStrings.xml": `<sst><si><t>Revenue</t></si><si><r><t>North </t></r><r><t>region</t></r></si></sst>`, "xl/worksheets/sheet2.xml": `<worksheet><row><c r="B3" t="s"><v>1</v></c><c r="D3" t="inlineStr"><is><t>Inline value</t></is></c></row></worksheet>`, "xl/worksheets/sheet1.xml": `<worksheet><row><c r="A1" t="s"><v>0</v></c><c r="C2"><f>21*2</f><v>42</v></c></row></worksheet>`}, "sheet1.xml\nA1: Revenue\nC2: 42\nsheet2.xml\nB3: North region\nD3: Inline value\n"},
	} {
		t.Run(tc.kind, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "file")
			if err := os.WriteFile(path, officeFixture(t, tc.files), 0600); err != nil {
				t.Fatal(err)
			}
			got, err := extractOffice(path, tc.kind)
			if err != nil || got != tc.want {
				t.Fatalf("got=%q err=%v want=%q", got, err, tc.want)
			}
		})
	}
	path := filepath.Join(t.TempDir(), "bomb.docx")
	if err := os.WriteFile(path, officeFixture(t, map[string]string{"word/document.xml": strings.Repeat("x", maxExtractedBytes+1)}), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := extractOffice(path, "docx"); err == nil {
		t.Fatal("expanded zip limit not enforced")
	}
	path = filepath.Join(t.TempDir(), "repeated.xlsx")
	data := officeFixture(t, map[string]string{
		"xl/sharedStrings.xml":     `<sst><si><t>` + strings.Repeat("x", 1024*1024) + `</t></si></sst>`,
		"xl/worksheets/sheet1.xml": `<worksheet>` + strings.Repeat(`<c r="A1" t="s"><v>0</v></c>`, 17) + `</worksheet>`,
	})
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := extractOffice(path, "xlsx"); err == nil || !strings.Contains(err.Error(), "extracted office text") {
		t.Fatalf("shared string amplification must be bounded: %v", err)
	}
}

type testMediaEmbedder struct {
	recordingEmbedder
	offsets []int
	kinds   []string
}

func (e *testMediaEmbedder) EmbedMedia(kind, path string, offset int) ([]float32, error) {
	if _, err := os.Stat(path); err != nil {
		return nil, err
	}
	e.offsets = append(e.offsets, offset)
	e.kinds = append(e.kinds, kind)
	if kind == "audio" && offset >= 60 {
		return nil, nil
	}
	return []float32{0, 1}, nil
}

func TestAttachmentsDownloadExtractAndPreserveSource(t *testing.T) {
	if _, err := exec.LookPath("pdftotext"); err != nil {
		t.Skip("Poppler required")
	}
	for _, tc := range []struct {
		name, mime string
		data       []byte
		expect     string
		media      int
	}{
		{"report.docx", "application/octet-stream", officeFixture(t, map[string]string{"word/document.xml": `<document><p><t>Profit margin 37 percent</t></p></document>`}), "Profit margin 37 percent", 0},
		{"report.pdf", "application/pdf", pdfFixture(true), "Quarterly revenue 42 EUR", 0},
		{"scan.pdf", "application/pdf", pdfFixture(false), "", 1},
		{"recording.wav", "audio/wav", []byte("fake audio decoded by test embedder"), "", 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Authorization") != "Bearer test-secret" || r.URL.Query().Get("workspace") != "ws" || r.URL.Path != "/files/"+testAttachmentID {
					t.Error("wrong authenticated request")
					http.Error(w, "denied", 403)
					return
				}
				w.Write(tc.data)
			}))
			defer server.Close()
			e := &testMediaEmbedder{}
			storage := newTestStorage(t)
			client, err := NewNRCClient(Config{EmbedAssetTypes: []uint16{3}, EmbedTasks: true, FilesURL: server.URL, NRCBotSecret: "test-secret"}, "ws", storage, e, NewIndex())
			if err != nil {
				t.Fatal(err)
			}
			asset := protocol.Asset{AssetID: 17, ConvID: 0, AssetType: 3, Preview: "neutral record", Payload: `{"type":"file"}`, Attachments: []protocol.Attachment{{FileId: testAttachmentID, Filename: tc.name, MimeType: tc.mime}}}
			client.ingestAsset(asset, true, 0)
			client.drainPersistentQueue()
			entry, ok := client.index.GetEntity(assetIdentity("ws", 17, 0))
			if !ok {
				t.Fatal("missing owner result")
			}
			if entry.Payload != asset.Payload {
				t.Fatal("source payload overwritten by extraction")
			}
			if len(entry.Metadata.Attachments) != 1 || entry.Metadata.Attachments[0].Status != "indexed" {
				t.Fatalf("status=%+v", entry.Metadata.Attachments)
			}
			if !strings.Contains(entry.SearchText, tc.expect) || !strings.Contains(entry.PayloadLower, strings.ToLower(tc.expect)) {
				t.Fatalf("missing extracted text: %q", entry.SearchText)
			}
			if len(entry.Chunks) != tc.media+1 && tc.media > 0 {
				t.Fatalf("chunks=%d", len(entry.Chunks))
			}
			stored, err := storage.LoadAllEntityEmbeddings()
			if err != nil {
				t.Fatal(err)
			}
			reloaded := indexEntryFromStoredEmbedding(stored[assetIdentity("ws", 17, 0)])
			if reloaded.PayloadLower != entry.PayloadLower {
				t.Fatal("extracted text lost on reload")
			}
			if tc.media == 2 && (len(e.offsets) != 3 || e.offsets[0] != 0 || e.offsets[1] != 30 || e.offsets[2] != 60) {
				t.Fatalf("audio windows=%v", e.offsets)
			}
			asset.Attachments = nil
			client.ingestAsset(asset, true, 0)
			client.drainPersistentQueue()
			entry, _ = client.index.GetEntity(assetIdentity("ws", 17, 0))
			if len(entry.Chunks) != 1 || len(entry.Metadata.Attachments) != 0 {
				t.Fatal("removed attachments left searchable vectors")
			}
		})
	}
}

func TestAttachmentFailureCannotLeakBytesAndCanRetry(t *testing.T) {
	for _, tc := range []struct {
		name   string
		code   int
		status string
		ready  bool
	}{
		{"forbidden", 403, "unavailable", true},
		{"not found", 404, "unavailable", true},
		{"unauthorized", 401, "failed", false},
		{"server error", 500, "failed", false},
		{"network error", 0, "failed", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				http.Error(w, "private payroll secret", tc.code)
			}))
			defer server.Close()
			if tc.code == 0 {
				server.Close()
			}
			storage := newTestStorage(t)
			c := newTaskClient(t, storage, &recordingEmbedder{})
			c.filesURL = server.URL
			c.subscribedRooms[0] = true
			c.inventoryEpochs[0] = c.ReadyGeneration()
			task := &protocol.Task{ID: 1, Title: "public task", Attachments: []protocol.Attachment{{FileId: testAttachmentID, Filename: "secret.docx"}}}
			job, err := c.ingestTask(task, true, 0, false)
			if err != nil || job == nil {
				t.Fatalf("missing initial job: %v", err)
			}
			c.processEmbedJob(*job)
			identity := taskIdentity("ws", 1, 0)
			entry, ok := c.index.GetEntity(identity)
			if !ok || entry.Preview != "public task" || len(entry.Chunks) != 1 {
				t.Fatal("owner text embedding lost")
			}
			if strings.Contains(entry.SearchText, "private payroll") {
				t.Fatal("denied bytes entered index")
			}
			status := entry.Metadata.Attachments[0]
			if status.Status != tc.status || status.Error == "" || strings.Contains(status.Error, "private payroll") {
				t.Fatalf("unexpected failure metadata: %+v", status)
			}
			if ready, err := c.indexComplete(); err != nil || ready != tc.ready {
				t.Fatalf("ready=%v err=%v want=%v", ready, err, tc.ready)
			}
			stored, err := storage.LoadAllEntityEmbeddings()
			if err != nil {
				t.Fatal(err)
			}
			c.index.AddEntity(identity, indexEntryFromStoredEmbedding(stored[identity]))
			if ready, err := c.indexComplete(); err != nil || ready != tc.ready {
				t.Fatalf("reloaded ready=%v err=%v want=%v", ready, err, tc.ready)
			}
			job, err = c.ingestTask(task, false, c.nextVersion.Load(), false)
			if err != nil || job == nil {
				t.Fatal("unsuccessful attachments must retry during reconciliation")
			}
			data := officeFixture(t, map[string]string{"word/document.xml": `<document><body><p><r><t>Recovered attachment</t></r></p></body></document>`})
			recovery := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(data) }))
			defer recovery.Close()
			c.filesURL = recovery.URL
			c.processEmbedJob(*job)
			entry, _ = c.index.GetEntity(identity)
			if entry.Metadata.Attachments[0].Status != "indexed" || entry.Metadata.Attachments[0].Error != "" || !strings.Contains(entry.SearchText, "Recovered attachment") {
				t.Fatalf("attachment did not recover: %+v", entry)
			}
			if ready, err := c.indexComplete(); err != nil || !ready {
				t.Fatalf("recovered attachment blocks activation: %v", err)
			}
		})
	}
}

func TestAssetDeleteDuringEmbeddingCannotResurrectFile(t *testing.T) {
	e := &blockingEmbedder{started: make(chan struct{}), release: make(chan struct{})}
	storage := newTestStorage(t)
	c, err := NewNRCClient(Config{EmbedAssetTypes: []uint16{3}}, "ws", storage, e, NewIndex())
	if err != nil {
		t.Fatal(err)
	}
	c.ingestAsset(protocol.Asset{AssetID: 99, AssetType: 3, Preview: "file"}, true, 0)
	id, entry, ok, err := storage.PeekQueueEntry("ws")
	if err != nil || !ok {
		t.Fatal("missing job")
	}
	done := make(chan bool)
	go func() { done <- c.processEmbedJob(EmbedJob{Workspace: "ws", AssetID: id, Entry: entry}) }()
	<-e.started
	payload := make([]byte, 20)
	binary.BigEndian.PutUint64(payload[8:16], 99)
	c.handleAssetDeleted(payload)
	close(e.release)
	<-done
	if _, ok := c.index.Get("ws", 99); ok {
		t.Fatal("deleted file resurrected")
	}
	stored, err := storage.LoadAllEntityEmbeddings()
	if err != nil || len(stored) != 0 {
		t.Fatalf("stale vectors persisted: %v err=%v", stored, err)
	}
}

func TestAssetNewAttachmentWinsOverInFlightJob(t *testing.T) {
	e := &blockingEmbedder{started: make(chan struct{}), release: make(chan struct{})}
	storage := newTestStorage(t)
	c, _ := NewNRCClient(Config{EmbedAssetTypes: []uint16{3}}, "ws", storage, e, NewIndex())
	asset := protocol.Asset{AssetID: 42, AssetType: 3, Preview: "same text", Attachments: []protocol.Attachment{{FileId: testAttachmentID, Filename: "old.png"}}}
	c.ingestAsset(asset, true, 0)
	id, entry, _, _ := storage.PeekQueueEntry("ws")
	done := make(chan bool)
	go func() { done <- c.processEmbedJob(EmbedJob{Workspace: "ws", AssetID: id, Entry: entry}) }()
	<-e.started
	asset.Attachments[0].Filename = "new.png"
	c.ingestAsset(asset, true, 0)
	close(e.release)
	<-done
	if _, ok := c.index.Get("ws", 42); ok {
		t.Fatal("superseded attachment job published")
	}
	c.drainPersistentQueue()
	indexed, ok := c.index.Get("ws", 42)
	if !ok || indexed.Metadata.Attachments[0].Filename != "new.png" {
		t.Fatal("new attachment not indexed")
	}
}

func rasterFixture(t *testing.T, c color.Color) []byte {
	t.Helper()
	var output bytes.Buffer
	img := image.NewRGBA(image.Rect(0, 0, 128, 128))
	for y := 0; y < 128; y++ {
		for x := 0; x < 128; x++ {
			img.Set(x, y, c)
		}
	}
	if err := png.Encode(&output, img); err != nil {
		t.Fatal(err)
	}
	return output.Bytes()
}

func TestReconciliationRemovesUnindexedDeletedFileQueue(t *testing.T) {
	storage := newTestStorage(t)
	c, err := NewNRCClient(Config{EmbedAssetTypes: []uint16{3}}, "ws", storage, &recordingEmbedder{}, NewIndex())
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []uint64{91, 92} {
		convID := uint64(7)
		if id == 92 {
			convID = 8
		}
		if err := storage.EnqueueAsset("ws", id, QueueEntry{ConvID: convID, AssetType: 3, Preview: "recovered file"}); err != nil {
			t.Fatal(err)
		}
	}
	c.sendMessage = func(opcode uint16, payload []byte) error {
		// This live creation occurs after the empty server snapshot: keep it.
		c.ingestAsset(protocol.Asset{AssetID: 93, ConvID: 7, AssetType: 3, Preview: "fresh file", Payload: "{}"}, true, 0)
		c.pendingReconcilePageMu.Lock()
		ch := c.pendingReconcilePage[7]
		delete(c.pendingReconcilePage, 7)
		c.pendingReconcilePageMu.Unlock()
		ch <- &protocol.AssetListPageResponse{ConvID: 7}
		return nil
	}
	if err := c.Reconcile(context.Background(), 7); err != nil {
		t.Fatal(err)
	}
	c.drainPersistentQueue()
	if _, ok := c.index.Get("ws", 91); ok {
		t.Fatal("offline-deleted queued File was resurrected")
	}
	for _, id := range []uint64{92, 93} {
		if _, ok := c.index.Get("ws", id); !ok {
			t.Fatalf("reconciliation discarded other-scope/live file %d", id)
		}
	}
}

func TestRealMediaOwnerSearch(t *testing.T) {
	if os.Getenv("MEDIA_MODEL_DIR") == "" {
		t.Skip("set MEDIA_MODEL_DIR for real media inference")
	}
	e := newRealEvalEmbedder(t)
	defer e.Close()
	files := map[string][]byte{testAttachmentID: rasterFixture(t, color.RGBA{R: 255, A: 255}), "att_1123456789abcdef0123456789abcdef": rasterFixture(t, color.RGBA{B: 255, A: 255})}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("workspace") != "ws" || r.Header.Get("Authorization") != "Bearer test-secret" {
			http.Error(w, "denied", 403)
			return
		}
		w.Write(files[strings.TrimPrefix(r.URL.Path, "/files/")])
	}))
	defer server.Close()
	c, err := NewNRCClient(Config{EmbedAssetTypes: []uint16{3}, FilesURL: server.URL, NRCBotSecret: "test-secret"}, "ws", newTestStorage(t), e, NewIndex())
	if err != nil {
		t.Fatal(err)
	}
	for i, id := range []string{testAttachmentID, "att_1123456789abcdef0123456789abcdef"} {
		c.ingestAsset(protocol.Asset{AssetID: uint64(i + 1), AssetType: 3, Preview: "sample", Payload: "{}", Attachments: []protocol.Attachment{{FileId: id, Filename: "sample.png", MimeType: "image/png"}}}, true, 0)
	}
	c.drainPersistentQueue()
	results, err := c.index.Search("ws", "a solid red square", e, 0, 2, []uint16{3})
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 2 || results[0].Entity.EntityID != 1 || results[0].Metadata.Attachments[0].Status != "indexed" {
		t.Fatalf("image retrieval did not select red owner: %+v", results)
	}
	t.Logf("red image retrieval: red=%.4f blue=%.4f", results[0].Similarity, results[1].Similarity)
	media, ok := e.(mediaEmbedder)
	if !ok {
		t.Fatal("missing media API")
	}
	wav := make([]byte, 44+32000)
	copy(wav, "RIFF")
	binary.LittleEndian.PutUint32(wav[4:], uint32(len(wav)-8))
	copy(wav[8:], "WAVEfmt ")
	binary.LittleEndian.PutUint32(wav[16:], 16)
	binary.LittleEndian.PutUint16(wav[20:], 1)
	binary.LittleEndian.PutUint16(wav[22:], 1)
	binary.LittleEndian.PutUint32(wav[24:], 16000)
	binary.LittleEndian.PutUint32(wav[28:], 32000)
	binary.LittleEndian.PutUint16(wav[32:], 2)
	binary.LittleEndian.PutUint16(wav[34:], 16)
	copy(wav[36:], "data")
	binary.LittleEndian.PutUint32(wav[40:], 32000)
	for i := 0; i < 16000; i++ {
		binary.LittleEndian.PutUint16(wav[44+i*2:], uint16(int16(math.Sin(float64(i)*2*math.Pi*440/16000)*10000)))
	}
	path := filepath.Join(t.TempDir(), "tone.wav")
	if err := os.WriteFile(path, wav, 0600); err != nil {
		t.Fatal(err)
	}
	vec, err := media.EmbedMedia("audio", path, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(vec) != 768 {
		t.Fatalf("audio dimension=%d", len(vec))
	}
	var norm float64
	for _, v := range vec {
		if math.IsNaN(float64(v)) || math.IsInf(float64(v), 0) {
			t.Fatal("invalid audio vector")
		}
		norm += float64(v) * float64(v)
	}
	if math.Abs(math.Sqrt(norm)-1) > 1e-4 {
		t.Fatalf("audio norm=%g", norm)
	}
	if vec, err := media.EmbedMedia("audio", path, 30); err != nil || len(vec) != 0 {
		t.Fatalf("audio EOF vec=%d err=%v", len(vec), err)
	}
}

func TestFilePaginationAndAttachmentTaskReconcileWithoutWaiting(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-release
		w.Write(officeFixture(t, map[string]string{"word/document.xml": `<document><p><t>Eventually enriched</t></p></document>`}))
	}))
	defer server.Close()
	defer close(release)
	c, err := NewNRCClient(Config{EmbedAssetTypes: []uint16{3}, EmbedTasks: true, FilesURL: server.URL}, "ws", newTestStorage(t), &recordingEmbedder{}, NewIndex())
	if err != nil {
		t.Fatal(err)
	}
	pages := 0
	task := &protocol.Task{ID: 14, ConvID: 7, Title: "attachment task", Status: protocol.TaskStatusTodo,
		Attachments: []protocol.Attachment{{FileId: testAttachmentID, Filename: "report.docx"}}}
	c.sendMessage = func(opcode uint16, payload []byte) error {
		if opcode == protocol.C_ListTasksPaged {
			correlation := binary.BigEndian.Uint32(payload[len(payload)-4:])
			c.handleTaskListPage(encodeTaskPage(7, []*protocol.Task{task}, false, protocol.TaskPageCursor{}, correlation))
			return nil
		}
		if opcode != protocol.C_ListAssetsPaged || binary.BigEndian.Uint16(payload[8:10]) != 3 {
			t.Fatalf("Files require typed pagination: opcode %d", opcode)
		}
		if payload[10] != 1 || binary.BigEndian.Uint16(payload[11:13]) != 1 {
			t.Fatal("File pages must request full content with limit one")
		}
		if pages > 0 && (payload[13] != 1 || binary.BigEndian.Uint64(payload[14:22]) != uint64(pages*11) || binary.BigEndian.Uint64(payload[22:30]) != uint64(pages)) {
			t.Fatal("File page cursor not forwarded")
		}
		pages++
		c.pendingReconcilePageMu.Lock()
		ch := c.pendingReconcilePage[7]
		delete(c.pendingReconcilePage, 7)
		c.pendingReconcilePageMu.Unlock()
		// Three 50KB records exceed the server's single-response byte budget.
		ch <- &protocol.AssetListPageResponse{ConvID: 7, HasMore: pages < 3, NextCursorUpdatedAt: int64(pages * 11), NextCursorAssetID: uint64(pages),
			Assets: []protocol.Asset{{AssetID: uint64(pages), ConvID: 7, AssetType: 3, Preview: "file", Payload: strings.Repeat("x", 50000)}}}
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- c.Reconcile(ctx, 7) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("reconciliation blocked on attachment download")
	}
	if pages != 3 {
		t.Fatalf("File pages=%d", pages)
	}
	workerDone := make(chan struct{})
	go func() { c.drainPersistentQueue(); close(workerDone) }()
	<-started
	// Search can still use the cached/text index while durable enrichment runs.
	if _, ok, err := c.storage.GetEntityQueueEntry(taskIdentity("ws", 14, 7)); err != nil || !ok {
		t.Fatal("task not durably queued")
	}
	release <- struct{}{}
	<-workerDone
	entry, ok := c.index.GetEntity(taskIdentity("ws", 14, 7))
	if !ok || !strings.Contains(entry.SearchText, "Eventually enriched") || entry.Metadata.Attachments[0].Status != "indexed" {
		t.Fatalf("missing eventual enrichment: %+v", entry)
	}
	for id := uint64(1); id <= 3; id++ {
		if file, ok := c.index.GetEntity(assetIdentity("ws", id, 7)); !ok || len(file.Payload) != 50000 {
			t.Fatalf("File page %d not indexed completely", id)
		}
	}
}
