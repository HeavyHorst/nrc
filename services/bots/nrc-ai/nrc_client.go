package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/heavyhorst/nrc/protocol-go"
)

var errNotConnected = fmt.Errorf("NRC client not connected")
var errWorkspaceDataScope = fmt.Errorf("durable data requires conv_id=0 (workspace scope)")

const graphRankProtocolVersion = 5

type NRCClient struct {
	conn      *websocket.Conn
	connMu    sync.RWMutex
	connected atomic.Bool
	serverURL string
	workspace string
	nickname  string
	botSecret string
	cancel    context.CancelFunc

	writeMu         sync.Mutex
	mu              sync.Mutex
	clientReqID     atomic.Uint32
	protocolVersion atomic.Uint32
	subscribedRooms map[uint64]bool
	taskCache       map[uint64]map[uint64]*protocol.Task // convID -> taskID -> Task
	lastAccess      atomic.Int64

	readyMu         sync.Mutex
	ready           chan struct{}
	readyGeneration uint64

	pendingEdgesMu sync.Mutex
	pendingEdges   map[uint64][]chan []protocol.Edge

	pendingEdgeCreatesMu sync.Mutex
	pendingEdgeCreates   map[uint32][]chan edgeCreateResult

	pendingEdgeDeletesMu sync.Mutex
	pendingEdgeDeletes   map[uint32][]chan edgeDeleteResult

	pendingAssetWritesMu sync.Mutex
	pendingAssetWrites   map[uint32][]chan assetWriteResult

	pendingAssetDeletesMu sync.Mutex
	pendingAssetDeletes   map[uint32][]chan assetDeleteResult

	pendingTasksMu sync.Mutex
	pendingTasks   map[uint64][]chan struct{}
	taskSnapshots  map[uint64]bool

	pendingTaskCreatesMu sync.Mutex
	pendingTaskCreates   map[uint32][]chan taskCreateResult

	pendingTaskUpdatesMu sync.Mutex
	pendingTaskUpdates   map[uint32][]chan taskUpdateResult

	pendingTaskPagesMu sync.Mutex
	pendingTaskPages   map[uint32][]chan taskPageResult

	pendingGraphQueriesMu sync.Mutex
	pendingGraphQueries   map[uint32][]chan graphQueryResult
	pendingGraphRanksMu   sync.Mutex
	pendingGraphRanks     map[uint32][]chan graphRankResult

	pendingAssetsMu sync.Mutex
	pendingAssets   map[assetRequestKey][]chan protocol.Asset

	pendingAssetPagesMu sync.Mutex
	pendingAssetPages   map[uint32][]chan assetPageResult

	pendingNoteProjectsMu sync.Mutex
	pendingNoteProjects   map[uint32][]chan noteProjectsResult

	pendingNoteTagsMu sync.Mutex
	pendingNoteTags   map[uint32][]chan noteTagsResult
}

type graphQueryKey struct {
	convID    uint64
	startType uint16
	startID   uint64
}

type graphQueryResult struct {
	CorrelationID uint32
	Truncated     bool
	Nodes         []protocol.GraphNode
	Edges         []protocol.Edge
}

type graphRankResult struct {
	Result protocol.GraphRankResult
	Err    error
}

type edgeCreateResult struct {
	Edge *protocol.Edge
	Err  error
}

type edgeDeleteResult struct {
	ConvID uint64
	EdgeID uint64
	Err    error
}

type assetWriteResult struct {
	Asset *protocol.Asset
	Err   error
}

type assetDeleteResult struct {
	ConvID  uint64
	AssetID uint64
	Err     error
}

type taskCreateResult struct {
	Task *protocol.Task
	Err  error
}

type taskUpdateResult struct {
	Task *protocol.Task
	Err  error
}

type assetRequestKey struct {
	convID  uint64
	assetID uint64
}

type assetPageResult struct {
	Page *protocol.AssetListPageResponse
	Err  error
}

type assetPageCursor struct {
	UpdatedAt int64
	AssetID   uint64
}

type taskPageResult struct {
	Page *protocol.TaskListPage
	Err  error
}

type noteProjectsResult struct {
	Projects []string
	Err      error
}

type noteTagsResult struct {
	Tags []string
	Err  error
}

type noteListFilter struct {
	Project string
	Tag     string
}

func NewNRCClient(cfg Config, workspace string) *NRCClient {
	c := &NRCClient{
		serverURL:           cfg.NRCServer,
		workspace:           workspace,
		nickname:            cfg.NRCNickname,
		botSecret:           cfg.NRCBotSecret,
		subscribedRooms:     make(map[uint64]bool),
		taskCache:           make(map[uint64]map[uint64]*protocol.Task),
		ready:               make(chan struct{}),
		pendingEdges:        make(map[uint64][]chan []protocol.Edge),
		pendingEdgeCreates:  make(map[uint32][]chan edgeCreateResult),
		pendingEdgeDeletes:  make(map[uint32][]chan edgeDeleteResult),
		pendingAssetWrites:  make(map[uint32][]chan assetWriteResult),
		pendingAssetDeletes: make(map[uint32][]chan assetDeleteResult),
		pendingTasks:        make(map[uint64][]chan struct{}),
		taskSnapshots:       make(map[uint64]bool),
		pendingTaskCreates:  make(map[uint32][]chan taskCreateResult),
		pendingTaskUpdates:  make(map[uint32][]chan taskUpdateResult),
		pendingTaskPages:    make(map[uint32][]chan taskPageResult),
		pendingGraphQueries: make(map[uint32][]chan graphQueryResult),
		pendingGraphRanks:   make(map[uint32][]chan graphRankResult),
		pendingAssets:       make(map[assetRequestKey][]chan protocol.Asset),
		pendingAssetPages:   make(map[uint32][]chan assetPageResult),
		pendingNoteProjects: make(map[uint32][]chan noteProjectsResult),
		pendingNoteTags:     make(map[uint32][]chan noteTagsResult),
	}
	c.lastAccess.Store(time.Now().Unix())
	return c
}

// ReadyState returns the current ready channel and generation, safe for concurrent use.
func (c *NRCClient) ReadyState() (<-chan struct{}, uint64) {
	c.readyMu.Lock()
	defer c.readyMu.Unlock()
	return c.ready, c.readyGeneration
}

func (c *NRCClient) ReadyGeneration() uint64 {
	c.readyMu.Lock()
	defer c.readyMu.Unlock()
	return c.readyGeneration
}

func (c *NRCClient) resetReady() {
	c.readyMu.Lock()
	oldReady := c.ready
	c.readyGeneration++
	c.ready = make(chan struct{})
	c.readyMu.Unlock()

	closeReadyChannel(oldReady)
}

func (c *NRCClient) closeReady() {
	c.readyMu.Lock()
	ready := c.ready
	c.readyMu.Unlock()
	closeReadyChannel(ready)
}

func closeReadyChannel(ch chan struct{}) {
	if ch == nil {
		return
	}
	select {
	case <-ch:
	default:
		close(ch)
	}
}

func (c *NRCClient) Run(ctx context.Context) {
	backoff := 1 * time.Second
	const maxBackoff = 30 * time.Second

	for {
		c.resetReady()
		c.protocolVersion.Store(0)

		c.mu.Lock()
		c.subscribedRooms = make(map[uint64]bool)
		c.mu.Unlock()
		c.pendingTasksMu.Lock()
		c.taskSnapshots = make(map[uint64]bool)
		c.pendingTasksMu.Unlock()

		if err := c.connect(ctx); err != nil {
			slog.Error("NRC client connect failed", "workspace", c.workspace, "error", err)
		} else {
			backoff = 1 * time.Second
			pingCtx, cancelPing := context.WithCancel(ctx)
			go c.pingLoop(pingCtx)
			c.readPump(ctx)
			cancelPing()
			c.connected.Store(false)
		}

		select {
		case <-ctx.Done():
			return
		default:
		}

		slog.Info("reconnecting to NRC server", "workspace", c.workspace, "backoff", backoff)
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff *= 2
		if backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
}

func (c *NRCClient) connect(ctx context.Context) error {
	url := fmt.Sprintf("%s/%s", c.serverURL, c.workspace)

	dialer := websocket.Dialer{
		HandshakeTimeout: 10 * time.Second,
	}

	var headers http.Header
	if c.botSecret != "" {
		headers = http.Header{
			"X-NRC-User-Type":    []string{"bot"},
			"X-NRC-Bot-Secret":   []string{c.botSecret},
			"X-NRC-Bot-Nickname": []string{c.nickname},
		}
	}

	conn, _, err := dialer.DialContext(ctx, url, headers)
	if err != nil {
		return fmt.Errorf("dial %s: %w", url, err)
	}

	c.connMu.Lock()
	c.conn = conn
	c.connMu.Unlock()

	conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})

	c.connected.Store(true)
	slog.Info("connected to NRC server", "url", url)
	return nil
}

