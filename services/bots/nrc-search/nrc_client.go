package main

import (
	"context"
	"encoding/binary"
	"fmt"
	"hash/fnv"
	"log/slog"
	"net/http"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/heavyhorst/nrc/protocol-go"
)

type EmbedJob struct {
	Workspace string
	AssetID   uint64
	Identity  EntityIdentity
	Entry     QueueEntry
}

type embedRetryKey struct {
	Entity  entityKey
	Version uint64
}

type reconcileState struct {
	done chan struct{}
	err  error
}

func (job EmbedJob) identity() EntityIdentity {
	if job.Identity.EntityType.Valid() {
		return job.Identity
	}
	return assetIdentity(job.Workspace, job.AssetID, job.Entry.ConvID)
}

type NRCClient struct {
	conn      *websocket.Conn
	serverURL string
	workspace string
	nickname  string
	botSecret string
	filesURL  string

	embedAssetTypes   map[uint16]bool
	embedTasks        bool
	reconcileInterval time.Duration

	storage  *Storage
	index    *Index
	embedder Embedder

	writeMu         sync.Mutex
	mu              sync.Mutex
	subscribedRooms map[uint64]bool
	reconcileDone   map[uint64]*reconcileState
	roomSyncTimes   map[uint64]time.Time

	readyMu         sync.Mutex
	ready           chan struct{}
	readyGeneration uint64
	embedCh         chan EmbedJob
	diskSignal      chan struct{}

	pendingReconcilePageMu sync.Mutex
	pendingReconcilePage   map[uint64]chan *protocol.AssetListPageResponse
	pendingTaskPagesMu     sync.Mutex
	pendingTaskPages       map[uint32]chan *protocol.TaskListPage
	pendingTaskFullMu      sync.Mutex
	pendingTaskFull        map[uint32]chan *protocol.TaskFull

	embedRetries    map[embedRetryKey]int
	embedRetriesMu  sync.Mutex
	queueRetryArmed atomic.Bool
	nextCorrelation atomic.Uint32
	nextVersion     atomic.Uint64
	taskMutationMu  sync.Mutex
	taskMutations   map[entityKey]uint64
	expectedHashes  map[entityKey]uint64
	unresolvedTasks map[entityKey]uint64
	inventoryEpochs map[uint64]uint64
	refreshWorkers  sync.WaitGroup
	sendMessage     func(uint16, []byte) error
}

func NewNRCClient(cfg Config, workspace string, storage *Storage, embedder Embedder, index *Index) (*NRCClient, error) {
	embedTypes := make(map[uint16]bool, len(cfg.EmbedAssetTypes))
	for _, t := range cfg.EmbedAssetTypes {
		embedTypes[t] = true
	}

	return &NRCClient{
		serverURL:            cfg.NRCServer,
		workspace:            workspace,
		nickname:             cfg.NRCNickname,
		botSecret:            cfg.NRCBotSecret,
		filesURL:             cfg.FilesURL,
		embedAssetTypes:      embedTypes,
		embedTasks:           cfg.EmbedTasks,
		reconcileInterval:    cfg.ReconcileInterval,
		storage:              storage,
		index:                index,
		embedder:             embedder,
		subscribedRooms:      make(map[uint64]bool),
		reconcileDone:        make(map[uint64]*reconcileState),
		roomSyncTimes:        make(map[uint64]time.Time),
		ready:                make(chan struct{}),
		embedCh:              make(chan EmbedJob, 256),
		diskSignal:           make(chan struct{}, 1),
		pendingReconcilePage: make(map[uint64]chan *protocol.AssetListPageResponse),
		pendingTaskPages:     make(map[uint32]chan *protocol.TaskListPage),
		pendingTaskFull:      make(map[uint32]chan *protocol.TaskFull),
		embedRetries:         make(map[embedRetryKey]int),
		taskMutations:        make(map[entityKey]uint64),
		expectedHashes:       make(map[entityKey]uint64),
		unresolvedTasks:      make(map[entityKey]uint64),
		inventoryEpochs:      make(map[uint64]uint64),
	}, nil
}

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

