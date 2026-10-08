package main

import (
	"context"
	"fmt"
	"strconv"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
	"google.golang.org/adk/tool"
	"google.golang.org/adk/tool/functiontool"
)

type dataReadResult struct {
	value any
	err   error
}
type pendingDataRead struct {
	opcode uint16
	ch     chan dataReadResult
}

func (c *NRCClient) settleDataRead(id uint32, opcode uint16, value any, err error) {
	c.dataReadsMu.Lock()
	defer c.dataReadsMu.Unlock()
	if p, ok := c.dataReads[id]; ok && p.opcode == opcode {
		delete(c.dataReads, id)
		p.ch <- dataReadResult{value, err}
	}
}

func (c *NRCClient) failDataReads(err error) {
	c.dataReadsMu.Lock()
	defer c.dataReadsMu.Unlock()
	for id, p := range c.dataReads {
		delete(c.dataReads, id)
		p.ch <- dataReadResult{err: err}
	}
}

func (c *NRCClient) handleDataRead(opcode uint16, payload []byte) {
	var id uint32
	var origin uint16
	var value any
	var err error
	switch opcode {
	case protocol.S_TaskFull:
		origin = protocol.C_GetTask
		var p *protocol.TaskFull
		p, err = protocol.DecodeTaskFull(payload)
		if p != nil {
			id = p.CorrelationID
			value = p
			if !p.Success || p.Task == nil {
				err = fmt.Errorf("task read failed: %s", p.ErrorMessage)
			}
		}
	case protocol.S_CalendarPage:
		origin = protocol.C_QueryCalendar
		var p *protocol.CalendarPage
		p, err = protocol.DecodeCalendarPage(payload)
		if err == nil {
			id = p.CorrelationID
			value = p
		}
	case protocol.S_TaskSliceList:
		origin = protocol.C_ListTaskSlices
		var p *protocol.TaskSliceList
		p, err = protocol.DecodeTaskSliceList(payload)
		if err == nil {
			id = p.CorrelationID
			value = p
			if !p.Success {
				err = fmt.Errorf("slice read failed: %s", p.Error)
			}
		}
	case protocol.S_EdgeListPage:
		origin = protocol.C_ListEdgesPaged
		var p *protocol.EdgeListPageResponse
		p, err = protocol.DecodeEdgeListPage(payload)
		if err == nil {
			id = p.CorrelationID
			value = p
		}
	}
	// A malformed response cannot be trusted to carry a correlation ID.
	if id != 0 {
		c.settleDataRead(id, origin, value, err)
	}
}