func (c *NRCClient) pingLoop(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			c.sendPing()
		}
	}
}

func (c *NRCClient) sendProtocolMessage(opcode uint16, payload []byte) error {
	if !c.connected.Load() {
		return errNotConnected
	}

	msg := &protocol.Message{Opcode: opcode, Data: payload}
	buf, err := msg.Write()
	if err != nil {
		return fmt.Errorf("failed to encode protocol message: %w", err)
	}

	c.connMu.RLock()
	conn := c.conn
	c.connMu.RUnlock()
	if conn == nil {
		return errNotConnected
	}

	c.writeMu.Lock()
	err = conn.WriteMessage(websocket.BinaryMessage, buf)
	c.writeMu.Unlock()
	if err != nil {
		return err
	}

	return nil
}

func (c *NRCClient) sendPing() {
	err := c.sendProtocolMessage(protocol.C_Ping, protocol.EncodePing(time.Now().UnixMilli()))
	if err != nil {
		slog.Debug("ping send failed", "error", err)
	}
}

func (c *NRCClient) readPump(ctx context.Context) {
	c.connMu.RLock()
	conn := c.conn
	c.connMu.RUnlock()

	for {
		select {
		case <-ctx.Done():
			conn.Close()
			return
		default:
		}

		_, data, err := conn.ReadMessage()
		if err != nil {
			select {
			case <-ctx.Done():
			default:
				slog.Error("read error", "workspace", c.workspace, "error", err)
			}
			return
		}

		conn.SetReadDeadline(time.Now().Add(60 * time.Second))

		msg, err := protocol.ReadMessage(data)
		if err != nil {
			slog.Warn("failed to parse protocol message", "workspace", c.workspace, "error", err)
			continue
		}

		switch msg.Opcode {
		case protocol.S_ServerReady:
			c.handleServerReady(data)
		case protocol.S_Pong:
			// pong received
		case protocol.S_TaskCreated:
			c.handleTaskCreated(msg.Data)
		case protocol.S_TaskUpdated:
			c.handleTaskUpdated(msg.Data)
		case protocol.S_TaskDeleted:
			c.handleTaskDeleted(msg.Data)
		case protocol.S_TaskListResponse:
			c.handleTaskListResponse(msg.Data)
		case protocol.S_TaskListPage:
			c.handleTaskListPage(msg.Data)
		case protocol.S_EdgeCreated:
			c.handleEdgeCreated(msg.Data)
		case protocol.S_EdgeDeleted:
			c.handleEdgeDeleted(msg.Data)
		case protocol.S_AllEdgeList:
			c.handleAllEdgeList(msg.Data)
		case protocol.S_GraphQueryResult:
			c.handleGraphQueryResult(msg.Data)
		case protocol.S_GraphRankResult:
			c.handleGraphRankResult(msg.Data)
		case protocol.S_AssetCreated:
			c.handleAssetCreated(msg.Data)
		case protocol.S_AssetUpdated:
			c.handleAssetUpdated(msg.Data)
		case protocol.S_AssetDeleted:
			c.handleAssetDeleted(msg.Data)
		case protocol.S_AssetFull:
			c.handleAssetFull(msg.Data)
		case protocol.S_AssetListPage:
			c.handleAssetListPage(msg.Data)
		case protocol.S_NoteProjectList:
			c.handleNoteProjectList(msg.Data)
		case protocol.S_NoteTagList:
			c.handleNoteTagList(msg.Data)
		case protocol.S_ErrorResponse:
			c.handleErrorResponse(msg.Data)
		}
	}
}

func (c *NRCClient) handleErrorResponse(payload []byte) {
	resp, err := protocol.DecodeErrorResponse(payload)
	if err != nil {
		slog.Warn("failed to decode error response", "error", err)
		return
	}

	if resp.CorrelationID != 0 && resp.OriginOpcode == protocol.C_CreateTask {
		c.settleTaskCreate(resp.CorrelationID, nil, fmt.Errorf("%s", resp.ErrorMessage))
	}

	if resp.CorrelationID != 0 && resp.OriginOpcode == protocol.C_UpdateTask {
		c.settleTaskUpdate(resp.CorrelationID, nil, fmt.Errorf("%s", resp.ErrorMessage))
	}

	if resp.CorrelationID != 0 && resp.OriginOpcode == protocol.C_ListTasksPaged {
		c.settleTaskPage(resp.CorrelationID, nil, fmt.Errorf("%s", resp.ErrorMessage))
	}

	if resp.CorrelationID != 0 && resp.OriginOpcode == protocol.C_GraphRank {
		c.settleGraphRank(resp.CorrelationID, protocol.GraphRankResult{}, fmt.Errorf("%s", resp.ErrorMessage))
	}

	if resp.CorrelationID != 0 && (resp.OriginOpcode == protocol.C_CreateAsset || resp.OriginOpcode == protocol.C_UpdateAsset) {
		c.pendingAssetWritesMu.Lock()
		waiters := c.pendingAssetWrites[resp.CorrelationID]
		delete(c.pendingAssetWrites, resp.CorrelationID)
		c.pendingAssetWritesMu.Unlock()

		result := assetWriteResult{Err: fmt.Errorf("%s", resp.ErrorMessage)}
		for _, ch := range waiters {
			ch <- result
		}
	}

	if resp.CorrelationID != 0 && resp.OriginOpcode == protocol.C_DeleteAsset {
		c.settleAssetDelete(resp.CorrelationID, 0, 0, fmt.Errorf("%s", resp.ErrorMessage))
	}

	if resp.CorrelationID != 0 && (resp.OriginOpcode == protocol.C_ListAssetsPaged || resp.OriginOpcode == protocol.C_ListAssetsPagedByProject || resp.OriginOpcode == protocol.C_ListAssetsPagedByTag) {
		c.settleAssetPage(resp.CorrelationID, nil, fmt.Errorf("%s", resp.ErrorMessage))
	}

	if resp.CorrelationID != 0 && resp.OriginOpcode == protocol.C_ListNoteProjects {
		c.settleNoteProjects(resp.CorrelationID, nil, fmt.Errorf("%s", resp.ErrorMessage))
	}

	if resp.CorrelationID != 0 && resp.OriginOpcode == protocol.C_ListNoteTags {
		c.settleNoteTags(resp.CorrelationID, nil, fmt.Errorf("%s", resp.ErrorMessage))
	}

	if resp.OriginOpcode == protocol.C_CreateEdge && resp.CorrelationID != 0 {
		c.pendingEdgeCreatesMu.Lock()
		waiters := c.pendingEdgeCreates[resp.CorrelationID]
		delete(c.pendingEdgeCreates, resp.CorrelationID)
		c.pendingEdgeCreatesMu.Unlock()

		result := edgeCreateResult{Err: fmt.Errorf("%s", resp.ErrorMessage)}
		for _, ch := range waiters {
			ch <- result
		}
	}

	if resp.CorrelationID != 0 && resp.OriginOpcode == protocol.C_DeleteEdge {
		c.settleEdgeDelete(resp.CorrelationID, 0, 0, fmt.Errorf("%s", resp.ErrorMessage))
	}

	slog.Warn("NRC server error response", "origin_opcode", resp.OriginOpcode, "correlation_id", resp.CorrelationID, "error", resp.ErrorMessage)
}

func (c *NRCClient) handleTaskListPage(payload []byte) {
	page, err := protocol.DecodeTaskListPage(payload)
	if err != nil {
		if page != nil && !page.Success {
			c.settleTaskPage(page.CorrelationID, nil, err)
		}
		slog.Warn("failed to decode task list page", "error", err)
		return
	}
	c.settleTaskPage(page.CorrelationID, page, nil)
}

func (c *NRCClient) settleTaskPage(correlationID uint32, page *protocol.TaskListPage, err error) {
	if correlationID == 0 {
		return
	}
	c.pendingTaskPagesMu.Lock()
	waiters := c.pendingTaskPages[correlationID]
	delete(c.pendingTaskPages, correlationID)
	c.pendingTaskPagesMu.Unlock()
	for _, ch := range waiters {
		ch <- taskPageResult{Page: page, Err: err}
	}
}

func (c *NRCClient) handleAssetListPage(payload []byte) {
	page, err := protocol.DecodeAssetListPage(payload)
	if err != nil {
		slog.Warn("failed to decode asset list page", "error", err)
		return
	}
	c.settleAssetPage(page.CorrelationID, page, nil)
	slog.Debug("asset list page received", "conv_id", page.ConvID, "assets", len(page.Assets), "has_more", page.HasMore)
}

func (c *NRCClient) handleNoteProjectList(payload []byte) {
	resp, err := protocol.DecodeNoteProjectList(payload)
	if err != nil {
		slog.Warn("failed to decode note project list", "error", err)
		return
	}
	c.settleNoteProjects(resp.CorrelationID, resp.Projects, nil)
	slog.Debug("note project list received", "conv_id", resp.ConvID, "projects", len(resp.Projects))
}

