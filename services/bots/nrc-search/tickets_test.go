package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/heavyhorst/nrc/protocol-go"
)

func TestTicketConversationSearchHTTPAndReload(t *testing.T) {
	dir := t.TempDir()
	storage, err := NewStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { storage.Close() }()
	index := NewIndex()
	embedder := &recordingEmbedder{}
	cfg := Config{EmbedAssetTypes: []uint16{13, 14}, ReconcileInterval: time.Hour}
	client, err := NewNRCClient(cfg, "ws", storage, embedder, index)
	if err != nil {
		t.Fatal(err)
	}
	handler := taskSearchTestHandler(t, cfg, storage, embedder, index, client)
	ticket := func(id uint64, status, assignee, company string) protocol.Asset {
		preview, err := json.Marshal(map[string]any{"version": 1, "title": fmt.Sprintf(`Request %d: R&D "timeout"`, id), "status": status, "assignee": assignee, "company_id": company, "requester": "ada@example.test"})
		if err != nil {
			t.Fatal(err)
		}
		return protocol.Asset{AssetID: id, AssetType: 13, Preview: string(preview), Payload: "original symptom"}
	}
	assets := []protocol.Asset{
		ticket(1, "closed", "Sam", "8"), ticket(2, "open", "Other", "8"), ticket(3, "open", "Sam", "9"),
		ticket(4, "open", "Sam", "8"), ticket(5, "open", "Sam", "8"),
	}
	for i, kind := range []string{"customer_reply", "public_reply", "internal_note"} {
		assets = append(assets, protocol.Asset{AssetID: uint64(20 + i), AssetType: 14, ParentType: protocol.ParentTypeAsset, ParentID: 4, Preview: fmt.Sprintf(`{"version":1,"kind":%q,"author":"Ada"}`, kind), Payload: "Distinctive diagnostic needle " + kind})
	}
	// Each wrong facet has an even stronger lexical hit; none may consume top-N.
	for id := uint64(1); id <= 3; id++ {
		assets = append(assets, protocol.Asset{AssetID: 30 + id, AssetType: 14, ParentType: protocol.ParentTypeAsset, ParentID: id, Preview: `{"version":1,"kind":"internal_note"}`, Payload: "needle needle needle needle"})
	}
	assets = append(assets,
		protocol.Asset{AssetID: 40, AssetType: 14, ParentType: protocol.ParentTypeTask, ParentID: 5, Payload: "wrong parent poison"},
		protocol.Asset{AssetID: 41, AssetType: 14, ConvID: 7, ParentType: protocol.ParentTypeAsset, ParentID: 5, Payload: "wrong room poison"},
		protocol.Asset{AssetID: 42, AssetType: 14, ParentType: protocol.ParentTypeAsset, ParentID: 999, Payload: "orphan poison"})
	for _, asset := range assets {
		if err := client.ingestAsset(asset, true, 0); err != nil {
			t.Fatal(err)
		}
	}
	client.drainPersistentQueue()
	request := `{"workspace":"ws","query":"needle","conv_id":"0","top_n":1,"filters":{"entity_types":["asset"],"asset_types":[13],"ticket":{"status":"open","assignee":"Sam","company_id":"8"}}}`
	response, _ := postTaskSearch(t, handler, request)
	if len(response.Results) != 1 || response.Results[0].Entity.EntityID != 4 || response.Results[0].Metadata.Ticket == nil || response.Results[0].Payload != "" {
		t.Fatalf("conversation match/facets before top-one: %#v", response)
	}
	text := func(query string) searchResponse {
		body := fmt.Sprintf(`{"workspace":"ws","mode":"text","query":%q,"conv_id":"0","top_n":100,"include_payload":true,"filters":{"asset_types":[13],"ticket":{"status":"open","assignee":"Sam","company_id":"8"}}}`, query)
		response, _ := postTaskSearch(t, handler, body)
		return response
	}
	for _, query := range []string{"DIAGNOSTIC", "#4", "original symptom", "ada@example.test", "customer_reply", "public_reply", "internal_note", `R&D "timeout"`} {
		got := text(query)
		if len(got.Results) == 0 || got.Results[0].Entity.EntityID != 4 || got.Results[0].Payload != "original symptom" {
			t.Fatalf("query %q: %#v", query, got)
		}
	}
	if got := text("needle"); got.TotalCount != 1 || len(got.Results) != 1 {
		t.Fatalf("reply hits not deduplicated: %#v", got)
	}
	if got := text("poison"); len(got.Results) != 0 {
		t.Fatalf("invalid child projected: %#v", got)
	}
	// Parent-only linkage changes must persist even when content/hash is unchanged.
	entry := assets[5]
	entry.ParentID = 5
	if err := client.ingestAsset(entry, true, 0); err != nil {
		t.Fatal(err)
	}
	client.drainPersistentQueue()
	if got := text("Distinctive"); got.TotalCount != 2 {
		t.Fatalf("parent reassignment missing: %#v", got)
	}
	for offset := 0; offset < 2; offset++ {
		body := fmt.Sprintf(`{"workspace":"ws","mode":"text","query":"Distinctive","offset":%d,"top_n":1,"filters":{"ticket":{"status":"open","assignee":"Sam","company_id":"8"}}}`, offset)
		page, _ := postTaskSearch(t, handler, body)
		if page.TotalCount != 2 || len(page.Results) != 1 || page.Results[0].Entity.EntityID != uint64(4+offset) || page.HasMore != (offset == 0) {
			t.Fatalf("ticket paging: %#v", page)
		}
	}
	if err := storage.Close(); err != nil {
		t.Fatal(err)
	}
	storage, err = NewStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	index = NewIndex()
	stored, err := storage.LoadAllEntityEmbeddings()
	if err != nil {
		t.Fatal(err)
	}
	for identity, embedding := range stored {
		if err := index.AddEntity(identity, indexEntryFromStoredEmbedding(embedding)); err != nil {
			t.Fatal(err)
		}
	}
	got, err := index.SearchText("ws", "distinctive", 0, SearchFilters{Ticket: &protocol.SearchTicketFilters{Status: "open", Assignee: "Sam", CompanyID: "8"}})
	if err != nil || len(got) != 2 {
		t.Fatalf("restart lost conversation metadata: %#v %v", got, err)
	}
	got, err = index.SearchText("ws", `R&D "timeout"`, 0, SearchFilters{Ticket: &protocol.SearchTicketFilters{Status: "open", Assignee: "Sam", CompanyID: "8"}})
	if err != nil || len(got) != 2 {
		t.Fatalf("restart lost literal metadata search: %#v %v", got, err)
	}
	// A semantic match exists only in ticket 4's reply, not its original request.
	for id, vector := range map[uint64][]float32{4: {-1, 0}, 5: {0.8, 0.6}, 20: {0, 1}, 21: {1, 0}, 22: {0, 1}} {
		identity := assetIdentity("ws", id, 0)
		entry, _ := index.GetEntity(identity)
		copy := *entry
		copy.Vector = vector
		copy.Chunks = []IndexChunk{{Vector: vector}}
		if err := index.AddEntity(identity, &copy); err != nil {
			t.Fatal(err)
		}
	}
	got, err = index.SearchEntitiesParallel("ws", "semantic synonym", &mockEmbedderForTest{vec: []float32{1, 0}}, 0, 1, SearchFilters{Ticket: &protocol.SearchTicketFilters{Status: "open", Assignee: "Sam", CompanyID: "8"}}, 2)
	if err != nil || len(got) != 1 || got[0].Entity.EntityID != 4 {
		t.Fatalf("reply vectors not ranked with ticket: %#v %v", got, err)
	}
	index.Remove("ws", 5)
	got, err = index.SearchText("ws", "distinctive", 0, SearchFilters{Ticket: &protocol.SearchTicketFilters{}})
	if err != nil || len(got) != 1 || got[0].Entity.EntityID != 4 {
		t.Fatalf("deleted parent retained child: %#v %v", got, err)
	}
	got, err = index.SearchText("other-workspace", "needle", 0, SearchFilters{Ticket: &protocol.SearchTicketFilters{}})
	if err != nil || len(got) != 0 {
		t.Fatalf("cross-workspace result: %#v %v", got, err)
	}
}

