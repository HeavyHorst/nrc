package main

import (
	"context"
	"fmt"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type assetState struct {
	Type             uint16
	Preview, Payload string
}

func assetValue(v protocol.Asset) assetState { return assetState{v.AssetType, v.Preview, v.Payload} }
func edgeKey(v protocol.Edge) string {
	return fmt.Sprintf("%d/%d/%d/%d/%d", v.SourceType, v.SourceID, v.TargetType, v.TargetID, v.Relation)
}
func deleteKey(id uint64) string { return fmt.Sprintf("delete-%d", id) }

func (a *actor) observeAsset(v protocol.Asset) error {
	w := a.ws
	w.mu.Lock()
	defer w.mu.Unlock()
	e := w.assets[v.Preview]
	if v.ConvID != 0 || e == nil || e.asset != assetValue(v) || v.AssetID == 0 || (e.id != 0 && e.id != v.AssetID) {
		return fmt.Errorf("unknown/corrupt asset")
	}
	e.id = v.AssetID
	if err := a.observe(e, "asset"); err != nil {
		return err
	}
	a.assets[v.AssetID] = assetValue(v)
	return nil
}

func (a *actor) observeEdge(v protocol.Edge) error {
	w := a.ws
	w.mu.Lock()
	defer w.mu.Unlock()
	e := w.edges[edgeKey(v)]
	if v.ConvID != 0 || e == nil || v.EdgeID == 0 || (e.id != 0 && e.id != v.EdgeID) || v.CreatedBy != fmt.Sprintf("sim-%d", w.actors[0].id) {
		return fmt.Errorf("unknown/corrupt membership edge")
	}
	e.id = v.EdgeID
	if err := a.observe(e, "edge"); err != nil {
		return err
	}
	a.edges[v.EdgeID] = v
	return nil
}

func (a *actor) observeDelete(kind string, scope, id uint64) error {
	w := a.ws
	w.mu.Lock()
	defer w.mu.Unlock()
	if scope != 0 {
		return fmt.Errorf("deletion scope mismatch")
	}
	var e *event
	switch kind {
	case "task":
		e = w.tasks[deleteKey(id)]
	case "asset":
		e = w.assets[deleteKey(id)]
	case "edge":
		e = w.edges[deleteKey(id)]
	}
	if err := a.observe(e, "delete_"+kind); err != nil {
		return err
	}
	switch kind {
	case "task":
		delete(a.cache, id)
	case "asset":
		delete(a.assets, id)
	case "edge":
		delete(a.edges, id)
	}
	return nil
}

func (w *workspace) seedRecords(ctx context.Context) error {
	a := w.actors[0]
	for _, state := range []assetState{
		{protocol.AssetTypeNote, fmt.Sprintf(`{"title":%q,"project":"simulation"}`, w.name+" note"), "# Shared note\nSynthetic workspace content."},
		{protocol.AssetTypeSlice, fmt.Sprintf(`{"version":1,"name":%q,"owner":"","outcome":"simulation","closed":false}`, w.name+" slice"), ""},
	} {
		w.mu.Lock()
		e := w.expect(a, 0, false)
		e.asset = state
		w.assets[state.Preview] = e
		w.mu.Unlock()
		r, err := a.request(ctx, "create_asset", false, func(id uint32) (uint16, []byte, error) {
			return protocol.C_CreateAsset, protocol.EncodeCreateAssetWithCorrelation(0, state.Type, protocol.ParentTypeNone, 0, state.Preview, state.Payload, id), nil
		})
		if err != nil {
			return err
		}
		w.assetIDs = append(w.assetIDs, r.data.(protocol.Asset).AssetID)
	}
	for _, source := range []struct {
		kind uint16
		id   uint64
	}{{protocol.TargetTypeTask, w.taskIDs[0]}, {protocol.TargetTypeAsset, w.assetIDs[0]}} {
		edge := protocol.Edge{SourceType: source.kind, SourceID: source.id, TargetType: protocol.TargetTypeAsset, TargetID: w.assetIDs[1], Relation: protocol.RelationMemberOf}
		w.mu.Lock()
		e := w.expect(a, 0, false)
		e.edge = edge
		w.edges[edgeKey(edge)] = e
		w.mu.Unlock()
		r, err := a.request(ctx, "create_membership", false, func(id uint32) (uint16, []byte, error) {
			return protocol.C_CreateEdge, protocol.EncodeCreateEdgeWithCorrelation(0, edge.SourceType, edge.SourceID, edge.TargetType, edge.TargetID, edge.Relation, id), nil
		})
		if err != nil {
			return err
		}
		w.edgeIDs = append(w.edgeIDs, r.data.(protocol.Edge).EdgeID)
	}
	return nil
}

func (a *actor) editNote(ctx context.Context, measured bool) error {
	w := a.ws
	a.action++
	state := assetState{protocol.AssetTypeNote, fmt.Sprintf(`{"title":%q,"project":"simulation"}`, fmt.Sprintf("%s-u%d-note%d", w.name, a.id, a.action)), fmt.Sprintf("# Revision %d\nWritten by user %d.", a.action, a.id)}
	w.mu.Lock()
	e := w.expect(a, 0, measured)
	e.asset = state
	e.id = w.assetIDs[0]
	w.assets[state.Preview] = e
	w.mu.Unlock()
	_, err := a.request(ctx, "edit_note", measured, func(id uint32) (uint16, []byte, error) {
		return protocol.C_UpdateAsset, protocol.EncodeUpdateAssetWithCorrelation(0, w.assetIDs[0], state.Preview, state.Payload, id), nil
	})
	return err
}

func (a *actor) getAsset(ctx context.Context, id uint64, measured bool) (assetState, error) {
	r, err := a.request(ctx, "read_note", measured, func(corr uint32) (uint16, []byte, error) {
		return protocol.C_GetAsset, protocol.EncodeGetAssetWithCorrelation(0, id, corr), nil
	})
	if err != nil {
		return assetState{}, err
	}
	v := r.data.(protocol.Asset)
	w := a.ws
	w.mu.Lock()
	defer w.mu.Unlock()
	e := w.assets[v.Preview]
	if v.ConvID != 0 || v.AssetID != id || e == nil || e.asset != assetValue(v) {
		return assetState{}, fmt.Errorf("asset read contains unrecognized state")
	}
	return assetValue(v), nil
}

func (w *workspace) reconcileRecords(ctx context.Context, refresh *actor) error {
	for _, id := range w.assetIDs {
		state, err := w.actors[len(w.actors)-1].getAsset(ctx, id, false)
		if err != nil {
			return err
		}
		w.mu.Lock()
		for _, a := range w.actors {
			if a == refresh {
				a.assets[id] = state
			} else if a.subscribed && a.assets[id] != state {
				w.sim.metrics.fail("correctness", "asset cache diverged")
			}
		}
		w.mu.Unlock()
	}
	r, err := w.actors[len(w.actors)-1].request(ctx, "read_memberships", false, func(id uint32) (uint16, []byte, error) {
		return protocol.C_ListAllEdges, protocol.EncodeListAllEdgesWithCorrelation(0, id), nil
	})
	if err != nil {
		return err
	}
	edges := r.data.(*protocol.AllEdgeListResponse)
	if edges.ConvID != 0 || len(edges.Edges) != len(w.edgeIDs) {
		return fmt.Errorf("membership snapshot mismatch")
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	for _, a := range w.actors {
		if len(a.cache) != len(w.taskIDs) || len(a.assets) != len(w.assetIDs) {
			w.sim.metrics.fail("correctness", "record cache count mismatch")
		}
		if a == refresh {
			clear(a.edges)
			for _, edge := range edges.Edges {
				a.edges[edge.EdgeID] = edge
			}
			continue
		}
		if len(a.edges) != len(edges.Edges) {
			w.sim.metrics.fail("correctness", "membership cache count mismatch")
		}
		for _, edge := range edges.Edges {
			if a.edges[edge.EdgeID] != edge {
				w.sim.metrics.fail("correctness", "membership cache diverged")
			}
		}
	}
	return nil
}

func (w *workspace) deleteRecords(ctx context.Context) error {
	a := w.actors[0]
	for _, id := range w.edgeIDs {
		w.mu.Lock()
		w.edges[deleteKey(id)] = w.expect(a, 0, false)
		w.mu.Unlock()
		if _, err := a.request(ctx, "delete_membership", false, func(corr uint32) (uint16, []byte, error) {
			return protocol.C_DeleteEdge, protocol.EncodeDeleteEdgeWithCorrelation(0, id, corr), nil
		}); err != nil {
			return err
		}
	}
	w.edgeIDs = nil
	id := w.assetIDs[0]
	w.mu.Lock()
	w.assets[deleteKey(id)] = w.expect(a, 0, false)
	w.mu.Unlock()
	if _, err := a.request(ctx, "delete_note", false, func(corr uint32) (uint16, []byte, error) {
		return protocol.C_DeleteAsset, protocol.EncodeDeleteAssetWithCorrelation(0, id, corr), nil
	}); err != nil {
		return err
	}
	w.assetIDs = w.assetIDs[1:]
	id = w.taskIDs[len(w.taskIDs)-1]
	w.mu.Lock()
	w.tasks[deleteKey(id)] = w.expect(a, 0, false)
	w.mu.Unlock()
	if _, err := a.request(ctx, "delete_task", false, func(corr uint32) (uint16, []byte, error) {
		return protocol.C_DeleteTask, protocol.EncodeTaskDeleteWithCorrelation(0, int64(id), corr), nil
	}); err != nil {
		return err
	}
	w.taskIDs = w.taskIDs[:len(w.taskIDs)-1]
	return w.reconcile(ctx, nil)
}