func (c *NRCClient) handleNoteTagList(payload []byte) {
	resp, err := protocol.DecodeNoteTagList(payload)
	if err != nil {
		slog.Warn("failed to decode note tag list", "error", err)
		return
	}
	c.settleNoteTags(resp.CorrelationID, resp.Tags, nil)
	slog.Debug("note tag list received", "conv_id", resp.ConvID, "tags", len(resp.Tags))
}

func (c *NRCClient) handleGraphQueryResult(payload []byte) {
	key, result, err := decodeGraphQueryResultPayload(payload)
	if err != nil {
		slog.Warn("failed to decode graph query result", "error", err)
		return
	}

	c.pendingGraphQueriesMu.Lock()
	waiters := c.pendingGraphQueries[result.CorrelationID]
	delete(c.pendingGraphQueries, result.CorrelationID)
	c.pendingGraphQueriesMu.Unlock()

	for _, ch := range waiters {
		ch <- result
	}

	slog.Debug("graph query result received", "conv_id", key.convID, "start_type", key.startType, "start_id", key.startID, "correlation_id", result.CorrelationID, "nodes", len(result.Nodes), "edges", len(result.Edges), "truncated", result.Truncated)
}

func (c *NRCClient) handleGraphRankResult(payload []byte) {
	result, err := protocol.DecodeGraphRankResult(payload)
	if err != nil {
		slog.Warn("failed to decode graph rank result", "error", err)
		return
	}
	c.settleGraphRank(result.CorrelationID, *result, nil)
	slog.Debug("graph rank result received", "conv_id", result.ConvID, "correlation_id", result.CorrelationID, "entries", len(result.Entries), "edges", len(result.Edges), "truncated", result.Truncated)
}

func (c *NRCClient) settleGraphRank(correlationID uint32, result protocol.GraphRankResult, err error) {
	if correlationID == 0 {
		return
	}
	c.pendingGraphRanksMu.Lock()
	waiters := c.pendingGraphRanks[correlationID]
	delete(c.pendingGraphRanks, correlationID)
	c.pendingGraphRanksMu.Unlock()
	for _, ch := range waiters {
		ch <- graphRankResult{Result: result, Err: err}
	}
}

func (c *NRCClient) handleAssetFull(payload []byte) {
	asset, err := protocol.DecodeAssetFull(payload)
	if err != nil {
		slog.Warn("failed to decode asset full", "error", err)
		return
	}

	key := assetRequestKey{convID: asset.ConvID, assetID: asset.AssetID}

	c.pendingAssetsMu.Lock()
	waiters := c.pendingAssets[key]
	delete(c.pendingAssets, key)
	c.pendingAssetsMu.Unlock()

	for _, ch := range waiters {
		ch <- asset
	}

	slog.Debug("asset full received", "conv_id", asset.ConvID, "asset_id", asset.AssetID)
}

func (c *NRCClient) handleAssetCreated(payload []byte) {
	resp, err := protocol.DecodeAssetCreated(payload)
	if err != nil {
		slog.Warn("failed to decode asset created", "error", err)
		return
	}
	c.settleAssetWrite(resp.CorrelationID, resp.Asset, nil)
	slog.Debug("asset created", "conv_id", resp.Asset.ConvID, "asset_id", resp.Asset.AssetID, "asset_type", resp.Asset.AssetType)
}

func (c *NRCClient) handleAssetUpdated(payload []byte) {
	resp, err := protocol.DecodeAssetUpdated(payload)
	if err != nil {
		slog.Warn("failed to decode asset updated", "error", err)
		return
	}
	c.settleAssetWrite(resp.CorrelationID, resp.Asset, nil)
	slog.Debug("asset updated", "conv_id", resp.Asset.ConvID, "asset_id", resp.Asset.AssetID, "asset_type", resp.Asset.AssetType)
}

func (c *NRCClient) handleAssetDeleted(payload []byte) {
	resp, err := protocol.DecodeAssetDeleted(payload)
	if err != nil {
		slog.Warn("failed to decode asset deleted", "error", err)
		return
	}
	c.settleAssetDelete(resp.CorrelationID, resp.ConvID, resp.AssetID, nil)
	slog.Debug("asset deleted", "conv_id", resp.ConvID, "asset_id", resp.AssetID)
}

func (c *NRCClient) settleAssetWrite(correlationID uint32, asset protocol.Asset, err error) {
	if correlationID == 0 {
		return
	}
	c.pendingAssetWritesMu.Lock()
	waiters := c.pendingAssetWrites[correlationID]
	delete(c.pendingAssetWrites, correlationID)
	c.pendingAssetWritesMu.Unlock()

	for _, ch := range waiters {
		assetCopy := asset
		ch <- assetWriteResult{Asset: &assetCopy, Err: err}
	}
}

func (c *NRCClient) settleAssetDelete(correlationID uint32, convID, assetID uint64, err error) {
	if correlationID == 0 {
		return
	}
	c.pendingAssetDeletesMu.Lock()
	waiters := c.pendingAssetDeletes[correlationID]
	delete(c.pendingAssetDeletes, correlationID)
	c.pendingAssetDeletesMu.Unlock()

	for _, ch := range waiters {
		ch <- assetDeleteResult{ConvID: convID, AssetID: assetID, Err: err}
	}
}

func (c *NRCClient) settleAssetPage(correlationID uint32, page *protocol.AssetListPageResponse, err error) {
	if correlationID == 0 {
		return
	}
	c.pendingAssetPagesMu.Lock()
	waiters := c.pendingAssetPages[correlationID]
	delete(c.pendingAssetPages, correlationID)
	c.pendingAssetPagesMu.Unlock()

	for _, ch := range waiters {
		ch <- assetPageResult{Page: page, Err: err}
	}
}

func (c *NRCClient) settleNoteProjects(correlationID uint32, projects []string, err error) {
	if correlationID == 0 {
		return
	}
	c.pendingNoteProjectsMu.Lock()
	waiters := c.pendingNoteProjects[correlationID]
	delete(c.pendingNoteProjects, correlationID)
	c.pendingNoteProjectsMu.Unlock()

	for _, ch := range waiters {
		ch <- noteProjectsResult{Projects: append([]string(nil), projects...), Err: err}
	}
}

func (c *NRCClient) settleNoteTags(correlationID uint32, tags []string, err error) {
	if correlationID == 0 {
		return
	}
	c.pendingNoteTagsMu.Lock()
	waiters := c.pendingNoteTags[correlationID]
	delete(c.pendingNoteTags, correlationID)
	c.pendingNoteTagsMu.Unlock()

	for _, ch := range waiters {
		ch <- noteTagsResult{Tags: append([]string(nil), tags...), Err: err}
	}
}

func decodeGraphQueryResultPayload(payload []byte) (graphQueryKey, graphQueryResult, error) {
	decoded, err := protocol.DecodeGraphQueryResult(payload)
	if err != nil {
		return graphQueryKey{}, graphQueryResult{}, err
	}

	key := graphQueryKey{convID: decoded.ConvID, startType: decoded.StartType, startID: decoded.StartID}
	result := graphQueryResult{CorrelationID: decoded.CorrelationID, Truncated: decoded.Truncated, Nodes: decoded.Nodes, Edges: decoded.Edges}
	return key, result, nil
}

func (c *NRCClient) handleServerReady(message []byte) {
	ready, err := protocol.ParseServerReady(message)
	if err != nil {
		slog.Warn("failed to decode server ready", "workspace", c.workspace, "error", err)
		return
	}

	slog.Info(
		"NRC server ready",
		"workspace", c.workspace,
		"build", ready.BuildVersion,
		"protocol", ready.ProtocolVersion,
		"cpu", ready.CPUModel,
		"username", ready.Username,
		"authenticated", ready.IsAuthenticated,
	)
	c.protocolVersion.Store(ready.ProtocolVersion)
	c.closeReady()
}

func (c *NRCClient) handleTaskCreated(payload []byte) {
	resp, err := protocol.DecodeTaskCreated(payload)
	if err != nil {
		slog.Warn("failed to decode task created", "error", err)
		return
	}
	task := resp.Task

	convID := uint64(task.ConvID)
	c.mu.Lock()
	if c.taskCache[convID] == nil {
		c.taskCache[convID] = make(map[uint64]*protocol.Task)
	}
	c.taskCache[convID][task.ID] = task
	c.mu.Unlock()

	c.settleTaskCreate(resp.CorrelationID, task, nil)

	slog.Debug("task created", "task_id", task.ID, "conv_id", convID, "title", task.Title)
}

func (c *NRCClient) settleTaskCreate(correlationID uint32, task *protocol.Task, err error) {
	if correlationID == 0 {
		return
	}
	c.pendingTaskCreatesMu.Lock()
	waiters := c.pendingTaskCreates[correlationID]
	delete(c.pendingTaskCreates, correlationID)
	c.pendingTaskCreatesMu.Unlock()

	for _, ch := range waiters {
		ch <- taskCreateResult{Task: task, Err: err}
	}
}