func (c *NRCClient) correlatedDataRead(ctx context.Context, convID uint64, opcode uint16, encode func(uint32) ([]byte, error)) (any, error) {
	if convID != protocol.WorkspaceDataConvID {
		return nil, errWorkspaceDataScope
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	c.touchAccess()
	id := c.clientReqID.Add(1)
	if id == 0 {
		id = c.clientReqID.Add(1)
	}
	payload, err := encode(id)
	if err != nil {
		return nil, err
	}
	ch := make(chan dataReadResult, 1)
	c.dataReadsMu.Lock()
	if !c.connected.Load() {
		c.dataReadsMu.Unlock()
		return nil, errNotConnected
	}
	if c.dataReads == nil {
		c.dataReads = make(map[uint32]pendingDataRead)
	}
	c.dataReads[id] = pendingDataRead{opcode, ch}
	c.dataReadsMu.Unlock()
	defer func() { c.dataReadsMu.Lock(); delete(c.dataReads, id); c.dataReadsMu.Unlock() }()
	if err := c.sendProtocolMessage(opcode, payload); err != nil {
		return nil, err
	}
	timer := time.NewTimer(15 * time.Second)
	defer timer.Stop()
	select {
	case r := <-ch:
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		return r.value, r.err
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-timer.C:
		return nil, fmt.Errorf("timeout waiting for data read opcode %d", opcode)
	}
}

// GetTask always reads the authoritative record, never the snapshot cache.
func (c *NRCClient) GetTask(ctx context.Context, convID, taskID uint64) (protocol.Task, error) {
	if taskID == 0 {
		return protocol.Task{}, fmt.Errorf("task_id must be positive")
	}
	v, err := c.correlatedDataRead(ctx, convID, protocol.C_GetTask, func(id uint32) ([]byte, error) { return protocol.EncodeGetTask(convID, taskID, id), nil })
	if err != nil {
		return protocol.Task{}, err
	}
	p := v.(*protocol.TaskFull)
	if p.ConvID != convID || p.Task.ID != taskID {
		return protocol.Task{}, fmt.Errorf("task response identity mismatch")
	}
	return *p.Task, nil
}

func (c *NRCClient) QueryCalendar(ctx context.Context, convID uint64, q protocol.CalendarQuery) (*protocol.CalendarPage, error) {
	v, err := c.correlatedDataRead(ctx, convID, protocol.C_QueryCalendar, func(id uint32) ([]byte, error) { q.CorrelationID = id; return protocol.EncodeCalendarQuery(q) })
	if err != nil {
		return nil, err
	}
	p := v.(*protocol.CalendarPage)
	if p.ConvID != convID {
		return nil, fmt.Errorf("calendar response scope mismatch")
	}
	return p, nil
}
func (c *NRCClient) ListTaskSlices(ctx context.Context, convID uint64, q protocol.SliceQuery) (*protocol.TaskSliceList, error) {
	if q.Limit < 1 || q.Limit > 100 || len(q.Owner) > protocol.MaxAssigneeLength || len(q.Name) > protocol.MaxProjectLength {
		return nil, fmt.Errorf("invalid slice query bounds")
	}
	v, err := c.correlatedDataRead(ctx, convID, protocol.C_ListTaskSlices, func(id uint32) ([]byte, error) { return protocol.EncodeListTaskSlices(convID, q, id), nil })
	if err != nil {
		return nil, err
	}
	p := v.(*protocol.TaskSliceList)
	if p.ConvID != convID {
		return nil, fmt.Errorf("slice response scope mismatch")
	}
	return p, nil
}
func (c *NRCClient) ListEntityLinks(ctx context.Context, convID uint64, entityType uint16, entityID uint64, limit uint16, afterEdgeID uint64) (*protocol.EdgeListPageResponse, error) {
	if (entityType != protocol.TargetTypeAsset && entityType != protocol.TargetTypeTask) || entityID == 0 || limit < 1 || limit > 100 {
		return nil, fmt.Errorf("invalid entity link query")
	}
	v, err := c.correlatedDataRead(ctx, convID, protocol.C_ListEdgesPaged, func(id uint32) ([]byte, error) {
		return protocol.EncodeListEdgesPaged(int64(convID), entityType, entityID, limit, afterEdgeID, id), nil
	})
	if err != nil {
		return nil, err
	}
	p := v.(*protocol.EdgeListPageResponse)
	if p.ConvID != convID || p.TargetType != entityType || p.TargetID != entityID {
		return nil, fmt.Errorf("edge response identity mismatch")
	}
	return p, nil
}

type dataCalendarCursor struct {
	At   string `json:"at"`
	Kind uint8  `json:"kind"`
	ID   string `json:"id"`
}
type dataCalendarInput struct {
	Start    string              `json:"start"`
	End      string              `json:"end"`
	Limit    uint16              `json:"limit,omitempty"`
	Assignee string              `json:"assignee,omitempty"`
	Project  string              `json:"project,omitempty"`
	Cursor   *dataCalendarCursor `json:"cursor,omitempty"`
}
type dataSliceCursor struct {
	Closed  bool   `json:"closed"`
	SortAt  string `json:"sort_at"`
	SliceID string `json:"slice_id"`
}
type dataSliceInput struct {
	IncludeClosed bool             `json:"include_closed,omitempty"`
	Owner         *string          `json:"owner,omitempty"`
	Name          *string          `json:"name,omitempty"`
	Limit         uint16           `json:"limit,omitempty"`
	Cursor        *dataSliceCursor `json:"cursor,omitempty"`
}
type dataLinksInput struct {
	EntityType  string `json:"entity_type"`
	ID          string `json:"id"`
	Limit       uint16 `json:"limit,omitempty"`
	AfterEdgeID string `json:"after_edge_id,omitempty"`
}

func dataUint(s string) (uint64, error) {
	v, e := strconv.ParseUint(s, 10, 64)
	if e != nil || v == 0 {
		return 0, fmt.Errorf("expected positive decimal uint64 string")
	}
	return v, nil
}
func dataInt(s string) (int64, error) { return strconv.ParseInt(s, 10, 64) }
func dataLimit(n uint16) uint16 {
	if n == 0 {
		return 20
	}
	return n
}
func dataString(n uint64) string { return strconv.FormatUint(n, 10) }
func dataTime(n int64) string    { return strconv.FormatInt(n, 10) }

// newADKDataReadTools exposes only bounded reads in the session's workspace.
func newADKDataReadTools(wm *WorkspaceManager, cache *adkAssetSourceCache) ([]tool.Tool, error) {
	calendar, err := functiontool.New(functiontool.Config{Name: "query_calendar", Description: "Read calendar range using explicit RFC3339 start/end, at most 62 days, limit 1-100 (default 20). Server overlap semantics include appointments overlapping [start,end), tasks/reminders occurring in it. Continue using returned cursor with unchanged filters; cursor timestamps and IDs are decimal strings."}, func(ctx tool.Context, in dataCalendarInput) (out map[string]any, err error) {
		started := time.Now()
		ws, conv, err := adkSessionScope(ctx)
		defer func() {
			recordToolTrace(ctx, "query_calendar", started, ws, conv, map[string]any{"start": in.Start, "end": in.End, "cursor": in.Cursor, "assignee": in.Assignee, "project": in.Project, "limit": in.Limit}, map[string]any{"count": out["count"], "has_more": out["has_more"]}, err)
		}()
		if err != nil {
			return nil, err
		}
		start, err := time.Parse(time.RFC3339Nano, in.Start)
		if err != nil {
			return nil, err
		}
		end, err := time.Parse(time.RFC3339Nano, in.End)
		if err != nil {
			return nil, err
		}
		// Restrict before UnixNano to avoid its undefined overflow range.
		if start.Before(time.Unix(0, 0)) || end.After(time.Unix(0, 1<<63-1)) {
			return nil, fmt.Errorf("calendar time outside supported range")
		}
		q := protocol.CalendarQuery{Start: start.UnixNano(), End: end.UnixNano(), Limit: dataLimit(in.Limit), Assignee: in.Assignee, Project: in.Project}
		if in.Cursor != nil {
			at, e := dataInt(in.Cursor.At)
			if e != nil {
				return nil, e
			}
			id, e := dataUint(in.Cursor.ID)
			if e != nil {
				return nil, e
			}
			q.Cursor = &protocol.CalendarCursor{At: at, Kind: in.Cursor.Kind, ID: id}
		}
		c, err := dataReadClient(wm, ws, conv)
		if err != nil {
			return nil, err
		}
		p, err := c.QueryCalendar(ctx, conv, q)
		if err != nil {
			return nil, err
		}
		rows := make([]map[string]any, 0, len(p.Rows))
		titles := map[uint64]string{}
		for _, r := range p.Rows {
			row := map[string]any{"kind": r.Kind, "id": dataString(r.ID), "at": dataTime(r.At), "blocked": r.Blocked, "title": r.Title, "assignee": r.Assignee, "project": r.Project}
			if r.Kind == protocol.CalendarKindAppointment {
				row["actual_start_at"] = dataTime(r.ActualStartAt)
				row["end_at"] = dataTime(r.EndAt)
			}
			if r.Kind != protocol.CalendarKindTask {
				titles[r.ID] = r.Title
			}
			rows = append(rows, row)
		}
		if cache != nil {
			cache.put(ws, conv, titles)
		}
		var cursor *dataCalendarCursor
		if p.HasMore {
			cursor = &dataCalendarCursor{dataTime(p.Cursor.At), p.Cursor.Kind, dataString(p.Cursor.ID)}
		}
		return map[string]any{"rows": rows, "count": len(rows), "has_more": p.HasMore, "cursor": cursor, "assignee": q.Assignee, "project": q.Project}, nil
	})
	if err != nil {
		return nil, err
	}
	slices, err := functiontool.New(functiontool.Config{Name: "list_task_slices", Description: "Read bounded slice register with server membership counters, not project-derived membership. Limit 1-100 (default 20). Optional owner (empty means unowned), name substring, include_closed, cursor. Whole-workspace assigned/unassigned counters are zero for filtered or continuing pages."}, func(ctx tool.Context, in dataSliceInput) (out map[string]any, err error) {
		started := time.Now()
		ws, conv, err := adkSessionScope(ctx)
		defer func() {
			recordToolTrace(ctx, "list_task_slices", started, ws, conv, map[string]any{"owner": in.Owner, "name": in.Name, "include_closed": in.IncludeClosed, "cursor": in.Cursor, "limit": in.Limit}, map[string]any{"count": out["count"], "total_count": out["total_count"], "has_more": out["has_more"]}, err)
		}()
		if err != nil {
			return nil, err
		}
		q := protocol.SliceQuery{Limit: dataLimit(in.Limit), IncludeClosed: in.IncludeClosed}
		if in.Owner != nil {
			q.HasOwner = true
			q.Owner = *in.Owner
		}
		if in.Name != nil {
			q.HasName = true
			q.Name = *in.Name
		}
		if in.Cursor != nil {
			at, e := dataInt(in.Cursor.SortAt)
			if e != nil {
				return nil, e
			}
			id, e := dataUint(in.Cursor.SliceID)
			if e != nil {
				return nil, e
			}
			q.Cursor = &protocol.SliceCursor{Closed: in.Cursor.Closed, SortAt: at, SliceID: id}
		}
		c, err := dataReadClient(wm, ws, conv)
		if err != nil {
			return nil, err
		}
		p, err := c.ListTaskSlices(ctx, conv, q)
		if err != nil {
			return nil, err
		}
		rows := make([]map[string]any, 0, len(p.Slices))
		titles := map[uint64]string{}
		for _, s := range p.Slices {
			titles[s.SliceID] = s.Name
			rows = append(rows, map[string]any{"slice_id": dataString(s.SliceID), "name": s.Name, "owner": s.Owner, "closed": s.IsClosed(), "backlog": s.Backlog, "todo": s.Todo, "in_progress": s.InProgress, "done": s.Done, "blocked": s.Blocked, "notes": s.Notes, "files": s.Files, "oldest_active_at": dataTime(s.OldestActiveAt), "last_moved_at": dataTime(s.LastMovedAt)})
		}
		if cache != nil {
			cache.put(ws, conv, titles)
		}
		var cursor *dataSliceCursor
		if p.HasMore {
			cursor = &dataSliceCursor{p.NextCursor.Closed, dataTime(p.NextCursor.SortAt), dataString(p.NextCursor.SliceID)}
		}
		return map[string]any{"slices": rows, "count": len(rows), "total_count": p.TotalCount, "has_more": p.HasMore, "cursor": cursor, "assigned_tasks": p.AssignedTasks, "unassigned_tasks": p.UnassignedTasks}, nil
	})
	if err != nil {
		return nil, err
	}
	links, err := functiontool.New(functiontool.Config{Name: "list_entity_links", Description: "Read incident server edges for entity_type task or asset and decimal-string id; companies and slices are assets. Includes MemberOf membership directly from edges, never metadata. Returns source/target IDs, relation and direction. Limit 1-100 (default 20); continue with decimal-string after_edge_id from next_edge_id."}, func(ctx tool.Context, in dataLinksInput) (out map[string]any, err error) {
		started := time.Now()
		ws, conv, err := adkSessionScope(ctx)
		defer func() {
			recordToolTrace(ctx, "list_entity_links", started, ws, conv, map[string]any{"entity_type": in.EntityType, "id": in.ID, "after_edge_id": in.AfterEdgeID, "limit": in.Limit}, map[string]any{"count": out["count"], "total_count": out["total_count"], "has_more": out["has_more"]}, err)
		}()
		if err != nil {
			return nil, err
		}
		var typ uint16
		switch in.EntityType {
		case "task":
			typ = protocol.TargetTypeTask
		case "asset":
			typ = protocol.TargetTypeAsset
		default:
			return nil, fmt.Errorf("entity_type must be task or asset")
		}
		id, err := dataUint(in.ID)
		if err != nil {
			return nil, err
		}
		var after uint64
		if in.AfterEdgeID != "" {
			after, err = strconv.ParseUint(in.AfterEdgeID, 10, 64)
			if err != nil {
				return nil, err
			}
		}
		c, err := dataReadClient(wm, ws, conv)
		if err != nil {
			return nil, err
		}
		p, err := c.ListEntityLinks(ctx, conv, typ, id, dataLimit(in.Limit), after)
		if err != nil {
			return nil, err
		}
		rows := make([]map[string]any, 0, len(p.Edges))
		for _, e := range p.Edges {
			direction := "incoming"
			if e.SourceType == typ && e.SourceID == id {
				direction = "outgoing"
			}
			rows = append(rows, map[string]any{"edge_id": dataString(e.EdgeID), "source_type": e.SourceType, "source_id": dataString(e.SourceID), "target_type": e.TargetType, "target_id": dataString(e.TargetID), "relation": e.Relation, "direction": direction, "created_at": dataTime(e.CreatedAt), "created_by": e.CreatedBy})
		}
		return map[string]any{"edges": rows, "count": len(rows), "total_count": p.TotalCount, "has_more": p.HasMore, "next_edge_id": dataString(p.NextEdgeID)}, nil
	})
	if err != nil {
		return nil, err
	}
	return []tool.Tool{calendar, slices, links}, nil
}

func dataReadClient(wm *WorkspaceManager, ws string, conv uint64) (*NRCClient, error) {
	if conv != protocol.WorkspaceDataConvID {
		return nil, errWorkspaceDataScope
	}
	c, err := wm.GetOrCreateClient(ws)
	if err != nil {
		return nil, err
	}
	if !c.IsSubscribed(conv) {
		if err = c.SubscribeConversation(conv); err != nil {
			return nil, err
		}
	}
	return c, nil
}