func (c *NRCClient) invalidateConnection() {
	c.taskMutationMu.Lock()
	defer c.taskMutationMu.Unlock()
	c.resetReady()
	c.inventoryEpochs = make(map[uint64]uint64)
	c.mu.Lock()
	c.subscribedRooms = make(map[uint64]bool)
	c.mu.Unlock()
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
	c.invalidateConnection()

	for {
		if ctx.Err() != nil {
			return
		}
		if err := c.connect(ctx); err != nil {
			slog.Error("NRC client connect failed", "error", err)
		} else {
			backoff = 1 * time.Second
			pingCtx, cancelPing := context.WithCancel(ctx)
			pingDone := make(chan struct{})
			go func() { defer close(pingDone); c.pingLoop(pingCtx) }()
			c.readPump(ctx)
			cancelPing()
			<-pingDone
		}

		select {
		case <-ctx.Done():
			return
		default:
		}

		slog.Info("reconnecting to NRC server", "backoff", backoff)
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

	conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if ctx.Err() != nil {
		conn.Close()
		return ctx.Err()
	}
	c.conn = conn

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
	if c.sendMessage != nil {
		return c.sendMessage(opcode, payload)
	}
	msg := &protocol.Message{Opcode: opcode, Data: payload}
	buf, err := msg.Write()
	if err != nil {
		return err
	}

	c.writeMu.Lock()
	if c.conn == nil {
		c.writeMu.Unlock()
		return fmt.Errorf("NRC connection unavailable")
	}
	c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	err = c.conn.WriteMessage(websocket.BinaryMessage, buf)
	c.writeMu.Unlock()
	return err
}

func (c *NRCClient) sendPing() {
	if err := c.sendProtocolMessage(protocol.C_Ping, protocol.EncodePing(time.Now().UnixMilli())); err != nil {
		slog.Debug("ping send failed", "error", err)
	}
}

func (c *NRCClient) readPump(ctx context.Context) {
	c.writeMu.Lock()
	conn := c.conn
	c.writeMu.Unlock()
	defer conn.Close()
	defer c.invalidateConnection()
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
				slog.Error("read error", "error", err)
			}
			return
		}

		conn.SetReadDeadline(time.Now().Add(60 * time.Second))

		msg, err := protocol.ReadMessage(data)
		if err != nil {
			slog.Warn("failed to parse protocol message", "error", err)
			continue
		}

		switch msg.Opcode {
		case protocol.S_ServerReady:
			c.handleServerReady(msg.Data)
		case protocol.S_Pong:
			c.handlePong(msg.Data)
		case protocol.S_AssetCreated:
			c.handleAssetCreated(msg.Data)
		case protocol.S_AssetUpdated:
			c.handleAssetUpdated(msg.Data)
		case protocol.S_AssetDeleted:
			c.handleAssetDeleted(msg.Data)
		case protocol.S_AssetListPage:
			c.handleAssetListPage(msg.Data)
		case protocol.S_TaskCreated:
			c.handleTaskCreated(msg.Data)
		case protocol.S_TaskUpdated:
			c.handleTaskUpdated(msg.Data)
		case protocol.S_TaskMoved:
			c.handleTaskMoved(ctx, msg.Data)
		case protocol.S_TaskDeleted:
			c.handleTaskDeleted(msg.Data)
		case protocol.S_TaskListPage:
			c.handleTaskListPage(msg.Data)
		case protocol.S_TaskFull:
			c.handleTaskFull(msg.Data)
		}
	}
}

func (c *NRCClient) handleServerReady(payload []byte) {
	if len(payload) < 2 {
		return
	}
	buildLen := int(binary.BigEndian.Uint16(payload[0:2]))
	offset := 2

	if len(payload) < offset+buildLen {
		return
	}
	buildVersion := string(payload[offset : offset+buildLen])
	offset += buildLen

	if len(payload) < offset+4 {
		return
	}
	protocolVersion := binary.BigEndian.Uint32(payload[offset:])
	offset += 4

	cpuModel := ""
	if len(payload) >= offset+2 {
		cpuLen := int(binary.BigEndian.Uint16(payload[offset:]))
		offset += 2
		if len(payload) >= offset+cpuLen {
			cpuModel = string(payload[offset : offset+cpuLen])
		}
	}

	slog.Info("NRC client ready",
		"build", buildVersion,
		"protocol_version", protocolVersion,
		"cpu", cpuModel,
	)

	c.closeReady()
}

func (c *NRCClient) handlePong(payload []byte) {
	if len(payload) < 8 {
		return
	}
	slog.Debug("pong received")
}

func (c *NRCClient) handleAssetCreated(payload []byte) {
	resp, err := protocol.DecodeAssetCreated(payload)
	if err != nil {
		slog.Warn("failed to decode asset created", "error", err)
		return
	}
	c.ingestAsset(resp.Asset, true, 0)
}

func (c *NRCClient) handleAssetUpdated(payload []byte) {
	resp, err := protocol.DecodeAssetUpdated(payload)
	if err != nil {
		slog.Warn("failed to decode asset updated", "error", err)
		return
	}
	c.ingestAsset(resp.Asset, true, 0)
}

func (c *NRCClient) reusableEmbedding(existing *IndexEntry, hash uint64) bool {
	if existing.ContentHash != hash {
		return false
	}
	if c.filesURL != "" {
		for _, attachment := range existing.Metadata.Attachments {
			if attachment.Status == "failed" || attachment.Status == "unavailable" || attachment.Status == "disabled" {
				return false
			}
		}
	}
	return true
}

func (c *NRCClient) ingestAsset(asset protocol.Asset, live bool, cutoff uint64) {
	c.taskMutationMu.Lock()
	defer c.taskMutationMu.Unlock()
	identity := assetIdentity(c.workspace, asset.AssetID, asset.ConvID)
	if live {
		c.taskMutations[identity.key()] = c.nextVersion.Add(1)
	} else if c.taskMutations[identity.key()] > cutoff {
		return
	}
	if !c.embedAssetTypes[asset.AssetType] {
		delete(c.expectedHashes, identity.key())
		c.index.Remove(c.workspace, asset.AssetID)
		_ = c.storage.DeleteQueueEntry(c.workspace, asset.AssetID)
		_ = c.storage.DeleteEmbedding(c.workspace, asset.AssetID)
		return
	}
	hash := document_content_hash(asset.Preview, asset.Payload, asset.Attachments...)
	c.expectedHashes[identity.key()] = hash
	if existing, ok := c.index.GetEntity(identity); ok && c.reusableEmbedding(existing, hash) {
		// A newer mutation can return to the already-indexed content while an
		// intermediate attachment job is pending. Cancel that stale work too.
		_ = c.storage.DeleteQueueEntry(c.workspace, asset.AssetID)
		return
	}
	entry := QueueEntry{ConvID: asset.ConvID, AssetType: asset.AssetType, Content: asset.Payload, Preview: asset.Preview, Attachments: append([]protocol.Attachment(nil), asset.Attachments...), Version: c.nextVersion.Add(1)}
	if err := c.storage.EnqueueAsset(c.workspace, asset.AssetID, entry); err != nil {
		slog.Error("enqueue asset", "asset_id", asset.AssetID, "error", err)
		return
	}
	c.signalPersistentQueue()
}

