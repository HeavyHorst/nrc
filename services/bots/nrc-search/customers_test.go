package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

func TestCustomerRegisterProjectionArchiveDuplicatesAndRestart(t *testing.T) {
	dir := t.TempDir()
	storage, err := NewStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	index := NewIndex()
	index.storage = storage
	embedder := &mockEmbedderForTest{vec: []float32{1, 0}}
	assets := []protocol.Asset{
		{AssetID: 1, AssetType: 8, Preview: `{"version":1,"title":"needle archived","archived":true}`},
		{AssetID: 2, AssetType: 8, Preview: `{"version":1,"title":"Company Two"}`},
		{AssetID: 3, AssetType: 8, Preview: `{"version":1,"title":"Company Three"}`},
		{AssetID: 4, AssetType: 9, Preview: `{"version":1,"title":"needle","email":"needle@example.com"}`},
		{AssetID: 5, AssetType: 10, Preview: `{"version":1,"title":"needle activity"}`},
	}
	_, err = storage.customerInventory("ws", 0, func(inventory *customerInventory) {
		for _, asset := range assets {
			inventory.Assets[asset.AssetID] = asset
		}
		inventory.Assets[6] = protocol.Asset{AssetID: 6, AssetType: 8, Preview: `{"version":1,"title":"Related only"}`}
		for i, pair := range [][3]uint64{{4, 2, 7}, {2, 4, 7}, {3, 4, 7}, {4, 1, 7}, {4, 6, 6}} {
			id := uint64(i + 1)
			inventory.Edges[id] = protocol.Edge{EdgeID: id, SourceType: 1, TargetType: 1, SourceID: pair[0], TargetID: pair[1], Relation: uint16(pair[2])}
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, asset := range assets {
		identity := assetIdentity("ws", asset.AssetID, 0)
		embedding := StoredEmbedding{AssetType: asset.AssetType, Preview: asset.Preview, Payload: asset.Payload, Vector: []float32{1, 0}}
		if err := storage.StoreEntityEmbedding(identity, embedding); err != nil {
			t.Fatal(err)
		}
		if err := index.AddEntity(identity, indexEntryFromStoredEmbedding(embedding)); err != nil {
			t.Fatal(err)
		}
	}
	filters := SearchFilters{EntityTypes: []EntityType{EntityTypeAsset}, AssetTypes: []uint16{8, 9}, Customer: &protocol.SearchCustomerFilters{}}
	search := func(n int) []SearchResult {
		t.Helper()
		results, err := index.SearchEntitiesParallel("ws", "needle", embedder, 0, n, filters, 2)
		if err != nil {
			t.Fatal(err)
		}
		return results
	}
	if results := search(1); len(results) != 1 || results[0].Entity.EntityID != 2 {
		t.Fatalf("archived top score must not consume top_n: %+v", results)
	}
	results := search(100)
	if len(results) != 2 || results[0].Entity.EntityID != 2 || results[1].Entity.EntityID != 3 {
		t.Fatalf("multi-company/reversed/dedup: %+v", results)
	}
	for _, result := range results {
		if result.AssetType != 8 || string(result.Metadata.Customer) != result.Preview {
			t.Fatalf("projection metadata: %+v", result)
		}
	}
	filters.AssetTypes = []uint16{9}
	if results = search(100); len(results) != 2 {
		t.Fatalf("contact-only reverse membership/RelatedTo: %+v", results)
	}
	filters.AssetTypes = []uint16{8, 9}
	rawFilters := SearchFilters{AssetTypes: []uint16{8, 9, 10}}
	raw, err := index.SearchEntitiesParallel("ws", "needle", embedder, 0, 100, rawFilters, 1)
	if err != nil || len(raw) != 5 {
		t.Fatalf("generic search independence: %v %+v", err, raw)
	}
	// Invalid contacts must not lend their score to an otherwise valid company.
	bad := protocol.Asset{AssetID: 7, AssetType: 9, Preview: `{"version":1,"email":"needle@example.com"}`}
	if err := storage.mutateCustomerRecord("ws", 0, 'a', 7, bad); err != nil {
		t.Fatal(err)
	}
	if err := storage.mutateCustomerRecord("ws", 0, 'e', 99, protocol.Edge{EdgeID: 99, SourceType: 1, SourceID: 7, TargetType: 1, TargetID: 6, Relation: 7}); err != nil {
		t.Fatal(err)
	}
	if err := index.AddEntity(assetIdentity("ws", 7, 0), indexEntryFromStoredEmbedding(StoredEmbedding{AssetType: 9, Preview: bad.Preview, Vector: []float32{1, 0}})); err != nil {
		t.Fatal(err)
	}
	if results = search(100); len(results) != 2 {
		t.Fatalf("malformed contact projected: %+v", results)
	}
	cfg := Config{EmbedAssetTypes: []uint16{8, 9}, ReconcileInterval: time.Hour}
	client, err := NewNRCClient(cfg, "ws", storage, embedder, index)
	if err != nil {
		t.Fatal(err)
	}
	handler := taskSearchTestHandler(t, cfg, storage, embedder, index, client)
	response, _ := postTaskSearch(t, handler, `{"workspace":"ws","query":"needle","conv_id":"0","top_n":1,"include_payload":false,"filters":{"entity_types":["asset"],"asset_types":[8,9],"customer":{}}}`)
	if response.Stale || len(response.Results) != 1 || response.Results[0].Entity.EntityID != 2 || response.Results[0].Payload != "" || response.Results[0].AssetType != 8 {
		t.Fatalf("HTTP customer/topN/payload contract: %+v", response)
	}
	response, _ = postTaskSearch(t, handler, `{"workspace":"ws","query":"needle","conv_id":"0","top_n":100,"filters":{"asset_types":[8,9],"customer":{"include_archived":true}}}`)
	if len(response.Results) != 3 {
		t.Fatalf("HTTP archive/dedup contract: %+v", response)
	}
	// Archive metadata is immediate even while embeddings still contain the old preview.
	_, err = storage.customerInventory("ws", 0, func(inventory *customerInventory) {
		asset := inventory.Assets[2]
		asset.Preview = `{"version":1,"title":"Company Two","archived":true}`
		inventory.Assets[2] = asset
		delete(inventory.Edges, 3)
	})
	if err != nil {
		t.Fatal(err)
	}
	results = search(100)
	if len(results) != 1 || results[0].Entity.EntityID != 3 {
		t.Fatalf("archive/removal: %+v", results)
	}
	filters.AssetTypes = []uint16{9}
	if results = search(100); len(results) != 0 {
		t.Fatalf("removed contact membership must disappear: %+v", results)
	}
	filters.AssetTypes = []uint16{8, 9}
	filters.Customer.IncludeArchived = true
	if results = search(100); len(results) != 3 {
		t.Fatalf("include archived: %+v", results)
	}
	if err := storage.Close(); err != nil {
		t.Fatal(err)
	}
	storage, err = NewStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	index = NewIndex()
	index.storage = storage
	embeddings, err := storage.LoadAllEntityEmbeddings()
	if err != nil {
		t.Fatal(err)
	}
	for identity, embedding := range embeddings {
		if err := index.AddEntity(identity, indexEntryFromStoredEmbedding(embedding)); err != nil {
			t.Fatal(err)
		}
	}
	filters.Customer.IncludeArchived = false
	if results = search(1); len(results) != 1 || results[0].Entity.EntityID != 3 {
		t.Fatalf("restart inventory: %+v", results)
	}
}

func TestCustomerReconciliationPagedGraphAndLiveIngestion(t *testing.T) {
	storage, err := NewStorage(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	embedder := &recordingEmbedder{}
	client, err := NewNRCClient(Config{EmbedAssetTypes: []uint16{8, 9, 10}}, "ws", storage, embedder, NewIndex())
	if err != nil {
		t.Fatal(err)
	}
	client.ingestAsset(protocol.Asset{AssetID: 10, AssetType: 8, Preview: `{"version":1,"title":"Old"}`}, true, 0)
	client.ingestAsset(protocol.Asset{AssetID: 10, AssetType: 8, Preview: `{"version":1,"title":"New","archived":true}`}, true, 0)
	inventory, err := storage.customerInventory("ws", 0, nil)
	if err != nil || string(customerPreview(inventory.Assets[10].Preview)) != `{"version":1,"title":"New","archived":true}` {
		t.Fatalf("live inventory: %v %+v", err, inventory)
	}
	// Populated pages exercise pagination, replacement, and response dispatch.
	pages := 0
	client.sendMessage = func(opcode uint16, payload []byte) error {
		if opcode != protocol.C_ListAllEdgesPaged {
			return fmt.Errorf("unexpected opcode %d", opcode)
		}
		pages++
		response := make([]byte, 27)
		if pages == 1 {
			response[8] = 1
			binary.BigEndian.PutUint64(response[9:], 7)
		} else if binary.BigEndian.Uint64(payload[10:]) != 7 {
			t.Fatal("cursor missing")
		}
		binary.BigEndian.PutUint32(response[23:], binary.BigEndian.Uint32(payload[18:]))
		binary.BigEndian.PutUint16(response[21:], 1)
		response = append(response, customerTestEdgeWire(protocol.Edge{EdgeID: uint64(pages), SourceType: 1, SourceID: 10, TargetType: 1, TargetID: 20, Relation: 7})[:48]...)
		client.handleCustomerEdge(protocol.S_AllEdgeListPage, response)
		return nil
	}
	if err := client.reconcileCustomerEdges(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	if pages != 2 {
		t.Fatalf("pages %d", pages)
	}
	inventory, err = storage.customerInventory("ws", 0, nil)
	if err != nil || len(inventory.Edges) != 2 {
		t.Fatalf("populated pagination: %v %+v", err, inventory)
	}
	text := customerText(`{"version":1,"title":"Company","number":"123","phone":"555","email":"a@example.com"}`, `{"description":"Readable activity"}`)
	for _, value := range []string{"Company", "123", "555", "a@example.com", "Readable activity"} {
		if !containsText(text, value) {
			t.Fatalf("missing %q in %q", value, text)
		}
	}
	var metadata SearchMetadata
	if err := json.Unmarshal([]byte(`{"customer":{"version":1,"title":"Company"}}`), &metadata); err != nil || string(metadata.Customer) == "" {
		t.Fatal("metadata contract", err)
	}
}

func containsText(text, value string) bool {
	for i := 0; i+len(value) <= len(text); i++ {
		if text[i:i+len(value)] == value {
			return true
		}
	}
	return false
}

func customerTestEdgeWire(edge protocol.Edge) []byte {
	data := make([]byte, 52)
	binary.BigEndian.PutUint64(data, edge.EdgeID)
	binary.BigEndian.PutUint64(data[8:], edge.ConvID)
	binary.BigEndian.PutUint16(data[16:], edge.SourceType)
	binary.BigEndian.PutUint64(data[18:], edge.SourceID)
	binary.BigEndian.PutUint16(data[26:], edge.TargetType)
	binary.BigEndian.PutUint64(data[28:], edge.TargetID)
	binary.BigEndian.PutUint16(data[36:], edge.Relation)
	return data
}

func TestCustomerPreviewRequiresCanonicalTitle(t *testing.T) {
	for _, preview := range []string{`{"version":1}`, `{"version":1,"title":""}`, `{"version":1,"title":7}`, `{"version":2,"title":"Company"}`} {
		if customerPreview(preview) != nil {
			t.Fatalf("accepted malformed preview %s", preview)
		}
	}
	if customerPreview(`{"version":1,"title":"Company"}`) == nil {
		t.Fatal("rejected canonical preview")
	}
}

func TestCustomerFailureAfterGraphSnapshotFencesPublicationAndHTTPRecovery(t *testing.T) {
	dir := t.TempDir()
	storage, err := NewStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { storage.Close() }()
	cfg := Config{EmbedAssetTypes: []uint16{8, 9}, EmbedTasks: true, ReconcileInterval: time.Hour}
	client, err := NewNRCClient(cfg, "ws", storage, &recordingEmbedder{}, NewIndex())
	if err != nil {
		t.Fatal(err)
	}
	handler := taskSearchTestHandler(t, cfg, storage, client.embedder, client.index, client)
	fail := true
	client.sendMessage = func(opcode uint16, payload []byte) error {
		switch opcode {
		case protocol.C_ListAssetsPaged:
			client.pendingReconcilePageMu.Lock()
			ch := client.pendingReconcilePage[0]
			delete(client.pendingReconcilePage, 0)
			client.pendingReconcilePageMu.Unlock()
			ch <- &protocol.AssetListPageResponse{}
		case protocol.C_ListAllEdgesPaged:
			response := make([]byte, 27)
			binary.BigEndian.PutUint32(response[23:], binary.BigEndian.Uint32(payload[18:]))
			client.handleCustomerEdge(protocol.S_AllEdgeListPage, response)
		case protocol.C_ListTasksPaged:
			if fail {
				if err := storage.Close(); err != nil {
					t.Fatal(err)
				}
				client.handleCustomerEdge(protocol.S_EdgeCreated, customerTestEdgeWire(protocol.Edge{EdgeID: 99}))
				reopened, err := NewStorage(dir)
				if err != nil {
					t.Fatal(err)
				}
				storage.db = reopened.db
			}
			client.pendingTaskPagesMu.Lock()
			for id, ch := range client.pendingTaskPages {
				ch <- &protocol.TaskListPage{Success: true}
				delete(client.pendingTaskPages, id)
			}
			client.pendingTaskPagesMu.Unlock()
		default:
			return fmt.Errorf("unexpected opcode %d", opcode)
		}
		return nil
	}
	client.taskMutationMu.Lock()
	client.invalidateCustomerInventory(0)
	client.taskMutationMu.Unlock()
	body := `{"workspace":"ws","query":"needle","conv_id":"0","filters":{"asset_types":[8,9],"customer":{}}}`
	response, _ := postTaskSearch(t, handler, body)
	if !response.Stale {
		t.Fatal("HTTP reported fresh after failed live persistence during reconciliation")
	}
	handler.manager.workers.Wait()
	if complete, _ := client.indexComplete(); complete {
		t.Fatal("old reconciliation republished failed epoch")
	}
	fail = false
	response, _ = postTaskSearch(t, handler, body)
	if !response.Stale {
		t.Fatal("recovery request must report the still-stale cached inventory")
	}
	handler.manager.workers.Wait()
	response, _ = postTaskSearch(t, handler, body)
	if response.Stale || client.NeedsReconcile(0, time.Hour) {
		t.Fatal("successful recovery remains stale")
	}
	if complete, err := client.indexComplete(); err != nil || !complete {
		t.Fatalf("recovery incomplete: %v %v", complete, err)
	}
}

func TestCustomerInventoryFailureDirtyAndMutationBoundary(t *testing.T) {
	storage, err := NewStorage(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	client, err := NewNRCClient(Config{EmbedAssetTypes: []uint16{8, 9}}, "ws", storage, &recordingEmbedder{}, NewIndex())
	if err != nil {
		t.Fatal(err)
	}
	client.subscribedRooms[0] = true
	client.roomSyncTimes[0] = time.Now()
	client.inventoryEpochs[0] = client.ReadyGeneration()
	if err := storage.Close(); err != nil {
		t.Fatal(err)
	}
	client.taskMutationMu.Lock()
	done := make(chan struct{})
	go func() {
		client.handleCustomerEdge(protocol.S_EdgeCreated, customerTestEdgeWire(protocol.Edge{EdgeID: 1}))
		close(done)
	}()
	select {
	case <-done:
		t.Fatal("edge persistence bypassed promotion lock")
	case <-time.After(20 * time.Millisecond):
	}
	client.taskMutationMu.Unlock()
	<-done
	if !client.NeedsReconcile(0, time.Hour) {
		t.Fatal("dirty inventory considered fresh")
	}
	if complete, _ := client.indexComplete(); complete {
		t.Fatal("failed persistence considered complete")
	}
	version := client.inventoryFailures
	deleted := make([]byte, 20)
	binary.BigEndian.PutUint64(deleted[8:], 1)
	client.handleAssetDeleted(deleted)
	if client.inventoryFailures <= version {
		t.Fatal("deletion failure did not fence reconciliation")
	}
}

func TestCustomerAttachmentLexicalOverlayTopOne(t *testing.T) {
	dir := t.TempDir()
	storage, err := NewStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { storage.Close() }()
	idx := NewIndex()
	idx.storage = storage
	for id := uint64(1); id <= 2; id++ {
		asset := protocol.Asset{AssetID: id, AssetType: 8, Preview: fmt.Sprintf(`{"version":1,"title":"Company %d"}`, id)}
		if err := storage.mutateCustomerRecord("ws", 0, 'a', id, asset); err != nil {
			t.Fatal(err)
		}
		stored := StoredEmbedding{AssetType: 8, Preview: asset.Preview, Vector: []float32{1, 0}}
		if id == 2 {
			stored.SearchText = "attachmentonlytoken"
			stored.Vector = []float32{0.8, 0.2}
		}
		if err := idx.AddEntity(assetIdentity("ws", id, 0), indexEntryFromStoredEmbedding(stored)); err != nil {
			t.Fatal(err)
		}
		if err := storage.StoreEntityEmbedding(assetIdentity("ws", id, 0), stored); err != nil {
			t.Fatal(err)
		}
	}
	check := func() {
		for _, customer := range []*protocol.SearchCustomerFilters{nil, {}} {
			results, err := idx.SearchEntitiesParallel("ws", "attachmentonlytoken", &mockEmbedderForTest{vec: []float32{1, 0}}, 0, 1, SearchFilters{AssetTypes: []uint16{8}, Customer: customer}, 1)
			if err != nil || len(results) != 1 || results[0].Entity.EntityID != 2 {
				t.Fatalf("attachment lexical ranking: %v %+v", err, results)
			}
		}
	}
	check()
	if err := storage.mutateCustomerRecord("ws", 0, 'a', 2, protocol.Asset{AssetID: 2, AssetType: 8, Preview: `{"version":1,"title":"Updated","archived":true}`}); err != nil {
		t.Fatal(err)
	}
	if err := storage.Close(); err != nil {
		t.Fatal(err)
	}
	storage, err = NewStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	idx = NewIndex()
	idx.storage = storage
	embeddings, err := storage.LoadAllEntityEmbeddings()
	if err != nil {
		t.Fatal(err)
	}
	for identity, stored := range embeddings {
		if err := idx.AddEntity(identity, indexEntryFromStoredEmbedding(stored)); err != nil {
			t.Fatal(err)
		}
	}
	results, err := idx.SearchEntitiesParallel("ws", "attachmentonlytoken", &mockEmbedderForTest{vec: []float32{1, 0}}, 0, 1, SearchFilters{AssetTypes: []uint16{8}}, 1)
	if err != nil || len(results) != 1 || results[0].Entity.EntityID != 2 || results[0].Preview != `{"version":1,"title":"Updated","archived":true}` {
		t.Fatalf("restart archive overlay lost attachment: %v %+v", err, results)
	}
	results, err = idx.SearchEntitiesParallel("ws", "attachmentonlytoken", &mockEmbedderForTest{vec: []float32{1, 0}}, 0, 1, SearchFilters{AssetTypes: []uint16{8}, Customer: &protocol.SearchCustomerFilters{IncludeArchived: true}}, 1)
	if err != nil || len(results) != 1 || results[0].Entity.EntityID != 2 {
		t.Fatalf("restart register lost attachment: %v %+v", err, results)
	}
}

func TestCustomerRebuildCompletenessAndLiveGraphMutation(t *testing.T) {
	storage, err := NewStorage(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	client, err := NewNRCClient(Config{EmbedAssetTypes: []uint16{8, 9, 10}}, "ws", storage, &recordingEmbedder{}, NewIndex())
	if err != nil {
		t.Fatal(err)
	}
	client.subscribedRooms[0] = true
	company := protocol.Asset{AssetID: 1, AssetType: 8, Preview: `{"version":1,"title":"Company"}`}
	contact := protocol.Asset{AssetID: 2, AssetType: 9, Preview: `{"version":1,"title":"Contact","email":"needle@example.com"}`}
	edge := protocol.Edge{EdgeID: 3, SourceType: 1, SourceID: 2, TargetType: 1, TargetID: 1, Relation: 7}
	mutate := true
	client.sendMessage = func(opcode uint16, payload []byte) error {
		switch opcode {
		case protocol.C_ListAssetsPaged:
			var assets []protocol.Asset
			switch binary.BigEndian.Uint16(payload[8:]) {
			case 8:
				assets = []protocol.Asset{company}
			case 9:
				assets = []protocol.Asset{contact}
			}
			client.pendingReconcilePageMu.Lock()
			ch := client.pendingReconcilePage[0]
			delete(client.pendingReconcilePage, 0)
			client.pendingReconcilePageMu.Unlock()
			ch <- &protocol.AssetListPageResponse{Assets: assets}
		case protocol.C_ListAllEdgesPaged:
			if mutate {
				client.handleCustomerEdge(protocol.S_EdgeCreated, customerTestEdgeWire(edge))
			}
			response := make([]byte, 27)
			binary.BigEndian.PutUint32(response[23:], binary.BigEndian.Uint32(payload[18:]))
			if !mutate {
				binary.BigEndian.PutUint16(response[21:], 1)
				response = append(response, customerTestEdgeWire(edge)[:48]...)
			}
			client.handleCustomerEdge(protocol.S_AllEdgeListPage, response)
		default:
			return fmt.Errorf("unexpected opcode %d", opcode)
		}
		return nil
	}
	if err := client.Reconcile(context.Background(), 0); err == nil {
		t.Fatal("mutation during snapshot must fail reconciliation")
	}
	if complete, err := client.indexComplete(); err != nil || complete {
		t.Fatalf("inconsistent graph promoted: %v %v", complete, err)
	}
	inventory, err := storage.customerInventory("ws", 0, nil)
	if err != nil || len(inventory.Edges) != 1 {
		t.Fatalf("live mutation lost: %v %+v", err, inventory)
	}
	mutate = false
	if err := client.Reconcile(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	if complete, _ := client.indexComplete(); complete {
		t.Fatal("queued customer embeddings promoted")
	}
	client.drainPersistentQueue()
	if complete, err := client.indexComplete(); err != nil || !complete {
		t.Fatalf("rebuilt customers not complete: %v %v", complete, err)
	}
	results, err := client.index.SearchEntitiesParallel("ws", "needle", client.embedder, 0, 1, SearchFilters{AssetTypes: []uint16{9}, Customer: &protocol.SearchCustomerFilters{}}, 1)
	if err != nil || len(results) != 1 || results[0].Entity.EntityID != 1 {
		t.Fatalf("rebuilt projection: %v %+v", err, results)
	}
	deleted := make([]byte, 20)
	binary.BigEndian.PutUint64(deleted[8:], 3)
	client.handleCustomerEdge(protocol.S_EdgeDeleted, deleted)
	results, err = client.index.SearchEntitiesParallel("ws", "needle", client.embedder, 0, 1, SearchFilters{AssetTypes: []uint16{9}, Customer: &protocol.SearchCustomerFilters{}}, 1)
	if err != nil || len(results) != 0 {
		t.Fatalf("live edge deletion: %v %+v", err, results)
	}
	assetDeleted := make([]byte, 20)
	binary.BigEndian.PutUint64(assetDeleted[8:], 1)
	client.handleAssetDeleted(assetDeleted)
	inventory, err = storage.customerInventory("ws", 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, exists := inventory.Assets[1]; exists {
		t.Fatal("deleted company survived inventory")
	}
}

func TestCustomerOfflineRemovalAndArchiveReconcileAfterRestart(t *testing.T) {
	dir := t.TempDir()
	storage, err := NewStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	company := protocol.Asset{AssetID: 1, AssetType: 8, Preview: `{"version":1,"title":"needle"}`}
	contact := protocol.Asset{AssetID: 2, AssetType: 9, Preview: `{"version":1,"title":"needle contact"}`}
	_, err = storage.customerInventory("ws", 0, func(inv *customerInventory) {
		inv.Assets[1], inv.Assets[2] = company, contact
		inv.Edges[3] = protocol.Edge{EdgeID: 3, SourceType: 1, SourceID: 2, TargetType: 1, TargetID: 1, Relation: 7}
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := storage.Close(); err != nil {
		t.Fatal(err)
	}
	storage, err = NewStorage(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	client, err := NewNRCClient(Config{EmbedAssetTypes: []uint16{8, 9}}, "ws", storage, &recordingEmbedder{}, NewIndex())
	if err != nil {
		t.Fatal(err)
	}
	company.Preview = `{"version":1,"title":"needle","archived":true}`
	client.sendMessage = func(opcode uint16, payload []byte) error {
		switch opcode {
		case protocol.C_ListAssetsPaged:
			var assets []protocol.Asset
			if binary.BigEndian.Uint16(payload[8:]) == 8 {
				assets = []protocol.Asset{company}
			}
			client.pendingReconcilePageMu.Lock()
			ch := client.pendingReconcilePage[0]
			delete(client.pendingReconcilePage, 0)
			client.pendingReconcilePageMu.Unlock()
			ch <- &protocol.AssetListPageResponse{Assets: assets}
		case protocol.C_ListAllEdgesPaged:
			response := make([]byte, 27)
			binary.BigEndian.PutUint32(response[23:], binary.BigEndian.Uint32(payload[18:]))
			client.handleCustomerEdge(protocol.S_AllEdgeListPage, response)
		default:
			return fmt.Errorf("unexpected opcode %d", opcode)
		}
		return nil
	}
	if err := client.Reconcile(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	client.drainPersistentQueue()
	inventory, err := storage.customerInventory("ws", 0, nil)
	if err != nil || len(inventory.Assets) != 1 || len(inventory.Edges) != 0 || inventory.Assets[1].Preview != company.Preview {
		t.Fatalf("offline reconciliation: %v %+v", err, inventory)
	}
	filters := SearchFilters{AssetTypes: []uint16{8, 9}, Customer: &protocol.SearchCustomerFilters{}}
	results, err := client.index.SearchEntitiesParallel("ws", "needle", client.embedder, 0, 1, filters, 1)
	if err != nil || len(results) != 0 {
		t.Fatalf("offline archive still visible: %v %+v", err, results)
	}
	filters.Customer.IncludeArchived = true
	results, err = client.index.SearchEntitiesParallel("ws", "needle", client.embedder, 0, 1, filters, 1)
	if err != nil || len(results) != 1 || results[0].Entity.EntityID != 1 {
		t.Fatalf("include archived after restart: %v %+v", err, results)
	}
}