func (c *NRCClient) handleTaskUpdated(payload []byte) {
	resp, err := protocol.DecodeTaskUpdated(payload)
	if err != nil {
		slog.Warn("failed to decode task updated", "error", err)
		return
	}
	task := resp.Task

	convID := uint64(task.ConvID)
	c.mu.Lock()
	if c.taskCache[convID] == nil {
		c.taskCache[convID] = make(map[uint64]*protocol.Task)
	}
	c.taskCache[convID][task.ID] = task
	c.mu.Unlock()

	c.settleTaskUpdate(resp.CorrelationID, task, nil)

	slog.Debug("task updated", "task_id", task.ID, "conv_id", convID)
}

func (c *NRCClient) settleTaskUpdate(correlationID uint32, task *protocol.Task, err error) {
	if correlationID == 0 {
		return
	}
	c.pendingTaskUpdatesMu.Lock()
	waiters := c.pendingTaskUpdates[correlationID]
	delete(c.pendingTaskUpdates, correlationID)
	c.pendingTaskUpdatesMu.Unlock()

	for _, ch := range waiters {
		ch <- taskUpdateResult{Task: task, Err: err}
	}
}

func (c *NRCClient) handleTaskDeleted(payload []byte) {
	resp, err := protocol.DecodeTaskDeleted(payload)
	if err != nil {
		slog.Warn("failed to decode task deleted", "error", err)
		return
	}

	convID := resp.ConvID
	taskID := resp.TaskID

	c.mu.Lock()
	if tasks, ok := c.taskCache[convID]; ok {
		delete(tasks, taskID)
	}
	c.mu.Unlock()

	slog.Debug("task deleted", "task_id", taskID, "conv_id", convID)
}

func (c *NRCClient) handleTaskListResponse(payload []byte) {
	resp, err := protocol.DecodeTaskListResponse(payload)
	if err != nil {
		if resp != nil && resp.CorrelationID != 0 && !resp.Success {
			applyErr := fmt.Errorf("%s", resp.ErrorMessage)
			c.settleTaskCreate(resp.CorrelationID, nil, applyErr)
			c.settleTaskUpdate(resp.CorrelationID, nil, applyErr)
		}
		slog.Warn("failed to decode task list response", "error", err)
		return
	}

	convID := resp.ConvID
	tasks := make(map[uint64]*protocol.Task, len(resp.Tasks))
	for _, task := range resp.Tasks {
		tasks[task.ID] = task
	}

	c.mu.Lock()
	c.taskCache[convID] = tasks
	c.mu.Unlock()

	c.pendingTasksMu.Lock()
	c.taskSnapshots[convID] = true
	waiters := c.pendingTasks[convID]
	delete(c.pendingTasks, convID)
	c.pendingTasksMu.Unlock()
	for _, ch := range waiters {
		close(ch)
	}

	slog.Debug("task list received", "conv_id", convID, "count", len(tasks))
}

func (c *NRCClient) handleEdgeCreated(payload []byte) {
	resp, err := protocol.DecodeEdgeCreated(payload)
	if err != nil {
		slog.Warn("failed to decode edge created", "error", err)
		return
	}
	edge := resp.Edge

	if resp.CorrelationID != 0 {
		c.pendingEdgeCreatesMu.Lock()
		waiters := c.pendingEdgeCreates[resp.CorrelationID]
		delete(c.pendingEdgeCreates, resp.CorrelationID)
		c.pendingEdgeCreatesMu.Unlock()

		for _, ch := range waiters {
			edgeCopy := edge
			ch <- edgeCreateResult{Edge: &edgeCopy}
		}
	}

	slog.Debug("edge created", "edge_id", edge.EdgeID, "conv_id", edge.ConvID, "source_type", edge.SourceType, "source_id", edge.SourceID, "target_type", edge.TargetType, "target_id", edge.TargetID, "relation", edge.Relation)
}

func (c *NRCClient) handleEdgeDeleted(payload []byte) {
	resp, err := protocol.DecodeEdgeDeleted(payload)
	if err != nil {
		slog.Warn("failed to decode edge deleted", "error", err)
		return
	}
	c.settleEdgeDelete(resp.CorrelationID, resp.ConvID, resp.EdgeID, nil)
	slog.Debug("edge deleted", "edge_id", resp.EdgeID, "conv_id", resp.ConvID)
}

func (c *NRCClient) settleEdgeDelete(correlationID uint32, convID, edgeID uint64, err error) {
	if correlationID == 0 {
		return
	}
	c.pendingEdgeDeletesMu.Lock()
	waiters := c.pendingEdgeDeletes[correlationID]
	delete(c.pendingEdgeDeletes, correlationID)
	c.pendingEdgeDeletesMu.Unlock()

	for _, ch := range waiters {
		ch <- edgeDeleteResult{ConvID: convID, EdgeID: edgeID, Err: err}
	}
}

func (c *NRCClient) handleAllEdgeList(payload []byte) {
	convID, edges, err := protocol.DecodeAllEdgeList(payload)
	if err != nil {
		slog.Warn("failed to decode all edge list", "error", err)
		return
	}

	c.pendingEdgesMu.Lock()
	waiters := c.pendingEdges[convID]
	delete(c.pendingEdges, convID)
	c.pendingEdgesMu.Unlock()

	for _, ch := range waiters {
		ch <- edges
	}

	slog.Debug("all edge list received", "conv_id", convID, "count", len(edges))
}

// GetTasks returns cached workspace tasks. Room/DM scopes have no durable data.
func (c *NRCClient) GetTasks(convID uint64) []protocol.Task {
	if convID != protocol.WorkspaceDataConvID {
		return nil
	}
	c.touchAccess()
	c.mu.Lock()
	defer c.mu.Unlock()

	tasks, ok := c.taskCache[convID]
	if !ok {
		return nil
	}

	result := make([]protocol.Task, 0, len(tasks))
	for _, t := range tasks {
		result = append(result, *t)
	}
	return result
}

// GetEdges sends C_ListAllEdges and waits for the response.
func (c *NRCClient) GetEdges(ctx context.Context, convID uint64) ([]protocol.Edge, error) {
	if convID != protocol.WorkspaceDataConvID {
		return nil, errWorkspaceDataScope
	}
	c.touchAccess()
	ch := make(chan []protocol.Edge, 1)

	c.pendingEdgesMu.Lock()
	c.pendingEdges[convID] = append(c.pendingEdges[convID], ch)
	needsSend := len(c.pendingEdges[convID]) == 1
	c.pendingEdgesMu.Unlock()

	defer removePendingEdge(c, convID, ch)

	if needsSend {
		if err := c.sendListAllEdges(convID); err != nil {
			return nil, err
		}
	}

	select {
	case edges := <-ch:
		return edges, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-time.After(15 * time.Second):
		return nil, fmt.Errorf("timeout waiting for edge list for conv_id %d", convID)
	}
}

// SubscribeRoom subscribes to workspace data delivery and loads its task snapshot.
// The scope argument is retained to reject obsolete room/DM data callers.
func (c *NRCClient) SubscribeRoom(convID uint64) error {
	c.touchAccess()
	if convID != protocol.WorkspaceDataConvID {
		return errWorkspaceDataScope
	}
	if err := c.SubscribeConversation(protocol.WorkspaceDataConvID); err != nil {
		return err
	}
	c.pendingTasksMu.Lock()
	hasSnapshot := c.taskSnapshots[convID]
	c.pendingTasksMu.Unlock()
	if hasSnapshot {
		return nil
	}

	if err := c.sendGetTasks(convID); err != nil {
		return err
	}
	return nil
}

// SubscribeConversation subscribes to a conversation if not already subscribed.
func (c *NRCClient) SubscribeConversation(convID uint64) error {
	c.touchAccess()
	c.mu.Lock()
	if c.subscribedRooms[convID] {
		c.mu.Unlock()
		return nil
	}
	c.mu.Unlock()

	if err := c.sendSubscribeConvs([]uint64{convID}); err != nil {
		return err
	}

	c.mu.Lock()
	c.subscribedRooms[convID] = true
	c.mu.Unlock()
	return nil
}

func (c *NRCClient) SendChatMessage(convID uint64, content string) error {
	c.touchAccess()

	if !c.connected.Load() {
		return errNotConnected
	}

	contentBytes := []byte(content)
	if len(contentBytes) > 65535 {
		contentBytes = contentBytes[:65535]
	}

	payload := protocol.EncodeSendMessage(int64(convID), c.clientReqID.Add(1), string(contentBytes), protocol.ContentTypePlainText)
	err := c.sendProtocolMessage(protocol.C_SendMessage, payload)
	if err != nil {
		slog.Error("failed to send chat message", "conv_id", convID, "error", err)
		return err
	}

	return nil
}