func (c *NRCClient) handleAssetDeleted(payload []byte) {
	resp, err := protocol.DecodeAssetDeleted(payload)
	if err != nil {
		slog.Warn("failed to decode asset deleted", "error", err)
		return
	}

	convID := resp.ConvID
	assetID := resp.AssetID

	slog.Debug("asset deleted", "asset_id", assetID, "conv_id", convID)

	c.taskMutationMu.Lock()
	defer c.taskMutationMu.Unlock()
	c.taskMutations[assetIdentity(c.workspace, assetID, convID).key()] = c.nextVersion.Add(1)
	delete(c.expectedHashes, assetIdentity(c.workspace, assetID, convID).key())
	c.index.Remove(c.workspace, assetID)
	_ = c.storage.DeleteQueueEntry(c.workspace, assetID)
	if err := c.storage.DeleteEmbedding(c.workspace, assetID); err != nil {
		slog.Error("failed to delete embedding", "asset_id", assetID, "error", err)
	}
}

func (c *NRCClient) signalPersistentQueue() {
	select {
	case c.diskSignal <- struct{}{}:
	default:
	}
}

func storedEmbeddingFromEntry(entry *IndexEntry) StoredEmbedding {
	return StoredEmbedding{
		ConvID: entry.ConvID, ContentHash: entry.ContentHash, Vector: entry.Vector,
		Chunks: storedChunksFromIndex(entry.Chunks), AssetType: entry.AssetType,
		Preview: entry.Preview, Payload: entry.Payload, Metadata: entry.Metadata,
		SearchText: entry.SearchText,
	}
}

func (c *NRCClient) persistTaskMetadata(identity EntityIdentity, metadata SearchMetadata) bool {
	if existing, ok := c.index.GetEntity(identity); ok {
		metadata.Attachments = existing.Metadata.Attachments
	}
	_, found, err := c.storage.UpdateEntityEmbeddingMetadataAndCancelQueue(identity, metadata)
	if err != nil {
		slog.Error("failed to persist task metadata", "identity", identity, "error", err)
		return false
	}
	if !found {
		return false
	}
	c.index.UpdateEntityMetadata(identity, metadata, time.Now())
	return true
}

func (c *NRCClient) ingestTask(task *protocol.Task, live bool, reconcileCutoff uint64, signal bool) (*EmbedJob, error) {
	if task == nil || task.ID == 0 || task.ConvID < 0 {
		return nil, fmt.Errorf("invalid task identity")
	}
	identity := taskIdentity(c.workspace, task.ID, uint64(task.ConvID))
	if live {
		c.taskMutationMu.Lock()
		defer c.taskMutationMu.Unlock()
		version := c.nextVersion.Add(1)
		c.taskMutations[identity.key()] = version
	} else {
		c.taskMutationMu.Lock()
		defer c.taskMutationMu.Unlock()
		if c.taskMutations[identity.key()] > reconcileCutoff {
			return nil, nil
		}
	}
	return c.ingestTaskLocked(task, identity, signal)
}

func (c *NRCClient) ingestTaskLocked(task *protocol.Task, identity EntityIdentity, signal bool) (*EmbedJob, error) {
	if !c.embedTasks {
		delete(c.expectedHashes, identity.key())
		delete(c.unresolvedTasks, identity.key())
		c.index.RemoveEntity(identity)
		_ = c.storage.DeleteEntityState(identity)
		return nil, nil
	}

	preview, content := taskEmbeddingContent(task)
	metadata := taskMetadata(task)
	hash := document_content_hash(preview, content, task.Attachments...)
	c.expectedHashes[identity.key()] = hash
	if existing, ok := c.index.GetEntity(identity); ok && c.reusableEmbedding(existing, hash) {
		if c.persistTaskMetadata(identity, metadata) {
			delete(c.unresolvedTasks, identity.key())
			return nil, nil
		}
	}
	entry := QueueEntry{
		ConvID: identity.ConvID, Content: content, Preview: preview,
		Metadata: metadata, Version: c.nextVersion.Add(1),
		Attachments: append([]protocol.Attachment(nil), task.Attachments...),
	}
	if err := c.storage.EnqueueEntity(identity, entry); err != nil {
		return nil, fmt.Errorf("enqueue task %v: %w", identity, err)
	}
	delete(c.unresolvedTasks, identity.key())
	if signal {
		c.signalPersistentQueue()
	}
	return &EmbedJob{Workspace: c.workspace, Identity: identity, Entry: entry}, nil
}

func (c *NRCClient) handleTaskCreated(payload []byte) {
	response, err := protocol.DecodeTaskCreated(payload)
	if err != nil {
		slog.Warn("failed to decode task created", "error", err)
		return
	}
	if _, err := c.ingestTask(response.Task, true, 0, true); err != nil {
		slog.Warn("failed to ingest created task", "error", err)
	}
}

func (c *NRCClient) handleTaskUpdated(payload []byte) {
	response, err := protocol.DecodeTaskUpdated(payload)
	if err != nil {
		slog.Warn("failed to decode task updated", "error", err)
		return
	}
	if _, err := c.ingestTask(response.Task, true, 0, true); err != nil {
		slog.Warn("failed to ingest updated task", "error", err)
	}
}