func TestTicketSearchRejectsConflictingScopes(t *testing.T) {
	for _, body := range []string{
		`{"entity_types":["task"],"ticket":{}}`, `{"asset_types":[14],"ticket":{}}`,
		`{"customer":{},"ticket":{}}`, `{"task":{},"ticket":{}}`,
	} {
		var filters SearchFilters
		if err := json.Unmarshal([]byte(body), &filters); err != nil {
			t.Fatal(err)
		}
		req := searchRequest{Workspace: "ws", Query: "needle", Filters: filters}
		if req.normalize() == nil {
			t.Fatalf("accepted incompatible ticket request %s", body)
		}
	}
}

func TestTicketObsoleteJobAndDurableDeletion(t *testing.T) {
	dir := t.TempDir()
	storage, err := NewStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { storage.Close() }()
	client, err := NewNRCClient(Config{EmbedAssetTypes: []uint16{13, 14}}, "ws", storage, &recordingEmbedder{}, NewIndex())
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []uint64{4, 5} {
		if err := client.ingestAsset(protocol.Asset{AssetID: id, AssetType: 13, Preview: `{"version":1,"title":"Ticket","status":"open"}`}, true, 0); err != nil {
			t.Fatal(err)
		}
	}
	entry := protocol.Asset{AssetID: 20, AssetType: 14, ParentType: protocol.ParentTypeAsset, ParentID: 4, Preview: `{"version":1,"kind":"internal_note"}`, Payload: "durable diagnostic"}
	if err := client.ingestAsset(entry, true, 0); err != nil {
		t.Fatal(err)
	}
	client.drainPersistentQueue()
	e := &blockingEmbedder{started: make(chan struct{}), release: make(chan struct{})}
	client.embedder = e
	changed := entry
	changed.Payload = "obsolete text"
	if err := client.ingestAsset(changed, true, 0); err != nil {
		t.Fatal(err)
	}
	id, job, ok, err := storage.PeekQueueEntry("ws")
	if err != nil || !ok {
		t.Fatal("missing queued update", err)
	}
	done := make(chan bool)
	go func() { done <- client.processEmbedJob(EmbedJob{Workspace: "ws", AssetID: id, Entry: job}) }()
	<-e.started
	entry.ParentID = 5
	if err := client.ingestAsset(entry, true, 0); err != nil {
		t.Fatal(err)
	}
	close(e.release)
	<-done
	got, err := client.index.SearchText("ws", "durable diagnostic", 0, SearchFilters{Ticket: &protocol.SearchTicketFilters{}})
	if err != nil || len(got) != 1 || got[0].Entity.EntityID != 5 {
		t.Fatalf("obsolete job restored old linkage: %#v %v", got, err)
	}
	deleteAsset := func(id uint64) {
		payload := make([]byte, 20)
		binary.BigEndian.PutUint64(payload[8:16], id)
		client.handleAssetDeleted(payload)
	}
	deleteAsset(20)
	client.embedder = &recordingEmbedder{}
	entry.AssetID = 21
	entry.ParentID = 4
	if err := client.ingestAsset(entry, true, 0); err != nil {
		t.Fatal(err)
	}
	client.drainPersistentQueue()
	deleteAsset(4)
	if err := storage.Close(); err != nil {
		t.Fatal(err)
	}
	storage, err = NewStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	stored, err := storage.LoadAllEntityEmbeddings()
	if err != nil {
		t.Fatal(err)
	}
	index := NewIndex()
	for identity, embedding := range stored {
		if identity.EntityID == 4 || identity.EntityID == 20 {
			t.Fatalf("deleted record persisted: %#v", identity)
		}
		if err := index.AddEntity(identity, indexEntryFromStoredEmbedding(embedding)); err != nil {
			t.Fatal(err)
		}
	}
	got, err = index.SearchText("ws", "durable diagnostic", 0, SearchFilters{Ticket: &protocol.SearchTicketFilters{}})
	if err != nil || len(got) != 0 {
		t.Fatalf("deleted ticket/entry search resurrected: %#v %v", got, err)
	}
}
