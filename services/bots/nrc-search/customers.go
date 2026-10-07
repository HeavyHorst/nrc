package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"log/slog"
	"reflect"
	"sort"
	"strings"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
	"go.etcd.io/bbolt"
)

// The inventory is independent of embeddings: archive and membership mutations
// are visible without waiting for the embedding worker, and survive restart.
type customerInventory struct {
	Assets map[uint64]protocol.Asset
	Edges  map[uint64]protocol.Edge
}

// Caller holds taskMutationMu, shared with generation promotion.
func (c *NRCClient) invalidateCustomerInventory(convID uint64) {
	c.inventoryFailures++
	if c.inventoryDirty == nil {
		c.inventoryDirty = map[uint64]bool{}
	}
	c.inventoryDirty[convID] = true
	delete(c.inventoryEpochs, convID)
}

func (s *Storage) customerAssets(workspace string, convID uint64, ids []uint64) (map[uint64]protocol.Asset, error) {
	assets := map[uint64]protocol.Asset{}
	if len(ids) == 0 {
		return assets, nil
	}
	err := s.db.View(func(tx *bbolt.Tx) error {
		bucket := tx.Bucket([]byte(fmt.Sprintf("customer_inventory_records/%s/%d", workspace, convID)))
		if bucket == nil {
			return nil
		}
		for _, id := range ids {
			if data := bucket.Get(customerRecordKey('a', id)); data != nil {
				var asset protocol.Asset
				if err := gobDecode(data, &asset); err != nil {
					return err
				}
				assets[id] = asset
			}
		}
		return nil
	})
	return assets, err
}

func (s *Storage) customerInventory(workspace string, convID uint64, update func(*customerInventory)) (customerInventory, error) {
	inventory := customerInventory{Assets: map[uint64]protocol.Asset{}, Edges: map[uint64]protocol.Edge{}}
	operation := func(tx *bbolt.Tx) error {
		name := []byte(fmt.Sprintf("customer_inventory_records/%s/%d", workspace, convID))
		bucket := tx.Bucket(name)
		if update != nil {
			var err error
			bucket, err = tx.CreateBucketIfNotExists(name)
			if err != nil {
				return err
			}
		}
		if bucket != nil {
			if err := bucket.ForEach(func(key, data []byte) error {
				if key[0] == 'a' {
					var asset protocol.Asset
					if err := gobDecode(data, &asset); err != nil {
						return err
					}
					inventory.Assets[asset.AssetID] = asset
				} else {
					var edge protocol.Edge
					if err := gobDecode(data, &edge); err != nil {
						return err
					}
					inventory.Edges[edge.EdgeID] = edge
				}
				return nil
			}); err != nil {
				return err
			}
		}
		if update == nil {
			return nil
		}
		beforeAssets, beforeEdges := make(map[uint64]protocol.Asset), make(map[uint64]protocol.Edge)
		for id, asset := range inventory.Assets {
			beforeAssets[id] = asset
		}
		for id, edge := range inventory.Edges {
			beforeEdges[id] = edge
		}
		update(&inventory)
		for id := range beforeAssets {
			if _, ok := inventory.Assets[id]; !ok {
				if err := bucket.Delete(customerRecordKey('a', id)); err != nil {
					return err
				}
			}
		}
		for id := range beforeEdges {
			if _, ok := inventory.Edges[id]; !ok {
				if err := bucket.Delete(customerRecordKey('e', id)); err != nil {
					return err
				}
			}
		}
		for id, asset := range inventory.Assets {
			if !reflect.DeepEqual(beforeAssets[id], asset) {
				if err := putCustomerRecord(bucket, 'a', id, asset); err != nil {
					return err
				}
			}
		}
		for id, edge := range inventory.Edges {
			if !reflect.DeepEqual(beforeEdges[id], edge) {
				if err := putCustomerRecord(bucket, 'e', id, edge); err != nil {
					return err
				}
			}
		}
		return nil
	}
	var err error
	if update == nil {
		err = s.db.View(operation)
	} else {
		err = s.db.Update(operation)
	}
	return inventory, err
}

func customerRecordKey(kind byte, id uint64) []byte {
	key := make([]byte, 9)
	key[0] = kind
	binary.BigEndian.PutUint64(key[1:], id)
	return key
}