func (c *NRCClient) handleTaskMoved(ctx context.Context, payload []byte) {
	response, err := protocol.DecodeTaskMoved(payload)
	if err != nil {
		slog.Warn("failed to decode task moved", "error", err)
		return
	}
	identity := taskIdentity(c.workspace, response.TaskID, response.ConvID)
	c.taskMutationMu.Lock()
	version := c.nextVersion.Add(1)
	c.taskMutations[identity.key()] = version
	if _, queued, queueErr := c.storage.GetEntityQueueEntry(identity); queueErr != nil {
		slog.Error("failed to inspect queued moved task", "identity", identity, "error", queueErr)
	} else if queued {
		c.unresolvedTasks[identity.key()] = version
		c.taskMutationMu.Unlock()
		c.startTaskRefresh(ctx, identity, version)
		return
	}
	if existing, ok := c.index.GetEntity(identity); ok && existing.Metadata.Task != nil {
		metadata := existing.Metadata
		copy := *metadata.Task
		copy.Status = response.Status
		copy.OrderIndex = response.OrderIndex
		copy.CompletedAt = response.CompletedAt
		copy.CompletedBy = response.CompletedBy
		metadata.Task = &copy
		if c.persistTaskMetadata(identity, metadata) {
			delete(c.unresolvedTasks, identity.key())
			c.taskMutationMu.Unlock()
			return
		}
	}
	c.unresolvedTasks[identity.key()] = version
	c.taskMutationMu.Unlock()
	c.startTaskRefresh(ctx, identity, version)
}

func (c *NRCClient) handleTaskDeleted(payload []byte) {
	response, err := protocol.DecodeTaskDeleted(payload)
	if err != nil {
		slog.Warn("failed to decode task deleted", "error", err)
		return
	}
	identity := taskIdentity(c.workspace, response.TaskID, response.ConvID)
	c.taskMutationMu.Lock()
	defer c.taskMutationMu.Unlock()
	version := c.nextVersion.Add(1)
	c.taskMutations[identity.key()] = version
	if err := c.storage.DeleteEntityState(identity); err != nil {
		slog.Error("failed to delete task state", "identity", identity, "error", err)
		return
	}
	c.index.RemoveEntity(identity)
	delete(c.expectedHashes, identity.key())
	delete(c.unresolvedTasks, identity.key())
}

func (c *NRCClient) handleTaskListPage(payload []byte) {
	page, err := protocol.DecodeTaskListPage(payload)
	if page == nil {
		slog.Warn("failed to decode task list page", "error", err)
		return
	}
	c.pendingTaskPagesMu.Lock()
	channel := c.pendingTaskPages[page.CorrelationID]
	delete(c.pendingTaskPages, page.CorrelationID)
	c.pendingTaskPagesMu.Unlock()
	if channel != nil {
		channel <- page
	} else if err != nil {
		slog.Warn("task list page failed", "error", err)
	}
}

func (c *NRCClient) handleTaskFull(payload []byte) {
	response, err := protocol.DecodeTaskFull(payload)
	if response == nil {
		slog.Warn("failed to decode task full", "error", err)
		return
	}
	c.pendingTaskFullMu.Lock()
	channel := c.pendingTaskFull[response.CorrelationID]
	delete(c.pendingTaskFull, response.CorrelationID)
	c.pendingTaskFullMu.Unlock()
	if channel != nil {
		channel <- response
	} else if err != nil {
		slog.Warn("task full request failed", "error", err)
	}
}

func (c *NRCClient) handleAssetListPage(payload []byte) {
	resp, err := protocol.DecodeAssetListPage(payload)
	if err != nil {
		convID := uint64(0)
		if len(payload) >= 8 {
			convID = binary.BigEndian.Uint64(payload[0:8])
		}
		slog.Error("failed to decode asset list page", "conv_id", convID, "error", err)

		if len(payload) >= 8 {
			c.pendingReconcilePageMu.Lock()
			ch, ok := c.pendingReconcilePage[convID]
			if ok {
				delete(c.pendingReconcilePage, convID)
			}
			c.pendingReconcilePageMu.Unlock()

			if ok {
				close(ch)
			}
		}
		return
	}

	slog.Debug("asset list page received", "conv_id", resp.ConvID, "count", len(resp.Assets), "has_more", resp.HasMore, "full_content", resp.FullContent)

	c.pendingReconcilePageMu.Lock()
	ch, ok := c.pendingReconcilePage[resp.ConvID]
	if ok {
		delete(c.pendingReconcilePage, resp.ConvID)
	}
	c.pendingReconcilePageMu.Unlock()

	if ok {
		ch <- resp
	}
}

func (c *NRCClient) sendSubscribeConvs(convIDs []uint64) {
	roomIDs := make([]int64, len(convIDs))
	for i, id := range convIDs {
		roomIDs[i] = int64(id)
	}

	payload := protocol.EncodeSubscribeConvs(roomIDs...)
	if err := c.sendProtocolMessage(protocol.C_SubscribeConvs, payload); err != nil {
		slog.Error("failed to send subscribe", "error", err)
	}
}

func (c *NRCClient) sendListAssetsPaged(convID uint64, assetType uint16, fullContent bool, limit uint16, hasCursor bool, cursorUpdatedAt int64, cursorAssetID uint64) {
	payload := protocol.EncodeListAssetsPagedWithCorrelation(int64(convID), assetType, fullContent, limit, hasCursor, cursorUpdatedAt, cursorAssetID, 0)
	if err := c.sendProtocolMessage(protocol.C_ListAssetsPaged, payload); err != nil {
		slog.Error("failed to send list assets paged", "error", err)
	}
}

const reconcileListTimeout = 30 * time.Second

// Full asset payloads can approach the protocol's 64 KiB per-asset limit, while
// NRC WebSocket frames are capped at 128 KiB. Fetch one asset per page so a
// reconciliation response cannot exceed the frame limit.
const reconcileAssetPageLimit = 1