// CreateTask sends C_CreateTask and waits for the correlated S_TaskCreated.
func (c *NRCClient) CreateTask(ctx context.Context, convID uint64, title, description string, priority uint8) (*protocol.Task, error) {
	if convID != protocol.WorkspaceDataConvID {
		return nil, errWorkspaceDataScope
	}
	c.touchAccess()
	if !c.connected.Load() {
		return nil, errNotConnected
	}

	correlationID := c.clientReqID.Add(1)
	if correlationID == 0 {
		correlationID = c.clientReqID.Add(1)
	}

	ch := make(chan taskCreateResult, 1)
	c.pendingTaskCreatesMu.Lock()
	c.pendingTaskCreates[correlationID] = append(c.pendingTaskCreates[correlationID], ch)
	c.pendingTaskCreatesMu.Unlock()

	defer removePendingTaskCreate(c, correlationID, ch)

	payload := protocol.EncodeTaskCreateWithCorrelation(protocol.WorkspaceDataConvID, title, description, int32(priority), correlationID)
	if err := c.sendProtocolMessage(protocol.C_CreateTask, payload); err != nil {
		return nil, err
	}

	select {
	case result := <-ch:
		if result.Err != nil {
			return nil, result.Err
		}
		return result.Task, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-time.After(15 * time.Second):
		return nil, fmt.Errorf("timeout waiting for task create response for conv_id %d", convID)
	}
}

// UpdateTask sends C_UpdateTask and waits for the correlated S_TaskUpdated.
func (c *NRCClient) UpdateTask(ctx context.Context, convID uint64, current protocol.Task, title, description string, status uint8, priority uint8, blockedBy uint64) (*protocol.Task, error) {
	if convID != protocol.WorkspaceDataConvID {
		return nil, errWorkspaceDataScope
	}
	c.touchAccess()
	if !c.connected.Load() {
		return nil, errNotConnected
	}
	if current.ID == 0 {
		return nil, fmt.Errorf("task_id is required")
	}

	correlationID := c.clientReqID.Add(1)
	if correlationID == 0 {
		correlationID = c.clientReqID.Add(1)
	}

	ch := make(chan taskUpdateResult, 1)
	c.pendingTaskUpdatesMu.Lock()
	c.pendingTaskUpdates[correlationID] = append(c.pendingTaskUpdates[correlationID], ch)
	c.pendingTaskUpdatesMu.Unlock()

	defer removePendingTaskUpdate(c, correlationID, ch)

	descriptionField := description
	if description == "" && current.Description != "" {
		descriptionField = "\x00"
	}
	blockedByField := blockedBy
	if blockedBy == 0 && current.BlockedBy != 0 {
		blockedByField = ^uint64(0)
	}

	payload := protocol.EncodeTaskUpdateFullWithCorrelation(
		protocol.WorkspaceDataConvID,
		int64(current.ID),
		title,
		descriptionField,
		status,
		current.Assignee,
		priority,
		current.Color,
		current.ExternalRef,
		current.DueAt,
		blockedByField,
		nil, // Preserve the current server-side attachment list.
		correlationID,
	)
	if err := c.sendProtocolMessage(protocol.C_UpdateTask, payload); err != nil {
		return nil, err
	}

	select {
	case result := <-ch:
		if result.Err != nil {
			return nil, result.Err
		}
		return result.Task, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-time.After(15 * time.Second):
		return nil, fmt.Errorf("timeout waiting for task update response for conv_id %d task_id %d", convID, current.ID)
	}
}

// CreateEdge sends C_CreateEdge and waits for the correlated S_EdgeCreated.
func (c *NRCClient) CreateEdge(ctx context.Context, convID uint64, sourceType uint16, sourceID uint64, targetType uint16, targetID uint64, relation uint16) (*protocol.Edge, error) {
	if convID != protocol.WorkspaceDataConvID {
		return nil, errWorkspaceDataScope
	}
	c.touchAccess()
	if !c.connected.Load() {
		return nil, errNotConnected
	}

	correlationID := c.clientReqID.Add(1)
	if correlationID == 0 {
		correlationID = c.clientReqID.Add(1)
	}

	ch := make(chan edgeCreateResult, 1)
	c.pendingEdgeCreatesMu.Lock()
	c.pendingEdgeCreates[correlationID] = append(c.pendingEdgeCreates[correlationID], ch)
	c.pendingEdgeCreatesMu.Unlock()

	defer removePendingEdgeCreate(c, correlationID, ch)

	payload := protocol.EncodeCreateEdgeWithCorrelation(protocol.WorkspaceDataConvID, sourceType, sourceID, targetType, targetID, relation, correlationID)
	if err := c.sendProtocolMessage(protocol.C_CreateEdge, payload); err != nil {
		return nil, err
	}

	select {
	case result := <-ch:
		if result.Err != nil {
			return nil, result.Err
		}
		return result.Edge, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-time.After(15 * time.Second):
		return nil, fmt.Errorf("timeout waiting for edge create response for conv_id %d", convID)
	}
}