func putCustomerRecord(bucket *bbolt.Bucket, kind byte, id uint64, value any) error {
	data, err := gobEncode(value)
	if err != nil {
		return err
	}
	return bucket.Put(customerRecordKey(kind, id), data)
}

// Live events touch only one durable record, never deserialize the graph.
func (s *Storage) mutateCustomerRecord(workspace string, convID uint64, kind byte, id uint64, value any) error {
	return s.db.Update(func(tx *bbolt.Tx) error {
		bucket, err := tx.CreateBucketIfNotExists([]byte(fmt.Sprintf("customer_inventory_records/%s/%d", workspace, convID)))
		if err != nil {
			return err
		}
		if value == nil {
			return bucket.Delete(customerRecordKey(kind, id))
		}
		return putCustomerRecord(bucket, kind, id, value)
	})
}

func customerPreview(preview string) json.RawMessage {
	var value struct {
		Version int    `json:"version"`
		Title   string `json:"title"`
	}
	if json.Unmarshal([]byte(preview), &value) != nil || value.Version != 1 || value.Title == "" {
		return nil
	}
	return json.RawMessage(preview)
}

func customerText(preview, payload string) string {
	var parts []string
	var walk func(any)
	walk = func(value any) {
		switch v := value.(type) {
		case string:
			parts = append(parts, v)
		case float64:
			parts = append(parts, fmt.Sprint(v))
		case map[string]any:
			keys := make([]string, 0, len(v))
			for k := range v {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, k := range keys {
				walk(v[k])
			}
		case []any:
			for _, item := range v {
				walk(item)
			}
		}
	}
	for _, source := range []string{preview, payload} {
		var value any
		if json.Unmarshal([]byte(source), &value) == nil {
			walk(value)
		} else {
			parts = append(parts, source)
		}
	}
	return strings.Join(parts, "\n")
}

func (idx *Index) searchCustomers(workspace, query string, embedder Embedder, convID uint64, topN int, filters SearchFilters, workers int) ([]SearchResult, error) {
	idx.mu.RLock()
	storage := idx.storage
	idx.mu.RUnlock()
	if storage == nil {
		return nil, fmt.Errorf("customer inventory unavailable")
	}
	inventory, err := storage.customerInventory(workspace, convID, nil)
	if err != nil {
		return nil, err
	}
	rawFilters := filters
	rawFilters.Customer = nil
	// No raw truncation, including when ingestion adds candidates concurrently.
	// The public limit applies only after company projection and deduplication.
	raw, err := idx.SearchEntitiesParallel(workspace, query, embedder, convID, int(^uint(0)>>1), rawFilters, workers)
	if err != nil {
		return nil, err
	}
	companies := map[uint64]protocol.Asset{}
	for id, asset := range inventory.Assets {
		if asset.AssetType != protocol.AssetTypeCustomerCompany || customerPreview(asset.Preview) == nil {
			continue
		}
		var preview struct {
			Archived bool `json:"archived"`
		}
		_ = json.Unmarshal([]byte(asset.Preview), &preview)
		if !filters.Customer.IncludeArchived && preview.Archived {
			continue
		}
		companies[id] = asset
	}
	adjacency := map[uint64][]uint64{}
	for _, edge := range inventory.Edges {
		if edge.Relation == protocol.RelationMemberOf && edge.SourceType == protocol.TargetTypeAsset && edge.TargetType == protocol.TargetTypeAsset {
			adjacency[edge.SourceID] = append(adjacency[edge.SourceID], edge.TargetID)
			adjacency[edge.TargetID] = append(adjacency[edge.TargetID], edge.SourceID)
		}
	}
	results := map[uint64]SearchResult{}
	for _, match := range raw {
		targets := map[uint64]bool{}
		if match.AssetType == protocol.AssetTypeCustomerCompany {
			targets[match.Entity.EntityID] = true
		}
		if match.AssetType == protocol.AssetTypeCustomerContact {
			asset, ok := inventory.Assets[match.Entity.EntityID]
			if !ok || customerPreview(asset.Preview) == nil {
				continue
			}
			for _, id := range adjacency[match.Entity.EntityID] {
				targets[id] = true
			}
		}
		for id := range targets {
			company, ok := companies[id]
			if !ok {
				continue
			}
			if old, exists := results[id]; exists && old.Score >= match.Score {
				continue
			}
			result := match
			result.Entity = assetIdentity(workspace, id, convID)
			result.AssetID = id
			result.AssetType = protocol.AssetTypeCustomerCompany
			result.Preview = company.Preview
			result.Payload = company.Payload
			result.Metadata = SearchMetadata{AssetType: protocol.AssetTypeCustomerCompany, Customer: customerPreview(company.Preview)}
			results[id] = result
		}
	}
	out := make([]SearchResult, 0, len(results))
	for _, result := range results {
		out = append(out, result)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Score != out[j].Score {
			return out[i].Score > out[j].Score
		}
		return identityLess(out[i].Entity, out[j].Entity)
	})
	if topN < len(out) {
		out = out[:topN]
	}
	return out, nil
}