func (c *NRCClient) requestAssetListPage(ctx context.Context, convID uint64, assetType uint16, fullContent bool, limit uint16, hasCursor bool, cursorUpdatedAt int64, cursorAssetID uint64) (*protocol.AssetListPageResponse, error) {
	ch := make(chan *protocol.AssetListPageResponse, 1)

	c.pendingReconcilePageMu.Lock()
	c.pendingReconcilePage[convID] = ch
	c.pendingReconcilePageMu.Unlock()

	c.sendListAssetsPaged(convID, assetType, fullContent, limit, hasCursor, cursorUpdatedAt, cursorAssetID)

	select {
	case resp, ok := <-ch:
		if !ok {
			return nil, fmt.Errorf("asset list page request aborted for conv_id %d", convID)
		}
		return resp, nil
	case <-ctx.Done():
		c.pendingReconcilePageMu.Lock()
		delete(c.pendingReconcilePage, convID)
		c.pendingReconcilePageMu.Unlock()
		return nil, ctx.Err()
	case <-time.After(reconcileListTimeout):
		c.pendingReconcilePageMu.Lock()
		delete(c.pendingReconcilePage, convID)
		c.pendingReconcilePageMu.Unlock()
		return nil, fmt.Errorf("asset list page request timeout for conv_id %d", convID)
	}
}

func (c *NRCClient) fetchReconcileAssets(ctx context.Context, convID uint64) ([]protocol.Asset, error) {
	embedTypes := make([]uint16, 0, len(c.embedAssetTypes))
	for t := range c.embedAssetTypes {
		embedTypes = append(embedTypes, t)
	}
	sort.Slice(embedTypes, func(i, j int) bool { return embedTypes[i] < embedTypes[j] })

	assets := make([]protocol.Asset, 0)
	for _, assetType := range embedTypes {
		hasCursor := false
		var cursorUpdatedAt int64
		var cursorAssetID uint64
		for {
			page, err := c.requestAssetListPage(ctx, convID, assetType, true, reconcileAssetPageLimit, hasCursor, cursorUpdatedAt, cursorAssetID)
			if err != nil {
				return nil, fmt.Errorf("list assets type %d paged failed: %w", assetType, err)
			}
			assets = append(assets, page.Assets...)
			if !page.HasMore {
				break
			}
			hasCursor = true
			cursorUpdatedAt = page.NextCursorUpdatedAt
			cursorAssetID = page.NextCursorAssetID
		}
	}

	return assets, nil
}

const reconcileTaskPageLimit = protocol.MaxTaskPageSize
const allTaskStatusesMask uint8 = (1 << (protocol.TaskStatusNote + 1)) - 1

func (c *NRCClient) correlationID() uint32 {
	id := c.nextCorrelation.Add(1)
	if id == 0 {
		id = c.nextCorrelation.Add(1)
	}
	return id
}

func (c *NRCClient) requestTaskPage(ctx context.Context, convID uint64, cursor *protocol.TaskPageCursor) (*protocol.TaskListPage, error) {
	correlationID := c.correlationID()
	payload, err := protocol.EncodeListTasksPaged(convID, allTaskStatusesMask, reconcileTaskPageLimit, cursor, correlationID)
	if err != nil {
		return nil, err
	}
	channel := make(chan *protocol.TaskListPage, 1)
	c.pendingTaskPagesMu.Lock()
	c.pendingTaskPages[correlationID] = channel
	c.pendingTaskPagesMu.Unlock()
	removePending := func() {
		c.pendingTaskPagesMu.Lock()
		delete(c.pendingTaskPages, correlationID)
		c.pendingTaskPagesMu.Unlock()
	}
	if err := c.sendProtocolMessage(protocol.C_ListTasksPaged, payload); err != nil {
		removePending()
		return nil, fmt.Errorf("send task page request: %w", err)
	}
	timer := time.NewTimer(reconcileListTimeout)
	defer timer.Stop()
	select {
	case page := <-channel:
		if !page.Success {
			return nil, fmt.Errorf("task page request failed: %s", page.ErrorMessage)
		}
		return page, nil
	case <-ctx.Done():
		removePending()
		return nil, ctx.Err()
	case <-timer.C:
		removePending()
		return nil, fmt.Errorf("task page request timeout for conv_id %d", convID)
	}
}

func (c *NRCClient) fetchReconcileTasks(ctx context.Context, convID uint64) ([]*protocol.Task, error) {
	var tasks []*protocol.Task
	var cursor *protocol.TaskPageCursor
	for {
		page, err := c.requestTaskPage(ctx, convID, cursor)
		if err != nil {
			return nil, err
		}
		for _, task := range page.Tasks {
			if task.ConvID != int64(convID) {
				return nil, fmt.Errorf("task %d belongs to conv_id %d, requested %d", task.ID, task.ConvID, convID)
			}
			tasks = append(tasks, task)
		}
		if !page.HasMore {
			return tasks, nil
		}
		if cursor != nil && *cursor == page.NextCursor {
			return nil, fmt.Errorf("task pagination cursor did not advance for conv_id %d", convID)
		}
		next := page.NextCursor
		cursor = &next
	}
}

func (c *NRCClient) requestTaskFull(ctx context.Context, identity EntityIdentity) (*protocol.Task, error) {
	correlationID := c.correlationID()
	channel := make(chan *protocol.TaskFull, 1)
	c.pendingTaskFullMu.Lock()
	c.pendingTaskFull[correlationID] = channel
	c.pendingTaskFullMu.Unlock()
	removePending := func() {
		c.pendingTaskFullMu.Lock()
		delete(c.pendingTaskFull, correlationID)
		c.pendingTaskFullMu.Unlock()
	}
	if err := c.sendProtocolMessage(protocol.C_GetTask, protocol.EncodeGetTask(identity.ConvID, identity.EntityID, correlationID)); err != nil {
		removePending()
		return nil, fmt.Errorf("send get task request: %w", err)
	}
	timer := time.NewTimer(reconcileListTimeout)
	defer timer.Stop()
	select {
	case response := <-channel:
		if !response.Success || response.Task == nil {
			return nil, fmt.Errorf("get task failed: %s", response.ErrorMessage)
		}
		return response.Task, nil
	case <-ctx.Done():
		removePending()
		return nil, ctx.Err()
	case <-timer.C:
		removePending()
		return nil, fmt.Errorf("get task timeout for conv_id %d task_id %d", identity.ConvID, identity.EntityID)
	}
}