// DeleteEdge sends C_DeleteEdge and waits for the correlated S_EdgeDeleted.
func (c *NRCClient) DeleteEdge(ctx context.Context, convID uint64, edgeID uint64) error {
	if convID != protocol.WorkspaceDataConvID {
		return errWorkspaceDataScope
	}
	c.touchAccess()
	if !c.connected.Load() {
		return errNotConnected
	}
	if edgeID == 0 {
		return fmt.Errorf("edge_id is required")
	}

	correlationID := c.clientReqID.Add(1)
	if correlationID == 0 {
		correlationID = c.clientReqID.Add(1)
	}

	ch := make(chan edgeDeleteResult, 1)
	c.pendingEdgeDeletesMu.Lock()
	c.pendingEdgeDeletes[correlationID] = append(c.pendingEdgeDeletes[correlationID], ch)
	c.pendingEdgeDeletesMu.Unlock()

	defer removePendingEdgeDelete(c, correlationID, ch)

	payload := protocol.EncodeDeleteEdgeWithCorrelation(protocol.WorkspaceDataConvID, edgeID, correlationID)
	if err := c.sendProtocolMessage(protocol.C_DeleteEdge, payload); err != nil {
		return err
	}

	select {
	case result := <-ch:
		if result.Err != nil {
			return result.Err
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(15 * time.Second):
		return fmt.Errorf("timeout waiting for edge delete response for conv_id %d edge_id %d", convID, edgeID)
	}
}

// CreateAsset sends C_CreateAsset and waits for the correlated S_AssetCreated.
func (c *NRCClient) CreateAsset(ctx context.Context, convID uint64, assetType uint16, parentType uint16, parentID uint64, preview, payload string) (*protocol.Asset, error) {
	if convID != protocol.WorkspaceDataConvID {
		return nil, errWorkspaceDataScope
	}
	c.touchAccess()
	if !c.connected.Load() {
		return nil, errNotConnected
	}

	correlationID := c.clientReqID.Add(1)
	if correlationID == 0 {
		correlationID = c.clientReqID.Add(1)
	}

	ch := make(chan assetWriteResult, 1)
	c.pendingAssetWritesMu.Lock()
	c.pendingAssetWrites[correlationID] = append(c.pendingAssetWrites[correlationID], ch)
	c.pendingAssetWritesMu.Unlock()

	defer removePendingAssetWrite(c, correlationID, ch)

	payloadBytes := protocol.EncodeCreateAssetWithCorrelation(protocol.WorkspaceDataConvID, assetType, parentType, parentID, preview, payload, correlationID)
	if err := c.sendProtocolMessage(protocol.C_CreateAsset, payloadBytes); err != nil {
		return nil, err
	}

	select {
	case result := <-ch:
		if result.Err != nil {
			return nil, result.Err
		}
		return result.Asset, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-time.After(15 * time.Second):
		return nil, fmt.Errorf("timeout waiting for asset create response for conv_id %d", convID)
	}
}

// UpdateAsset sends C_UpdateAsset and waits for the correlated S_AssetUpdated.
func (c *NRCClient) UpdateAsset(ctx context.Context, convID uint64, assetID uint64, preview, payload string) (*protocol.Asset, error) {
	if convID != protocol.WorkspaceDataConvID {
		return nil, errWorkspaceDataScope
	}
	c.touchAccess()
	if !c.connected.Load() {
		return nil, errNotConnected
	}

	correlationID := c.clientReqID.Add(1)
	if correlationID == 0 {
		correlationID = c.clientReqID.Add(1)
	}

	ch := make(chan assetWriteResult, 1)
	c.pendingAssetWritesMu.Lock()
	c.pendingAssetWrites[correlationID] = append(c.pendingAssetWrites[correlationID], ch)
	c.pendingAssetWritesMu.Unlock()

	defer removePendingAssetWrite(c, correlationID, ch)

	payloadBytes := protocol.EncodeUpdateAssetWithCorrelation(protocol.WorkspaceDataConvID, assetID, preview, payload, correlationID)
	if err := c.sendProtocolMessage(protocol.C_UpdateAsset, payloadBytes); err != nil {
		return nil, err
	}

	select {
	case result := <-ch:
		if result.Err != nil {
			return nil, result.Err
		}
		return result.Asset, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-time.After(15 * time.Second):
		return nil, fmt.Errorf("timeout waiting for asset update response for conv_id %d asset_id %d", convID, assetID)
	}
}

// DeleteAsset sends C_DeleteAsset and waits for the correlated S_AssetDeleted.
func (c *NRCClient) DeleteAsset(ctx context.Context, convID uint64, assetID uint64) error {
	if convID != protocol.WorkspaceDataConvID {
		return errWorkspaceDataScope
	}
	c.touchAccess()
	if !c.connected.Load() {
		return errNotConnected
	}
	if assetID == 0 {
		return fmt.Errorf("asset_id is required")
	}

	correlationID := c.clientReqID.Add(1)
	if correlationID == 0 {
		correlationID = c.clientReqID.Add(1)
	}

	ch := make(chan assetDeleteResult, 1)
	c.pendingAssetDeletesMu.Lock()
	c.pendingAssetDeletes[correlationID] = append(c.pendingAssetDeletes[correlationID], ch)
	c.pendingAssetDeletesMu.Unlock()

	defer removePendingAssetDelete(c, correlationID, ch)

	payloadBytes := protocol.EncodeDeleteAssetWithCorrelation(protocol.WorkspaceDataConvID, assetID, correlationID)
	if err := c.sendProtocolMessage(protocol.C_DeleteAsset, payloadBytes); err != nil {
		return err
	}

	select {
	case result := <-ch:
		if result.Err != nil {
			return result.Err
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(15 * time.Second):
		return fmt.Errorf("timeout waiting for asset delete response for conv_id %d asset_id %d", convID, assetID)
	}
}

// ListTasksPage requests a correlated page without changing the task snapshot cache.
func (c *NRCClient) ListTasksPage(ctx context.Context, convID uint64, statusMask uint8, limit uint16, cursor *protocol.TaskPageCursor) (*protocol.TaskListPage, error) {
	if convID != protocol.WorkspaceDataConvID {
		return nil, errWorkspaceDataScope
	}
	c.touchAccess()
	if !c.connected.Load() {
		return nil, errNotConnected
	}
	correlationID := c.clientReqID.Add(1)
	if correlationID == 0 {
		correlationID = c.clientReqID.Add(1)
	}
	payload, err := protocol.EncodeListTasksPaged(convID, statusMask, limit, cursor, correlationID)
	if err != nil {
		return nil, err
	}
	ch := make(chan taskPageResult, 1)
	c.pendingTaskPagesMu.Lock()
	c.pendingTaskPages[correlationID] = append(c.pendingTaskPages[correlationID], ch)
	c.pendingTaskPagesMu.Unlock()
	defer removePendingTaskPage(c, correlationID, ch)
	if err := c.sendProtocolMessage(protocol.C_ListTasksPaged, payload); err != nil {
		return nil, err
	}
	select {
	case result := <-ch:
		return result.Page, result.Err
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-time.After(15 * time.Second):
		return nil, fmt.Errorf("timeout waiting for task page for conv_id %d", convID)
	}
}

func removePendingTaskPage(c *NRCClient, correlationID uint32, ch chan taskPageResult) {
	c.pendingTaskPagesMu.Lock()
	defer c.pendingTaskPagesMu.Unlock()
	waiters := c.pendingTaskPages[correlationID]
	for i, waiter := range waiters {
		if waiter == ch {
			c.pendingTaskPages[correlationID] = append(waiters[:i], waiters[i+1:]...)
			break
		}
	}
	if len(c.pendingTaskPages[correlationID]) == 0 {
		delete(c.pendingTaskPages, correlationID)
	}
}

func (c *NRCClient) ListAssetsPage(ctx context.Context, convID uint64, assetType uint16, filter noteListFilter, limit uint16, includePayload bool, cursor *assetPageCursor) (*protocol.AssetListPageResponse, error) {
	if convID != protocol.WorkspaceDataConvID {
		return nil, errWorkspaceDataScope
	}
	c.touchAccess()
	if !c.connected.Load() {
		return nil, errNotConnected
	}
	if strings.TrimSpace(filter.Project) != "" && strings.TrimSpace(filter.Tag) != "" {
		return nil, fmt.Errorf("use either project or tag, not both")
	}
	if assetType != protocol.AssetTypeNote && (filter.Project != "" || filter.Tag != "") {
		return nil, fmt.Errorf("project and tag filters require notes")
	}
	if limit == 0 {
		limit = 20
	}
	if limit > 50 {
		limit = 50
	}

	correlationID := c.clientReqID.Add(1)
	if correlationID == 0 {
		correlationID = c.clientReqID.Add(1)
	}

	ch := make(chan assetPageResult, 1)
	c.pendingAssetPagesMu.Lock()
	c.pendingAssetPages[correlationID] = append(c.pendingAssetPages[correlationID], ch)
	c.pendingAssetPagesMu.Unlock()

	defer removePendingAssetPage(c, correlationID, ch)

	var updatedAt int64
	var assetID uint64
	if cursor != nil {
		updatedAt, assetID = cursor.UpdatedAt, cursor.AssetID
	}
	opcode := protocol.C_ListAssetsPaged
	payload := protocol.EncodeListAssetsPagedWithCorrelation(protocol.WorkspaceDataConvID, assetType, includePayload, limit, cursor != nil, updatedAt, assetID, correlationID)
	if project := strings.TrimSpace(filter.Project); project != "" {
		opcode = protocol.C_ListAssetsPagedByProject
		payload = protocol.EncodeListAssetsPagedByProjectWithCorrelation(protocol.WorkspaceDataConvID, assetType, includePayload, limit, cursor != nil, updatedAt, assetID, project, correlationID)
	} else if tag := strings.TrimSpace(filter.Tag); tag != "" {
		opcode = protocol.C_ListAssetsPagedByTag
		payload = protocol.EncodeListAssetsPagedByTagWithCorrelation(protocol.WorkspaceDataConvID, assetType, includePayload, limit, cursor != nil, updatedAt, assetID, tag, correlationID)
	}

	if err := c.sendProtocolMessage(opcode, payload); err != nil {
		return nil, err
	}

	select {
	case result := <-ch:
		if result.Err != nil {
			return nil, result.Err
		}
		return result.Page, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-time.After(15 * time.Second):
		return nil, fmt.Errorf("timeout waiting for asset list response for conv_id %d", convID)
	}
}

func (c *NRCClient) ListNoteProjects(ctx context.Context, convID uint64) ([]string, error) {
	if convID != protocol.WorkspaceDataConvID {
		return nil, errWorkspaceDataScope
	}
	c.touchAccess()
	if !c.connected.Load() {
		return nil, errNotConnected
	}

	correlationID := c.clientReqID.Add(1)
	if correlationID == 0 {
		correlationID = c.clientReqID.Add(1)
	}

	ch := make(chan noteProjectsResult, 1)
	c.pendingNoteProjectsMu.Lock()
	c.pendingNoteProjects[correlationID] = append(c.pendingNoteProjects[correlationID], ch)
	c.pendingNoteProjectsMu.Unlock()

	defer removePendingNoteProjects(c, correlationID, ch)

	payload := protocol.EncodeListNoteProjectsWithCorrelation(protocol.WorkspaceDataConvID, correlationID)
	if err := c.sendProtocolMessage(protocol.C_ListNoteProjects, payload); err != nil {
		return nil, err
	}

	select {
	case result := <-ch:
		if result.Err != nil {
			return nil, result.Err
		}
		return result.Projects, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-time.After(15 * time.Second):
		return nil, fmt.Errorf("timeout waiting for note projects response for conv_id %d", convID)
	}
}

func (c *NRCClient) ListNoteTags(ctx context.Context, convID uint64) ([]string, error) {
	if convID != protocol.WorkspaceDataConvID {
		return nil, errWorkspaceDataScope
	}
	c.touchAccess()
	if !c.connected.Load() {
		return nil, errNotConnected
	}

	correlationID := c.clientReqID.Add(1)
	if correlationID == 0 {
		correlationID = c.clientReqID.Add(1)
	}

	ch := make(chan noteTagsResult, 1)
	c.pendingNoteTagsMu.Lock()
	c.pendingNoteTags[correlationID] = append(c.pendingNoteTags[correlationID], ch)
	c.pendingNoteTagsMu.Unlock()

	defer removePendingNoteTags(c, correlationID, ch)

	payload := protocol.EncodeListNoteTagsWithCorrelation(protocol.WorkspaceDataConvID, correlationID)
	if err := c.sendProtocolMessage(protocol.C_ListNoteTags, payload); err != nil {
		return nil, err
	}

	select {
	case result := <-ch:
		if result.Err != nil {
			return nil, result.Err
		}
		return result.Tags, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-time.After(15 * time.Second):
		return nil, fmt.Errorf("timeout waiting for note tags response for conv_id %d", convID)
	}
}

func (c *NRCClient) CreateNote(ctx context.Context, convID uint64, title, content, project string, tags []string) (*protocol.Asset, error) {
	_, content, _, _, preview, err := validateNoteActionPayloadWithMetadata(title, content, project, tags)
	if err != nil {
		return nil, err
	}
	return c.CreateAsset(ctx, convID, protocol.AssetTypeNote, protocol.ParentTypeNone, 0, preview, content)
}

func (c *NRCClient) UpdateNote(ctx context.Context, convID uint64, assetID uint64, title, content, project string, tags []string, format string) (*protocol.Asset, error) {
	_, content, project, tags, _, err := validateNoteActionPayloadWithMetadata(title, content, project, tags)
	if err != nil {
		return nil, err
	}
	preview, err := buildNotePreviewWithFormat(title, content, project, tags, format)
	if err != nil {
		return nil, err
	}
	return c.UpdateAsset(ctx, convID, assetID, preview, content)
}

func (c *NRCClient) DeleteNote(ctx context.Context, convID uint64, assetID uint64) error {
	return c.DeleteAsset(ctx, convID, assetID)
}

// WaitForTasks waits until the workspace task list response is received.
func (c *NRCClient) WaitForTasks(ctx context.Context, convID uint64) error {
	if convID != protocol.WorkspaceDataConvID {
		return errWorkspaceDataScope
	}
	ch := make(chan struct{})

	c.pendingTasksMu.Lock()
	if c.taskSnapshots[convID] {
		c.pendingTasksMu.Unlock()
		return nil
	}
	c.pendingTasks[convID] = append(c.pendingTasks[convID], ch)
	c.pendingTasksMu.Unlock()

	defer removePendingTask(c, convID, ch)

	select {
	case <-ch:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(15 * time.Second):
		return fmt.Errorf("timeout waiting for task list for conv_id %d", convID)
	}
}

func (c *NRCClient) GetGraphNeighborhood(ctx context.Context, convID uint64, startType uint16, startID uint64, maxDepth uint8, relationMask uint16, direction uint8, flags uint8) (graphQueryResult, error) {
	if convID != protocol.WorkspaceDataConvID {
		return graphQueryResult{}, errWorkspaceDataScope
	}
	c.touchAccess()
	correlationID := c.clientReqID.Add(1)
	if correlationID == 0 {
		correlationID = c.clientReqID.Add(1)
	}
	ch := make(chan graphQueryResult, 1)

	c.pendingGraphQueriesMu.Lock()
	c.pendingGraphQueries[correlationID] = append(c.pendingGraphQueries[correlationID], ch)
	c.pendingGraphQueriesMu.Unlock()

	defer removePendingGraphQuery(c, correlationID, ch)

	if err := c.sendGraphQuery(convID, startType, startID, maxDepth, relationMask, direction, flags, correlationID); err != nil {
		return graphQueryResult{}, err
	}

	select {
	case result := <-ch:
		return result, nil
	case <-ctx.Done():
		return graphQueryResult{}, ctx.Err()
	case <-time.After(15 * time.Second):
		return graphQueryResult{}, fmt.Errorf("timeout waiting for graph query result for conv_id %d start_type %d start_id %d", convID, startType, startID)
	}
}

func (c *NRCClient) GetGraphRank(ctx context.Context, convID uint64, anchors, candidates []protocol.GraphRankEntity, maxDepth uint8, relationMask uint16, direction uint8, topN uint8) (protocol.GraphRankResult, error) {
	if convID != protocol.WorkspaceDataConvID {
		return protocol.GraphRankResult{}, errWorkspaceDataScope
	}
	c.touchAccess()
	if c.protocolVersion.Load() < graphRankProtocolVersion {
		return protocol.GraphRankResult{}, fmt.Errorf("server protocol does not support graph ranking")
	}
	correlationID := c.clientReqID.Add(1)
	if correlationID == 0 {
		correlationID = c.clientReqID.Add(1)
	}
	payload, err := protocol.EncodeGraphRankWithCorrelation(protocol.WorkspaceDataConvID, anchors, candidates, maxDepth, relationMask, direction, topN, correlationID)
	if err != nil {
		return protocol.GraphRankResult{}, err
	}
	ch := make(chan graphRankResult, 1)
	c.pendingGraphRanksMu.Lock()
	c.pendingGraphRanks[correlationID] = append(c.pendingGraphRanks[correlationID], ch)
	c.pendingGraphRanksMu.Unlock()
	defer removePendingGraphRank(c, correlationID, ch)
	if err := c.sendProtocolMessage(protocol.C_GraphRank, payload); err != nil {
		return protocol.GraphRankResult{}, err
	}
	select {
	case result := <-ch:
		return result.Result, result.Err
	case <-ctx.Done():
		return protocol.GraphRankResult{}, ctx.Err()
	case <-time.After(15 * time.Second):
		return protocol.GraphRankResult{}, fmt.Errorf("timeout waiting for graph rank result for conv_id %d", convID)
	}
}

// GetAsset sends C_GetAsset and waits for S_AssetFull.
func (c *NRCClient) GetAsset(ctx context.Context, convID, assetID uint64) (protocol.Asset, error) {
	if convID != protocol.WorkspaceDataConvID {
		return protocol.Asset{}, errWorkspaceDataScope
	}
	c.touchAccess()
	ch := make(chan protocol.Asset, 1)
	key := assetRequestKey{convID: convID, assetID: assetID}

	c.pendingAssetsMu.Lock()
	c.pendingAssets[key] = append(c.pendingAssets[key], ch)
	needsSend := len(c.pendingAssets[key]) == 1
	c.pendingAssetsMu.Unlock()

	defer removePendingAsset(c, key, ch)

	if needsSend {
		if err := c.sendGetAsset(convID, assetID); err != nil {
			return protocol.Asset{}, err
		}
	}

	select {
	case asset := <-ch:
		return asset, nil
	case <-ctx.Done():
		return protocol.Asset{}, ctx.Err()
	case <-time.After(15 * time.Second):
		return protocol.Asset{}, fmt.Errorf("timeout waiting for asset full conv_id %d asset_id %d", convID, assetID)
	}
}

func removePendingEdge(c *NRCClient, convID uint64, ch chan []protocol.Edge) {
	c.pendingEdgesMu.Lock()
	waiters := c.pendingEdges[convID]
	for i, w := range waiters {
		if w == ch {
			c.pendingEdges[convID] = append(waiters[:i], waiters[i+1:]...)
			break
		}
	}
	if len(c.pendingEdges[convID]) == 0 {
		delete(c.pendingEdges, convID)
	}
	c.pendingEdgesMu.Unlock()
}

func removePendingTask(c *NRCClient, convID uint64, ch chan struct{}) {
	c.pendingTasksMu.Lock()
	waiters := c.pendingTasks[convID]
	for i, w := range waiters {
		if w == ch {
			c.pendingTasks[convID] = append(waiters[:i], waiters[i+1:]...)
			break
		}
	}
	if len(c.pendingTasks[convID]) == 0 {
		delete(c.pendingTasks, convID)
	}
	c.pendingTasksMu.Unlock()
}

func removePendingTaskCreate(c *NRCClient, correlationID uint32, ch chan taskCreateResult) {
	c.pendingTaskCreatesMu.Lock()
	waiters := c.pendingTaskCreates[correlationID]
	for i, w := range waiters {
		if w == ch {
			c.pendingTaskCreates[correlationID] = append(waiters[:i], waiters[i+1:]...)
			break
		}
	}
	if len(c.pendingTaskCreates[correlationID]) == 0 {
		delete(c.pendingTaskCreates, correlationID)
	}
	c.pendingTaskCreatesMu.Unlock()
}

func removePendingTaskUpdate(c *NRCClient, correlationID uint32, ch chan taskUpdateResult) {
	c.pendingTaskUpdatesMu.Lock()
	waiters := c.pendingTaskUpdates[correlationID]
	for i, w := range waiters {
		if w == ch {
			c.pendingTaskUpdates[correlationID] = append(waiters[:i], waiters[i+1:]...)
			break
		}
	}
	if len(c.pendingTaskUpdates[correlationID]) == 0 {
		delete(c.pendingTaskUpdates, correlationID)
	}
	c.pendingTaskUpdatesMu.Unlock()
}

func removePendingEdgeCreate(c *NRCClient, correlationID uint32, ch chan edgeCreateResult) {
	c.pendingEdgeCreatesMu.Lock()
	waiters := c.pendingEdgeCreates[correlationID]
	for i, w := range waiters {
		if w == ch {
			c.pendingEdgeCreates[correlationID] = append(waiters[:i], waiters[i+1:]...)
			break
		}
	}
	if len(c.pendingEdgeCreates[correlationID]) == 0 {
		delete(c.pendingEdgeCreates, correlationID)
	}
	c.pendingEdgeCreatesMu.Unlock()
}

func removePendingEdgeDelete(c *NRCClient, correlationID uint32, ch chan edgeDeleteResult) {
	c.pendingEdgeDeletesMu.Lock()
	waiters := c.pendingEdgeDeletes[correlationID]
	for i, w := range waiters {
		if w == ch {
			c.pendingEdgeDeletes[correlationID] = append(waiters[:i], waiters[i+1:]...)
			break
		}
	}
	if len(c.pendingEdgeDeletes[correlationID]) == 0 {
		delete(c.pendingEdgeDeletes, correlationID)
	}
	c.pendingEdgeDeletesMu.Unlock()
}

func removePendingAssetWrite(c *NRCClient, correlationID uint32, ch chan assetWriteResult) {
	c.pendingAssetWritesMu.Lock()
	waiters := c.pendingAssetWrites[correlationID]
	for i, w := range waiters {
		if w == ch {
			c.pendingAssetWrites[correlationID] = append(waiters[:i], waiters[i+1:]...)
			break
		}
	}
	if len(c.pendingAssetWrites[correlationID]) == 0 {
		delete(c.pendingAssetWrites, correlationID)
	}
	c.pendingAssetWritesMu.Unlock()
}

func removePendingAssetDelete(c *NRCClient, correlationID uint32, ch chan assetDeleteResult) {
	c.pendingAssetDeletesMu.Lock()
	waiters := c.pendingAssetDeletes[correlationID]
	for i, w := range waiters {
		if w == ch {
			c.pendingAssetDeletes[correlationID] = append(waiters[:i], waiters[i+1:]...)
			break
		}
	}
	if len(c.pendingAssetDeletes[correlationID]) == 0 {
		delete(c.pendingAssetDeletes, correlationID)
	}
	c.pendingAssetDeletesMu.Unlock()
}

func removePendingGraphQuery(c *NRCClient, correlationID uint32, ch chan graphQueryResult) {
	c.pendingGraphQueriesMu.Lock()
	waiters := c.pendingGraphQueries[correlationID]
	for i, w := range waiters {
		if w == ch {
			c.pendingGraphQueries[correlationID] = append(waiters[:i], waiters[i+1:]...)
			break
		}
	}
	if len(c.pendingGraphQueries[correlationID]) == 0 {
		delete(c.pendingGraphQueries, correlationID)
	}
	c.pendingGraphQueriesMu.Unlock()
}

func removePendingGraphRank(c *NRCClient, correlationID uint32, ch chan graphRankResult) {
	c.pendingGraphRanksMu.Lock()
	waiters := c.pendingGraphRanks[correlationID]
	for i, waiter := range waiters {
		if waiter == ch {
			c.pendingGraphRanks[correlationID] = append(waiters[:i], waiters[i+1:]...)
			break
		}
	}
	if len(c.pendingGraphRanks[correlationID]) == 0 {
		delete(c.pendingGraphRanks, correlationID)
	}
	c.pendingGraphRanksMu.Unlock()
}

func removePendingAsset(c *NRCClient, key assetRequestKey, ch chan protocol.Asset) {
	c.pendingAssetsMu.Lock()
	waiters := c.pendingAssets[key]
	for i, w := range waiters {
		if w == ch {
			c.pendingAssets[key] = append(waiters[:i], waiters[i+1:]...)
			break
		}
	}
	if len(c.pendingAssets[key]) == 0 {
		delete(c.pendingAssets, key)
	}
	c.pendingAssetsMu.Unlock()
}

func removePendingAssetPage(c *NRCClient, correlationID uint32, ch chan assetPageResult) {
	c.pendingAssetPagesMu.Lock()
	waiters := c.pendingAssetPages[correlationID]
	for i, w := range waiters {
		if w == ch {
			c.pendingAssetPages[correlationID] = append(waiters[:i], waiters[i+1:]...)
			break
		}
	}
	if len(c.pendingAssetPages[correlationID]) == 0 {
		delete(c.pendingAssetPages, correlationID)
	}
	c.pendingAssetPagesMu.Unlock()
}

func removePendingNoteProjects(c *NRCClient, correlationID uint32, ch chan noteProjectsResult) {
	c.pendingNoteProjectsMu.Lock()
	waiters := c.pendingNoteProjects[correlationID]
	for i, w := range waiters {
		if w == ch {
			c.pendingNoteProjects[correlationID] = append(waiters[:i], waiters[i+1:]...)
			break
		}
	}
	if len(c.pendingNoteProjects[correlationID]) == 0 {
		delete(c.pendingNoteProjects, correlationID)
	}
	c.pendingNoteProjectsMu.Unlock()
}

func removePendingNoteTags(c *NRCClient, correlationID uint32, ch chan noteTagsResult) {
	c.pendingNoteTagsMu.Lock()
	waiters := c.pendingNoteTags[correlationID]
	for i, w := range waiters {
		if w == ch {
			c.pendingNoteTags[correlationID] = append(waiters[:i], waiters[i+1:]...)
			break
		}
	}
	if len(c.pendingNoteTags[correlationID]) == 0 {
		delete(c.pendingNoteTags, correlationID)
	}
	c.pendingNoteTagsMu.Unlock()
}

func (c *NRCClient) IsSubscribed(convID uint64) bool {
	if convID == protocol.WorkspaceDataConvID {
		c.pendingTasksMu.Lock()
		defer c.pendingTasksMu.Unlock()
		return c.taskSnapshots[protocol.WorkspaceDataConvID]
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.subscribedRooms[convID]
}

func (c *NRCClient) sendSubscribeConvs(convIDs []uint64) error {
	roomIDs := make([]int64, 0, len(convIDs))
	for _, convID := range convIDs {
		roomIDs = append(roomIDs, int64(convID))
	}

	payload := protocol.EncodeSubscribeConvs(roomIDs...)
	err := c.sendProtocolMessage(protocol.C_SubscribeConvs, payload)
	if err != nil {
		slog.Error("failed to send subscribe", "error", err)
		return err
	}
	return nil
}

func (c *NRCClient) sendGetTasks(convID uint64) error {
	if convID != protocol.WorkspaceDataConvID {
		return errWorkspaceDataScope
	}
	payload := protocol.EncodeGetTasks(protocol.WorkspaceDataConvID)
	err := c.sendProtocolMessage(protocol.C_GetTasks, payload)
	if err != nil {
		slog.Error("failed to send get tasks", "error", err)
		return err
	}
	return nil
}

func (c *NRCClient) sendListAllEdges(convID uint64) error {
	if convID != protocol.WorkspaceDataConvID {
		return errWorkspaceDataScope
	}
	payload := protocol.EncodeListAllEdges(protocol.WorkspaceDataConvID)
	err := c.sendProtocolMessage(protocol.C_ListAllEdges, payload)
	if err != nil {
		slog.Error("failed to send list all edges", "error", err)
		return err
	}
	return nil
}

func (c *NRCClient) sendGraphQuery(convID uint64, startType uint16, startID uint64, maxDepth uint8, relationMask uint16, direction uint8, flags uint8, correlationID uint32) error {
	if convID != protocol.WorkspaceDataConvID {
		return errWorkspaceDataScope
	}
	payload := protocol.EncodeGraphQueryWithCorrelation(protocol.WorkspaceDataConvID, startType, startID, maxDepth, relationMask, direction, flags, correlationID)
	err := c.sendProtocolMessage(protocol.C_GraphQuery, payload)
	if err != nil {
		slog.Error("failed to send graph query", "error", err)
		return err
	}
	return nil
}

func (c *NRCClient) sendGetAsset(convID, assetID uint64) error {
	if convID != protocol.WorkspaceDataConvID {
		return errWorkspaceDataScope
	}
	payload := protocol.EncodeGetAsset(protocol.WorkspaceDataConvID, assetID)
	err := c.sendProtocolMessage(protocol.C_GetAsset, payload)
	if err != nil {
		slog.Error("failed to send get asset", "conv_id", convID, "asset_id", assetID, "error", err)
		return err
	}
	return nil
}

func (c *NRCClient) touchAccess() {
	c.lastAccess.Store(time.Now().Unix())
}

// Stop cancels the client's Run loop and closes the connection.
func (c *NRCClient) Stop() {
	if c.cancel != nil {
		c.cancel()
	}
	c.connMu.RLock()
	conn := c.conn
	c.connMu.RUnlock()
	if conn != nil {
		conn.Close()
	}
}

// IsConnected returns whether the client currently has an active WebSocket connection.
func (c *NRCClient) IsConnected() bool {
	return c.connected.Load()
}