func (c *NRCClient) handleCustomerEdge(opcode uint16, data []byte) {
	if opcode == protocol.S_AllEdgeListPage {
		c.customerMu.Lock()
		defer c.customerMu.Unlock()
		page, err := protocol.DecodeAllEdgeListPage(data)
		if err == nil {
			if ch := c.customerPages[page.CorrelationID]; ch != nil {
				ch <- page
				delete(c.customerPages, page.CorrelationID)
			}
		}
		return
	}
	var convID, id uint64
	var edge protocol.Edge
	if opcode == protocol.S_EdgeCreated {
		response, err := protocol.DecodeEdgeCreated(data)
		if err != nil {
			return
		}
		edge = response.Edge
		convID, id = edge.ConvID, edge.EdgeID
	} else {
		response, err := protocol.DecodeEdgeDeleted(data)
		if err != nil {
			return
		}
		convID, id = response.ConvID, response.EdgeID
	}
	c.taskMutationMu.Lock()
	defer c.taskMutationMu.Unlock()
	c.customerVersion++
	var value any
	if opcode == protocol.S_EdgeCreated {
		value = edge
	}
	err := c.storage.mutateCustomerRecord(c.workspace, convID, 'e', id, value)
	if err != nil {
		slog.Error("persist customer edge inventory", "error", err)
		c.invalidateCustomerInventory(convID)
	}
}

func (c *NRCClient) reconcileCustomerEdges(ctx context.Context, convID uint64) error {
	c.taskMutationMu.Lock()
	version := c.customerVersion
	c.taskMutationMu.Unlock()
	edges := map[uint64]protocol.Edge{}
	var cursor uint64
	for {
		id := c.correlationID()
		ch := make(chan *protocol.AllEdgeListPageResponse, 1)
		c.customerMu.Lock()
		if c.customerPages == nil {
			c.customerPages = map[uint32]chan *protocol.AllEdgeListPageResponse{}
		}
		c.customerPages[id] = ch
		c.customerMu.Unlock()
		err := c.sendProtocolMessage(protocol.C_ListAllEdgesPaged, protocol.EncodeListAllEdgesPaged(int64(convID), 100, cursor, id))
		if err == nil {
			select {
			case page := <-ch:
				if page.ConvID != convID {
					err = fmt.Errorf("edge page scope mismatch")
				} else {
					for _, edge := range page.Edges {
						edges[edge.EdgeID] = edge
					}
					if page.HasMore {
						if page.NextEdgeID <= cursor {
							err = fmt.Errorf("edge cursor did not advance")
						} else {
							cursor = page.NextEdgeID
						}
					} else {
						cursor = 0
					}
				}
			case <-ctx.Done():
				err = ctx.Err()
			case <-time.After(reconcileListTimeout):
				err = fmt.Errorf("edge page timeout")
			}
		}
		c.customerMu.Lock()
		delete(c.customerPages, id)
		c.customerMu.Unlock()
		if err != nil {
			return err
		}
		if cursor == 0 {
			break
		}
	}
	c.taskMutationMu.Lock()
	defer c.taskMutationMu.Unlock()
	// Never overwrite a live mutation with an older snapshot. Retry the inventory
	// rather than claiming generation completeness with an inconsistent graph.
	if version != c.customerVersion {
		return fmt.Errorf("customer edges changed during reconciliation")
	}
	_, err := c.storage.customerInventory(c.workspace, convID, func(inventory *customerInventory) { inventory.Edges = edges })
	if err != nil {
		c.invalidateCustomerInventory(convID)
	}
	return err
}