func (c *NRCClient) refreshTask(ctx context.Context, identity EntityIdentity, expectedVersion uint64) {
	task, err := c.requestTaskFull(ctx, identity)
	if err != nil {
		slog.Warn("failed to refresh partially cached moved task", "identity", identity, "error", err)
		return
	}
	if task.ID != identity.EntityID || task.ConvID < 0 || uint64(task.ConvID) != identity.ConvID {
		slog.Warn("task refresh identity mismatch", "requested", identity, "task_id", task.ID, "conv_id", task.ConvID)
		return
	}
	c.taskMutationMu.Lock()
	defer c.taskMutationMu.Unlock()
	if version, pending := c.unresolvedTasks[identity.key()]; !pending || version != expectedVersion || c.taskMutations[identity.key()] != expectedVersion {
		return
	}
	if _, err := c.ingestTaskLocked(task, identity, true); err != nil {
		slog.Warn("failed to ingest refreshed task", "identity", identity, "error", err)
	}
}

func (c *NRCClient) IsSubscribed(convID uint64) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.subscribedRooms[convID]
}

func (c *NRCClient) NeedsReconcile(convID uint64, interval time.Duration) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	lastSync, ok := c.roomSyncTimes[convID]
	if !ok {
		return true
	}
	return time.Since(lastSync) > interval
}

func (c *NRCClient) SubscribeAndReconcile(ctx context.Context, convID uint64) error {
	c.mu.Lock()
	if state, ok := c.reconcileDone[convID]; ok {
		c.mu.Unlock()
		select {
		case <-state.done:
			return state.err
		case <-ctx.Done():
			return ctx.Err()
		}
	}

	wasSubscribed := c.subscribedRooms[convID]
	state := &reconcileState{done: make(chan struct{})}
	c.reconcileDone[convID] = state
	c.subscribedRooms[convID] = true
	c.mu.Unlock()

	if !wasSubscribed {
		c.sendSubscribeConvs([]uint64{convID})
	}

	err := c.Reconcile(ctx, convID)

	c.mu.Lock()
	state.err = err
	delete(c.reconcileDone, convID)
	if err != nil && !wasSubscribed {
		c.subscribedRooms[convID] = false
	}
	close(state.done)
	c.mu.Unlock()

	return err
}

// Enumeration and deletion share the commit lock: a recovered queue job cannot
// slip into the index between the two inventories. Only live events newer than
// the server snapshot preserve absent records, not recent embedding timestamps.
func (c *NRCClient) cleanupReconciledScope(convID uint64, entityType EntityType, serverIDs map[uint64]struct{}, cutoff uint64) (int, error) {
	c.taskMutationMu.Lock()
	defer c.taskMutationMu.Unlock()
	stale := make(map[entityKey]EntityIdentity)
	for _, identity := range c.index.StaleEntityIdentities(c.workspace, convID, entityType, serverIDs, time.Time{}) {
		stale[identity.key()] = identity
	}
	queued, err := c.storage.EntityQueueIdentities(c.workspace, entityType, convID)
	if err != nil {
		return 0, fmt.Errorf("enumerate stale queue: %w", err)
	}
	addAbsent := func(key entityKey) {
		if key.ConvID == convID && key.EntityType == entityType {
			if _, exists := serverIDs[key.EntityID]; !exists {
				stale[key] = EntityIdentity{Workspace: c.workspace, EntityType: entityType, ConvID: convID, EntityID: key.EntityID}
			}
		}
	}
	for _, identity := range queued {
		addAbsent(identity.key())
	}
	for key := range c.expectedHashes {
		addAbsent(key)
	}
	for key := range c.unresolvedTasks {
		addAbsent(key)
	}
	removed := 0
	for key, identity := range stale {
		if c.taskMutations[key] > cutoff {
			continue
		}
		if err := c.storage.DeleteEntityState(identity); err != nil {
			return removed, fmt.Errorf("delete stale record %v: %w", identity, err)
		}
		c.index.RemoveEntity(identity)
		delete(c.expectedHashes, key)
		delete(c.unresolvedTasks, key)
		removed++
	}
	return removed, nil
}

func (c *NRCClient) Reconcile(ctx context.Context, convID uint64) error {
	c.taskMutationMu.Lock()
	taskMutationCutoff := c.nextVersion.Load()
	epoch := c.ReadyGeneration()
	c.taskMutationMu.Unlock()

	assets, err := c.fetchReconcileAssets(ctx, convID)
	if err != nil {
		return err
	}
	var tasks []*protocol.Task
	if c.embedTasks {
		tasks, err = c.fetchReconcileTasks(ctx, convID)
		if err != nil {
			return fmt.Errorf("list tasks paged failed: %w", err)
		}
	}

	serverAssetIDs := make(map[uint64]struct{}, len(assets))

	for _, asset := range assets {
		serverAssetIDs[asset.AssetID] = struct{}{}
		c.ingestAsset(asset, false, taskMutationCutoff)
	}

	removedAssets, err := c.cleanupReconciledScope(convID, EntityTypeAsset, serverAssetIDs, taskMutationCutoff)
	if err != nil {
		return err
	}

	serverTaskIDs := make(map[uint64]struct{}, len(tasks))
	for _, task := range tasks {
		serverTaskIDs[task.ID] = struct{}{}
		job, ingestErr := c.ingestTask(task, false, taskMutationCutoff, false)
		if ingestErr != nil {
			return fmt.Errorf("ingest reconciled task %d: %w", task.ID, ingestErr)
		}
		if job == nil {
			continue
		}
		if len(job.Entry.Attachments) > 0 {
			// Like assets, attachment-bearing tasks enrich asynchronously. Never
			// put downloads/media inference on a search request's reconciliation path.
			c.signalPersistentQueue()
			continue
		}
		if !c.processEmbedJob(*job) {
			c.signalPersistentQueue()
			return fmt.Errorf("embed reconciled task %d", task.ID)
		}
		entry, ok := c.index.GetEntity(job.Identity)
		if !ok || entry.ContentHash != document_content_hash(job.Entry.Preview, job.Entry.Content, job.Entry.Attachments...) {
			return fmt.Errorf("commit reconciled task %d", task.ID)
		}
	}
	removedTasks, err := c.cleanupReconciledScope(convID, EntityTypeTask, serverTaskIDs, taskMutationCutoff)
	if err != nil {
		return err
	}

	c.taskMutationMu.Lock()
	if epoch != c.ReadyGeneration() {
		c.taskMutationMu.Unlock()
		return fmt.Errorf("connection changed during reconciliation")
	}
	c.inventoryEpochs[convID] = epoch
	c.taskMutationMu.Unlock()

	now := time.Now()
	c.mu.Lock()
	c.roomSyncTimes[convID] = now
	c.mu.Unlock()

	if err := c.storage.SetRoomSync(c.workspace, convID, RoomSyncState{LastFullSync: now}); err != nil {
		slog.Error("reconcile: failed to persist room sync time", "conv_id", convID, "error", err)
	}

	slog.Info("reconcile complete",
		"conv_id", convID,
		"server_assets", len(assets),
		"removed", removedAssets,
		"server_tasks", len(tasks),
		"removed_tasks", removedTasks,
	)

	return nil
}

func (c *NRCClient) DrainEmbedQueue(ctx context.Context) {
	// Drain persistent queues from previous runs (peek + process + delete).
	for {
		if ctx.Err() != nil {
			return
		}
		identity, entityEntry, entityOK, entityErr := c.storage.PeekEntityQueueEntry(c.workspace)
		if entityErr != nil {
			slog.Error("failed to peek persistent entity queue", "error", entityErr)
			break
		}
		if entityOK {
			if !c.processEmbedJob(EmbedJob{Workspace: c.workspace, Identity: identity, Entry: entityEntry}) {
				c.schedulePersistentQueueRetry()
				break
			}
			continue
		}
		assetID, entry, ok, err := c.storage.PeekQueueEntry(c.workspace)
		if err != nil {
			slog.Error("failed to peek persistent queue", "error", err)
			break
		}
		if !ok {
			break
		}
		slog.Debug("draining persistent queue", "asset_id", assetID)
		if !c.processEmbedJob(EmbedJob{Workspace: c.workspace, AssetID: assetID, Entry: entry}) {
			slog.Warn("startup drain: embed failed, remaining items will retry via disk signal")
			c.schedulePersistentQueueRetry()
			break
		}
	}

	for {
		select {
		case <-ctx.Done():
			return
		case job := <-c.embedCh:
			if !c.processEmbedJob(job) {
				c.schedulePersistentQueueRetry()
			}
		case <-c.diskSignal:
			c.drainPersistentQueue()
		}
	}
}

func (c *NRCClient) closeConnection() {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if c.conn != nil {
		c.conn.Close()
	}
}

func (c *NRCClient) startTaskRefresh(ctx context.Context, identity EntityIdentity, version uint64) {
	c.refreshWorkers.Add(1)
	go func() { defer c.refreshWorkers.Done(); c.refreshTask(ctx, identity, version) }()
}

func (c *NRCClient) drainPersistentQueue() {
	const batchSize = 50
	for i := 0; i < batchSize; i++ {
		identity, entityEntry, entityOK, entityErr := c.storage.PeekEntityQueueEntry(c.workspace)
		if entityErr != nil {
			slog.Error("failed to peek persistent entity queue", "error", entityErr)
			return
		}
		if entityOK {
			if !c.processEmbedJob(EmbedJob{Workspace: c.workspace, Identity: identity, Entry: entityEntry}) {
				c.schedulePersistentQueueRetry()
				return
			}
			continue
		}
		assetID, entry, ok, err := c.storage.PeekQueueEntry(c.workspace)
		if err != nil {
			slog.Error("failed to peek persistent queue", "error", err)
			return
		}
		if !ok {
			return
		}
		slog.Debug("draining persistent queue", "asset_id", assetID)
		if !c.processEmbedJob(EmbedJob{Workspace: c.workspace, AssetID: assetID, Entry: entry}) {
			c.schedulePersistentQueueRetry()
			return
		}
	}
	// Signal again if there might be more items
	select {
	case c.diskSignal <- struct{}{}:
	default:
	}
}

const persistentQueueRetryDelay = 250 * time.Millisecond

func (c *NRCClient) schedulePersistentQueueRetry() {
	if !c.queueRetryArmed.CompareAndSwap(false, true) {
		return
	}
	time.AfterFunc(persistentQueueRetryDelay, func() {
		c.queueRetryArmed.Store(false)
		c.signalPersistentQueue()
	})
}

const maxEmbedRetries = 3

// processEmbedJob returns true if the queue entry was consumed (success or permanent failure),
// false if it should be retried later (transient failure).
func (c *NRCClient) processEmbedJob(job EmbedJob) bool {
	identity := job.identity()
	searchableContent := searchableAssetContent(job.Entry.AssetType, job.Entry.Preview, job.Entry.Content)
	// Hash the source payload, not only extracted HTML text. Styling and script
	// changes must still refresh the stored canonical payload even when they do
	// not change the text sent to the embedder.
	hash := document_content_hash(job.Entry.Preview, job.Entry.Content, job.Entry.Attachments...)

	if identity.EntityType == EntityTypeTask {
		c.taskMutationMu.Lock()
		if existing, ok := c.index.GetEntity(identity); ok && c.reusableEmbedding(existing, hash) {
			embedding := storedEmbeddingFromEntry(existing)
			embedding.Metadata = job.Entry.Metadata
			embedding.Metadata.Attachments = existing.Metadata.Attachments
			committed, err := c.storage.CommitEntityEmbedding(identity, job.Entry, embedding)
			if err != nil {
				c.taskMutationMu.Unlock()
				slog.Error("failed to commit task metadata", "identity", identity, "error", err)
				return false
			}
			if committed {
				c.index.UpdateEntityMetadata(identity, embedding.Metadata, time.Now())
			}
			c.taskMutationMu.Unlock()
			c.clearRetries(job)
			return true
		}
		c.taskMutationMu.Unlock()
	} else if existing, ok := c.index.GetEntity(identity); ok {
		if c.reusableEmbedding(existing, hash) {
			slog.Debug("skipping already-indexed asset", "asset_id", job.AssetID)
			if _, err := c.storage.DeleteEntityQueueEntryIfCurrent(identity, job.Entry); err != nil {
				slog.Error("failed to delete queue entry", "asset_id", job.AssetID, "error", err)
			}
			c.clearRetries(job)
			return true
		}
	}

	start := time.Now()
	chunks, vec, err := embedDocumentChunks(c.embedder, job.Entry.Preview, searchableContent)
	if err != nil {
		retries := c.incrementRetries(job)
		if retries >= maxEmbedRetries {
			slog.Error("embedding failed, max retries exceeded, dropping from queue",
				"asset_id", job.AssetID, "retries", retries, "error", err)
			if _, deleteErr := c.storage.DeleteEntityQueueEntryIfCurrent(identity, job.Entry); deleteErr != nil {
				slog.Error("failed to delete queue entry", "identity", identity, "error", deleteErr)
			}
			c.clearRetries(job)
			return true
		}
		slog.Warn("embedding failed, will retry",
			"asset_id", job.AssetID, "retries", retries, "max", maxEmbedRetries, "error", err)
		return false
	}

	attachmentChunks, attachmentText, attachmentStatuses := c.embedAttachments(job.Entry.Attachments)
	chunks = append(chunks, attachmentChunks...)
	for i := range chunks {
		chunks[i].Index = i
	}
	if len(attachmentChunks) > 0 {
		vec = aggregateChunkVectors(chunks)
	}
	if attachmentText != "" {
		searchableContent += "\n" + attachmentText
	}
	metadata := job.Entry.Metadata
	metadata.Attachments = attachmentStatuses
	slog.Info("embedded asset", "asset_id", job.AssetID, "chunks", len(chunks), "content_len", len(job.Entry.Content), "duration", time.Since(start).Round(time.Millisecond))

	emb := StoredEmbedding{
		ConvID:      job.Entry.ConvID,
		ContentHash: hash,
		Vector:      vec,
		Chunks:      storedChunksFromIndex(chunks),
		AssetType:   job.Entry.AssetType,
		Preview:     job.Entry.Preview,
		Payload:     job.Entry.Content,
		Metadata:    metadata,
		SearchText:  searchableContent,
	}
	c.taskMutationMu.Lock()
	defer c.taskMutationMu.Unlock()
	committed, err := c.storage.CommitEntityEmbedding(identity, job.Entry, emb)
	if err != nil {
		slog.Error("commit embedding", "identity", identity, "error", err)
		return false
	}
	if !committed {
		c.clearRetries(job)
		c.signalPersistentQueue()
		return true
	}
	indexEntry := indexEntryFromStoredEmbedding(emb)
	indexEntry.IndexedAt = time.Now()
	if err := c.index.AddEntity(identity, indexEntry); err != nil {
		slog.Error("publish embedding", "identity", identity, "error", err)
		return false
	}

	c.clearRetries(job)
	return true
}

func embedDocumentChunks(embedder Embedder, preview, content string) ([]IndexChunk, []float32, error) {
	docChunks := chunkDocumentForEmbedding(content)
	if len(docChunks) == 0 {
		docChunks = []DocumentChunk{{Index: 0, Text: strings.TrimSpace(content)}}
	}

	chunks := make([]IndexChunk, 0, len(docChunks))
	for _, chunk := range docChunks {
		text := format_document_for_embedding(preview, chunk.Text)
		vec, err := embedder.Embed(text)
		if err != nil {
			return nil, nil, err
		}
		chunks = append(chunks, IndexChunk{Index: chunk.Index, Vector: vec})
	}

	vec := aggregateChunkVectors(chunks)
	if len(vec) == 0 {
		fallbackVec, err := embedder.Embed(format_document_for_embedding(preview, content))
		if err != nil {
			return nil, nil, err
		}
		vec = fallbackVec
	}
	return chunks, vec, nil
}

func (c *NRCClient) retryKey(job EmbedJob) embedRetryKey {
	return embedRetryKey{Entity: job.identity().key(), Version: job.Entry.Version}
}

func (c *NRCClient) incrementRetries(job EmbedJob) int {
	c.embedRetriesMu.Lock()
	defer c.embedRetriesMu.Unlock()
	key := c.retryKey(job)
	c.embedRetries[key]++
	return c.embedRetries[key]
}

func (c *NRCClient) clearRetries(job EmbedJob) {
	c.embedRetriesMu.Lock()
	defer c.embedRetriesMu.Unlock()
	delete(c.embedRetries, c.retryKey(job))
}

func contentHash(data []byte) uint64 {
	h := fnv.New64a()
	h.Write(data)
	return h.Sum64()
}
